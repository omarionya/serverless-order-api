"""Explicitly republish one retained outbox event after fixing the failure."""

import argparse
import json
from datetime import datetime

import boto3

parser = argparse.ArgumentParser()
parser.add_argument("--table", required=True)
parser.add_argument("--event-id", required=True)
parser.add_argument("--bus", required=True)
args = parser.parse_args()

events = boto3.client("events")
# PutEvents can silently drop events sent to a nonexistent bus.
events.describe_event_bus(Name=args.bus)
item = (
    boto3.resource("dynamodb")
    .Table(args.table)
    .get_item(Key={"event_id": args.event_id}, ConsistentRead=True)
    .get("Item")
)
if not item:
    raise SystemExit("Outbox event not found.")

result = events.put_events(
    Entries=[
        {
            "EventBusName": args.bus,
            "Source": item["source"],
            "DetailType": item["detail_type"],
            "Detail": item["detail_json"],
            "Time": datetime.fromisoformat(item["created_at"]),
        }
    ]
)
if result.get("FailedEntryCount", 0) or not result["Entries"][0].get("EventId"):
    raise SystemExit(json.dumps(result))
print("Republished stable event_id:", item["event_id"])
