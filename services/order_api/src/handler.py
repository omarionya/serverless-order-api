import base64
import binascii
import json
import logging
import os
import uuid

from datetime import datetime, timezone
from decimal import Decimal

import boto3


logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

dynamodb = boto3.resource("dynamodb")


def json_default(value):
    if isinstance(value, Decimal):
        if value == value.to_integral_value():
            return int(value)
        return float(value)

    raise TypeError(f"Cannot serialize {type(value).__name__}")


def response(status_code, payload):
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json"
        },
        "body": json.dumps(payload, default=json_default)
    }


def parse_body(event):
    body = event.get("body")

    if not isinstance(body, str) or not body:
        raise ValueError("Request body is required.")

    if event.get("isBase64Encoded"):
        try:
            body = base64.b64decode(
                body, validate=True
            ).decode("utf-8")
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
    customer_id = payload.get("customer_id")

    if not isinstance(customer_id, str) or not customer_id.strip():
        raise ValueError("customer_id must be a non-empty string.")

    if len(customer_id.strip()) > 128:
        raise ValueError("customer_id must be at most 128 characters.")

    items = payload.get("items")

    if not isinstance(items, list) or not 1 <= len(items) <= 100:
        raise ValueError("items must contain between 1 and 100 products.")

    validated_items = []

    for index, item in enumerate(items):
        if not isinstance(item, dict):
            raise ValueError(f"items[{index}] must be an object.")

        product_id = item.get("product_id")
        quantity = item.get("quantity")

        if not isinstance(product_id, str) or not product_id.strip():
            raise ValueError(
                f"items[{index}].product_id must be a non-empty string."
            )

        if len(product_id.strip()) > 128:
            raise ValueError(
                f"items[{index}].product_id must be at most 128 characters."
            )

        if type(quantity) is not int or not 1 <= quantity <= 1000:
            raise ValueError(
                f"items[{index}].quantity must be an integer from 1 to 1000."
            )

        validated_items.append({
            "product_id": product_id.strip(),
            "quantity": quantity
        })

    return customer_id.strip(), validated_items


def create_order(event, table):
    payload = parse_body(event)
    customer_id, items = validate_order(payload)

    order = {
        "order_id": str(uuid.uuid4()),
        "customer_id": customer_id,
        "items": items,
        "status": "CREATED",
        "created_at": datetime.now(timezone.utc).isoformat()
    }

    table.put_item(
        Item=order,
        ConditionExpression="attribute_not_exists(order_id)"
    )

    logger.info("Order created: %s", order["order_id"])

    return response(201, {
        "order_id": order["order_id"],
        "status": order["status"],
        "created_at": order["created_at"]
    })


def get_order(event, table):
    parameters = event.get("pathParameters") or {}
    order_id = parameters.get("id")

    if not isinstance(order_id, str) or not order_id.strip():
        raise ValueError("Order ID is required.")

    result = table.get_item(
        Key={"order_id": order_id},
        ConsistentRead=True
    )

    order = result.get("Item")

    if order is None:
        return response(404, {"message": "Order not found."})

    return response(200, order)


def lambda_handler(event, context):
    request_id = getattr(context, "aws_request_id", "local")

    try:
        table = dynamodb.Table(os.environ["ORDERS_TABLE"])

        method = event.get("httpMethod")
        resource = event.get("resource")

        if method == "POST" and resource == "/orders":
            return create_order(event, table)

        if method == "GET" and resource == "/orders/{id}":
            return get_order(event, table)

        return response(404, {"message": "Route not found."})

    except ValueError as error:
        return response(400, {"message": str(error)})

    except Exception:
        logger.exception(
            "Order API failed; request_id=%s", request_id
        )

        return response(500, {
            "message": "Internal server error.",
            "request_id": request_id
        })