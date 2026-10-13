"""Offline unit tests. AWS SDK constructors and serializers are mocked.

These tests verify application control flow, not live AWS or SDK behavior.
Run: python3 scripts/test_handlers.py
"""
import importlib.util
import json
import os
import sys
import types
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

sdk = types.ModuleType("boto3")
sdk.resource = MagicMock()
sdk.client = MagicMock()
ddb_types = types.ModuleType("boto3.dynamodb.types")
ddb_types.TypeSerializer = MagicMock()
ddb_types.TypeDeserializer = MagicMock()


class ClientError(Exception):
    def __init__(self, response, operation_name="TransactWriteItems"):
        self.response = response
        super().__init__(str(response))


errors = types.ModuleType("botocore.exceptions")
errors.ClientError = ClientError
sys.modules.update({
    "boto3": sdk,
    "boto3.dynamodb": types.ModuleType("boto3.dynamodb"),
    "boto3.dynamodb.types": ddb_types,
    "botocore": types.ModuleType("botocore"),
    "botocore.exceptions": errors
})
root = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


api = load("api_handler", root / "services/order_api/src/handler.py")
publisher = load("publisher_handler", root / "services/outbox_publisher/src/handler.py")


class HandlerTests(unittest.TestCase):
    def setUp(self):
        self.env = patch.dict(os.environ, {
            "ORDERS_TABLE": "orders",
            "IDEMPOTENCY_TABLE": "idempotency",
            "OUTBOX_TABLE": "outbox",
            "EVENT_BUS_ARN": "test-bus"
        })
        self.env.start()
        self.addCleanup(self.env.stop)
        api.dynamodb = MagicMock()
        api.transaction_client = MagicMock()
        # Leave payloads plain to inspect transaction intent, not SDK encoding.
        api.serializer.serialize.side_effect = lambda value: value
        api.dynamodb.Table.return_value.get_item.return_value = {}
        self.event = {
            "httpMethod": "POST",
            "resource": "/orders",
            "headers": {"Idempotency-Key": "test-001"},
            "requestContext": {"authorizer": {"claims": {"sub": "customer-a"}}},
            "body": json.dumps({"items": [{"product_id": "p1", "quantity": 2}]})
        }

    def test_atomic_three_item_write(self):
        result = api.lambda_handler(self.event, None)
        self.assertEqual(result["statusCode"], 201)
        writes = api.transaction_client.transact_write_items.call_args.kwargs["TransactItems"]
        self.assertEqual([item["Put"]["TableName"] for item in writes], ["idempotency", "orders", "outbox"])
        order = writes[1]["Put"]["Item"]
        detail = json.loads(writes[2]["Put"]["Item"]["detail_json"])
        self.assertEqual(order["customer_id"], "customer-a")
        self.assertEqual(detail["order_id"], order["order_id"])
        self.assertEqual(detail["event_id"], writes[2]["Put"]["Item"]["event_id"])

    def replay_record(self):
        request_hash = api.hashlib.sha256(json.dumps(
            {"items": [{"product_id": "p1", "quantity": 2}]},
            sort_keys=True, separators=(",", ":")
        ).encode()).hexdigest()
        return {
            "expires_at": int(api.time.time()) + 1000,
            "request_hash": request_hash,
            "response": {"order_id": "original-order", "status": "CREATED", "created_at": "original-time"}
        }

    def test_retry_returns_original_without_writes(self):
        api.dynamodb.Table.return_value.get_item.return_value = {"Item": self.replay_record()}
        result = api.lambda_handler(self.event, None)
        self.assertEqual(json.loads(result["body"])["order_id"], "original-order")
        api.transaction_client.transact_write_items.assert_not_called()

    def test_changed_body_conflicts(self):
        api.dynamodb.Table.return_value.get_item.return_value = {"Item": self.replay_record()}
        self.event["body"] = json.dumps({"items": [{"product_id": "p1", "quantity": 3}]})
        self.assertEqual(api.lambda_handler(self.event, None)["statusCode"], 409)
        api.transaction_client.transact_write_items.assert_not_called()

    def test_expired_record_allows_new_transaction(self):
        record = self.replay_record()
        record["expires_at"] = int(api.time.time()) - 1
        api.dynamodb.Table.return_value.get_item.return_value = {"Item": record}
        self.assertEqual(api.lambda_handler(self.event, None)["statusCode"], 201)
        api.transaction_client.transact_write_items.assert_called_once()

    def test_concurrent_winner_is_replayed(self):
        api.dynamodb.Table.return_value.get_item.side_effect = [{}, {"Item": self.replay_record()}]
        api.transaction_client.transact_write_items.side_effect = ClientError({
            "Error": {"Code": "TransactionCanceledException"}
        })
        result = api.lambda_handler(self.event, None)
        self.assertEqual(json.loads(result["body"])["order_id"], "original-order")

    def test_missing_key_rejected_before_write(self):
        self.event["headers"] = {}
        self.assertEqual(api.lambda_handler(self.event, None)["statusCode"], 400)
        api.transaction_client.transact_write_items.assert_not_called()

    def test_cross_customer_read_hidden(self):
        api.dynamodb.Table.return_value.get_item.return_value = {"Item": {"customer_id": "customer-b"}}
        self.event.update(httpMethod="GET", resource="/orders/{id}", pathParameters={"id": "order-1"})
        self.assertEqual(api.lambda_handler(self.event, None)["statusCode"], 404)

    def test_failed_putevents_reports_stream_sequence(self):
        publisher.events = MagicMock()
        publisher.deserializer.deserialize.side_effect = lambda value: value
        publisher.events.put_events.return_value = {
            "FailedEntryCount": 1,
            "Entries": [{"ErrorCode": "InternalFailure"}]
        }
        record = {
            "eventName": "INSERT",
            "dynamodb": {
                "SequenceNumber": "123",
                "NewImage": {
                    "event_id": "stable-1", "source": "com.example.orders",
                    "detail_type": "OrderCreated", "detail_json": "{}",
                    "created_at": "2026-10-11T10:00:00+00:00"
                }
            }
        }
        with patch.object(publisher.logger, "exception"):
            result = publisher.lambda_handler({"Records": [record, record]}, None)
        self.assertEqual(result, {"batchItemFailures": [{"itemIdentifier": "123"}]})
        publisher.events.put_events.assert_called_once()


if __name__ == "__main__":
    unittest.main()
