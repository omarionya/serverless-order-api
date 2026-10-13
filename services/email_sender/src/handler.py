import json
import logging
import os
import uuid
from datetime import datetime, timezone

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)
dynamodb = boto3.resource("dynamodb")
cognito = boto3.client("cognito-idp")
# SES SendEmail has no client idempotency token. Do not automatically retry
# ambiguous network failures that may already have accepted an email.
ses = boto3.client("ses", config=Config(
    connect_timeout=3, read_timeout=5, retries={"total_max_attempts": 1}
))


def timestamp():
    return datetime.now(timezone.utc).isoformat()


def recipient(customer_id):
    request = {
        "UserPoolId": os.environ["COGNITO_POOL_ID"],
        "Filter": f"sub = {json.dumps(customer_id)}",
        "Limit": 10
    }
    while True:
        result = cognito.list_users(**request)
        for user in result.get("Users", []):
            attributes = {item["Name"]: item["Value"] for item in user.get("Attributes", [])}
            if attributes.get("sub") != customer_id:
                continue
            if attributes.get("email_verified") != "true" or not attributes.get("email"):
                raise ValueError("Customer needs a verified Cognito email address.")
            return attributes["email"]
        if not result.get("PaginationToken"):
            raise ValueError("Customer not found in Cognito.")
        request["PaginationToken"] = result["PaginationToken"]


def send_pending(table, item):
    event_id = item["event_id"]
    # Resolve before claiming. No delivery attempt occurs on lookup failure.
    try:
        email = recipient(item["customer_id"])
    except ValueError as error:
        logger.error("Email requires review: event_id=%s reason=%s", event_id, error)
        try:
            table.update_item(
                Key={"event_id": event_id},
                UpdateExpression="SET delivery_status = :failed, delivery_error = :error",
                ConditionExpression="delivery_status = :pending",
                ExpressionAttributeValues={
                    ":failed": "FAILED", ":error": str(error), ":pending": "PENDING"
                }
            )
        except ClientError as conflict:
            if conflict.response["Error"]["Code"] != "ConditionalCheckFailedException":
                raise
        return

    attempt_id = str(uuid.uuid4())
    try:
        table.update_item(
            Key={"event_id": event_id},
            UpdateExpression="SET delivery_status = :sending, attempt_id = :attempt, attempt_started_at = :now",
            ConditionExpression="delivery_status = :pending",
            ExpressionAttributeValues={
                ":sending": "SENDING", ":pending": "PENDING",
                ":attempt": attempt_id, ":now": timestamp()
            }
        )
    except ClientError as conflict:
        if conflict.response["Error"]["Code"] == "ConditionalCheckFailedException":
            logger.info("Email claim skipped: event_id=%s", event_id)
            return
        raise

    message_id = None
    try:
        result = ses.send_email(
            Source=os.environ["SES_SENDER_EMAIL"],
            Destination={"ToAddresses": [email]},
            Message={
                "Subject": {"Data": f"Order received: {item['order_id']}", "Charset": "UTF-8"},
                "Body": {"Text": {
                    "Data": f"We received your order {item['order_id']}.\nTotal units: {item['total_units']}.\nThank you.",
                    "Charset": "UTF-8"
                }}
            }
        )
        message_id = result["MessageId"]
        table.update_item(
            Key={"event_id": event_id},
            UpdateExpression="SET delivery_status = :sent, ses_message_id = :message, sent_at = :now",
            ConditionExpression="delivery_status = :sending AND attempt_id = :attempt",
            ExpressionAttributeValues={
                ":sent": "SENT", ":sending": "SENDING", ":attempt": attempt_id,
                ":message": message_id, ":now": timestamp()
            }
        )
        logger.info("Email accepted by SES: event_id=%s message_id=%s", event_id, message_id)
    except Exception:
        # Failure may have happened after SES accepted the email, including
        # a failure saving SENT. Automatic resending could duplicate it.
        logger.exception("Email requires review: event_id=%s attempt_id=%s", event_id, attempt_id)
        review_expression = "SET delivery_status = :review, review_at = :now"
        review_values = {
            ":review": "REVIEW", ":sending": "SENDING",
            ":attempt": attempt_id, ":now": timestamp()
        }
        if message_id:
            review_expression += ", attempt_ses_message_id = :message"
            review_values[":message"] = message_id
        table.update_item(
            Key={"event_id": event_id},
            UpdateExpression=review_expression,
            ConditionExpression="delivery_status = :sending AND attempt_id = :attempt",
            ExpressionAttributeValues=review_values
        )


def lambda_handler(event, context):
    table = dynamodb.Table(os.environ["NOTIFICATIONS_TABLE"])
    # A hard timeout/crash after claiming leaves SENDING. Surface stale claims
    # for manual review without automatically repeating an uncertain send.
    sending = table.query(
        IndexName="delivery-status-index",
        KeyConditionExpression="delivery_status = :sending",
        ExpressionAttributeValues={":sending": "SENDING"},
        Limit=10,
        ScanIndexForward=True
    )
    for item in sending.get("Items", []):
        started = datetime.fromisoformat(item["attempt_started_at"])
        if (datetime.now(timezone.utc) - started).total_seconds() > 300:
            logger.error("Email requires review: stale SENDING event_id=%s", item["event_id"])
    result = table.query(
        IndexName="delivery-status-index",
        KeyConditionExpression="delivery_status = :pending",
        ExpressionAttributeValues={":pending": "PENDING"},
        Limit=int(os.environ.get("BATCH_LIMIT", "1")),
        ScanIndexForward=True
    )
    for item in result.get("Items", []):
        send_pending(table, item)
    return {"examined": len(result.get("Items", []))}
