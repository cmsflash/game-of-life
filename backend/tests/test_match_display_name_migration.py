from __future__ import annotations

from datetime import UTC, datetime
from typing import Any

from botocore.exceptions import ClientError

from life_api.migrate_match_display_names import (
    CognitoNameResolver,
    migrate_match_display_names,
    plan_match_migration,
)
from life_api.models import MatchStatus, PlayerSummary, StoredMatch


class FakeTable:
    def __init__(self, items: list[dict[str, Any]], *, conflict: bool = False) -> None:
        self.items = items
        self.conflict = conflict
        self.updates: list[dict[str, Any]] = []

    def get_item(self, **kwargs: Any) -> dict[str, Any]:
        key = kwargs["Key"]
        return {
            "Item": next(
                (
                    item
                    for item in self.items
                    if item["PK"] == key["PK"] and item["SK"] == key["SK"]
                ),
                None,
            )
        }

    def scan(self, **kwargs: Any) -> dict[str, Any]:
        del kwargs
        return {"Items": self.items}

    def update_item(self, **kwargs: Any) -> dict[str, Any]:
        self.updates.append(kwargs)
        if self.conflict:
            raise ClientError(
                {
                    "Error": {
                        "Code": "ConditionalCheckFailedException",
                        "Message": "changed concurrently",
                    }
                },
                "UpdateItem",
            )
        key = kwargs["Key"]
        item = next(
            item for item in self.items if item["PK"] == key["PK"] and item["SK"] == key["SK"]
        )
        values = kwargs["ExpressionAttributeValues"]
        item["document"] = values[":document"]
        item["version"] = values[":version"]
        return {}


class FakeCognitoClient:
    def __init__(self) -> None:
        self.calls: list[dict[str, Any]] = []

    def list_users(self, **kwargs: Any) -> dict[str, Any]:
        self.calls.append(kwargs)
        return {
            "Users": [
                {
                    "Attributes": [
                        {"Name": "sub", "Value": "alice-id"},
                        {"Name": "name", "Value": "Alice Example"},
                    ]
                }
            ]
        }


class UsernameOnlyCognitoClient:
    def list_users(self, **kwargs: Any) -> dict[str, Any]:
        del kwargs
        return {
            "Users": [
                {
                    "Username": "federated-player",
                    "Attributes": [{"Name": "sub", "Value": "federated-id"}],
                }
            ]
        }


def _legacy_match() -> StoredMatch:
    created_at = datetime(2026, 8, 1, tzinfo=UTC)
    updated_at = datetime(2026, 8, 2, tzinfo=UTC)
    return StoredMatch(
        id="00000000-0000-0000-0000-000000000001",
        join_code="ABC123",
        rules={},
        state={"revision": 4, "toMove": "black"},
        creator_id="alice-id",
        creator_name="Player",
        black_player=PlayerSummary(id="alice-id", display_name="Black player"),
        white_player=PlayerSummary(id="bob-id", display_name="White player"),
        status=MatchStatus.active,
        version=7,
        created_at=created_at,
        updated_at=updated_at,
    )


def _item(match: StoredMatch) -> dict[str, Any]:
    return {
        "PK": f"MATCH#{match.id}",
        "SK": "STATE",
        "entity": "match",
        "version": match.version,
        "document": match.model_dump_json(by_alias=True),
    }


def test_plan_replaces_generic_labels_but_preserves_deleted_identity_and_timestamp() -> None:
    match = _legacy_match().model_copy(
        update={
            "white_player": PlayerSummary(
                id="deleted-opaque-id",
                display_name="Deleted player",
            )
        }
    )
    resolved: list[str] = []

    def resolve_name(user_id: str) -> str | None:
        resolved.append(user_id)
        return {"alice-id": "Alice Example"}.get(user_id)

    plan = plan_match_migration(match, resolve_name)

    assert plan is not None
    assert plan.changed_labels == 2
    assert resolved == ["alice-id"]
    assert plan.match.creator_name == "Alice Example"
    assert plan.match.black_player == PlayerSummary(
        id="alice-id",
        display_name="Alice Example",
    )
    assert plan.match.white_player == match.white_player
    assert plan.match.version == match.version + 1
    assert plan.match.updated_at == match.updated_at


def test_apply_uses_document_and_version_condition_and_changes_etag_version() -> None:
    match = _legacy_match()
    table = FakeTable([_item(match)])
    names = {"alice-id": "Shen Zhuoran", "bob-id": "cmswindzerg"}

    stats = migrate_match_display_names(
        table,
        names.get,
        apply=True,
        match_id=match.id,
    )

    assert stats.examined == 1
    assert stats.eligible == 1
    assert stats.applied == 1
    assert not stats.has_failures
    assert len(table.updates) == 1
    update = table.updates[0]
    assert update["ConditionExpression"] == ("#document = :oldDocument AND #version = :oldVersion")
    values = update["ExpressionAttributeValues"]
    migrated = StoredMatch.model_validate_json(values[":document"])
    assert migrated.version == 8
    assert values[":version"] == 8
    assert values[":oldVersion"] == 7
    assert migrated.updated_at == match.updated_at
    assert {
        migrated.black_player.display_name if migrated.black_player else None,
        migrated.white_player.display_name if migrated.white_player else None,
    } == {"Shen Zhuoran", "cmswindzerg"}


def test_dry_run_and_unresolved_identity_never_write() -> None:
    match = _legacy_match()
    table = FakeTable([_item(match)])

    dry_run = migrate_match_display_names(
        table,
        {"alice-id": "Alice", "bob-id": "Bob"}.get,
        apply=False,
    )
    unresolved = migrate_match_display_names(
        table,
        {"alice-id": "Alice"}.get,
        apply=True,
    )

    assert dry_run.eligible == 1
    assert dry_run.applied == 0
    assert unresolved.unresolved == 1
    assert unresolved.has_failures
    assert table.updates == []


def test_legitimate_display_name_matching_a_legacy_label_is_idempotent() -> None:
    match = _legacy_match().model_copy(
        update={
            "creator_name": "Black player",
            "black_player": PlayerSummary(
                id="alice-id",
                display_name="Black player",
            ),
            "white_player": PlayerSummary(id="bob-id", display_name="Bob"),
        }
    )

    plan = plan_match_migration(
        match,
        {"alice-id": "Black player"}.get,
    )

    assert plan is None


def test_applied_migration_is_a_no_op_when_rerun() -> None:
    match = _legacy_match()
    table = FakeTable([_item(match)])
    names = {"alice-id": "Alice", "bob-id": "Bob"}

    first = migrate_match_display_names(table, names.get, apply=True)
    second = migrate_match_display_names(table, names.get, apply=True)

    assert first.applied == 1
    assert second.examined == 1
    assert second.eligible == 0
    assert second.applied == 0
    assert not second.has_failures
    assert len(table.updates) == 1


def test_concurrent_match_change_is_reported_without_overwrite() -> None:
    match = _legacy_match()
    table = FakeTable([_item(match)], conflict=True)

    stats = migrate_match_display_names(
        table,
        {"alice-id": "Alice", "bob-id": "Bob"}.get,
        apply=True,
    )

    assert stats.applied == 0
    assert stats.conflicts == 1
    assert stats.has_failures


def test_cognito_name_resolver_uses_sub_filter_and_caches_result() -> None:
    client = FakeCognitoClient()
    resolver = CognitoNameResolver(client, "pool-id")

    assert resolver("alice-id") == "Alice Example"
    assert resolver("alice-id") == "Alice Example"
    assert client.calls == [
        {
            "UserPoolId": "pool-id",
            "Filter": 'sub = "alice-id"',
            "Limit": 2,
        }
    ]


def test_cognito_name_resolver_does_not_publish_cognito_username() -> None:
    resolver = CognitoNameResolver(UsernameOnlyCognitoClient(), "pool-id")

    assert resolver("federated-id") is None
