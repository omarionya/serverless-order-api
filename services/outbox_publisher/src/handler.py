import json
import logging
import os
from datetime import datetime

import boto3
from boto3.dynamodb.types import TypeDeserializer

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)
events = boto3.client("events")
deserializer = TypeDeserializer()


def lambda_handler(event, context):
    # Stop at the first failure so Lambda retries from that stream checkpoint.
    for record in event.get("Records", []):
        if record.get("eventName") != "INSERT":
            continue
        sequence_number = record["dynamodb"]["SequenceNumber"]
        try:
            item = {
                key: deserializer.deserialize(value)
                for key, value in record["dynamodb"]["NewImage"].items()
            }
            result = events.put_events(Entries=[{
                "EventBusName": os.environ["EVENT_BUS_ARN"],
                "Source": item["source"],
                "DetailType": item["detail_type"],
                "Detail": item["detail_json"],
                "Time": datetime.fromisoformat(item["created_at"])
            }])
            # An HTTP 200 alone does not imply successful event publication.
            entry = result["Entries"][0]
            if result.get("FailedEntryCount", 0) or not entry.get("EventId"):
                raise RuntimeError(json.dumps(entry))
            logger.info("Published event_id=%s bridge_id=%s", item["event_id"], entry["EventId"])
        except Exception:
            logger.exception("Outbox publication failed; sequence_number=%s", sequence_number)
            return {"batchItemFailures": [{"itemIdentifier": sequence_number}]}
    return {"batchItemFailures": []}
