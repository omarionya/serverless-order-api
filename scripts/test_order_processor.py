"""Offline application-control-flow tests; SDK calls/encoding are mocked."""
import hashlib
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


class ClientError(Exception):
    def __init__(self, response):
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
path = Path(__file__).resolve().parents[1] / "services/order_processor/src/handler.py"
spec = importlib.util.spec_from_file_location("processor", path)
processor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(processor)


class ProcessorTests(unittest.TestCase):
    def setUp(self):
        env = patch.dict(os.environ, {"ORDERS_TABLE": "orders", "PROCESSED_EVENTS_TABLE": "processed"})
        env.start()
        self.addCleanup(env.stop)
        processor.dynamodb = MagicMock()
        processor.transaction_client = MagicMock()
        processor.serializer.serialize.side_effect = lambda value: value
        processor.dynamodb.Table.return_value.get_item.return_value = {}
        logging = patch.object(processor.logger, "exception")
        logging.start()
        self.addCleanup(logging.stop)
        self.detail = {
            "schema_version": 1, "event_id": "stable-event-1",
            "order_id": "order-1", "customer_id": "customer-1",
            "created_at": "2026-10-12T10:00:00+00:00",
            "status": "CREATED", "items": [{"product_id": "p1", "quantity": 2}]
        }
        self.envelope = {
            "id": "envelope-1", "source": "com.example.orders",
            "detail-type": "OrderCreated", "detail": self.detail
        }

    def record(self, message_id="message-1"):
        return {"messageId": message_id, "body": json.dumps(self.envelope)}

    def stored(self):
        return {"Item": {"event_hash": hashlib.sha256(
            json.dumps(self.detail, sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest()}}

    def test_atomic_dedupe_and_order_update(self):
        result = processor.lambda_handler({"Records": [self.record()]}, None)
        self.assertEqual(result, {"batchItemFailures": []})
        writes = processor.transaction_client.transact_write_items.call_args.kwargs["TransactItems"]
        self.assertEqual(len(writes), 2)
        self.assertEqual(writes[0]["Put"]["Item"]["event_id"], "stable-event-1")
        update = writes[1]["Update"]
        self.assertEqual(update["Key"]["order_id"]["S"], "order-1")
        self.assertEqual(update["ExpressionAttributeValues"][":processing"], {"S": "PROCESSING"})
        self.assertIn("#status = :created", update["ConditionExpression"])
        self.assertIn("customer_id = :customer", update["ConditionExpression"])

    def test_duplicate_skips_all_writes(self):
        processor.dynamodb.Table.return_value.get_item.return_value = self.stored()
        self.assertEqual(processor.lambda_handler({"Records": [self.record()]}, None), {"batchItemFailures": []})
        processor.transaction_client.transact_write_items.assert_not_called()

    def test_new_envelope_id_still_deduplicates(self):
        processor.dynamodb.Table.return_value.get_item.return_value = self.stored()
        self.envelope["id"] = "new-envelope-from-replay"
        self.assertEqual(processor.lambda_handler({"Records": [self.record()]}, None), {"batchItemFailures": []})
        processor.transaction_client.transact_write_items.assert_not_called()

    def test_same_event_id_changed_payload_is_rejected(self):
        processor.dynamodb.Table.return_value.get_item.return_value = self.stored()
        self.detail["items"][0]["quantity"] = 3
        result = processor.lambda_handler({"Records": [self.record()]}, None)
        self.assertEqual(result, {"batchItemFailures": [{"itemIdentifier": "message-1"}]})
        processor.transaction_client.transact_write_items.assert_not_called()

    def test_concurrent_winner_is_acknowledged(self):
        processor.dynamodb.Table.return_value.get_item.side_effect = [{}, self.stored()]
        processor.transaction_client.transact_write_items.side_effect = ClientError({
            "Error": {"Code": "TransactionCanceledException"}
        })
        self.assertEqual(processor.lambda_handler({"Records": [self.record()]}, None), {"batchItemFailures": []})

    def test_failed_transaction_is_not_acknowledged(self):
        processor.transaction_client.transact_write_items.side_effect = ClientError({
            "Error": {"Code": "TransactionCanceledException"}
        })
        result = processor.lambda_handler({"Records": [self.record()]}, None)
        self.assertEqual(result, {"batchItemFailures": [{"itemIdentifier": "message-1"}]})

    def test_mixed_batch_only_reports_failed_message(self):
        bad = {"messageId": "bad-1", "body": "{"}
        result = processor.lambda_handler({"Records": [self.record(), bad]}, None)
        self.assertEqual(result, {"batchItemFailures": [{"itemIdentifier": "bad-1"}]})
        processor.transaction_client.transact_write_items.assert_called_once()

    def test_unknown_schema_is_rejected_before_database(self):
        self.detail["schema_version"] = 2
        result = processor.lambda_handler({"Records": [self.record()]}, None)
        self.assertEqual(result, {"batchItemFailures": [{"itemIdentifier": "message-1"}]})
        processor.dynamodb.Table.assert_not_called()


if __name__ == "__main__":
    unittest.main()
