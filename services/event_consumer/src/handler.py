import hashlib
import json
import logging
import os
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)
dynamodb = boto3.resource("dynamodb")


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


def duplicate(table, event_id, fingerprint):
    existing = table.get_item(Key={"event_id": event_id}, ConsistentRead=True).get("Item")
    if existing is None:
        return False
    if existing["event_hash"] != fingerprint:
        raise ValueError("event_id was already recorded with different content.")
    return True


def process_record(record):
    detail = parse_event(record)
    kind = os.environ["CONSUMER_KIND"]
    if kind not in {"notifications", "analytics"}:
        raise RuntimeError("Invalid CONSUMER_KIND configuration.")
    table = dynamodb.Table(os.environ["RECORDS_TABLE"])
    fingerprint = hashlib.sha256(
        json.dumps(detail, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    if duplicate(table, detail["event_id"], fingerprint):
        logger.info("Duplicate skipped: consumer=%s event_id=%s", kind, detail["event_id"])
        return

    item = {
        "event_id": detail["event_id"],
        "event_hash": fingerprint,
        "order_id": detail["order_id"],
        "customer_id": detail["customer_id"],
        "created_at": detail["created_at"],
        "recorded_at": datetime.now(timezone.utc).isoformat(),
        "items": detail["items"],
        "total_units": sum(product["quantity"] for product in detail["items"]),
    }
    if kind == "notifications":
        item.update(delivery_status="PENDING", notification_type="ORDER_CONFIRMATION")
    else:
        item.update(event_type="OrderCreated", schema_version=1)
    try:
        # The recorded fact/request IS the durable effect and dedupe marker.
        table.put_item(Item=item, ConditionExpression="attribute_not_exists(event_id)")
    except ClientError as error:
        if error.response["Error"]["Code"] == "ConditionalCheckFailedException":
            if duplicate(table, detail["event_id"], fingerprint):
                logger.info(
                    "Concurrent duplicate skipped: consumer=%s event_id=%s",
                    kind,
                    detail["event_id"],
                )
                return
        raise
    logger.info(
        "%s recorded: order_id=%s event_id=%s", kind, detail["order_id"], detail["event_id"]
    )


def lambda_handler(event, context):
    failures = []
    for record in event.get("Records", []):
        try:
            process_record(record)
        except Exception:
            logger.exception("Consumer failed: message_id=%s", record["messageId"])
            failures.append({"itemIdentifier": record["messageId"]})
    return {"batchItemFailures": failures}
