from __future__ import annotations

import json
import logging
import os
import re
from typing import Any, Protocol

import boto3

LOGGER = logging.getLogger("life_api.avatar_cleanup")
_KEY_SUFFIX = re.compile(r"^[0-9a-fA-F-]{36}\.webp$")


class Table(Protocol):
    def get_item(self, **kwargs: Any) -> dict[str, Any]: ...


class S3Client(Protocol):
    def delete_object(self, **kwargs: Any) -> dict[str, Any]: ...

    def put_object_tagging(self, **kwargs: Any) -> dict[str, Any]: ...


def handler(event: dict[str, Any], context: object) -> dict[str, list[dict[str, str]]]:
    del context
    table_name = os.environ["TABLE_NAME"]
    bucket_name = os.environ["AVATAR_BUCKET_NAME"]
    region = os.getenv("AWS_REGION", "ap-east-1")
    table = boto3.resource("dynamodb", region_name=region).Table(table_name)
    s3 = boto3.client("s3", region_name=region)
    failures: list[dict[str, str]] = []
    for record in event.get("Records", []):
        message_id = str(record.get("messageId", ""))
        try:
            _process(str(record["body"]), table, s3, bucket_name)
        except Exception:
            LOGGER.exception("Avatar cleanup delivery failed")
            failures.append({"itemIdentifier": message_id})
    return {"batchItemFailures": failures}


def _process(body: str, table: Table, s3: S3Client, bucket_name: str) -> None:
    payload = json.loads(body)
    if not isinstance(payload, dict) or set(payload) != {"ownerDigest", "key"}:
        raise ValueError("invalid avatar cleanup payload")
    owner_digest = payload["ownerDigest"]
    key = payload["key"]
    if (
        not isinstance(owner_digest, str)
        or not re.fullmatch(r"[0-9a-f]{64}", owner_digest)
        or not isinstance(key, str)
    ):
        raise ValueError("invalid avatar cleanup identity")
    prefix = f"avatars/{owner_digest}/"
    if not key.startswith(prefix) or not _KEY_SUFFIX.fullmatch(key.removeprefix(prefix)):
        raise ValueError("avatar cleanup key is outside its owner prefix")

    account = table.get_item(
        Key={"PK": f"ACCOUNT#{owner_digest}", "SK": "STATE"},
        ConsistentRead=True,
    ).get("Item")
    if isinstance(account, dict) and account.get("state") != "active":
        _delete(s3, bucket_name, key)
        return

    pointer = table.get_item(
        Key={"PK": f"ACCOUNT#{owner_digest}", "SK": "AVATAR"},
        ConsistentRead=True,
    ).get("Item")
    if isinstance(pointer, dict) and pointer.get("avatarKey") == key:
        _activate(s3, bucket_name, key)
        return
    _delete(s3, bucket_name, key)


def _delete(s3: S3Client, bucket_name: str, key: str) -> None:
    s3.delete_object(Bucket=bucket_name, Key=key)


def _activate(s3: S3Client, bucket_name: str, key: str) -> None:
    s3.put_object_tagging(
        Bucket=bucket_name,
        Key=key,
        Tagging={"TagSet": [{"Key": "state", "Value": "active"}]},
    )
