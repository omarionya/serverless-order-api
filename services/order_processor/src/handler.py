import hashlib
import json
import logging
import os
import uuid
from datetime import datetime, timezone

import boto3
from boto3.dynamodb.types import TypeSerializer
from botocore.exceptions import ClientError

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)
dynamodb = boto3.resource("dynamodb")
transaction_client = boto3.client("dynamodb")
serializer = TypeSerializer()


def typed_item(item):
    return {key: serializer.serialize(value) for key, value in item.items()}


def parse_event(record):
    envelope = json.loads(record["body"])
    if not isinstance(envelope, dict):
        raise ValueError("SQS body must contain an EventBridge event object.")
    if envelope.get("source") != "com.example.orders":
        raise ValueError("Unexpected event source.")
    if envelope.get("detail-type") != "OrderCreated":
        raise ValueError("Unexpected event type.")

    detail = envelope.get("detail")
    if not isinstance(detail, dict):
        raise ValueError("Event detail must be an object.")
    if type(detail.get("schema_version")) is not int or detail["schema_version"] != 1:
        raise ValueError("Unsupported schema version.")
    for key in ("event_id", "order_id", "customer_id", "created_at"):
        value = detail.get(key)
        if not isinstance(value, str) or not 1 <= len(value) <= 128:
            raise ValueError(f"Missing or invalid {key}.")
    created_at = datetime.fromisoformat(detail["created_at"])
    if created_at.tzinfo is None:
        raise ValueError("created_at must include its timezone.")
    if detail.get("status") != "CREATED":
        raise ValueError("OrderCreated must describe a CREATED order.")

    items = detail.get("items")
    if not isinstance(items, list) or not 1 <= len(items) <= 100:
        raise ValueError("Invalid order items.")
    for item in items:
        if not isinstance(item, dict) or set(item) != {"product_id", "quantity"}:
            raise ValueError("Invalid item structure.")
        if (
            not isinstance(item["product_id"], str)
            or not 1 <= len(item["product_id"].strip()) <= 128
        ):
            raise ValueError("Invalid product ID.")
        if type(item["quantity"]) is not int or not 1 <= item["quantity"] <= 1000:
            raise ValueError("Invalid quantity.")
    return detail


def was_processed(table, event_id, fingerprint):
    existing = table.get_item(Key={"event_id": event_id}, ConsistentRead=True).get("Item")
    if existing is None:
        return False
    if existing["event_hash"] != fingerprint:
        raise ValueError("This event_id was already processed with different content.")
    return True


def process_record(record):
    detail = parse_event(record)
    # Ignore EventBridge envelope id/time when deduplicating: republishing
    # generates a new envelope, but detail.event_id and its payload stay stable.
    event_id = detail["event_id"]
    fingerprint = hashlib.sha256(
        json.dumps(detail, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    processed = dynamodb.Table(os.environ["PROCESSED_EVENTS_TABLE"])

    if was_processed(processed, event_id, fingerprint):
        logger.info("Duplicate skipped: event_id=%s", event_id)
        return

    processed_at = datetime.now(timezone.utc).isoformat()
    dedupe_record = {
        "event_id": event_id,
        "event_hash": fingerprint,
        "order_id": detail["order_id"],
        "processed_at": processed_at,
    }

    try:
        # Marking the event processed and changing the order are atomic.
        # Do not replace this with a dedupe write followed by a separate update.
        transaction_client.transact_write_items(
            ClientRequestToken=str(uuid.uuid4()),
            TransactItems=[
                {
                    "Put": {
                        "TableName": os.environ["PROCESSED_EVENTS_TABLE"],
                        "Item": typed_item(dedupe_record),
                        "ConditionExpression": "attribute_not_exists(event_id)",
                    }
                },
                {
                    "Update": {
                        "TableName": os.environ["ORDERS_TABLE"],
                        "Key": {"order_id": {"S": detail["order_id"]}},
                        "UpdateExpression": "SET #status = :processing, processing_event_id = :event, processing_started_at = :now",
                        "ConditionExpression": "attribute_exists(order_id) AND #status = :created AND customer_id = :customer AND created_at = :created_at AND #items = :items",
                        "ExpressionAttributeNames": {"#status": "status", "#items": "items"},
                        "ExpressionAttributeValues": {
                            ":processing": {"S": "PROCESSING"},
                            ":created": {"S": "CREATED"},
                            ":customer": {"S": detail["customer_id"]},
                            ":created_at": {"S": detail["created_at"]},
                            ":items": serializer.serialize(detail["items"]),
                            ":event": {"S": event_id},
                            ":now": {"S": processed_at},
                        },
                    }
                },
            ],
        )
    except ClientError as error:
        # Another invocation may have processed the same event concurrently.
        if error.response["Error"]["Code"] == "TransactionCanceledException":
            if was_processed(processed, event_id, fingerprint):
                logger.info("Concurrent duplicate skipped: event_id=%s", event_id)
                return
        # Missing/stale orders, transaction conflicts and permission failures
        # must be retried rather than acknowledged as successfully processed.
        raise

    logger.info("Order processing started: order_id=%s event_id=%s", detail["order_id"], event_id)


def lambda_handler(event, context):
    failures = []
    for record in event.get("Records", []):
        try:
            process_record(record)
        except Exception:
            logger.exception("Order processing failed: message_id=%s", record["messageId"])
            failures.append({"itemIdentifier": record["messageId"]})
    # Lambda deletes successes and retries only these failed SQS messages.
    return {"batchItemFailures": failures}
