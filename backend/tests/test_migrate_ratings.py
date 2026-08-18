from __future__ import annotations

import json
from datetime import UTC, datetime, timedelta
from typing import Any

import pytest
from boto3.dynamodb.types import TypeDeserializer
from botocore.exceptions import ClientError

from life_api.migrate_ratings import (
    BackfillCandidate,
    _backfill_transaction,
    apply_backfill,
    backfill_confirmed_profiles,
    collect_candidates,
    finish_backfill,
    plan_backfill,
)
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
        self.update_requests: list[dict[str, Any]] = []

    def scan(self, **kwargs: Any) -> dict[str, Any]:
        entity = next(
            (
                value
                for key, value in kwargs.get("ExpressionAttributeValues", {}).items()
                if key in {":match", ":ledger", ":stats"}
            ),
            None,
        )
        return {"Items": [item for item in self.items if item.get("entity") == entity]}

    def query(self, **kwargs: Any) -> dict[str, Any]:
        pk = kwargs.get("ExpressionAttributeValues", {}).get(":pk")
        return {
            "Items": [
                item
                for item in self.items
                if item.get("PK") == pk and str(item.get("SK", "")).startswith("MOVE#")
            ]
        }

    def get_item(self, **kwargs: Any) -> dict[str, Any]:
        key = kwargs["Key"]
        item = next(
            (
                value
                for value in self.items
                if value.get("PK") == key["PK"] and value.get("SK") == key["SK"]
            ),
            None,
        )
        return {"Item": item} if item is not None else {}

    def put_item(self, **kwargs: Any) -> dict[str, Any]:
        self.items.append(kwargs["Item"])
        return {}

    def update_item(self, **kwargs: Any) -> dict[str, Any]:
        self.update_requests.append(kwargs)
        key = kwargs["Key"]
        item = next(
            value
            for value in self.items
            if value.get("PK") == key["PK"] and value.get("SK") == key["SK"]
        )
        if ":ready" in kwargs.get("ExpressionAttributeValues", {}):
            item["state"] = kwargs["ExpressionAttributeValues"][":ready"]
        return {}


class RecordingClient:
    def __init__(self) -> None:
        self.transactions: list[list[dict[str, Any]]] = []

    def transact_write_items(self, **kwargs: Any) -> dict[str, Any]:
        self.transactions.append(kwargs["TransactItems"])
        return {}


class LegacyGuardRejectingClient(RecordingClient):
    def transact_write_items(self, **kwargs: Any) -> dict[str, Any]:
        transaction = kwargs["TransactItems"]
        deserializer = TypeDeserializer()
        keys = [
            {
                name: deserializer.deserialize(value)
                for name, value in operation["ConditionCheck"]["Key"].items()
            }
            for operation in transaction
            if "ConditionCheck" in operation
        ]
        if any(key["SK"] == "ACCOUNT_DELETED" for key in keys):
            raise ClientError(
                {"Error": {"Code": "TransactionCanceledException", "Message": "guarded"}},
                "TransactWriteItems",
            )
        return super().transact_write_items(**kwargs)


class ConfirmedCognito:
    def list_users(self, **kwargs: Any) -> dict[str, Any]:
        del kwargs
        return {
            "Users": [
                {
                    "Username": "legacy-login-name",
                    "Enabled": True,
                    "UserStatus": "CONFIRMED",
                    "Attributes": [
                        {"Name": "sub", "Value": "deleting-user"},
                        {"Name": "name", "Value": "Public Name"},
                    ],
                }
            ]
        }


class NamedConfirmedCognito:
    def __init__(self, display_name: str) -> None:
        self.display_name = display_name

    def list_users(self, **kwargs: Any) -> dict[str, Any]:
        del kwargs
        return {
            "Users": [
                {
                    "Username": "confirmed-login",
                    "Enabled": True,
                    "UserStatus": "CONFIRMED",
                    "Attributes": [
                        {"Name": "sub", "Value": "confirmed-user"},
                        {"Name": "name", "Value": self.display_name},
                    ],
                }
            ]
        }


def _match(
    match_id: str,
    *,
    updated_at: datetime,
    reason: str,
    deleted: bool = False,
) -> StoredMatch:
    black_id = "deleted-black" if deleted else f"black-{match_id}"
    white_id = "deleted-white" if deleted else f"white-{match_id}"
    return StoredMatch(
        id=match_id,
        join_code="ABC123",
        rules={},
        state={"revision": 1, "toMove": "white"},
        creator_id=black_id,
        creator_name="Black",
        black_player=PlayerSummary(id=black_id, display_name="Black"),
        white_player=PlayerSummary(id=white_id, display_name="White"),
        status=MatchStatus.completed,
        result={"type": "win", "winner": "black", "reason": reason},
        updated_at=updated_at,
    )


def _move(match: StoredMatch, created_at: datetime, delta: dict[str, Any]) -> dict[str, Any]:
    event = MoveEvent(
        revision=1,
        actor_id=match.black_player.id if match.black_player else "unknown",
        player="black",
        row=0,
        column=0,
        delta=delta,
        state_hash="state-1",
        created_at=created_at,
    )
    return {
        "PK": f"MATCH#{match.id}",
        "SK": "MOVE#00000001",
        "entity": "move",
        "document": event.model_dump_json(by_alias=True),
    }


def _match_item(match: StoredMatch, *, raw_document: str | None = None) -> dict[str, Any]:
    return {
        "PK": f"MATCH#{match.id}",
        "SK": "STATE",
        "entity": "match",
        "version": match.version,
        "document": raw_document or match.model_dump_json(by_alias=True),
    }


def _control() -> dict[str, Any]:
    return {
        "PK": "CONTROL#METRICS",
        "SK": "STATE",
        "entity": "metricsControl",
        "state": "backfilling",
        "epoch": 1,
        "globalVersion": 0,
    }


def test_resignation_uses_terminal_updated_at_even_when_prior_moves_exist() -> None:
    base = datetime(2026, 8, 14, tzinfo=UTC)
    resigned = _match(
        "00000000-0000-4000-8000-000000000002",
        updated_at=base + timedelta(hours=10),
        reason="resignation",
    )
    natural = _match(
        "00000000-0000-4000-8000-000000000001",
        updated_at=base + timedelta(hours=12),
        reason="elimination",
    )
    table = MemoryTable(
        [
            _match_item(resigned),
            _move(resigned, base + timedelta(hours=1), {"changes": []}),
            _match_item(natural),
            _move(natural, base + timedelta(hours=5), {"changes": []}),
        ]
    )

    candidates, invalid = collect_candidates(table)

    assert invalid == 0
    assert [candidate.match.id for candidate in candidates] == [natural.id, resigned.id]
    assert candidates[1].terminal_at == resigned.updated_at


def test_dry_run_validates_malformed_historical_move_without_writing() -> None:
    match = _match(
        "00000000-0000-4000-8000-000000000003",
        updated_at=datetime(2026, 8, 14, tzinfo=UTC),
        reason="elimination",
    )
    table = MemoryTable([_control(), _match_item(match), _move(match, match.updated_at, {})])
    client = RecordingClient()

    report = apply_backfill(table, client, apply=False)

    assert report.invalid == 1
    assert client.transactions == []


def test_anonymized_legacy_matches_are_explicitly_excluded_from_elo() -> None:
    match = _match(
        "00000000-0000-4000-8000-000000000004",
        updated_at=datetime(2026, 8, 14, tzinfo=UTC),
        reason="resignation",
        deleted=True,
    )
    report = plan_backfill(MemoryTable([_match_item(match)]))

    assert report.examined == 1
    assert report.excluded_legacy == 1
    assert report.eligible == 0
    assert report.would_apply == 1


def test_match_cas_uses_exact_legacy_json_instead_of_reserialized_defaults() -> None:
    match = _match(
        "00000000-0000-4000-8000-000000000005",
        updated_at=datetime(2026, 8, 14, tzinfo=UTC),
        reason="elimination",
    )
    legacy = match.model_dump(by_alias=True, mode="json")
    for field in (
        "origin",
        "rated",
        "blackKills",
        "whiteKills",
        "killCountsComplete",
        "statsFinalized",
        "completedAt",
    ):
        legacy.pop(field, None)
    raw = json.dumps(legacy, separators=(",", ":"))
    parsed = StoredMatch.model_validate_json(raw)
    assert parsed.black_player is not None
    assert parsed.white_player is not None
    candidate = BackfillCandidate(
        item=_match_item(parsed, raw_document=raw),
        match=parsed,
        moves=(),
        terminal_at=parsed.updated_at,
    )
    stats_black = StoredPlayerStats(
        player_id=parsed.black_player.id,
        rating=1200,
        games=0,
        wins=0,
        losses=0,
        draws=0,
        kills=0,
    )
    stats_white = stats_black.model_copy(update={"player_id": parsed.white_player.id})
    updated = parsed.model_copy(
        update={
            "kill_counts_complete": True,
            "stats_finalized": True,
            "completed_at": parsed.updated_at,
            "version": parsed.version + 1,
        }
    )
    control = MetricsControl(
        state=MetricsControlState.backfilling,
        epoch=1,
        global_version=0,
    )
    ledger = build_metrics_ledger(
        updated,
        stats_black,
        stats_white,
        control,
        parsed.updated_at,
    )

    transaction = _backfill_transaction(
        "game-table", candidate, updated, ledger, stats_black, stats_white, control
    )
    match_put = next(
        operation["Put"]
        for operation in transaction
        if "Put" in operation and operation["Put"]["Item"]["SK"] == {"S": "STATE"}
    )
    expected = match_put["ExpressionAttributeValues"][":document"]

    assert TypeDeserializer().deserialize(expected) == raw


def test_profile_backfill_checks_legacy_deletion_guard_before_public_indexing() -> None:
    table = MemoryTable([])
    client = LegacyGuardRejectingClient()

    report = backfill_confirmed_profiles(
        table,
        client,
        ConfirmedCognito(),
        "pool-id",
        apply=True,
    )

    assert report.profiles_created == 0
    assert all(not item.get("PK", "").startswith("PLAYER#") for item in table.items)


@pytest.mark.parametrize(
    ("display_name", "expected_partitions"),
    [
        ("Q", {"SEARCH#q"}),
        ("Li", {"SEARCH#l", "SEARCH#li"}),
        ("Alice", {"SEARCH#a", "SEARCH#al", "SEARCH#ali"}),
    ],
)
def test_profile_backfill_writes_all_available_public_search_prefixes(
    display_name: str,
    expected_partitions: set[str],
) -> None:
    client = RecordingClient()

    report = backfill_confirmed_profiles(
        MemoryTable([]),
        client,
        NamedConfirmedCognito(display_name),
        "pool-id",
        apply=True,
    )

    assert report.profiles_created == 1
    deserializer = TypeDeserializer()
    partitions = {
        str(deserializer.deserialize(operation["Put"]["Item"]["PK"]))
        for operation in client.transactions[0]
        if operation.get("Put", {}).get("Item", {}).get("entity") == {"S": "playerSearch"}
    }
    assert partitions == expected_partitions


def _finished_table(*, control_version: int = 1, corrupt_zero_stats: bool = False) -> MemoryTable:
    terminal_at = datetime(2026, 8, 14, tzinfo=UTC)
    match = _match(
        "00000000-0000-4000-8000-000000000010",
        updated_at=terminal_at,
        reason="elimination",
    )
    move = _move(match, terminal_at, {"changes": []})
    updated = match.model_copy(
        update={
            "black_kills": 0,
            "white_kills": 0,
            "kill_counts_complete": True,
            "stats_finalized": True,
            "completed_at": terminal_at,
            "version": match.version + 1,
        }
    )
    assert updated.black_player is not None and updated.white_player is not None
    black_before = StoredPlayerStats(
        player_id=updated.black_player.id,
        rating=1200,
        games=0,
        wins=0,
        losses=0,
        draws=0,
        kills=0,
    )
    white_before = black_before.model_copy(update={"player_id": updated.white_player.id})
    ledger = build_metrics_ledger(
        updated,
        black_before,
        white_before,
        MetricsControl(
            state=MetricsControlState.backfilling,
            epoch=1,
            global_version=0,
        ),
        terminal_at,
    )
    black_stats = {
        "PK": f"PLAYER#{updated.black_player.id}",
        "SK": "STATS",
        "entity": "playerStats",
        "playerId": updated.black_player.id,
        "rating": ledger.black_rating_after,
        "games": 1,
        "wins": 1,
        "losses": 0,
        "draws": 0,
        "kills": 0,
        "version": 1,
    }
    if corrupt_zero_stats:
        black_stats.update(rating=1500, games=0, wins=0, version=0)
    return MemoryTable(
        [
            {
                **_control(),
                "globalVersion": control_version,
            },
            _match_item(updated),
            move,
            {
                "PK": f"MATCH#{updated.id}",
                "SK": "RESULT#METRICS",
                "entity": "matchMetrics",
                "ratingSequence": 1,
                "document": ledger.model_dump_json(by_alias=True),
            },
            black_stats,
            {
                "PK": f"PLAYER#{updated.white_player.id}",
                "SK": "STATS",
                "entity": "playerStats",
                "playerId": updated.white_player.id,
                "rating": ledger.white_rating_after,
                "games": 1,
                "wins": 0,
                "losses": 1,
                "draws": 0,
                "kills": 0,
                "version": 1,
            },
        ]
    )


def test_finish_dry_run_does_not_flip_and_apply_is_idempotent() -> None:
    table = _finished_table()

    dry_run = finish_backfill(table, apply=False)
    assert not dry_run.has_failures
    assert table.update_requests == []
    assert (
        table.get_item(Key={"PK": "CONTROL#METRICS", "SK": "STATE"})["Item"]["state"]
        == "backfilling"
    )

    applied = finish_backfill(table, apply=True)
    assert not applied.has_failures
    assert len(table.update_requests) == 1
    assert table.get_item(Key={"PK": "CONTROL#METRICS", "SK": "STATE"})["Item"]["state"] == "ready"

    repeated = finish_backfill(table, apply=True)
    assert not repeated.has_failures
    assert len(table.update_requests) == 1


def test_finish_refuses_control_or_zero_game_stats_mismatch() -> None:
    wrong_control = finish_backfill(_finished_table(control_version=0), apply=True)
    corrupt_stats = finish_backfill(
        _finished_table(corrupt_zero_stats=True),
        apply=True,
    )

    assert wrong_control.conflicts > 0
    assert corrupt_stats.conflicts > 0 or corrupt_stats.invalid > 0


def test_existing_ledger_prefix_remains_clean_with_a_missing_suffix() -> None:
    table = _finished_table()
    later = _match(
        "00000000-0000-4000-8000-000000000011",
        updated_at=datetime(2026, 8, 14, 1, tzinfo=UTC),
        reason="elimination",
    )
    table.items.extend(
        [
            _match_item(later),
            _move(later, later.updated_at, {"changes": []}),
        ]
    )
    client = RecordingClient()

    report = apply_backfill(table, client, apply=False)

    assert report.already_finalized == 1
    assert report.eligible == 1
    assert report.conflicts == 0
    assert report.invalid == 0
    assert client.transactions == []
