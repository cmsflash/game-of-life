from __future__ import annotations

from typing import Any

import pytest
from boto3.dynamodb.types import TypeDeserializer
from botocore.exceptions import ClientError

from life_api.migrate_public_players import _confirmed_public_identities, migrate_public_players
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
        self.transactions: list[dict[str, Any]] = []

    def transact_write_items(self, **kwargs: Any) -> dict[str, Any]:
        self.transactions.append(kwargs)
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


class ConflictOnCallClient(ApplyingClient):
    def __init__(self, table: MemoryTable, *, conflict_on_call: int) -> None:
        super().__init__(table)
        self.conflict_on_call = conflict_on_call

    def transact_write_items(self, **kwargs: Any) -> dict[str, Any]:
        if len(self.transactions) + 1 == self.conflict_on_call:
            self.transactions.append(kwargs)
            raise ClientError(
                {"Error": {"Code": "TransactionCanceledException", "Message": "conflict"}},
                "TransactWriteItems",
            )
        return super().transact_write_items(**kwargs)


def _migrate(
    table: MemoryTable,
    client: ApplyingClient,
    *,
    apply: bool,
    username: str | None = "alice_avatar",
):
    return migrate_public_players(
        table,
        client,
        {"player-1": username},
        apply=apply,
    )


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

    dry = _migrate(table, client, apply=False)
    assert (dry.examined, dry.eligible, dry.applied) == (1, 1, 0)
    original = StoredPublicPlayer.model_validate_json(
        table.items[("PLAYER#player-1", "PROFILE")]["document"]
    )
    assert original.discoverable is False

    applied = _migrate(table, client, apply=True)
    assert (applied.eligible, applied.applied, applied.conflicts) == (1, 1, 0)
    migrated = StoredPublicPlayer.model_validate_json(
        table.items[("PLAYER#player-1", "PROFILE")]["document"]
    )
    assert migrated.discoverable is True
    assert migrated.version == 8
    assert migrated.avatar_key == original.avatar_key
    assert migrated.avatar_version == original.avatar_version
    assert migrated.username == "alice_avatar"
    assert migrated.normalized_username == "alice_avatar"
    assert migrated.search_index_version == 2

    rerun = _migrate(table, client, apply=True)
    assert (rerun.examined, rerun.eligible, rerun.applied, rerun.conflicts) == (1, 0, 0, 0)


def test_public_player_migration_repairs_missing_search_index_without_version_bump() -> None:
    profile = _hidden_profile().model_copy(
        update={
            "discoverable": True,
            "username": "alice_avatar",
            "normalized_username": "alice_avatar",
            "search_index_version": 2,
        }
    )
    table = MemoryTable(profile)
    report = _migrate(table, ApplyingClient(table), apply=True)

    assert report.applied == 1
    stored = StoredPublicPlayer.model_validate_json(
        table.items[("PLAYER#player-1", "PROFILE")]["document"]
    )
    assert stored.version == profile.version
    assert ("SEARCH_TEXT#a", "alice avatar#player-1") in table.items
    assert ("SEARCH_TEXT#v", "vatar#player-1") in table.items


def test_public_player_migration_reports_concurrent_profile_mutation() -> None:
    table = MemoryTable(_hidden_profile())
    report = _migrate(table, ApplyingClient(table, conflict=True), apply=True)

    assert report.eligible == 1
    assert report.applied == 0
    assert report.conflicts == 1


def test_public_player_migration_refuses_inconsistent_storage_row() -> None:
    table = MemoryTable(_hidden_profile())
    table.items[("PLAYER#player-1", "PROFILE")]["version"] = 99

    report = _migrate(table, ApplyingClient(table), apply=True)

    assert report.examined == 1
    assert report.invalid == 1
    assert report.applied == 0
    assert not any(key[0].startswith("SEARCH#") for key in table.items)


@pytest.mark.parametrize(
    ("display_name", "expected_partitions"),
    [
        ("Q", {"SEARCH_TEXT#q"}),
        ("Li", {"SEARCH_TEXT#l", "SEARCH_TEXT#i"}),
        ("Zed", {"SEARCH_TEXT#z", "SEARCH_TEXT#e", "SEARCH_TEXT#d"}),
    ],
)
def test_public_player_migration_writes_every_display_name_suffix(
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

    report = _migrate(table, ApplyingClient(table), apply=True, username=None)

    assert report.applied == 1
    partitions = {key[0] for key in table.items if key[0].startswith("SEARCH_TEXT#")}
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

    dry = _migrate(table, ApplyingClient(table), apply=False)
    assert (dry.search_examined, dry.stale_indexes, dry.eligible) == (1, 1, 1)

    client = ApplyingClient(table)
    applied = _migrate(table, client, apply=True)
    assert (applied.applied, applied.stale_indexes) == (1, 1)
    stale_delete = client.transactions[0]["TransactItems"][1]["Delete"]
    assert stale_delete["ConditionExpression"] == (
        "#playerId = :playerId AND #entity = :entity AND #document = :document"
    )
    assert stale_key not in table.items
    assert all(not key[0].startswith("SEARCH#") for key in table.items)
    assert any(key[0].startswith("SEARCH_TEXT#") for key in table.items)
    rerun = _migrate(table, ApplyingClient(table), apply=True)
    assert (rerun.eligible, rerun.applied, rerun.stale_indexes) == (0, 0, 0)


def test_stale_alias_cleanup_precedes_the_profile_index_cutover() -> None:
    profile = _hidden_profile().model_copy(update={"discoverable": True})
    table = MemoryTable(profile)
    stale_key = ("SEARCH#old", "old name#player-1")
    table.items[stale_key] = {
        "PK": stale_key[0],
        "SK": stale_key[1],
        "entity": "playerSearch",
        "playerId": profile.id,
        "document": profile.model_dump_json(by_alias=True),
    }

    interrupted = _migrate(
        table,
        ConflictOnCallClient(table, conflict_on_call=2),
        apply=True,
    )

    assert interrupted.conflicts == 1
    assert interrupted.applied == 0
    assert stale_key not in table.items
    unchanged = StoredPublicPlayer.model_validate_json(
        table.items[("PLAYER#player-1", "PROFILE")]["document"]
    )
    assert unchanged == profile
    assert not any(key[0].startswith("SEARCH_TEXT#") for key in table.items)

    resumed = _migrate(table, ApplyingClient(table), apply=True)
    assert (resumed.eligible, resumed.applied, resumed.conflicts) == (1, 1, 0)


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

    report = _migrate(table, ApplyingClient(table), apply=True)

    assert (report.orphan_indexes, report.applied) == (1, 2)
    assert orphan_key not in table.items


def test_public_player_migration_blocks_apply_when_cognito_identity_is_unresolved() -> None:
    table = MemoryTable(_hidden_profile())
    client = ApplyingClient(table)

    report = migrate_public_players(table, client, {}, apply=True)

    assert report.unresolved == 1
    assert report.applied == 0
    assert report.has_failures


class PublicIdentityCognito:
    def list_users(self, **kwargs: Any) -> dict[str, Any]:
        assert kwargs == {"UserPoolId": "pool-id", "Limit": 60}
        return {
            "Users": [
                {
                    "Username": "CMS_Flash",
                    "Enabled": True,
                    "UserStatus": "CONFIRMED",
                    "Attributes": [
                        {"Name": "sub", "Value": "native-id"},
                        {"Name": "name", "Value": "Shen Zhuoran"},
                    ],
                },
                {
                    "Username": "Google_private-provider-id",
                    "Enabled": True,
                    "UserStatus": "EXTERNAL_PROVIDER",
                    "Attributes": [
                        {"Name": "sub", "Value": "google-id"},
                        {"Name": "identities", "Value": '[{"providerName":"Google"}]'},
                    ],
                },
            ]
        }


def test_cognito_identity_resolution_keeps_provider_identifiers_private() -> None:
    usernames, display_names = _confirmed_public_identities(
        PublicIdentityCognito(),
        "pool-id",
    )

    assert usernames == {"native-id": "CMS_Flash", "google-id": None}
    assert display_names == {
        "native-id": "Shen Zhuoran",
        "google-id": "Google Player",
    }


class SingleIdentityCognito:
    def __init__(self, identities: str, *, name: str = "Provider Player") -> None:
        self.identities = identities
        self.name = name

    def list_users(self, **kwargs: Any) -> dict[str, Any]:
        assert kwargs == {"UserPoolId": "pool-id", "Limit": 60}
        return {
            "Users": [
                {
                    "Username": "Google_private-provider-id",
                    "Enabled": True,
                    "UserStatus": "CONFIRMED",
                    "Attributes": [
                        {"Name": "sub", "Value": "google-id"},
                        {"Name": "name", "Value": self.name},
                        {"Name": "identities", "Value": self.identities},
                    ],
                }
            ]
        }


@pytest.mark.parametrize("identities", ["{}", "null", "0", "{"])
def test_cognito_identity_resolution_fails_closed_for_unexpected_shapes(
    identities: str,
) -> None:
    usernames, display_names = _confirmed_public_identities(
        SingleIdentityCognito(identities),
        "pool-id",
    )

    assert usernames == {"google-id": None}
    assert display_names == {"google-id": "Provider Player"}


def test_cognito_identity_resolution_canonicalizes_public_display_name() -> None:
    usernames, display_names = _confirmed_public_identities(
        SingleIdentityCognito(
            '[{"providerName":"Google"}]',
            name="  Ｓｈｅｎ\u3000\u3000Zhuoran  ",  # noqa: RUF001
        ),
        "pool-id",
    )

    assert usernames == {"google-id": None}
    assert display_names == {"google-id": "Shen Zhuoran"}
