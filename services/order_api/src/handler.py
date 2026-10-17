import base64
import binascii
import hashlib
import json
import logging
import os
import re
import time
import uuid
from datetime import datetime, timezone
from decimal import Decimal

import boto3
from boto3.dynamodb.types import TypeSerializer
from botocore.exceptions import ClientError

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)
dynamodb = boto3.resource("dynamodb")
transaction_client = boto3.client("dynamodb")
serializer = TypeSerializer()
IDEMPOTENCY_SECONDS = 86400


class ConflictError(Exception):
    pass


def json_default(value):
    if isinstance(value, Decimal):
        return int(value) if value == value.to_integral_value() else float(value)
    raise TypeError(f"Cannot serialize {type(value).__name__}")


def response(status_code, payload):
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(payload, default=json_default),
    }


def typed_item(item):
    return {key: serializer.serialize(value) for key, value in item.items()}


def authenticated_customer_id(event):
    claims = (event.get("requestContext", {}).get("authorizer", {}).get("claims", {})) or {}
    if not claims.get("sub"):
        raise PermissionError("Authentication is required.")
    return claims["sub"]


def parse_body(event):
    body = event.get("body")
    if not isinstance(body, str) or not body:
        raise ValueError("Request body is required.")
    if event.get("isBase64Encoded"):
        try:
            body = base64.b64decode(body, validate=True).decode("utf-8")
        except (binascii.Error, UnicodeDecodeError, ValueError):
            raise ValueError("Invalid encoded request body.")
    try:
        payload = json.loads(body)
    except json.JSONDecodeError:
        raise ValueError("Request body must contain valid JSON.")
    if not isinstance(payload, dict):
        raise ValueError("Request body must be a JSON object.")
    return payload


def validate_order(payload):
    # Hash only fields that affect the order. Reject unsupported fields so
    # callers cannot accidentally assume price/customer/status inputs are used.
    if set(payload) != {"items"}:
        raise ValueError("The request must contain only the items field.")
    items = payload["items"]
    if not isinstance(items, list) or not 1 <= len(items) <= 100:
        raise ValueError("items must contain between 1 and 100 products.")
    normalized = []
    for index, item in enumerate(items):
        if not isinstance(item, dict) or set(item) != {"product_id", "quantity"}:
            raise ValueError(f"items[{index}] must contain product_id and quantity only.")
        product_id = item["product_id"]
        quantity = item["quantity"]
        if not isinstance(product_id, str) or not 1 <= len(product_id.strip()) <= 128:
            raise ValueError(f"items[{index}].product_id must be 1-128 characters.")
        if type(quantity) is not int or not 1 <= quantity <= 1000:
            raise ValueError(f"items[{index}].quantity must be an integer from 1 to 1000.")
        normalized.append({"product_id": product_id.strip(), "quantity": quantity})
    return normalized


def idempotency_key(event):
    headers = {key.lower(): value for key, value in (event.get("headers") or {}).items()}
    key = headers.get("idempotency-key")
    if not isinstance(key, str) or not re.fullmatch(r"[A-Za-z0-9._:-]{1,128}", key):
        raise ValueError("Provide Idempotency-Key: 1-128 letters, digits, '.', '_', ':', or '-'.")
    return key


def existing_response(table, request_key, request_hash, now):
    result = table.get_item(Key={"request_key": request_key}, ConsistentRead=True)
    record = result.get("Item")
    # TTL deletion is asynchronous; expiration must be checked in application code.
    if not record or int(record["expires_at"]) <= now:
        return None
    if record["request_hash"] != request_hash:
        raise ConflictError("Idempotency-Key was already used with a different order.")
    return response(201, record["response"])


def create_order(event):
    customer_id = authenticated_customer_id(event)
    items = validate_order(parse_body(event))
    key = idempotency_key(event)
    now = int(time.time())
    # Separate idempotency namespaces for different authenticated customers.
    request_key = hashlib.sha256(json.dumps([customer_id, key]).encode()).hexdigest()
    request_hash = hashlib.sha256(
        json.dumps({"items": items}, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    idempotency = dynamodb.Table(os.environ["IDEMPOTENCY_TABLE"])

    replay = existing_response(idempotency, request_key, request_hash, now)
    if replay is not None:
        return replay

    order_id = str(uuid.uuid4())
    event_id = str(uuid.uuid4())
    created_at = datetime.now(timezone.utc).isoformat()
    order = {
        "order_id": order_id,
        "customer_id": customer_id,
        "items": items,
        "status": "CREATED",
        "created_at": created_at,
    }
    result = {"order_id": order_id, "status": "CREATED", "created_at": created_at}
    record = {
        "request_key": request_key,
        "request_hash": request_hash,
        "expires_at": now + IDEMPOTENCY_SECONDS,
        "response": result,
    }
    outbox = {
        "event_id": event_id,
        "source": "com.example.orders",
        "detail_type": "OrderCreated",
        "created_at": created_at,
        "detail_json": json.dumps({"schema_version": 1, "event_id": event_id, **order}),
    }

    try:
        transaction_client.transact_write_items(
            ClientRequestToken=order_id,
            TransactItems=[
                {
                    "Put": {
                        "TableName": os.environ["IDEMPOTENCY_TABLE"],
                        "Item": typed_item(record),
                        "ConditionExpression": "attribute_not_exists(request_key) OR expires_at <= :now",
                        "ExpressionAttributeValues": {":now": {"N": str(now)}},
                    }
                },
                {
                    "Put": {
                        "TableName": os.environ["ORDERS_TABLE"],
                        "Item": typed_item(order),
                        "ConditionExpression": "attribute_not_exists(order_id)",
                    }
                },
                {
                    "Put": {
                        "TableName": os.environ["OUTBOX_TABLE"],
                        "Item": typed_item(outbox),
                        "ConditionExpression": "attribute_not_exists(event_id)",
                    }
                },
            ],
        )
    except ClientError as error:
        # A concurrent request can win the conditional transaction. Read its
        # committed result instead of creating another order.
        if error.response["Error"]["Code"] == "TransactionCanceledException":
            replay = existing_response(idempotency, request_key, request_hash, int(time.time()))
            if replay is not None:
                return replay
        raise

    logger.info("Order committed: order_id=%s event_id=%s", order_id, event_id)
    return response(201, result)


def get_order(event):
    customer_id = authenticated_customer_id(event)
    order_id = (event.get("pathParameters") or {}).get("id")
    if not isinstance(order_id, str) or not order_id.strip():
        raise ValueError("Order ID is required.")
    result = dynamodb.Table(os.environ["ORDERS_TABLE"]).get_item(
        Key={"order_id": order_id}, ConsistentRead=True
    )
    order = result.get("Item")
    if not order or order.get("customer_id") != customer_id:
        return response(404, {"message": "Order not found."})
    return response(200, order)


def lambda_handler(event, context):
    try:
        route = (event.get("httpMethod"), event.get("resource"))
        if route == ("POST", "/orders"):
            return create_order(event)
        if route == ("GET", "/orders/{id}"):
            return get_order(event)
        return response(404, {"message": "Route not found."})
    except ConflictError as error:
        return response(409, {"message": str(error)})
    except ValueError as error:
        return response(400, {"message": str(error)})
    except PermissionError:
        return response(403, {"message": "Access denied."})
    except Exception:
        request_id = getattr(context, "aws_request_id", "local")
        logger.exception("Order API failed; request_id=%s", request_id)
        return response(500, {"message": "Internal server error.", "request_id": request_id})
