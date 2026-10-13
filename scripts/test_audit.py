"""Offline tests for audit decisions and pagination; no AWS SDK needed."""
import ast
import hashlib
import importlib.util
import json
import unittest
from datetime import datetime, timezone
from pathlib import Path

path = Path(__file__).with_name("audit_orders.py")
spec = importlib.util.spec_from_file_location("audit_orders", path)
audit_orders = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit_orders)


class FakeTable:
    def __init__(self, items=None, rows=None):
        self.items = items or {}
        self.rows = rows or []

    def get_item(self, Key, ConsistentRead):
        self.assert_consistent(ConsistentRead)
        value = self.items.get(next(iter(Key.values())))
        return {"Item": value} if value is not None else {}

    @staticmethod
    def assert_consistent(value):
        if not value:
            raise AssertionError("Use consistent per-item reads.")

    def scan(self, **kwargs):
        start = (kwargs.get("ExclusiveStartKey") or {}).get("offset", 0)
        # Small pages force the audit to exercise pagination.
        end = min(start + min(kwargs["Limit"], 2), len(self.rows))
        result = {"Items": self.rows[start:end], "ScannedCount": end - start}
        if end < len(self.rows):
            result["LastEvaluatedKey"] = {"offset": end}
        return result


class AuditTests(unittest.TestCase):
    def setUp(self):
        self.now = datetime(2026, 10, 12, 12, 0, tzinfo=timezone.utc)
        self.detail = {"event_id": "event-1", "order_id": "order-1", "items": [{"product_id": "p1", "quantity": 3}]}
        self.row = {
            "event_id": "event-1", "created_at": "2026-10-12T10:00:00+00:00",
            "detail_json": json.dumps(self.detail)
        }
        fingerprint = hashlib.sha256(json.dumps(self.detail, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
        self.tables = {
            "outbox": FakeTable(rows=[self.row]),
            "orders": FakeTable({"order-1": {"status": "PROCESSING"}}),
            "processed": FakeTable({"event-1": {"event_hash": fingerprint}}),
            "notifications": FakeTable({"event-1": {"event_hash": fingerprint, "delivery_status": "PENDING"}}),
            "analytics": FakeTable({"event-1": {"event_hash": fingerprint}})
        }

    def run_audit(self, **kwargs):
        return audit_orders.audit(self.tables, self.now, **kwargs)

    def test_healthy_pipeline_with_email_disabled(self):
        self.assertEqual(self.run_audit()["finding_count"], 0)

    def test_missing_analytics_is_reported(self):
        self.tables["analytics"].items = {}
        report = self.run_audit()
        self.assertEqual(report["findings"][0]["component"], "analytics")
        self.assertEqual(report["findings"][0]["kind"], "missing_consumer_record")

    def test_created_order_is_stalled(self):
        self.tables["orders"].items["order-1"]["status"] = "CREATED"
        self.assertEqual(self.run_audit()["findings"][0]["kind"], "order_not_started")

    def test_recent_event_is_not_flagged(self):
        self.row["created_at"] = "2026-10-12T11:59:00+00:00"
        self.tables["analytics"].items = {}
        self.assertEqual(self.run_audit()["events_checked"], 0)

    def test_since_excludes_predeployment_events(self):
        since = datetime(2026, 10, 12, 11, 0, tzinfo=timezone.utc)
        self.assertEqual(self.run_audit(since=since)["events_checked"], 0)

    def test_enabled_email_pending_is_reported(self):
        self.assertEqual(self.run_audit(include_email=True)["findings"][0]["kind"], "email_pending")

    def test_new_notification_from_old_replay_gets_grace(self):
        self.tables["notifications"].items["event-1"]["recorded_at"] = "2026-10-12T11:59:00+00:00"
        self.assertEqual(self.run_audit(include_email=True)["finding_count"], 0)

    def test_stale_email_claim_is_reported(self):
        self.tables["notifications"].items["event-1"].update(
            delivery_status="SENDING", attempt_started_at="2026-10-12T10:05:00+00:00"
        )
        self.assertEqual(self.run_audit(include_email=True)["findings"][0]["kind"], "email_stale_sending")

    def test_payload_fingerprint_mismatch_is_reported(self):
        self.tables["analytics"].items["event-1"]["event_hash"] = "wrong"
        self.assertEqual(self.run_audit()["findings"][0]["kind"], "fingerprint_mismatch")

    def test_pagination_and_cap_are_explicit(self):
        self.tables["outbox"].rows = [self.row.copy() for _ in range(5)]
        complete = self.run_audit(max_rows=10)
        self.assertEqual(complete["rows_scanned"], 5)
        self.assertFalse(complete["truncated"])
        limited = self.run_audit(max_rows=3)
        self.assertEqual(limited["rows_scanned"], 3)
        self.assertTrue(limited["truncated"])

    def test_aws_operations_are_read_only(self):
        tree = ast.parse(path.read_text())
        names = {node.func.attr for node in ast.walk(tree) if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)}
        for operation in ("put_item", "update_item", "delete_item", "put_events", "send_email", "invoke", "publish"):
            self.assertNotIn(operation, names)


if __name__ == "__main__":
    unittest.main()
