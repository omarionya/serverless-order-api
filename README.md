# Chunk 4: Idempotency and transactional outbox

This package extends the Terraform project from chunks 1-3. It is not a standalone root configuration. Use the existing `environment/dev` backend/provider/variables and keep the Cognito, REST API and WAF modules.

## What changes

```
POST /orders with Idempotency-Key + Cognito access token
  -> Order Lambda
  -> Atomic DynamoDB transaction:
       orders + idempotency + outbox
  -> Outbox DynamoDB Stream
  -> Publisher Lambda
  -> EventBridge custom bus
  -> Development verification SQS queue
```

- The same user, key and normalized body returns the same 201 response for 24 hours.
- Reusing a key with a different body during that window returns 409.
- Missing or malformed Idempotency-Key returns 400.
- Customer identity is taken from Cognito's `sub`, and GET retains ownership checks.
- The transaction saves all three items or none. The API does not directly publish events.
- A stream publisher checks EventBridge per-entry failures and reports the failing sequence number for retry.
- Stream batches that exhaust retries/age limits are retained with their full payload in S3.
- The verification queue is for dev inspection; service queues are added in chunk 5.

## 1. Copy the code

Copy the package's `modules/`, `services/`, and `scripts/` into the matching locations in your project. Replace the four files in `modules/database`, the four files in `modules/lambda`, and the Order API handler. Add the new modules and publisher handler. If you have already customized those files, merge the changes.

Resource addresses for the existing orders table and Order Lambda follow the earlier examples. Keep your existing table name and function name. Review the plan: the existing orders table should not be replaced or deleted. Existing orders are retained but do not receive retrospective outbox events.

## 2. Update dev wiring

Open `dev-wiring.tf.example`. Merge its module blocks into `environment/dev/main.tf`: replace the existing `database` and `order_lambda` blocks and add the two new blocks. Preserve any custom database settings you already use. Keep `auth`, `api`, and `waf` blocks.

Merge `dev-outputs.tf.example` into `environment/dev/outputs.tf`. Do not duplicate existing outputs. These example files are not automatically loaded by Terraform.

The root must declare the AWS and archive providers, as in chunk 2:

```hcl
terraform {
  required_version = ">= 1.10, < 2.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}
```

Do not add a second `required_providers` block if one already exists. Keep your existing AWS provider configuration and backend. Ensure `.gitignore` excludes `*.zip`, `*.tfplan`, local state, and `.terraform/`, but not `.terraform.lock.hcl`.

## 3. Deploy

Run from your project root, with your AWS profile selected:

```bash
terraform -chdir=environment/dev init
terraform fmt -recursive
terraform -chdir=environment/dev validate
terraform -chdir=environment/dev plan -out=dev.tfplan
terraform -chdir=environment/dev apply dev.tfplan
terraform -chdir=environment/dev output
```

Deploy before creating test orders. No AWS deployment has been performed by this package.

Offline application checks are included:

```bash
python3 scripts/test_handlers.py
```

Eight tests cover atomic-write intent, duplicate replay, changed-body conflicts, expiration, concurrent-request recovery, missing keys, customer ownership, and EventBridge entry failures. AWS SDK calls/serializers are mocked. Python syntax checks and Terraform formatting passed during preparation. Provider-backed Terraform validation could not run because this environment cannot access the Terraform registry; run `init` and `validate` in your project before applying.

## 4. Test idempotency in Postman

Use the existing API URL and an access token with `orders/write`.

```
POST <api_url>/orders
Content-Type: application/json
Authorization: Bearer <access-token>
Idempotency-Key: chunk4-order-001
```

Use raw JSON (not the Lambda-console envelope):

```json
{"items":[{"product_id":"product-001","quantity":2}]}
```

1. Send once: expect 201; note order_id and created_at.
2. Send the exact same request with the same key: expect 201 with the same order_id and created_at. One order/outbox event should have been created.
3. Change quantity to 3 while retaining the key: expect 409 and no new order.
4. Change the key to `chunk4-order-002`: expect a new order and event.
5. Remove the key: expect 400.
6. Optional concurrency test: send identical requests with a fresh key simultaneously. They must not create multiple orders. A transient transaction conflict can return 500; retry with the same key.

Idempotency is bounded to 24 hours. After expiry, the same key may create a new order. TTL deletion is asynchronous, so the handler checks expiry explicitly and conditionally replaces expired records. Keep the same key for retries of one logical order; generate a fresh key for a different order.

## 5. Verify the event

In DynamoDB, inspect the outbox table: find the event with your order_id inside `detail_json`, and note its stable `event_id`.

In Lambda -> publisher -> Monitor -> CloudWatch logs, expect `Published event_id=...`.

For an end-to-end delivery check, copy `verification_queue_url` from Terraform outputs:

```bash
aws sqs receive-message \
  --queue-url 'PASTE_VERIFICATION_QUEUE_URL' \
  --wait-time-seconds 20 \
  --max-number-of-messages 10
```

The calling AWS identity needs `sqs:ReceiveMessage`. Receiving temporarily hides messages; it does not delete them. The message Body contains the EventBridge envelope with `source=com.example.orders`, `detail-type=OrderCreated`, and `detail.event_id` plus the order fields. Use the SQS console to inspect/delete dev verification messages after testing.

The publisher is at-least-once. A crash after successful publication can cause publication again. Stream checkpoint retries can also repeat successful records. Consumers in chunk 5 must deduplicate using `detail.event_id`, not EventBridge's envelope `id`. Duplicate queue messages do not mean duplicate orders were created.

## 6. Test recovery in dev

1. In Terraform, temporarily change the publisher role's `events:PutEvents` statement from `Allow` to `Deny`; apply. Only do this in dev.
2. POST with a new key. The order still returns 201 because the event is committed to the outbox.
3. Inspect publisher logs: publication fails and records are retried.
4. Restore `Allow` and apply promptly. The stream should publish during retry.
5. If attempts/age have already been exhausted, inspect the output `publisher_failed_batches_bucket`. S3 objects contain failed invocation metadata and payload. The outbox item is retained independently.
6. Fix the cause, then explicitly republish the retained event by its stable event_id:

```bash
python3 -m venv .venv
.venv/bin/python -m pip install boto3
.venv/bin/python scripts/replay_outbox.py \
  --table 'PASTE_OUTBOX_TABLE_NAME' \
  --event-id 'PASTE_STABLE_EVENT_ID' \
  --bus 'PASTE_EVENT_BUS_NAME'
```

The replay operator needs `dynamodb:GetItem` on the outbox and `events:DescribeEventBus` / `events:PutEvents` on the bus. Replaying can duplicate delivery: downstream consumers must be idempotent. Do not bulk replay every outbox item.

## Operational limits

- DynamoDB Streams retain records for 24 hours. This mapping uses TRIM_HORIZON and retries up to 20 times / one-hour record age. Configure these limits for your eventual production recovery objective.
- Retained S3 failures preserve full records. An SQS stream failure destination would normally retain metadata rather than the complete payload.
- Outbox rows have no TTL and are not automatically removed or marked published. This deliberately preserves recovery data; add an audited retention/cleanup process before production. Failed batches also have no automatic expiry.
- EventBridge can silently drop events if the specified bus does not exist. Terraform wires the actual managed bus ARN to the publisher; don't manually replace its environment value with an arbitrary bus name.
- The EventBridge delivery DLQ handles failures delivering to the verification queue. It is separate from the publisher's S3 failure destination.
- The SDK is supplied by the Python Lambda runtime for this exercise. Pin and package dependencies for repeatable production builds.
- Full alarm notifications, automatic reconciliation, consumer processing, and CI/CD are subsequent milestones.

## Lambda console test

Save this as a POST test. Body must be a JSON string:

```json
{
  "httpMethod": "POST",
  "resource": "/orders",
  "headers": {"Idempotency-Key": "console-order-001"},
  "requestContext": {"authorizer": {"claims": {"sub": "test-customer-001"}}},
  "isBase64Encoded": false,
  "body": "{\"items\":[{\"product_id\":\"product-001\",\"quantity\":2}]}"
}
```

Repeated tests with the same key and customer must return the same order within the window. Test through API Gateway separately to verify real Cognito authorization.
