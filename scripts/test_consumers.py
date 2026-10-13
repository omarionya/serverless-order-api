"""Offline tests: application behavior only; AWS clients are mocked."""
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
config = types.ModuleType("botocore.config")
config.Config = MagicMock()


class ClientError(Exception):
    def __init__(self, response):
        self.response = response
        super().__init__(str(response))


errors = types.ModuleType("botocore.exceptions")
errors.ClientError = ClientError
sys.modules.update({
    "boto3": sdk, "botocore": types.ModuleType("botocore"),
    "botocore.config": config, "botocore.exceptions": errors
})
root = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


consumer = load("consumer", root / "services/event_consumer/src/handler.py")
sender = load("sender", root / "services/email_sender/src/handler.py")


class ConsumerTests(unittest.TestCase):
    def setUp(self):
        env = patch.dict(os.environ, {
            "RECORDS_TABLE": "notifications", "CONSUMER_KIND": "notifications"
        })
        env.start()
        self.addCleanup(env.stop)
        consumer.dynamodb = MagicMock()
        self.table = consumer.dynamodb.Table.return_value
        self.table.get_item.return_value = {}
        log = patch.object(consumer.logger, "exception")
        log.start()
        self.addCleanup(log.stop)
        self.detail = {
            "schema_version": 1, "event_id": "stable-1", "order_id": "order-1",
            "customer_id": "customer-1", "created_at": "2026-10-12T12:00:00+00:00",
            "status": "CREATED", "items": [{"product_id": "p1", "quantity": 3}]
        }
        self.event = {
            "source": "com.example.orders", "detail-type": "OrderCreated",
            "id": "envelope-1", "detail": self.detail
        }

    def record(self):
        return {"messageId": "m1", "body": json.dumps(self.event)}

    def stored(self):
        return {"Item": {"event_hash": hashlib.sha256(
            json.dumps(self.detail, sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest()}}

    def test_notification_saved_pending_once(self):
        result = consumer.lambda_handler({"Records": [self.record()]}, None)
        self.assertEqual(result, {"batchItemFailures": []})
        args = self.table.put_item.call_args.kwargs
        self.assertEqual(args["Item"]["delivery_status"], "PENDING")
        self.assertEqual(args["ConditionExpression"], "attribute_not_exists(event_id)")
        self.assertEqual(args["Item"]["total_units"], 3)

    def test_analytics_saves_fact_without_delivery_status(self):
        os.environ["CONSUMER_KIND"] = "analytics"
        consumer.lambda_handler({"Records": [self.record()]}, None)
        item = self.table.put_item.call_args.kwargs["Item"]
        self.assertNotIn("delivery_status", item)
        self.assertEqual(item["event_type"], "OrderCreated")

    def test_replay_skips_writes_even_with_new_envelope_id(self):
        self.table.get_item.return_value = self.stored()
        self.event["id"] = "replay-envelope"
        result = consumer.lambda_handler({"Records": [self.record()]}, None)
        self.assertEqual(result, {"batchItemFailures": []})
        self.table.put_item.assert_not_called()

    def test_event_id_reused_with_changed_content_fails(self):
        self.table.get_item.return_value = self.stored()
        self.detail["items"][0]["quantity"] = 9
        result = consumer.lambda_handler({"Records": [self.record()]}, None)
        self.assertEqual(result["batchItemFailures"], [{"itemIdentifier": "m1"}])

    def test_concurrent_conditional_write_is_deduplicated(self):
        self.table.get_item.side_effect = [{}, self.stored()]
        self.table.put_item.side_effect = ClientError({"Error": {"Code": "ConditionalCheckFailedException"}})
        self.assertEqual(consumer.lambda_handler({"Records": [self.record()]}, None), {"batchItemFailures": []})

    def test_only_bad_message_is_retried(self):
        result = consumer.lambda_handler({"Records": [self.record(), {"messageId": "bad", "body": "{"}]}, None)
        self.assertEqual(result["batchItemFailures"], [{"itemIdentifier": "bad"}])


class SenderTests(unittest.TestCase):
    def setUp(self):
        env = patch.dict(os.environ, {
            "NOTIFICATIONS_TABLE": "notifications", "COGNITO_POOL_ID": "pool",
            "SES_SENDER_EMAIL": "sender@example.com"
        })
        env.start()
        self.addCleanup(env.stop)
        sender.cognito = MagicMock()
        sender.ses = MagicMock()
        sender.ses.send_email.return_value = {"MessageId": "ses-1"}
        sender.cognito.list_users.return_value = {"Users": [{"Attributes": [
            {"Name": "sub", "Value": "customer-1"},
            {"Name": "email", "Value": "customer@example.com"},
            {"Name": "email_verified", "Value": "true"}
        ]}]}
        self.table = MagicMock()
        self.item = {"event_id": "stable-1", "customer_id": "customer-1", "order_id": "order-1", "total_units": 3}
        for method in ("error", "exception"):
            log = patch.object(sender.logger, method)
            log.start()
            self.addCleanup(log.stop)

    def test_claim_precedes_send_then_marks_sent(self):
        steps = []
        self.table.update_item.side_effect = lambda **kwargs: steps.append(
            "SENT" if ":sent" in kwargs["ExpressionAttributeValues"] else "SENDING"
        )
        def send(**kwargs):
            steps.append("SES")
            return {"MessageId": "ses-1"}
        sender.ses.send_email.side_effect = send
        sender.send_pending(self.table, self.item)
        self.assertEqual(steps, ["SENDING", "SES", "SENT"])
        last = self.table.update_item.call_args.kwargs["ExpressionAttributeValues"]
        self.assertEqual(last[":sent"], "SENT")
        self.assertEqual(last[":message"], "ses-1")

    def test_failed_claim_does_not_send(self):
        self.table.update_item.side_effect = ClientError({"Error": {"Code": "ConditionalCheckFailedException"}})
        sender.send_pending(self.table, self.item)
        sender.ses.send_email.assert_not_called()

    def test_ambiguous_send_failure_requires_review(self):
        sender.ses.send_email.side_effect = TimeoutError("Response lost")
        sender.send_pending(self.table, self.item)
        self.assertEqual(self.table.update_item.call_args.kwargs["ExpressionAttributeValues"][":review"], "REVIEW")
        sender.ses.send_email.assert_called_once()

    def test_sent_status_save_failure_requires_review_without_resend(self):
        self.table.update_item.side_effect = [{}, RuntimeError("Database unavailable"), {}]
        sender.send_pending(self.table, self.item)
        sender.ses.send_email.assert_called_once()
        self.assertEqual(self.table.update_item.call_args.kwargs["ExpressionAttributeValues"][":review"], "REVIEW")

    def test_unverified_email_is_failed_without_send(self):
        sender.cognito.list_users.return_value["Users"][0]["Attributes"][-1]["Value"] = "false"
        sender.send_pending(self.table, self.item)
        sender.ses.send_email.assert_not_called()
        self.assertEqual(self.table.update_item.call_args.kwargs["ExpressionAttributeValues"][":failed"], "FAILED")

    def test_worker_queries_only_pending_for_sending(self):
        sender.dynamodb = MagicMock()
        sender.dynamodb.Table.return_value.query.side_effect = [{"Items": []}, {"Items": []}]
        sender.lambda_handler({}, None)
        calls = sender.dynamodb.Table.return_value.query.call_args_list
        self.assertEqual(calls[1].kwargs["ExpressionAttributeValues"], {":pending": "PENDING"})
        sender.ses.send_email.assert_not_called()


if __name__ == "__main__":
    unittest.main()
