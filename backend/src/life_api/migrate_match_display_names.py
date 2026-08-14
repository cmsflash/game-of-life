from __future__ import annotations

import argparse
from collections.abc import Callable, Iterator, Sequence
from dataclasses import dataclass
from typing import Any, Protocol

import boto3
from botocore.exceptions import ClientError

from .models import PlayerSummary, StoredMatch

_LEGACY_DISPLAY_NAMES = frozenset({"Player", "Black player", "White player"})


class DynamoTable(Protocol):
    def get_item(self, **kwargs: Any) -> dict[str, Any]: ...

    def scan(self, **kwargs: Any) -> dict[str, Any]: ...

    def update_item(self, **kwargs: Any) -> dict[str, Any]: ...


class CognitoClient(Protocol):
    def list_users(self, **kwargs: Any) -> dict[str, Any]: ...


NameResolver = Callable[[str], str | None]


@dataclass(frozen=True, slots=True)
class MigrationStats:
    examined: int = 0
    eligible: int = 0
    applied: int = 0
    unresolved: int = 0
    conflicts: int = 0
    invalid: int = 0

    @property
    def has_failures(self) -> bool:
        return self.unresolved > 0 or self.conflicts > 0 or self.invalid > 0


@dataclass(frozen=True, slots=True)
class MatchMigrationPlan:
    match: StoredMatch
    changed_labels: int


class CognitoNameResolver:
    def __init__(self, client: CognitoClient, user_pool_id: str) -> None:
        self._client = client
        self._user_pool_id = user_pool_id
        self._cache: dict[str, str | None] = {}

    def __call__(self, user_id: str) -> str | None:
        if user_id in self._cache:
            return self._cache[user_id]
        response = self._client.list_users(
            UserPoolId=self._user_pool_id,
            Filter=f'sub = "{_escape_cognito_filter(user_id)}"',
            Limit=2,
        )
        users = response.get("Users", [])
        name = None
        if len(users) == 1:
            attributes = {
                str(attribute.get("Name")): str(attribute.get("Value", ""))
                for attribute in users[0].get("Attributes", [])
            }
            candidate = attributes.get("name", "").strip()
            username = str(users[0].get("Username", "")).strip()
            name = candidate or username or None
        self._cache[user_id] = name
        return name


def plan_match_migration(
    match: StoredMatch,
    resolve_name: NameResolver,
) -> MatchMigrationPlan | None:
    required_ids: set[str] = set()
    if _needs_name(match.creator_id, match.creator_name):
        required_ids.add(match.creator_id)
    for player in (match.black_player, match.white_player):
        if player is not None and _needs_name(player.id, player.display_name):
            required_ids.add(player.id)
    if not required_ids:
        return None

    names = {user_id: resolve_name(user_id) for user_id in required_ids}
    if any(name is None for name in names.values()):
        return MatchMigrationPlan(match=match, changed_labels=0)

    changes: dict[str, object] = {}
    changed_labels = 0
    if _needs_name(match.creator_id, match.creator_name):
        creator_name = _resolved_name(names, match.creator_id)
        if creator_name != match.creator_name:
            changes["creator_name"] = creator_name
            changed_labels += 1

    for field_name, player in (
        ("black_player", match.black_player),
        ("white_player", match.white_player),
    ):
        if player is None or not _needs_name(player.id, player.display_name):
            continue
        display_name = _resolved_name(names, player.id)
        if display_name != player.display_name:
            changes[field_name] = PlayerSummary(
                id=player.id,
                display_name=display_name,
            )
            changed_labels += 1

    if not changes:
        return None

    # Bump only the match version so ETag-based clients refetch the corrected
    # document. Preserve updatedAt: a label repair is not gameplay activity and
    # must not reorder history or reset turn-reminder timing.
    changes["version"] = match.version + 1
    return MatchMigrationPlan(
        match=match.model_copy(update=changes, deep=True),
        changed_labels=changed_labels,
    )


def migrate_match_display_names(
    table: DynamoTable,
    resolve_name: NameResolver,
    *,
    apply: bool,
    match_id: str | None = None,
) -> MigrationStats:
    stats = MigrationStats()
    for item in _match_items(table, match_id):
        stats = _replace_stats(stats, examined=stats.examined + 1)
        document = item.get("document")
        if not isinstance(document, str):
            stats = _replace_stats(stats, invalid=stats.invalid + 1)
            continue
        try:
            match = StoredMatch.model_validate_json(document)
        except ValueError:
            stats = _replace_stats(stats, invalid=stats.invalid + 1)
            continue
        plan = plan_match_migration(match, resolve_name)
        if plan is None:
            continue
        if plan.changed_labels == 0:
            stats = _replace_stats(stats, unresolved=stats.unresolved + 1)
            continue
        stats = _replace_stats(stats, eligible=stats.eligible + 1)
        if not apply:
            continue
        try:
            table.update_item(
                Key={"PK": item["PK"], "SK": item["SK"]},
                UpdateExpression="SET #document = :document, #version = :version",
                ConditionExpression="#document = :oldDocument AND #version = :oldVersion",
                ExpressionAttributeNames={
                    "#document": "document",
                    "#version": "version",
                },
                ExpressionAttributeValues={
                    ":document": plan.match.model_dump_json(by_alias=True),
                    ":version": plan.match.version,
                    ":oldDocument": document,
                    ":oldVersion": match.version,
                },
            )
        except ClientError as error:
            if error.response.get("Error", {}).get("Code") != ("ConditionalCheckFailedException"):
                raise
            stats = _replace_stats(stats, conflicts=stats.conflicts + 1)
            continue
        stats = _replace_stats(stats, applied=stats.applied + 1)
    return stats


def _match_items(table: DynamoTable, match_id: str | None) -> Iterator[dict[str, Any]]:
    if match_id is not None:
        response = table.get_item(
            Key={"PK": f"MATCH#{match_id}", "SK": "STATE"},
            ConsistentRead=True,
        )
        item = response.get("Item")
        if isinstance(item, dict):
            yield item
        return

    request: dict[str, Any] = {
        "FilterExpression": "#entity = :match",
        "ExpressionAttributeNames": {"#entity": "entity"},
        "ExpressionAttributeValues": {":match": "match"},
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


def _needs_name(user_id: str, display_name: str) -> bool:
    return not user_id.startswith("deleted-") and display_name in _LEGACY_DISPLAY_NAMES


def _resolved_name(names: dict[str, str | None], user_id: str) -> str:
    name = names[user_id]
    if name is None:  # guarded by plan_match_migration before constructing changes
        raise AssertionError("display name was not resolved")
    return name


def _escape_cognito_filter(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"')


def _replace_stats(stats: MigrationStats, **changes: int) -> MigrationStats:
    values = {
        "examined": stats.examined,
        "eligible": stats.eligible,
        "applied": stats.applied,
        "unresolved": stats.unresolved,
        "conflicts": stats.conflicts,
        "invalid": stats.invalid,
    }
    values.update(changes)
    return MigrationStats(**values)


def _stack_resources(session: boto3.Session, stack_name: str) -> tuple[str, str]:
    cloudformation = session.client("cloudformation")
    response = cloudformation.describe_stacks(StackName=stack_name)
    outputs = {
        str(output["OutputKey"]): str(output["OutputValue"])
        for output in response["Stacks"][0].get("Outputs", [])
    }
    try:
        return outputs["DynamoTableName"], outputs["CognitoUserPoolId"]
    except KeyError as error:
        raise ValueError("The stack must export DynamoTableName and CognitoUserPoolId.") from error


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Replace legacy generic match labels with Cognito display-name snapshots. "
            "The default is a read-only dry run."
        )
    )
    parser.add_argument("--stack-name", help="CloudFormation stack providing table/pool outputs")
    parser.add_argument("--table-name", help="DynamoDB table name (requires --user-pool-id)")
    parser.add_argument("--user-pool-id", help="Cognito user pool (requires --table-name)")
    parser.add_argument("--region", required=True, help="AWS region containing both resources")
    parser.add_argument("--profile", help="Optional local AWS profile")
    parser.add_argument("--match-id", help="Migrate only one match UUID")
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Apply conditional updates; omit for a dry run",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    explicit_resources = bool(args.table_name or args.user_pool_id)
    if bool(args.table_name) != bool(args.user_pool_id):
        _parser().error("--table-name and --user-pool-id must be supplied together")
    if bool(args.stack_name) == explicit_resources:
        _parser().error("supply either --stack-name or both --table-name and --user-pool-id")

    session = boto3.Session(profile_name=args.profile, region_name=args.region)
    if args.stack_name:
        table_name, user_pool_id = _stack_resources(session, args.stack_name)
    else:
        table_name = str(args.table_name)
        user_pool_id = str(args.user_pool_id)
    table = session.resource("dynamodb").Table(table_name)
    resolver = CognitoNameResolver(session.client("cognito-idp"), user_pool_id)
    stats = migrate_match_display_names(
        table,
        resolver,
        apply=bool(args.apply),
        match_id=args.match_id,
    )
    mode = "apply" if args.apply else "dry-run"
    print(
        f"{mode}: examined={stats.examined} eligible={stats.eligible} "
        f"applied={stats.applied} unresolved={stats.unresolved} "
        f"conflicts={stats.conflicts} invalid={stats.invalid}"
    )
    return 1 if stats.has_failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
