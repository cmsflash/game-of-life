from __future__ import annotations

import argparse
import hashlib
import json
import re
from collections.abc import Iterator, Mapping, Sequence
from dataclasses import asdict, dataclass
from datetime import UTC, datetime
from typing import Any, Protocol

import boto3
from boto3.dynamodb.types import TypeSerializer
from botocore.exceptions import ClientError

from .models import StoredPublicPlayer
from .player_search import (
    SEARCH_INDEX_VERSION,
    SEARCH_PARTITION_PREFIX,
    canonical_display_name,
    normalize_search_text,
    search_index_keys,
)


class DynamoTable(Protocol):
    name: str

    def get_item(self, **kwargs: Any) -> dict[str, Any]: ...

    def scan(self, **kwargs: Any) -> dict[str, Any]: ...


class DynamoClient(Protocol):
    def transact_write_items(self, **kwargs: Any) -> dict[str, Any]: ...


class CognitoClient(Protocol):
    def list_users(self, **kwargs: Any) -> dict[str, Any]: ...


@dataclass(frozen=True, slots=True)
class PublicPlayerMigrationReport:
    examined: int = 0
    search_examined: int = 0
    eligible: int = 0
    applied: int = 0
    stale_indexes: int = 0
    orphan_indexes: int = 0
    conflicts: int = 0
    unresolved: int = 0
    invalid: int = 0

    @property
    def has_failures(self) -> bool:
        return self.conflicts > 0 or self.unresolved > 0 or self.invalid > 0


def migrate_public_players(
    table: DynamoTable,
    client: DynamoClient,
    public_usernames: Mapping[str, str | None],
    display_names: Mapping[str, str] | None = None,
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
        if player.id not in public_usernames or (
            display_names is not None and player.id not in display_names
        ):
            report = _replace(report, unresolved=report.unresolved + 1)
            continue
        username = public_usernames[player.id]
        if username is not None and re.fullmatch(r"[A-Za-z0-9_.-]{3,32}", username) is None:
            report = _replace(report, invalid=report.invalid + 1)
            continue
        display_name = (
            display_names[player.id] if display_names is not None else player.display_name
        )
        normalized_display_name = normalize_search_text(display_name)
        if not normalized_display_name or len(normalized_display_name) > 48:
            report = _replace(report, invalid=report.invalid + 1)
            continue
        normalized_username = normalize_search_text(username) if username is not None else None
        changed = (
            not player.discoverable
            or player.discoverability_updated_at is not None
            or player.username != username
            or player.normalized_username != normalized_username
            or player.display_name != display_name
            or player.normalized_display_name != normalized_display_name
            or player.search_index_version != SEARCH_INDEX_VERSION
        )
        updated = player.model_copy(
            update={
                "username": username,
                "normalized_username": normalized_username,
                "display_name": display_name,
                "normalized_display_name": normalized_display_name,
                "search_index_version": SEARCH_INDEX_VERSION,
                "discoverable": True,
                "discoverability_updated_at": None,
                "version": player.version + (1 if changed else 0),
            },
            deep=True,
        )
        search_keys = _search_keys(updated)
        if len(search_keys) > 80:
            report = _replace(report, invalid=report.invalid + 1)
            continue
        expected_pairs = {(value["PK"], value["SK"]) for value in search_keys}
        indexed = indexed_by_player.get(player.id, [])
        indexed_by_pair = {(str(value["PK"]), str(value["SK"])): value for value in indexed}
        search_current = all(
            _search_item_current(
                indexed_by_pair.get((search_key["PK"], search_key["SK"])),
                player.id,
            )
            for search_key in search_keys
        )
        stale = [
            value for value in indexed if (str(value["PK"]), str(value["SK"])) not in expected_pairs
        ]
        if not changed and search_current and not stale:
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
    if not apply or report.invalid or report.unresolved:
        return report

    for item, player, updated, search_keys, stale in plans:
        cleanup_conflict = False
        for offset in range(0, len(stale), 99):
            cleanup = [
                _profile_exact_condition(table.name, item, player),
                *[
                    _conditional_search_delete(table.name, value)
                    for value in stale[offset : offset + 99]
                ],
            ]
            try:
                client.transact_write_items(TransactItems=cleanup)
            except ClientError as error:
                if error.response.get("Error", {}).get("Code") != "TransactionCanceledException":
                    raise
                report = _replace(report, conflicts=report.conflicts + 1)
                cleanup_conflict = True
                break
        if cleanup_conflict:
            continue
        transaction = [
            *_account_conditions(table.name, player.id),
            _profile_guard_or_update(table.name, item, player, updated),
            *[
                {
                    "Put": {
                        "TableName": table.name,
                        "Item": _serialize(
                            {
                                **search_key,
                                "entity": "playerSearch",
                                "playerId": player.id,
                                "searchIndexVersion": SEARCH_INDEX_VERSION,
                                "profileVersion": updated.version,
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
    if updated == player:
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


def _profile_exact_condition(
    table_name: str,
    item: dict[str, Any],
    player: StoredPublicPlayer,
) -> dict[str, Any]:
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
                {
                    ":version": player.version,
                    ":document": item["document"],
                }
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
    return search_index_keys(player)


def _search_item_current(item: object, player_id: str) -> bool:
    return (
        isinstance(item, dict)
        and item.get("playerId") == player_id
        and item.get("searchIndexVersion") == SEARCH_INDEX_VERSION
    )


def _valid_search_item(item: dict[str, Any]) -> bool:
    return (
        item.get("entity") == "playerSearch"
        and isinstance(item.get("PK"), str)
        and (
            str(item["PK"]).startswith("SEARCH#")
            or str(item["PK"]).startswith(SEARCH_PARTITION_PREFIX)
        )
        and isinstance(item.get("SK"), str)
        and isinstance(item.get("playerId"), str)
        and 1 <= len(str(item["playerId"])) <= 128
    )


def _conditional_search_delete(table_name: str, item: dict[str, Any]) -> dict[str, Any]:
    compared_fields = [
        field
        for field in (
            "playerId",
            "entity",
            "document",
            "searchIndexVersion",
            "profileVersion",
        )
        if field in item
    ]
    return {
        "Delete": {
            "TableName": table_name,
            "Key": _serialize({"PK": item["PK"], "SK": item["SK"]}),
            "ConditionExpression": " AND ".join(
                f"#{field} = :{field}" for field in compared_fields
            ),
            "ExpressionAttributeNames": {f"#{field}": field for field in compared_fields},
            "ExpressionAttributeValues": _serialize_values(
                {f":{field}": item[field] for field in compared_fields}
            ),
        }
    }


def _valid_profile_item(item: dict[str, Any], player: StoredPublicPlayer) -> bool:
    normalized = normalize_search_text(player.display_name)
    normalized_username = (
        normalize_search_text(player.username) if player.username is not None else None
    )
    return (
        item.get("PK") == f"PLAYER#{player.id}"
        and item.get("SK") == "PROFILE"
        and item.get("version") == player.version
        and item.get("discoverable") == player.discoverable
        and 1 <= len(normalized) <= 48
        and player.normalized_display_name == normalized
        and player.normalized_username == normalized_username
        and (
            player.username is None or bool(re.fullmatch(r"[A-Za-z0-9_.-]{3,32}", player.username))
        )
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


def _confirmed_public_identities(
    client: CognitoClient,
    user_pool_id: str,
) -> tuple[dict[str, str | None], dict[str, str]]:
    usernames: dict[str, str | None] = {}
    display_names: dict[str, str] = {}
    request: dict[str, Any] = {"UserPoolId": user_pool_id, "Limit": 60}
    while True:
        response = client.list_users(**request)
        for user in response.get("Users", []):
            if not user.get("Enabled", True) or user.get("UserStatus") not in {
                "CONFIRMED",
                "EXTERNAL_PROVIDER",
            }:
                continue
            attributes = {
                str(value.get("Name")): str(value.get("Value", ""))
                for value in user.get("Attributes", [])
            }
            user_id = attributes.get("sub", "").strip()
            if not user_id or user_id in usernames:
                continue
            federated = user.get("UserStatus") == "EXTERNAL_PROVIDER" or _has_federated_identity(
                attributes.get("identities")
            )
            raw_username = str(user.get("Username", "")).strip()
            username = None if federated else raw_username
            if username is not None and re.fullmatch(r"[A-Za-z0-9_.-]{3,32}", username) is None:
                continue
            display_name = canonical_display_name(attributes.get("name", "")) or (
                "Google Player" if federated else raw_username
            )
            normalized_display_name = normalize_search_text(display_name)
            if not normalized_display_name or len(normalized_display_name) > 48:
                continue
            usernames[user_id] = username
            display_names[user_id] = display_name
        token = response.get("PaginationToken")
        if not isinstance(token, str):
            return usernames, display_names
        request["PaginationToken"] = token


def _has_federated_identity(raw: str | None) -> bool:
    if not raw:
        return False
    try:
        identities = json.loads(raw)
    except ValueError:
        return True
    return not isinstance(identities, list) or bool(identities)


def _stack_resources(session: boto3.Session, stack_name: str) -> tuple[str, str]:
    response = session.client("cloudformation").describe_stacks(StackName=stack_name)
    outputs = {
        str(output["OutputKey"]): str(output["OutputValue"])
        for output in response["Stacks"][0].get("Outputs", [])
    }
    try:
        return outputs["DynamoTableName"], outputs["CognitoUserPoolId"]
    except KeyError as error:
        raise ValueError("stack must export DynamoTableName and CognitoUserPoolId") from error


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Index every active display name and native login username.",
    )
    parser.add_argument("--stack-name", required=True)
    parser.add_argument("--region", default="ap-east-1")
    parser.add_argument("--profile")
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Apply the migration. Omit for a read-only plan.",
    )
    args = parser.parse_args(argv)
    session = boto3.Session(profile_name=args.profile, region_name=args.region)
    table_name, user_pool_id = _stack_resources(session, args.stack_name)
    table = session.resource("dynamodb").Table(table_name)
    client = session.client("dynamodb")
    public_usernames, display_names = _confirmed_public_identities(
        session.client("cognito-idp"),
        user_pool_id,
    )
    report = migrate_public_players(
        table,
        client,
        public_usernames,
        display_names,
        apply=args.apply,
    )
    print(json.dumps(asdict(report), separators=(",", ":"), sort_keys=True))
    return 1 if report.has_failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
