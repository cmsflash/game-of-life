from __future__ import annotations

import argparse
import hashlib
import json
import unicodedata
from collections.abc import Iterator, Sequence
from dataclasses import asdict, dataclass
from datetime import UTC, datetime
from typing import Any, Protocol

import boto3
from boto3.dynamodb.types import TypeSerializer
from botocore.exceptions import ClientError

from .models import StoredPublicPlayer


class DynamoTable(Protocol):
    name: str

    def get_item(self, **kwargs: Any) -> dict[str, Any]: ...

    def scan(self, **kwargs: Any) -> dict[str, Any]: ...


class DynamoClient(Protocol):
    def transact_write_items(self, **kwargs: Any) -> dict[str, Any]: ...


@dataclass(frozen=True, slots=True)
class PublicPlayerMigrationReport:
    examined: int = 0
    search_examined: int = 0
    eligible: int = 0
    applied: int = 0
    stale_indexes: int = 0
    orphan_indexes: int = 0
    conflicts: int = 0
    invalid: int = 0

    @property
    def has_failures(self) -> bool:
        return self.conflicts > 0 or self.invalid > 0


def migrate_public_players(
    table: DynamoTable,
    client: DynamoClient,
    *,
    apply: bool,
) -> PublicPlayerMigrationReport:
    report = PublicPlayerMigrationReport()
    profile_items = list(_entity_items(table, "publicPlayer", ":profile"))
    search_items = list(_entity_items(table, "playerSearch", ":search"))
    report = _replace(report, search_examined=len(search_items))
    parsed_profiles: list[tuple[dict[str, Any], StoredPublicPlayer]] = []
    raw_profile_ids = {
        str(item["PK"]).removeprefix("PLAYER#")
        for item in profile_items
        if str(item.get("PK", "")).startswith("PLAYER#") and item.get("SK") == "PROFILE"
    }
    for item in profile_items:
        report = _replace(report, examined=report.examined + 1)
        document = item.get("document")
        try:
            if not isinstance(document, str):
                raise ValueError("missing profile document")
            player = StoredPublicPlayer.model_validate_json(document)
            if not _valid_profile_item(item, player):
                raise ValueError("profile storage invariants do not match")
        except ValueError:
            report = _replace(report, invalid=report.invalid + 1)
            continue
        parsed_profiles.append((item, player))

    indexed_by_player: dict[str, list[dict[str, Any]]] = {}
    for item in search_items:
        if not _valid_search_item(item):
            report = _replace(report, invalid=report.invalid + 1)
            continue
        indexed_by_player.setdefault(str(item["playerId"]), []).append(item)

    plans: list[
        tuple[
            dict[str, Any],
            StoredPublicPlayer,
            StoredPublicPlayer,
            list[dict[str, str]],
            list[dict[str, Any]],
        ]
    ] = []
    valid_profile_ids = {player.id for _, player in parsed_profiles}
    for item, player in parsed_profiles:
        updated = (
            player
            if player.discoverable
            else player.model_copy(
                update={
                    "discoverable": True,
                    "discoverability_updated_at": None,
                    "version": player.version + 1,
                },
                deep=True,
            )
        )
        expected_search_document = updated.model_dump_json(by_alias=True)
        search_keys = _search_keys(updated)
        expected_pairs = {(value["PK"], value["SK"]) for value in search_keys}
        indexed = indexed_by_player.get(player.id, [])
        indexed_by_pair = {(str(value["PK"]), str(value["SK"])): value for value in indexed}
        search_current = all(
            _search_item_current(
                indexed_by_pair.get((search_key["PK"], search_key["SK"])),
                player.id,
                expected_search_document,
            )
            for search_key in search_keys
        )
        stale = [
            value for value in indexed if (str(value["PK"]), str(value["SK"])) not in expected_pairs
        ]
        if len(stale) > 94:
            report = _replace(report, invalid=report.invalid + 1)
            continue
        if player.discoverable and search_current and not stale:
            continue
        report = _replace(
            report,
            eligible=report.eligible + 1,
            stale_indexes=report.stale_indexes + len(stale),
        )
        plans.append((item, player, updated, search_keys, stale))

    orphans = [
        item
        for player_id, items in indexed_by_player.items()
        if player_id not in valid_profile_ids and player_id not in raw_profile_ids
        for item in items
    ]
    report = _replace(
        report,
        eligible=report.eligible + len(orphans),
        orphan_indexes=len(orphans),
    )
    if not apply or report.invalid:
        return report

    for item, player, updated, search_keys, stale in plans:
        expected_search_document = updated.model_dump_json(by_alias=True)
        transaction = [
            *_account_conditions(table.name, player.id),
            _profile_guard_or_update(table.name, item, player, updated),
            *[_conditional_search_delete(table.name, value) for value in stale],
            *[
                {
                    "Put": {
                        "TableName": table.name,
                        "Item": _serialize(
                            {
                                **search_key,
                                "entity": "playerSearch",
                                "playerId": player.id,
                                "document": expected_search_document,
                            }
                        ),
                    }
                }
                for search_key in search_keys
            ],
        ]
        try:
            client.transact_write_items(TransactItems=transaction)
        except ClientError as error:
            if error.response.get("Error", {}).get("Code") != "TransactionCanceledException":
                raise
            report = _replace(report, conflicts=report.conflicts + 1)
            continue
        report = _replace(report, applied=report.applied + 1)
    for item in orphans:
        player_id = str(item["playerId"])
        transaction = [
            {
                "ConditionCheck": {
                    "TableName": table.name,
                    "Key": _serialize({"PK": f"PLAYER#{player_id}", "SK": "PROFILE"}),
                    "ConditionExpression": "attribute_not_exists(PK)",
                }
            },
            _conditional_search_delete(table.name, item),
        ]
        try:
            client.transact_write_items(TransactItems=transaction)
        except ClientError as error:
            if error.response.get("Error", {}).get("Code") != "TransactionCanceledException":
                raise
            report = _replace(report, conflicts=report.conflicts + 1)
            continue
        report = _replace(report, applied=report.applied + 1)
    return report


def _entity_items(
    table: DynamoTable,
    entity: str,
    placeholder: str,
) -> Iterator[dict[str, Any]]:
    request: dict[str, Any] = {
        "FilterExpression": f"#entity = {placeholder}",
        "ExpressionAttributeNames": {"#entity": "entity"},
        "ExpressionAttributeValues": {placeholder: entity},
        "ConsistentRead": True,
    }
    while True:
        response = table.scan(**request)
        for item in response.get("Items", []):
            if isinstance(item, dict):
                yield item
        last_key = response.get("LastEvaluatedKey")
        if not isinstance(last_key, dict):
            return
        request["ExclusiveStartKey"] = last_key


def _profile_guard_or_update(
    table_name: str,
    item: dict[str, Any],
    player: StoredPublicPlayer,
    updated: StoredPublicPlayer,
) -> dict[str, Any]:
    if updated is player:
        return {
            "ConditionCheck": {
                "TableName": table_name,
                "Key": _serialize({"PK": item["PK"], "SK": item["SK"]}),
                "ConditionExpression": "#version = :version AND #document = :document",
                "ExpressionAttributeNames": {
                    "#version": "version",
                    "#document": "document",
                },
                "ExpressionAttributeValues": _serialize_values(
                    {":version": player.version, ":document": item["document"]}
                ),
            }
        }
    return {
        "Put": {
            "TableName": table_name,
            "Item": _serialize(
                {
                    "PK": item["PK"],
                    "SK": item["SK"],
                    "entity": "publicPlayer",
                    "version": updated.version,
                    "discoverable": True,
                    "document": updated.model_dump_json(by_alias=True),
                }
            ),
            "ConditionExpression": "#version = :version AND #document = :document",
            "ExpressionAttributeNames": {
                "#version": "version",
                "#document": "document",
            },
            "ExpressionAttributeValues": _serialize_values(
                {":version": player.version, ":document": item["document"]}
            ),
        }
    }


def _account_conditions(table_name: str, user_id: str) -> list[dict[str, Any]]:
    digest = hashlib.sha256(user_id.encode()).hexdigest()
    return [
        {
            "ConditionCheck": {
                "TableName": table_name,
                "Key": _serialize({"PK": f"ACCOUNT#{digest}", "SK": "STATE"}),
                "ConditionExpression": "attribute_not_exists(PK) OR #state = :active",
                "ExpressionAttributeNames": {"#state": "state"},
                "ExpressionAttributeValues": _serialize_values({":active": "active"}),
            }
        },
        {
            "ConditionCheck": {
                "TableName": table_name,
                "Key": _serialize({"PK": f"USER#{user_id}", "SK": "ACCOUNT_DELETED"}),
                "ConditionExpression": "attribute_not_exists(PK) OR expiresAt <= :now",
                "ExpressionAttributeValues": _serialize_values(
                    {":now": int(datetime.now(UTC).timestamp())}
                ),
            }
        },
    ]


def _search_keys(player: StoredPublicPlayer) -> list[dict[str, str]]:
    name = player.normalized_display_name
    return [
        {
            "PK": f"SEARCH#{name[:length]}",
            "SK": f"{name}#{player.id}",
        }
        for length in range(1, min(3, len(name)) + 1)
    ]


def _search_item_current(item: object, player_id: str, document: str) -> bool:
    return (
        isinstance(item, dict)
        and item.get("playerId") == player_id
        and item.get("document") == document
    )


def _valid_search_item(item: dict[str, Any]) -> bool:
    return (
        item.get("entity") == "playerSearch"
        and isinstance(item.get("PK"), str)
        and str(item["PK"]).startswith("SEARCH#")
        and isinstance(item.get("SK"), str)
        and isinstance(item.get("playerId"), str)
        and 1 <= len(str(item["playerId"])) <= 128
        and isinstance(item.get("document"), str)
    )


def _conditional_search_delete(table_name: str, item: dict[str, Any]) -> dict[str, Any]:
    return {
        "Delete": {
            "TableName": table_name,
            "Key": _serialize({"PK": item["PK"], "SK": item["SK"]}),
            "ConditionExpression": "playerId = :playerId AND #document = :document",
            "ExpressionAttributeNames": {"#document": "document"},
            "ExpressionAttributeValues": _serialize_values(
                {":playerId": item["playerId"], ":document": item["document"]}
            ),
        }
    }


def _valid_profile_item(item: dict[str, Any], player: StoredPublicPlayer) -> bool:
    normalized = " ".join(unicodedata.normalize("NFKC", player.display_name).casefold().split())
    return (
        item.get("PK") == f"PLAYER#{player.id}"
        and item.get("SK") == "PROFILE"
        and item.get("version") == player.version
        and item.get("discoverable") == player.discoverable
        and 1 <= len(normalized) <= 48
        and player.normalized_display_name == normalized
    )


def _replace(
    report: PublicPlayerMigrationReport,
    **changes: int,
) -> PublicPlayerMigrationReport:
    values = asdict(report)
    values.update(changes)
    return PublicPlayerMigrationReport(**values)


def _serialize(item: dict[str, Any]) -> dict[str, Any]:
    serializer = TypeSerializer()
    return {key: serializer.serialize(value) for key, value in item.items()}


def _serialize_values(item: dict[str, Any]) -> dict[str, Any]:
    return _serialize(item)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Make every active player profile publicly searchable.",
    )
    parser.add_argument("--table-name", required=True)
    parser.add_argument("--region", default="ap-east-1")
    parser.add_argument("--profile")
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Apply the migration. Omit for a read-only plan.",
    )
    args = parser.parse_args(argv)
    session = boto3.Session(profile_name=args.profile, region_name=args.region)
    table = session.resource("dynamodb").Table(args.table_name)
    client = session.client("dynamodb")
    report = migrate_public_players(table, client, apply=args.apply)
    print(json.dumps(asdict(report), separators=(",", ":"), sort_keys=True))
    return 1 if report.has_failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
