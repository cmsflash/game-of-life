from __future__ import annotations

from copy import deepcopy
from datetime import UTC, datetime
from typing import Any

from boto3.dynamodb.types import TypeDeserializer
from botocore.exceptions import ClientError

from life_api.migrate_ratings import finish_backfill
from life_api.migrate_spawns import migrate_completed_spawns
from life_api.models import (
    MatchStatus,
    MetricsControl,
    MetricsControlState,
    MoveEvent,
    PlayerSummary,
    StoredMatch,
    StoredPlayerStats,
)
from life_api.ratings import build_metrics_ledger


class MemoryTable:
    name = "game-table"

    def __init__(self, items: list[dict[str, Any]]) -> None:
        self.items = items

    def scan(self, **kwargs: Any) -> dict[str, Any]:
        values = kwargs.get("ExpressionAttributeValues", {})
        entity = next(
            (values[key] for key in (":match", ":ledger", ":stats", ":entity") if key in values),
            None,
        )
        return {"Items": [item for item in self.items if item.get("entity") == entity]}

    def query(self, **kwargs: Any) -> dict[str, Any]:
        pk = kwargs["ExpressionAttributeValues"][":pk"]
        prefix = kwargs["ExpressionAttributeValues"][":prefix"]
        return {
            "Items": [
                item
                for item in self.items
                if item.get("PK") == pk and str(item.get("SK", "")).startswith(prefix)
            ]
        }

    def get_item(self, **kwargs: Any) -> dict[str, Any]:
        key = kwargs["Key"]
        item = next(
            (
                item
                for item in self.items
                if item.get("PK") == key["PK"] and item.get("SK") == key["SK"]
            ),
            None,
        )
        return {"Item": item} if item is not None else {}


class ApplyingClient:
    def __init__(self, table: MemoryTable) -> None:
        self.table = table
        self.calls = 0

    def transact_write_items(self, **kwargs: Any) -> dict[str, Any]:
        operations = kwargs["TransactItems"]
        deserializer = TypeDeserializer()

        def deserialize(values: dict[str, Any]) -> dict[str, Any]:
            return {key: deserializer.deserialize(value) for key, value in values.items()}

        marker = deserialize(operations[0]["Put"]["Item"])
        if self.table.get_item(Key={"PK": marker["PK"], "SK": marker["SK"]}).get("Item"):
            raise ClientError(
                {"Error": {"Code": "TransactionCanceledException", "Message": "exists"}},
                "TransactWriteItems",
            )
        pending: list[tuple[dict[str, Any], int]] = []
        for operation in operations[1:]:
            update = operation["Update"]
            key = deserialize(update["Key"])
            values = deserialize(update["ExpressionAttributeValues"])
            item = self.table.get_item(Key=key).get("Item")
            if (
                not isinstance(item, dict)
                or item.get("entity") != values[":statsEntity"]
                or item.get("playerId") != values[":playerId"]
            ):
                raise ClientError(
                    {
                        "Error": {
                            "Code": "TransactionCanceledException",
                            "Message": "stats changed",
                        }
                    },
                    "TransactWriteItems",
                )
            pending.append((item, int(values[":spawns"])))
        self.table.items.append(marker)
        for item, spawns in pending:
            item["spawns"] = int(item.get("spawns", 0)) + spawns
        self.calls += 1
        return {}


def _fixture(
    *,
    deleted_white: bool = False,
    match_id: str = "00000000-0000-4000-8000-000000000101",
) -> tuple[MemoryTable, StoredMatch]:
    completed_at = datetime(2026, 8, 18, 12, tzinfo=UTC)
    black_id = "alice"
    white_id = "deleted-bob" if deleted_white else "bob"
    match = StoredMatch(
        id=match_id,
        join_code="SPAWN1",
        rules={},
        state={"revision": 2, "toMove": "black", "stateHash": "state-2"},
        creator_id=black_id,
        creator_name="Alice",
        black_player=PlayerSummary(id=black_id, display_name="Alice"),
        white_player=PlayerSummary(id=white_id, display_name="Deleted" if deleted_white else "Bob"),
        status=MatchStatus.completed,
        result={"type": "win", "winner": "black", "reason": "elimination"},
        rated=True,
        kill_counts_complete=True,
        stats_finalized=True,
        completed_at=completed_at,
        version=3,
        updated_at=completed_at,
    )
    black_before = StoredPlayerStats(
        player_id=black_id,
        rating=1200,
        games=0,
        wins=0,
        losses=0,
        draws=0,
        kills=0,
    )
    white_before = black_before.model_copy(update={"player_id": white_id})
    ledger = build_metrics_ledger(
        match,
        black_before,
        white_before,
        MetricsControl(
            state=MetricsControlState.backfilling,
            epoch=1,
            global_version=0,
        ),
        completed_at,
    )
    moves = [
        MoveEvent(
            revision=1,
            actor_id=black_id,
            player="black",
            row=0,
            column=0,
            delta={
                "evolution": {
                    "births": [{"player": "black"}, {"player": "white"}],
                    "deaths": [],
                }
            },
            state_hash="state-1",
            created_at=completed_at,
        ),
        MoveEvent(
            revision=2,
            actor_id=white_id,
            player="white",
            row=0,
            column=1,
            delta={
                "evolution": {
                    "births": [{"player": "black"}, {"player": "black"}],
                    "deaths": [],
                }
            },
            state_hash="state-2",
            created_at=completed_at,
        ),
    ]
    items: list[dict[str, Any]] = [
        {
            "PK": "CONTROL#METRICS",
            "SK": "STATE",
            "entity": "metricsControl",
            "state": "ready",
            "epoch": 1,
            "globalVersion": 1,
        },
        {
            "PK": f"MATCH#{match.id}",
            "SK": "STATE",
            "entity": "match",
            "version": match.version,
            "revision": match.revision,
            "status": match.status.value,
            "document": match.model_dump_json(by_alias=True),
        },
        {
            "PK": f"MATCH#{match.id}",
            "SK": "RESULT#METRICS",
            "entity": "matchMetrics",
            "ratingSequence": 1,
            "document": ledger.model_dump_json(by_alias=True),
        },
        *[
            {
                "PK": f"MATCH#{match.id}",
                "SK": f"MOVE#{move.revision:08d}",
                "entity": "move",
                "document": move.model_dump_json(by_alias=True),
            }
            for move in moves
        ],
        {
            "PK": f"PLAYER#{black_id}",
            "SK": "STATS",
            "entity": "playerStats",
            "playerId": black_id,
            "rating": ledger.black_rating_after,
            "games": 1,
            "wins": 1,
            "losses": 0,
            "draws": 0,
            "kills": 0,
            "version": 1,
        },
    ]
    if not deleted_white:
        items.append(
            {
                "PK": f"PLAYER#{white_id}",
                "SK": "STATS",
                "entity": "playerStats",
                "playerId": white_id,
                "rating": ledger.white_rating_after,
                "games": 1,
                "wins": 0,
                "losses": 1,
                "draws": 0,
                "kills": 0,
                "version": 1,
            }
        )
    return MemoryTable(items), match


def test_spawn_migration_is_dry_run_first_atomic_and_idempotent() -> None:
    table, match = _fixture()
    client = ApplyingClient(table)

    dry_run = migrate_completed_spawns(table, client, apply=False)
    assert dry_run.examined == 1
    assert dry_run.eligible == 1
    assert dry_run.applied == 0
    assert not dry_run.has_failures
    assert client.calls == 0

    applied = migrate_completed_spawns(table, client, apply=True)
    assert applied.eligible == 1
    assert applied.applied == 1
    assert not applied.has_failures
    assert client.calls == 1
    assert table.get_item(Key={"PK": f"MATCH#{match.id}", "SK": "RESULT#SPAWNS"})
    assert table.get_item(Key={"PK": "PLAYER#alice", "SK": "STATS"})["Item"]["spawns"] == 3
    assert table.get_item(Key={"PK": "PLAYER#bob", "SK": "STATS"})["Item"]["spawns"] == 1

    repeated = migrate_completed_spawns(table, client, apply=False)
    assert repeated.eligible == 0
    assert repeated.already_complete == 1
    assert not repeated.has_failures
    assert client.calls == 1

    # The orthogonal spawn field is ignored by the historical Elo replay, so
    # its dry-run remains clean and never rewrites or re-rates the prefix.
    ratings_rerun = finish_backfill(table, apply=False)
    assert not ratings_rerun.has_failures


def test_spawn_migration_preserves_survivor_when_opponent_was_anonymized() -> None:
    table, _ = _fixture(deleted_white=True)
    client = ApplyingClient(table)

    applied = migrate_completed_spawns(table, client, apply=True)
    assert applied.applied == 1
    assert not applied.has_failures
    assert table.get_item(Key={"PK": "PLAYER#alice", "SK": "STATS"})["Item"]["spawns"] == 3

    repeated = migrate_completed_spawns(table, client, apply=False)
    assert repeated.already_complete == 1
    assert not repeated.has_failures


def test_complete_marker_with_missing_durable_stats_fails_aggregate_validation() -> None:
    table, _ = _fixture()
    client = ApplyingClient(table)
    migrate_completed_spawns(table, client, apply=True)
    table.items = [item for item in table.items if item.get("PK") != "PLAYER#alice"]

    report = migrate_completed_spawns(table, client, apply=False)

    assert report.already_complete == 1
    assert report.invalid > 0


def test_complete_marker_with_wrong_global_spawn_sum_fails_validation() -> None:
    table, _ = _fixture()
    client = ApplyingClient(table)
    migrate_completed_spawns(table, client, apply=True)
    table.get_item(Key={"PK": "PLAYER#alice", "SK": "STATS"})["Item"]["spawns"] = 99

    report = migrate_completed_spawns(table, client, apply=False)

    assert report.already_complete == 1
    assert report.invalid > 0


def test_apply_validates_preexisting_markers_with_newly_applied_candidate() -> None:
    table, _ = _fixture()
    client = ApplyingClient(table)
    migrate_completed_spawns(table, client, apply=True)
    table.get_item(Key={"PK": "PLAYER#alice", "SK": "STATS"})["Item"]["spawns"] = 99
    second, _ = _fixture(match_id="00000000-0000-4000-8000-000000000102")
    table.items.extend(
        item for item in second.items if item.get("entity") in {"match", "matchMetrics", "move"}
    )

    report = migrate_completed_spawns(table, client, apply=True)

    assert report.already_complete == 1
    assert report.applied == 1
    assert report.invalid > 0


def test_unfinalized_legacy_result_is_reported_as_excluded() -> None:
    table, match = _fixture()
    unfinalized = match.model_copy(update={"stats_finalized": False})
    match_item = table.get_item(Key={"PK": f"MATCH#{match.id}", "SK": "STATE"})["Item"]
    match_item["document"] = unfinalized.model_dump_json(by_alias=True)

    report = migrate_completed_spawns(table, ApplyingClient(table), apply=False)

    assert report.excluded == 1
    assert report.eligible == 0
    assert not report.has_failures


def test_malformed_move_storage_or_swapped_actor_fails_closed() -> None:
    table, match = _fixture()
    first_move = table.get_item(Key={"PK": f"MATCH#{match.id}", "SK": "MOVE#00000001"})["Item"]
    malformed = deepcopy(first_move)
    malformed["SK"] = "MOVE#00000009"
    table.items[table.items.index(first_move)] = malformed

    report = migrate_completed_spawns(table, ApplyingClient(table), apply=False)
    assert report.invalid == 1

    table, match = _fixture()
    first_move = table.get_item(Key={"PK": f"MATCH#{match.id}", "SK": "MOVE#00000001"})["Item"]
    event = MoveEvent.model_validate_json(first_move["document"])
    first_move["document"] = event.model_copy(update={"actor_id": "bob"}).model_dump_json(
        by_alias=True
    )

    report = migrate_completed_spawns(table, ApplyingClient(table), apply=False)
    assert report.invalid == 1
