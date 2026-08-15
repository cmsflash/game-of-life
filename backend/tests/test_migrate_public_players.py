from __future__ import annotations

from typing import Any

import pytest
from boto3.dynamodb.types import TypeDeserializer
from botocore.exceptions import ClientError

from life_api.migrate_public_players import migrate_public_players
from life_api.models import StoredPublicPlayer


class MemoryTable:
    name = "players"

    def __init__(self, profile: StoredPublicPlayer) -> None:
        self.items: dict[tuple[str, str], dict[str, Any]] = {
            (f"PLAYER#{profile.id}", "PROFILE"): {
                "PK": f"PLAYER#{profile.id}",
                "SK": "PROFILE",
                "entity": "publicPlayer",
                "version": profile.version,
                "discoverable": profile.discoverable,
                "document": profile.model_dump_json(by_alias=True),
            }
        }

    def scan(self, **kwargs: Any) -> dict[str, Any]:
        entity = next(iter(kwargs["ExpressionAttributeValues"].values()))
        return {
            "Items": [value.copy() for value in self.items.values() if value["entity"] == entity]
        }

    def get_item(self, **kwargs: Any) -> dict[str, Any]:
        key = kwargs["Key"]
        item = self.items.get((str(key["PK"]), str(key["SK"])))
        return {"Item": item.copy()} if item is not None else {}


class ApplyingClient:
    def __init__(self, table: MemoryTable, *, conflict: bool = False) -> None:
        self.table = table
        self.conflict = conflict

    def transact_write_items(self, **kwargs: Any) -> dict[str, Any]:
        if self.conflict:
            raise ClientError(
                {"Error": {"Code": "TransactionCanceledException", "Message": "conflict"}},
                "TransactWriteItems",
            )
        deserializer = TypeDeserializer()
        for operation in kwargs["TransactItems"]:
            put = operation.get("Put")
            if put is not None:
                item = {key: deserializer.deserialize(value) for key, value in put["Item"].items()}
                self.table.items[(str(item["PK"]), str(item["SK"]))] = item
            delete = operation.get("Delete")
            if delete is not None:
                key = {
                    name: deserializer.deserialize(value) for name, value in delete["Key"].items()
                }
                self.table.items.pop((str(key["PK"]), str(key["SK"])), None)
        return {}


def _hidden_profile() -> StoredPublicPlayer:
    return StoredPublicPlayer(
        id="player-1",
        display_name="Alice Avatar",
        normalized_display_name="alice avatar",
        discoverable=False,
        version=7,
        avatar_key="avatars/owner/current.webp",
        avatar_version=4,
    )


def test_public_player_migration_is_dry_run_first_and_idempotent() -> None:
    table = MemoryTable(_hidden_profile())
    client = ApplyingClient(table)

    dry = migrate_public_players(table, client, apply=False)
    assert (dry.examined, dry.eligible, dry.applied) == (1, 1, 0)
    original = StoredPublicPlayer.model_validate_json(
        table.items[("PLAYER#player-1", "PROFILE")]["document"]
    )
    assert original.discoverable is False

    applied = migrate_public_players(table, client, apply=True)
    assert (applied.eligible, applied.applied, applied.conflicts) == (1, 1, 0)
    migrated = StoredPublicPlayer.model_validate_json(
        table.items[("PLAYER#player-1", "PROFILE")]["document"]
    )
    assert migrated.discoverable is True
    assert migrated.version == 8
    assert migrated.avatar_key == original.avatar_key
    assert migrated.avatar_version == original.avatar_version

    rerun = migrate_public_players(table, client, apply=True)
    assert (rerun.examined, rerun.eligible, rerun.applied, rerun.conflicts) == (1, 0, 0, 0)


def test_public_player_migration_repairs_missing_search_index_without_version_bump() -> None:
    profile = _hidden_profile().model_copy(update={"discoverable": True})
    table = MemoryTable(profile)
    report = migrate_public_players(table, ApplyingClient(table), apply=True)

    assert report.applied == 1
    stored = StoredPublicPlayer.model_validate_json(
        table.items[("PLAYER#player-1", "PROFILE")]["document"]
    )
    assert stored.version == profile.version
    assert ("SEARCH#ali", "alice avatar#player-1") in table.items


def test_public_player_migration_reports_concurrent_profile_mutation() -> None:
    table = MemoryTable(_hidden_profile())
    report = migrate_public_players(table, ApplyingClient(table, conflict=True), apply=True)

    assert report.eligible == 1
    assert report.applied == 0
    assert report.conflicts == 1


def test_public_player_migration_refuses_inconsistent_storage_row() -> None:
    table = MemoryTable(_hidden_profile())
    table.items[("PLAYER#player-1", "PROFILE")]["version"] = 99

    report = migrate_public_players(table, ApplyingClient(table), apply=True)

    assert report.examined == 1
    assert report.invalid == 1
    assert report.applied == 0
    assert not any(key[0].startswith("SEARCH#") for key in table.items)


@pytest.mark.parametrize(
    ("display_name", "expected_partitions"),
    [
        ("Q", {"SEARCH#q"}),
        ("Li", {"SEARCH#l", "SEARCH#li"}),
        ("Zed", {"SEARCH#z", "SEARCH#ze", "SEARCH#zed"}),
    ],
)
def test_public_player_migration_writes_every_available_prefix(
    display_name: str,
    expected_partitions: set[str],
) -> None:
    profile = StoredPublicPlayer(
        id="player-1",
        display_name=display_name,
        normalized_display_name=display_name.casefold(),
        discoverable=False,
    )
    table = MemoryTable(profile)

    report = migrate_public_players(table, ApplyingClient(table), apply=True)

    assert report.applied == 1
    partitions = {key[0] for key in table.items if key[0].startswith("SEARCH#")}
    assert partitions == expected_partitions


def test_public_player_migration_deletes_stale_renamed_search_rows() -> None:
    profile = _hidden_profile().model_copy(update={"discoverable": True})
    table = MemoryTable(profile)
    stale_key = ("SEARCH#old", "old name#player-1")
    table.items[stale_key] = {
        "PK": stale_key[0],
        "SK": stale_key[1],
        "entity": "playerSearch",
        "playerId": profile.id,
        "document": profile.model_copy(
            update={
                "display_name": "Old Name",
                "normalized_display_name": "old name",
                "version": profile.version - 1,
            }
        ).model_dump_json(by_alias=True),
    }

    dry = migrate_public_players(table, ApplyingClient(table), apply=False)
    assert (dry.search_examined, dry.stale_indexes, dry.eligible) == (1, 1, 1)

    applied = migrate_public_players(table, ApplyingClient(table), apply=True)
    assert (applied.applied, applied.stale_indexes) == (1, 1)
    assert stale_key not in table.items
    assert {key[0] for key in table.items if key[0].startswith("SEARCH#")} == {
        "SEARCH#a",
        "SEARCH#al",
        "SEARCH#ali",
    }
    rerun = migrate_public_players(table, ApplyingClient(table), apply=True)
    assert (rerun.eligible, rerun.applied, rerun.stale_indexes) == (0, 0, 0)


def test_public_player_migration_deletes_orphan_search_rows() -> None:
    table = MemoryTable(_hidden_profile())
    orphan_key = ("SEARCH#g", "ghost#missing-player")
    table.items[orphan_key] = {
        "PK": orphan_key[0],
        "SK": orphan_key[1],
        "entity": "playerSearch",
        "playerId": "missing-player",
        "document": _hidden_profile()
        .model_copy(
            update={
                "id": "missing-player",
                "display_name": "Ghost",
                "normalized_display_name": "ghost",
            }
        )
        .model_dump_json(by_alias=True),
    }

    report = migrate_public_players(table, ApplyingClient(table), apply=True)

    assert (report.orphan_indexes, report.applied) == (1, 2)
    assert orphan_key not in table.items
