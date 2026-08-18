from __future__ import annotations

import argparse
import json
from collections.abc import Iterator, Sequence
from dataclasses import asdict, dataclass
from typing import Any, Protocol

import boto3
from boto3.dynamodb.types import TypeSerializer
from botocore.exceptions import ClientError

from .models import MatchMetricsLedger, MatchSpawnMetrics, MatchStatus, MoveEvent, StoredMatch
from .ratings import accumulated_spawns


class DynamoTable(Protocol):
    name: str

    def get_item(self, **kwargs: Any) -> dict[str, Any]: ...

    def query(self, **kwargs: Any) -> dict[str, Any]: ...

    def scan(self, **kwargs: Any) -> dict[str, Any]: ...


class DynamoClient(Protocol):
    def transact_write_items(self, **kwargs: Any) -> dict[str, Any]: ...


@dataclass(frozen=True, slots=True)
class SpawnMigrationReport:
    examined: int = 0
    excluded: int = 0
    eligible: int = 0
    already_complete: int = 0
    applied: int = 0
    conflicts: int = 0
    invalid: int = 0

    @property
    def has_failures(self) -> bool:
        return self.conflicts > 0 or self.invalid > 0


@dataclass(frozen=True, slots=True)
class _Candidate:
    match: StoredMatch
    spawn_metrics: MatchSpawnMetrics
    player_spawns: tuple[tuple[str, int], ...]


def migrate_completed_spawns(
    table: DynamoTable,
    client: DynamoClient,
    *,
    apply: bool,
    match_id: str | None = None,
) -> SpawnMigrationReport:
    report = SpawnMigrationReport()
    for item in _match_items(table, match_id=match_id):
        document = item.get("document")
        if not isinstance(document, str):
            report = _replace_report(report, invalid=report.invalid + 1)
            continue
        try:
            match = StoredMatch.model_validate_json(document)
            storage_valid = (
                item.get("PK") == f"MATCH#{match.id}"
                and item.get("SK") == "STATE"
                and item.get("entity") == "match"
                and int(item["version"]) == match.version
                and int(item["revision"]) == match.revision
                and str(item["status"]) == match.status.value
            )
        except (KeyError, TypeError, ValueError):
            storage_valid = False
            match = None
        if not storage_valid or match is None:
            report = _replace_report(report, invalid=report.invalid + 1)
            continue
        if match.status != MatchStatus.completed or not match.rated:
            continue
        report = _replace_report(report, examined=report.examined + 1)
        if not match.stats_finalized:
            report = _replace_report(report, excluded=report.excluded + 1)
            continue
        candidate = _candidate(table, match)
        if isinstance(candidate, str):
            if candidate == "complete":
                report = _replace_report(
                    report,
                    already_complete=report.already_complete + 1,
                )
            else:
                report = _replace_report(report, invalid=report.invalid + 1)
            continue
        report = _replace_report(report, eligible=report.eligible + 1)
        if not apply:
            continue
        try:
            client.transact_write_items(
                TransactItems=_transaction(table.name, candidate),
            )
        except ClientError as error:
            if error.response.get("Error", {}).get("Code") != "TransactionCanceledException":
                raise
            report = _replace_report(report, conflicts=report.conflicts + 1)
            continue
        report = _replace_report(report, applied=report.applied + 1)
    aggregate_ready = not report.eligible or (apply and report.applied == report.eligible)
    if aggregate_ready and not report.has_failures:
        report = _replace_report(
            report,
            invalid=report.invalid + _aggregate_errors(table),
        )
    return report


def _candidate(table: DynamoTable, match: StoredMatch) -> _Candidate | str:
    if match.black_player is None or match.white_player is None:
        return "invalid"
    if match.black_player.id == match.white_player.id:
        return "invalid"
    ledger_item = table.get_item(
        Key={"PK": f"MATCH#{match.id}", "SK": "RESULT#METRICS"},
        ConsistentRead=True,
    ).get("Item")
    if not isinstance(ledger_item, dict) or not isinstance(ledger_item.get("document"), str):
        return "invalid"
    ledger_json = str(ledger_item["document"])
    try:
        ledger = MatchMetricsLedger.model_validate_json(ledger_json)
        ledger_storage_valid = (
            ledger_item.get("PK") == f"MATCH#{match.id}"
            and ledger_item.get("SK") == "RESULT#METRICS"
            and ledger_item.get("entity") == "matchMetrics"
            and int(ledger_item.get("ratingSequence", -1)) == ledger.rating_sequence
            and ledger.match_id == match.id
            and match.completed_at == ledger.completed_at
        )
    except (TypeError, ValueError):
        return "invalid"
    if not ledger_storage_valid:
        return "invalid"
    try:
        moves = tuple(_move_items(table, match.id))
        if tuple(move.revision for move in moves) != tuple(range(1, match.revision + 1)):
            return "invalid"
        if any(not _actor_matches_player(move, match) for move in moves):
            return "invalid"
        black_spawns, white_spawns = accumulated_spawns([move.delta for move in moves])
    except (KeyError, TypeError, ValueError):
        return "invalid"
    expected = MatchSpawnMetrics(
        match_id=match.id,
        completed_at=ledger.completed_at,
        black_spawns=black_spawns,
        white_spawns=white_spawns,
    )
    marker_item = table.get_item(
        Key={"PK": f"MATCH#{match.id}", "SK": "RESULT#SPAWNS"},
        ConsistentRead=True,
    ).get("Item")
    if marker_item is not None:
        if not isinstance(marker_item, dict) or not isinstance(marker_item.get("document"), str):
            return "invalid"
        try:
            existing_marker = MatchSpawnMetrics.model_validate_json(marker_item["document"])
        except ValueError:
            return "invalid"
        if (
            marker_item.get("PK") != f"MATCH#{match.id}"
            or marker_item.get("SK") != "RESULT#SPAWNS"
            or marker_item.get("entity") != "matchSpawns"
            or existing_marker != expected
        ):
            return "invalid"
        return "complete"
    player_spawns = tuple(
        (player.id, count)
        for player, count in (
            (match.black_player, black_spawns),
            (match.white_player, white_spawns),
        )
        if not player.id.startswith("deleted-")
    )
    for player_id, _ in player_spawns:
        stats = table.get_item(
            Key={"PK": f"PLAYER#{player_id}", "SK": "STATS"},
            ConsistentRead=True,
        ).get("Item")
        if (
            not isinstance(stats, dict)
            or stats.get("entity") != "playerStats"
            or stats.get("playerId") != player_id
        ):
            return "invalid"
    return _Candidate(
        match=match,
        spawn_metrics=expected,
        player_spawns=player_spawns,
    )


def _transaction(table_name: str, candidate: _Candidate) -> list[dict[str, Any]]:
    operations: list[dict[str, Any]] = [
        {
            "Put": {
                "TableName": table_name,
                "Item": _serialize(
                    {
                        "PK": f"MATCH#{candidate.match.id}",
                        "SK": "RESULT#SPAWNS",
                        "entity": "matchSpawns",
                        "document": candidate.spawn_metrics.model_dump_json(by_alias=True),
                    }
                ),
                "ConditionExpression": "attribute_not_exists(PK)",
            }
        }
    ]
    operations.extend(
        {
            "Update": {
                "TableName": table_name,
                "Key": _serialize({"PK": f"PLAYER#{player_id}", "SK": "STATS"}),
                "UpdateExpression": "SET spawns = if_not_exists(spawns, :zero) + :spawns",
                "ConditionExpression": "entity = :statsEntity AND playerId = :playerId",
                "ExpressionAttributeValues": _serialize_values(
                    {
                        ":zero": 0,
                        ":spawns": spawns,
                        ":statsEntity": "playerStats",
                        ":playerId": player_id,
                    }
                ),
            }
        }
        for player_id, spawns in candidate.player_spawns
    )
    return operations


def _match_items(table: DynamoTable, *, match_id: str | None) -> Iterator[dict[str, Any]]:
    if match_id is not None:
        item = table.get_item(
            Key={"PK": f"MATCH#{match_id}", "SK": "STATE"},
            ConsistentRead=True,
        ).get("Item")
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
        yield from (item for item in response.get("Items", []) if isinstance(item, dict))
        last_key = response.get("LastEvaluatedKey")
        if not isinstance(last_key, dict):
            return
        request["ExclusiveStartKey"] = last_key


def _move_items(table: DynamoTable, match_id: str) -> Iterator[MoveEvent]:
    request: dict[str, Any] = {
        "KeyConditionExpression": "PK = :pk AND begins_with(SK, :prefix)",
        "ExpressionAttributeValues": {":pk": f"MATCH#{match_id}", ":prefix": "MOVE#"},
        "ConsistentRead": True,
    }
    while True:
        response = table.query(**request)
        for item in response.get("Items", []):
            event = MoveEvent.model_validate_json(item["document"])
            if (
                item.get("PK") != f"MATCH#{match_id}"
                or item.get("SK") != f"MOVE#{event.revision:08d}"
                or item.get("entity") != "move"
            ):
                raise ValueError("move storage fields do not match its document")
            yield event
        last_key = response.get("LastEvaluatedKey")
        if not isinstance(last_key, dict):
            return
        request["ExclusiveStartKey"] = last_key


def _actor_matches_player(move: MoveEvent, match: StoredMatch) -> bool:
    player = match.black_player if move.player == "black" else match.white_player
    return player is not None and move.actor_id == player.id


def _aggregate_errors(table: DynamoTable) -> int:
    expected: dict[str, int] = {}
    errors = 0
    for item in _entity_items(table, "matchSpawns"):
        document = item.get("document")
        if not isinstance(document, str):
            errors += 1
            continue
        try:
            marker = MatchSpawnMetrics.model_validate_json(document)
        except ValueError:
            errors += 1
            continue
        if (
            item.get("PK") != f"MATCH#{marker.match_id}"
            or item.get("SK") != "RESULT#SPAWNS"
            or item.get("entity") != "matchSpawns"
        ):
            errors += 1
            continue
        match_item = table.get_item(
            Key={"PK": f"MATCH#{marker.match_id}", "SK": "STATE"},
            ConsistentRead=True,
        ).get("Item")
        if not isinstance(match_item, dict) or not isinstance(match_item.get("document"), str):
            errors += 1
            continue
        try:
            match = StoredMatch.model_validate_json(match_item["document"])
        except ValueError:
            errors += 1
            continue
        if (
            match_item.get("PK") != f"MATCH#{match.id}"
            or match_item.get("SK") != "STATE"
            or match_item.get("entity") != "match"
            or match.id != marker.match_id
            or match.status != MatchStatus.completed
            or not match.rated
            or not match.stats_finalized
            or match.completed_at != marker.completed_at
            or match.black_player is None
            or match.white_player is None
        ):
            errors += 1
            continue
        for player, count in (
            (match.black_player, marker.black_spawns),
            (match.white_player, marker.white_spawns),
        ):
            if not player.id.startswith("deleted-"):
                expected[player.id] = expected.get(player.id, 0) + count
    seen: set[str] = set()
    for item in _entity_items(table, "playerStats"):
        try:
            player_id = str(item["playerId"])
            spawns = int(item.get("spawns", 0))
        except (KeyError, TypeError, ValueError):
            errors += 1
            continue
        storage_valid = (
            item.get("PK") == f"PLAYER#{player_id}"
            and item.get("SK") == "STATS"
            and item.get("entity") == "playerStats"
        )
        if not storage_valid or player_id in seen or spawns != expected.get(player_id, 0):
            errors += 1
        seen.add(player_id)
    errors += len(set(expected) - seen)
    return errors


def _entity_items(table: DynamoTable, entity: str) -> Iterator[dict[str, Any]]:
    request: dict[str, Any] = {
        "FilterExpression": "#entity = :entity",
        "ExpressionAttributeNames": {"#entity": "entity"},
        "ExpressionAttributeValues": {":entity": entity},
        "ConsistentRead": True,
    }
    while True:
        response = table.scan(**request)
        yield from (item for item in response.get("Items", []) if isinstance(item, dict))
        last_key = response.get("LastEvaluatedKey")
        if not isinstance(last_key, dict):
            return
        request["ExclusiveStartKey"] = last_key


def _serialize(item: dict[str, Any]) -> dict[str, Any]:
    serializer = TypeSerializer()
    return {key: serializer.serialize(value) for key, value in item.items()}


def _serialize_values(item: dict[str, Any]) -> dict[str, Any]:
    return _serialize(item)


def _replace_report(
    report: SpawnMigrationReport,
    **updates: int,
) -> SpawnMigrationReport:
    values = asdict(report)
    values.update(updates)
    return SpawnMigrationReport(**values)


def _stack_table_name(session: boto3.Session, stack_name: str) -> str:
    response = session.client("cloudformation").describe_stacks(StackName=stack_name)
    outputs = {
        str(output["OutputKey"]): str(output["OutputValue"])
        for output in response["Stacks"][0].get("Outputs", [])
    }
    try:
        return outputs["DynamoTableName"]
    except KeyError as error:
        raise ValueError("stack must export DynamoTableName") from error


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Atomically add historical spawn-result records and player totals. "
            "The default is a read-only dry run."
        )
    )
    parser.add_argument("--stack-name", required=True)
    parser.add_argument("--region", required=True)
    parser.add_argument("--profile")
    parser.add_argument("--match-id", help="Migrate only one completed match UUID")
    parser.add_argument(
        "--apply",
        action="store_true",
        help="perform conditional writes; omit for a read-only dry run",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    session = boto3.Session(profile_name=args.profile, region_name=args.region)
    table_name = _stack_table_name(session, args.stack_name)
    report = migrate_completed_spawns(
        session.resource("dynamodb").Table(table_name),
        session.client("dynamodb"),
        apply=bool(args.apply),
        match_id=args.match_id,
    )
    print(json.dumps(asdict(report), sort_keys=True))
    return 1 if report.has_failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
