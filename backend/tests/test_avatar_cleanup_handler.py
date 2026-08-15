from __future__ import annotations

import hashlib
import json
from typing import Any

from life_api.avatar_cleanup_handler import _process


class MemoryTable:
    def __init__(self, items: dict[tuple[str, str], dict[str, Any]]) -> None:
        self.items = items

    def get_item(self, **kwargs: Any) -> dict[str, Any]:
        key = kwargs["Key"]
        item = self.items.get((str(key["PK"]), str(key["SK"])))
        return {"Item": item} if item is not None else {}


class MemoryS3:
    def __init__(self) -> None:
        self.deleted: list[tuple[str, str]] = []
        self.tagged: list[tuple[str, str, str]] = []

    def delete_object(self, **kwargs: Any) -> dict[str, Any]:
        self.deleted.append((str(kwargs["Bucket"]), str(kwargs["Key"])))
        return {}

    def put_object_tagging(self, **kwargs: Any) -> dict[str, Any]:
        self.tagged.append(
            (
                str(kwargs["Bucket"]),
                str(kwargs["Key"]),
                str(kwargs["Tagging"]["TagSet"][0]["Value"]),
            )
        )
        return {}


def _payload(user_id: str, key: str) -> str:
    return json.dumps(
        {
            "ownerDigest": hashlib.sha256(user_id.encode()).hexdigest(),
            "key": key,
        }
    )


def _key(user_id: str, suffix: str = "00000000-0000-4000-8000-000000000001") -> str:
    digest = hashlib.sha256(user_id.encode()).hexdigest()
    return f"avatars/{digest}/{suffix}.webp"


def test_cleanup_keeps_only_the_authoritatively_referenced_object() -> None:
    user_id = "user-1"
    digest = hashlib.sha256(user_id.encode()).hexdigest()
    current = _key(user_id)
    stale = _key(user_id, "00000000-0000-4000-8000-000000000002")
    table = MemoryTable(
        {
            (f"ACCOUNT#{digest}", "STATE"): {"state": "active"},
            (f"ACCOUNT#{digest}", "AVATAR"): {"avatarKey": current},
        }
    )
    s3 = MemoryS3()

    _process(_payload(user_id, current), table, s3, "avatars")
    _process(_payload(user_id, stale), table, s3, "avatars")

    assert s3.deleted == [("avatars", stale)]
    assert s3.tagged == [("avatars", current, "active")]


def test_cleanup_deletes_current_object_after_account_fence() -> None:
    user_id = "user-1"
    digest = hashlib.sha256(user_id.encode()).hexdigest()
    current = _key(user_id)
    table = MemoryTable(
        {
            (f"ACCOUNT#{digest}", "STATE"): {"state": "deleting"},
            (f"ACCOUNT#{digest}", "AVATAR"): {"avatarKey": current},
        }
    )
    s3 = MemoryS3()

    _process(_payload(user_id, current), table, s3, "avatars")

    assert s3.deleted == [("avatars", current)]
    assert s3.tagged == []


def test_cleanup_rejects_a_key_outside_the_hashed_owner_prefix() -> None:
    user_id = "user-1"
    foreign_key = _key("user-2")

    try:
        _process(_payload(user_id, foreign_key), MemoryTable({}), MemoryS3(), "avatars")
    except ValueError as error:
        assert "owner prefix" in str(error)
    else:
        raise AssertionError("expected an invalid cleanup key")
