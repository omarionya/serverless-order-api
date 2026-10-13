"""Read-only, bounded cross-table audit. No AWS writes or event replay."""
import argparse
import hashlib
import json
import sys
from datetime import datetime, timezone
from pathlib import Path


def aware(value):
    parsed = datetime.fromisoformat(value)
    if parsed.tzinfo is None:
        raise ValueError("Timestamps must include a timezone.")
    return parsed


def audit(tables, now, min_age=600, since=None, max_rows=1000, include_email=False):
    if min_age < 0 or max_rows < 1:
        raise ValueError("min_age must be nonnegative and max_rows must be positive.")
    findings = []
    scanned = checked = 0
    start_key = None
    truncated = False

    def finding(kind, event_id, order_id, component=None):
        entry = {"kind": kind, "event_id": event_id, "order_id": order_id}
        if component:
            entry["component"] = component
        findings.append(entry)

    def get(table, key_name, key_value):
        return table.get_item(Key={key_name: key_value}, ConsistentRead=True).get("Item")

    while scanned < max_rows:
        request = {
            "Limit": min(100, max_rows - scanned),
            "ConsistentRead": True,
            "ProjectionExpression": "event_id, created_at, detail_json"
        }
        if start_key:
            request["ExclusiveStartKey"] = start_key
        page = tables["outbox"].scan(**request)
        rows = page.get("Items", [])
        scanned += page.get("ScannedCount", len(rows))
        for row in rows:
            event_id = row.get("event_id", "unknown")
            try:
                created = aware(row["created_at"])
                if since and created < since:
                    continue
                if (now - created).total_seconds() < min_age:
                    continue
                detail = json.loads(row["detail_json"])
                if not isinstance(detail, dict) or detail.get("event_id") != event_id:
                    raise ValueError("Invalid outbox detail.")
                order_id = detail["order_id"]
            except (ValueError, KeyError, TypeError):
                finding("invalid_outbox_record", event_id, None)
                continue
            checked += 1
            fingerprint = hashlib.sha256(
                json.dumps(detail, sort_keys=True, separators=(",", ":")).encode()
            ).hexdigest()
            order = get(tables["orders"], "order_id", order_id)
            if not order:
                finding("missing_order", event_id, order_id)
            elif order.get("status") == "CREATED":
                finding("order_not_started", event_id, order_id)

            for component in ("processed", "notifications", "analytics"):
                record = get(tables[component], "event_id", event_id)
                if not record:
                    finding("missing_consumer_record", event_id, order_id, component)
                    continue
                if record.get("event_hash") != fingerprint:
                    finding("fingerprint_mismatch", event_id, order_id, component)
                if component == "notifications" and include_email:
                    state = record.get("delivery_status")
                    if state in {"FAILED", "REVIEW"}:
                        finding("email_needs_review", event_id, order_id, state)
                    elif state == "PENDING":
                        # An older outbox event may have just been replayed.
                        # Give its newly recorded notification its own grace.
                        recorded = aware(record.get("recorded_at", row["created_at"]))
                        if (now - recorded).total_seconds() >= min_age:
                            finding("email_pending", event_id, order_id)
                    elif state == "SENDING":
                        try:
                            started = aware(record["attempt_started_at"])
                            stale = (now - started).total_seconds() >= min_age
                        except (ValueError, TypeError, KeyError):
                            stale = True
                        if stale:
                            finding("email_stale_sending", event_id, order_id)
                    elif state != "SENT":
                        finding("unknown_email_state", event_id, order_id)

        start_key = page.get("LastEvaluatedKey")
        if not start_key:
            break
        if not rows and not page.get("ScannedCount"):
            # Defensive guard: don't loop forever on an unexpected empty page.
            truncated = True
            break
        if scanned >= max_rows:
            truncated = True

    return {
        "audit_time": now.isoformat(),
        "rows_scanned": scanned,
        "events_checked": checked,
        "truncated": truncated,
        "finding_count": len(findings),
        "findings": findings
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for table in ("outbox", "orders", "processed", "notifications", "analytics"):
        parser.add_argument(f"--{table}-table")
    parser.add_argument("--config-json", help="JSON map of table names exported from the reconciliation_tables Terraform output.")
    parser.add_argument("--since", help="ISO timestamp with timezone; use the chunk 6 deployment time to exclude older events.")
    parser.add_argument("--min-age-seconds", type=int, default=600)
    parser.add_argument("--max-rows", type=int, default=1000)
    parser.add_argument("--include-email", action="store_true")
    parser.add_argument("--report", help="Optional local JSON output file.")
    args = parser.parse_args()
    configuration = json.loads(Path(args.config_json).read_text()) if args.config_json else {}
    names = {
        key: getattr(args, f"{key}_table") or configuration.get(key)
        for key in ("outbox", "orders", "processed", "notifications", "analytics")
    }
    if any(not isinstance(value, str) or not value for value in names.values()):
        parser.error("Supply all five table names through --config-json or individual --*-table arguments.")
    import boto3
    resource = boto3.resource("dynamodb")
    tables = {
        key: resource.Table(value) for key, value in names.items()
    }
    report = audit(
        tables, datetime.now(timezone.utc), args.min_age_seconds,
        aware(args.since) if args.since else None,
        args.max_rows, args.include_email
    )
    rendered = json.dumps(report, indent=2)
    if args.report:
        path = Path(args.report)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(rendered + "\n")
    print(rendered)
    return 2 if report["findings"] or report["truncated"] else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print(f"Audit failed: {error}", file=sys.stderr)
        sys.exit(1)
