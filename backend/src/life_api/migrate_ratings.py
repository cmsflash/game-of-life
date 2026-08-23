from __future__ import annotations

import argparse
import hashlib
import json
import re
from collections.abc import Iterator, Sequence
from dataclasses import asdict, dataclass
from datetime import datetime
from typing import Any, Protocol

import boto3
from boto3.dynamodb.types import TypeSerializer
from botocore.exceptions import ClientError

from .models import (
    AccountState,
    MatchMetricsLedger,
    MatchStatus,
    MetricsControl,
    MetricsControlState,
    MoveEvent,
    StoredMatch,
    StoredPlayerStats,
    StoredPublicPlayer,
)
from .player_search import (
    SEARCH_INDEX_VERSION,
    canonical_display_name,
    normalize_search_text,
    search_index_keys,
)
from .ratings import accumulated_kills, build_metrics_ledger


class DynamoTable(Protocol):
    name: str

    def get_item(self, **kwargs: Any) -> dict[str, Any]: ...

    def put_item(self, **kwargs: Any) -> dict[str, Any]: ...

    def query(self, **kwargs: Any) -> dict[str, Any]: ...

    def scan(self, **kwargs: Any) -> dict[str, Any]: ...

    def update_item(self, **kwargs: Any) -> dict[str, Any]: ...


class DynamoClient(Protocol):
    def transact_write_items(self, **kwargs: Any) -> dict[str, Any]: ...


class CognitoClient(Protocol):
    def list_users(self, **kwargs: Any) -> dict[str, Any]: ...


@dataclass(frozen=True, slots=True)
class BackfillCandidate:
    item: dict[str, Any]
    match: StoredMatch
    moves: tuple[MoveEvent, ...]
    terminal_at: datetime


@dataclass(frozen=True, slots=True)
class BackfillReport:
    examined: int = 0
    excluded_legacy: int = 0
    eligible: int = 0
    already_finalized: int = 0
    applied: int = 0
    would_apply: int = 0
    profiles_created: int = 0
    conflicts: int = 0
    invalid: int = 0

    @property
    def has_failures(self) -> bool:
        return self.conflicts > 0 or self.invalid > 0


def collect_candidates(table: DynamoTable) -> tuple[list[BackfillCandidate], int]:
    candidates: list[BackfillCandidate] = []
    invalid = 0
    for item in _match_items(table):
        document = item.get("document")
        if not isinstance(document, str):
            invalid += 1
            continue
        try:
            match = StoredMatch.model_validate_json(document)
        except ValueError:
            invalid += 1
            continue
        try:
            revision = match.revision
            storage_valid = (
                item.get("PK") == f"MATCH#{match.id}"
                and item.get("SK") == "STATE"
                and int(item.get("version", match.version)) == match.version
                and int(item.get("revision", revision)) == revision
                and str(item.get("status", match.status.value)) == match.status.value
            )
        except (KeyError, TypeError, ValueError):
            storage_valid = False
        if not storage_valid:
            invalid += 1
            continue
        if match.status != MatchStatus.completed:
            continue
        try:
            moves = tuple(_move_items(table, match.id))
        except (KeyError, TypeError, ValueError):
            invalid += 1
            continue
        terminal_at = match.completed_at
        reason = match.result.get("reason") if isinstance(match.result, dict) else None
        if terminal_at is None and reason == "resignation":
            # A resignation has no terminal MoveEvent. Its preserved updatedAt
            # is the authoritative completion time even when earlier moves exist.
            terminal_at = match.updated_at
        elif terminal_at is None and moves:
            terminal_at = moves[-1].created_at
        if terminal_at is None:
            # Legacy resignations have no terminal MoveEvent; updatedAt is the
            # authoritative terminal write time for those documents.
            terminal_at = match.updated_at
        candidates.append(
            BackfillCandidate(
                item=item,
                match=match,
                moves=moves,
                terminal_at=terminal_at,
            )
        )
    candidates.sort(key=lambda value: (value.terminal_at, value.match.id))
    return candidates, invalid


def plan_backfill(table: DynamoTable) -> BackfillReport:
    candidates, invalid = collect_candidates(table)
    control = _optional_control(table)
    epoch = control.epoch if control is not None else 1
    _, _, report = _validated_plan(table, candidates, epoch=epoch)
    return _replace_report(report, invalid=report.invalid + invalid)


def begin_backfill(table: DynamoTable, *, apply: bool) -> BackfillReport:
    report = plan_backfill(table)
    if not apply or report.has_failures:
        return report
    existing = table.get_item(
        Key={"PK": "CONTROL#METRICS", "SK": "STATE"}, ConsistentRead=True
    ).get("Item")
    if existing is not None:
        state = str(existing.get("state", ""))
        if state == MetricsControlState.backfilling.value:
            return report
        raise ValueError("metrics control already exists in ready state; refusing to reset Elo")
    table.put_item(
        Item={
            "PK": "CONTROL#METRICS",
            "SK": "STATE",
            "entity": "metricsControl",
            "state": MetricsControlState.backfilling.value,
            "epoch": 1,
            "globalVersion": 0,
        },
        ConditionExpression="attribute_not_exists(PK)",
    )
    return report


def apply_backfill(
    table: DynamoTable,
    client: DynamoClient,
    *,
    apply: bool,
) -> BackfillReport:
    candidates, invalid = collect_candidates(table)
    control = _control(table)
    if control.state != MetricsControlState.backfilling:
        raise ValueError("metrics control must be backfilling before apply")
    planned, _, report = _validated_plan(table, candidates, epoch=control.epoch)
    report = _replace_report(report, invalid=report.invalid + invalid)
    if control.global_version != report.already_finalized:
        report = _replace_report(report, conflicts=report.conflicts + 1)
    if report.has_failures or not apply:
        return report

    for candidate in candidates:
        if not _is_deleted_legacy(candidate.match) or not candidate.match.rated:
            continue
        unrated = candidate.match.model_copy(
            update={
                "rated": False,
                "version": candidate.match.version + 1,
                "updated_at": candidate.match.updated_at,
            },
            deep=True,
        )
        try:
            client.transact_write_items(
                TransactItems=[
                    {
                        "Put": {
                            "TableName": table.name,
                            "Item": _serialize(_match_storage_item(unrated)),
                            "ConditionExpression": ("#version = :version AND document = :document"),
                            "ExpressionAttributeNames": {"#version": "version"},
                            "ExpressionAttributeValues": _serialize_values(
                                {
                                    ":version": candidate.match.version,
                                    ":document": str(candidate.item["document"]),
                                }
                            ),
                        }
                    }
                ]
            )
        except ClientError as error:
            if error.response.get("Error", {}).get("Code") != "TransactionCanceledException":
                raise
            return _replace_report(report, conflicts=report.conflicts + 1)
        report = _replace_report(report, applied=report.applied + 1)

    for entry in planned:
        if entry.existing:
            continue
        current_control = _control(table)
        if current_control.global_version != entry.ledger.rating_sequence - 1:
            return _replace_report(report, conflicts=report.conflicts + 1)
        if not _rating_stats_equal(
            _stats(table, entry.black_before.player_id),
            entry.black_before,
        ):
            return _replace_report(report, conflicts=report.conflicts + 1)
        if not _rating_stats_equal(
            _stats(table, entry.white_before.player_id),
            entry.white_before,
        ):
            return _replace_report(report, conflicts=report.conflicts + 1)
        try:
            client.transact_write_items(
                TransactItems=_backfill_transaction(
                    table.name,
                    entry.candidate,
                    entry.updated_match,
                    entry.ledger,
                    entry.black_before,
                    entry.white_before,
                    current_control,
                )
            )
        except ClientError as error:
            if error.response.get("Error", {}).get("Code") != "TransactionCanceledException":
                raise
            return _replace_report(report, conflicts=report.conflicts + 1)
        report = _replace_report(report, applied=report.applied + 1)
    return report


def finish_backfill(table: DynamoTable, *, apply: bool) -> BackfillReport:
    control = _control(table)
    candidates, invalid = collect_candidates(table)
    _, expected_stats, report = _validated_plan(table, candidates, epoch=control.epoch)
    report = _replace_report(report, invalid=report.invalid + invalid)
    if report.has_failures or report.eligible or report.would_apply:
        return report
    attributable_count = sum(_is_attributable(candidate.match) for candidate in candidates)
    if control.global_version != attributable_count:
        return _replace_report(report, conflicts=report.conflicts + 1)
    actual_ids: set[str] = set()
    for item in _stats_items(table):
        stats = _stats_from_item(item)
        actual_ids.add(stats.player_id)
        expected = expected_stats.get(stats.player_id)
        if stats.games != stats.wins + stats.losses + stats.draws or not _rating_stats_equal(
            stats,
            expected or _default_backfill_stats(stats.player_id),
        ):
            return _replace_report(report, invalid=report.invalid + 1)
    if any(player_id not in actual_ids for player_id in expected_stats):
        return _replace_report(report, invalid=report.invalid + 1)
    if not apply or control.state == MetricsControlState.ready:
        return report
    try:
        table.update_item(
            Key={"PK": "CONTROL#METRICS", "SK": "STATE"},
            UpdateExpression="SET #state = :ready",
            ConditionExpression=(
                "#state = :backfilling AND epoch = :epoch AND globalVersion = :version"
            ),
            ExpressionAttributeNames={"#state": "state"},
            ExpressionAttributeValues={
                ":ready": MetricsControlState.ready.value,
                ":backfilling": MetricsControlState.backfilling.value,
                ":epoch": control.epoch,
                ":version": control.global_version,
            },
        )
    except ClientError as error:
        if error.response.get("Error", {}).get("Code") != "ConditionalCheckFailedException":
            raise
        return _replace_report(report, conflicts=report.conflicts + 1)
    return report


@dataclass(frozen=True, slots=True)
class _PlannedCandidate:
    candidate: BackfillCandidate
    updated_match: StoredMatch
    ledger: MatchMetricsLedger
    black_before: StoredPlayerStats
    white_before: StoredPlayerStats
    existing: bool


def _validated_plan(
    table: DynamoTable,
    candidates: list[BackfillCandidate],
    *,
    epoch: int,
) -> tuple[list[_PlannedCandidate], dict[str, StoredPlayerStats], BackfillReport]:
    ledgers, invalid_ledgers = _all_ledgers(table)
    candidate_ids = {
        candidate.match.id for candidate in candidates if _is_attributable(candidate.match)
    }
    report = BackfillReport(examined=len(candidates), invalid=invalid_ledgers)
    if set(ledgers) - candidate_ids:
        report = _replace_report(report, conflicts=report.conflicts + 1)
    stats: dict[str, StoredPlayerStats] = {}
    planned: list[_PlannedCandidate] = []
    saw_missing = False
    sequence = 0
    for candidate in candidates:
        match = candidate.match
        if match.black_player is None or match.white_player is None:
            report = _replace_report(report, invalid=report.invalid + 1)
            continue
        if match.black_player.id == match.white_player.id:
            report = _replace_report(report, invalid=report.invalid + 1)
            continue
        if _is_deleted_legacy(match):
            report = _replace_report(
                report,
                excluded_legacy=report.excluded_legacy + 1,
            )
            if match.rated:
                report = _replace_report(report, would_apply=report.would_apply + 1)
            continue
        if not match.rated:
            report = _replace_report(report, invalid=report.invalid + 1)
            continue
        if _account_is_deleting(table, match.black_player.id) or _account_is_deleting(
            table, match.white_player.id
        ):
            report = _replace_report(report, conflicts=report.conflicts + 1)
            continue
        sequence += 1
        ordinal = sequence
        if match.result is None or tuple(event.revision for event in candidate.moves) != tuple(
            range(1, match.revision + 1)
        ):
            report = _replace_report(report, invalid=report.invalid + 1)
            continue
        try:
            black_kills, white_kills = accumulated_kills([event.delta for event in candidate.moves])
            updated = match.model_copy(
                update={
                    "black_kills": black_kills,
                    "white_kills": white_kills,
                    "kill_counts_complete": True,
                    "stats_finalized": True,
                    "completed_at": candidate.terminal_at,
                    "version": match.version if match.stats_finalized else match.version + 1,
                    "updated_at": match.updated_at,
                },
                deep=True,
            )
            black_before = stats.get(
                match.black_player.id, _default_backfill_stats(match.black_player.id)
            )
            white_before = stats.get(
                match.white_player.id, _default_backfill_stats(match.white_player.id)
            )
            ledger = build_metrics_ledger(
                updated,
                black_before,
                white_before,
                MetricsControl(
                    state=MetricsControlState.backfilling,
                    epoch=epoch,
                    global_version=ordinal - 1,
                ),
                candidate.terminal_at,
            )
        except (ValueError, OverflowError):
            report = _replace_report(report, invalid=report.invalid + 1)
            continue
        existing = ledgers.get(match.id)
        if existing is not None:
            report = _replace_report(
                report,
                already_finalized=report.already_finalized + 1,
            )
            if saw_missing or existing != ledger or not match.stats_finalized:
                report = _replace_report(report, conflicts=report.conflicts + 1)
            if (
                match.black_kills != updated.black_kills
                or match.white_kills != updated.white_kills
                or not match.kill_counts_complete
                or match.completed_at != updated.completed_at
            ):
                report = _replace_report(report, conflicts=report.conflicts + 1)
        else:
            saw_missing = True
            report = _replace_report(
                report,
                eligible=report.eligible + 1,
                would_apply=report.would_apply + 1,
            )
        planned.append(
            _PlannedCandidate(
                candidate=candidate,
                updated_match=updated,
                ledger=ledger,
                black_before=black_before,
                white_before=white_before,
                existing=existing is not None,
            )
        )
        stats[match.black_player.id] = _stats_after(
            black_before,
            rating=ledger.black_rating_after,
            score=ledger.black_score,
            kills=ledger.black_kills,
        )
        stats[match.white_player.id] = _stats_after(
            white_before,
            rating=ledger.white_rating_after,
            score=1.0 - ledger.black_score,
            kills=ledger.white_kills,
        )
    prefix_stats: dict[str, StoredPlayerStats] = {}
    for entry in planned:
        if not entry.existing:
            break
        match = entry.updated_match
        assert match.black_player is not None and match.white_player is not None
        prefix_stats[match.black_player.id] = _stats_after(
            prefix_stats.get(
                match.black_player.id,
                _default_backfill_stats(match.black_player.id),
            ),
            rating=entry.ledger.black_rating_after,
            score=entry.ledger.black_score,
            kills=entry.ledger.black_kills,
        )
        prefix_stats[match.white_player.id] = _stats_after(
            prefix_stats.get(
                match.white_player.id,
                _default_backfill_stats(match.white_player.id),
            ),
            rating=entry.ledger.white_rating_after,
            score=1.0 - entry.ledger.black_score,
            kills=entry.ledger.white_kills,
        )
    actual_stats_ids: set[str] = set()
    for item in _stats_items(table):
        try:
            actual = _stats_from_item(item)
        except (TypeError, ValueError):
            report = _replace_report(report, invalid=report.invalid + 1)
            continue
        actual_stats_ids.add(actual.player_id)
        expected = prefix_stats.get(
            actual.player_id,
            _default_backfill_stats(actual.player_id),
        )
        if not _rating_stats_equal(actual, expected):
            report = _replace_report(report, conflicts=report.conflicts + 1)
    if set(prefix_stats) - actual_stats_ids:
        report = _replace_report(report, conflicts=report.conflicts + 1)
    return planned, stats, report


def _default_backfill_stats(player_id: str) -> StoredPlayerStats:
    return StoredPlayerStats(
        player_id=player_id,
        rating=1200,
        games=0,
        wins=0,
        losses=0,
        draws=0,
        kills=0,
        spawns=0,
        version=0,
    )


def _is_attributable(match: StoredMatch) -> bool:
    players = (match.black_player, match.white_player)
    return match.rated and all(
        player is not None and not player.id.startswith("deleted-") for player in players
    )


def _rating_stats_equal(first: StoredPlayerStats, second: StoredPlayerStats) -> bool:
    return first.model_copy(update={"spawns": 0}) == second.model_copy(update={"spawns": 0})


def _is_deleted_legacy(match: StoredMatch) -> bool:
    players = (match.black_player, match.white_player)
    return all(player is not None for player in players) and any(
        player is not None and player.id.startswith("deleted-") for player in players
    )


def _match_storage_item(match: StoredMatch) -> dict[str, Any]:
    return {
        "PK": f"MATCH#{match.id}",
        "SK": "STATE",
        "entity": "match",
        "revision": match.revision,
        "version": match.version,
        "status": match.status.value,
        "creatorId": match.creator_id,
        "document": match.model_dump_json(by_alias=True),
    }


def _stats_after(
    before: StoredPlayerStats,
    *,
    rating: int,
    score: float,
    kills: int,
) -> StoredPlayerStats:
    wins, losses, draws = _result_counters(score)
    return before.model_copy(
        update={
            "rating": rating,
            "games": before.games + 1,
            "wins": before.wins + wins,
            "losses": before.losses + losses,
            "draws": before.draws + draws,
            "kills": before.kills + kills,
            "version": before.version + 1,
        }
    )


def backfill_confirmed_profiles(
    table: DynamoTable,
    client: DynamoClient,
    cognito: CognitoClient,
    user_pool_id: str,
    *,
    apply: bool,
) -> BackfillReport:
    created = 0
    invalid = 0
    for user in _confirmed_users(cognito, user_pool_id):
        attributes = {
            str(value.get("Name")): str(value.get("Value", ""))
            for value in user.get("Attributes", [])
        }
        user_id = attributes.get("sub", "").strip()
        federated = user.get("UserStatus") == "EXTERNAL_PROVIDER" or _has_federated_identity(
            attributes.get("identities")
        )
        raw_username = str(user.get("Username", "")).strip()
        username = None if federated else raw_username
        display_name = canonical_display_name(attributes.get("name", "")) or (
            "Google Player" if federated else raw_username
        )
        normalized = normalize_search_text(display_name)
        if username is not None and re.fullmatch(r"[A-Za-z0-9_.-]{3,32}", username) is None:
            invalid += 1
            continue
        normalized_username = normalize_search_text(username) if username is not None else None
        if not user_id or not normalized or len(normalized) > 48:
            invalid += 1
            continue
        if _account_is_deleting(table, user_id):
            continue
        existing = table.get_item(
            Key={"PK": f"PLAYER#{user_id}", "SK": "PROFILE"}, ConsistentRead=True
        ).get("Item")
        if existing is not None:
            try:
                StoredPublicPlayer.model_validate_json(existing["document"])
            except (KeyError, ValueError):
                invalid += 1
            continue
        created += 1
        if not apply:
            continue
        player = StoredPublicPlayer(
            id=user_id,
            username=username,
            normalized_username=normalized_username,
            display_name=display_name,
            normalized_display_name=normalized,
            search_index_version=SEARCH_INDEX_VERSION,
            discoverable=True,
            discoverability_updated_at=None,
            version=0,
        )
        try:
            client.transact_write_items(
                TransactItems=[
                    {
                        "ConditionCheck": {
                            "TableName": table.name,
                            "Key": _serialize(_account_state_key(user_id)),
                            "ConditionExpression": ("attribute_not_exists(PK) OR #state = :active"),
                            "ExpressionAttributeNames": {"#state": "state"},
                            "ExpressionAttributeValues": _serialize_values(
                                {":active": AccountState.active.value}
                            ),
                        }
                    },
                    {
                        "ConditionCheck": {
                            "TableName": table.name,
                            "Key": _serialize({"PK": f"USER#{user_id}", "SK": "ACCOUNT_DELETED"}),
                            "ConditionExpression": (
                                "attribute_not_exists(PK) OR expiresAt <= :now"
                            ),
                            "ExpressionAttributeValues": _serialize_values(
                                {":now": int(datetime.now().timestamp())}
                            ),
                        }
                    },
                    {
                        "Put": {
                            "TableName": table.name,
                            "Item": _serialize(
                                {
                                    "PK": f"PLAYER#{user_id}",
                                    "SK": "PROFILE",
                                    "entity": "publicPlayer",
                                    "version": 0,
                                    "discoverable": True,
                                    "document": player.model_dump_json(by_alias=True),
                                }
                            ),
                            "ConditionExpression": "attribute_not_exists(PK)",
                        }
                    },
                    *[
                        {
                            "Put": {
                                "TableName": table.name,
                                "Item": _serialize(
                                    {
                                        **search_key,
                                        "entity": "playerSearch",
                                        "playerId": user_id,
                                        "searchIndexVersion": SEARCH_INDEX_VERSION,
                                        "profileVersion": player.version,
                                    }
                                ),
                                "ConditionExpression": "attribute_not_exists(PK)",
                            }
                        }
                        for search_key in search_index_keys(player)
                    ],
                ]
            )
        except ClientError as error:
            if error.response.get("Error", {}).get("Code") != "TransactionCanceledException":
                raise
            created -= 1
    return BackfillReport(profiles_created=created, invalid=invalid)


def _backfill_transaction(
    table_name: str,
    candidate: BackfillCandidate,
    match: StoredMatch,
    ledger: MatchMetricsLedger,
    black_stats: StoredPlayerStats,
    white_stats: StoredPlayerStats,
    control: MetricsControl,
) -> list[dict[str, Any]]:
    if match.black_player is None or match.white_player is None:
        raise ValueError("completed match requires two players")
    return [
        *_backfill_account_conditions(table_name, match.black_player.id),
        *_backfill_account_conditions(table_name, match.white_player.id),
        {
            "Put": {
                "TableName": table_name,
                "Item": _serialize(
                    {
                        "PK": f"MATCH#{match.id}",
                        "SK": "STATE",
                        "entity": "match",
                        "revision": match.revision,
                        "version": match.version,
                        "status": match.status.value,
                        "creatorId": match.creator_id,
                        "document": match.model_dump_json(by_alias=True),
                    }
                ),
                "ConditionExpression": "#version = :version AND document = :document",
                "ExpressionAttributeNames": {"#version": "version"},
                "ExpressionAttributeValues": _serialize_values(
                    {
                        ":version": candidate.match.version,
                        ":document": str(candidate.item["document"]),
                    }
                ),
            }
        },
        {
            "Put": {
                "TableName": table_name,
                "Item": _serialize(
                    {
                        "PK": f"MATCH#{match.id}",
                        "SK": "RESULT#METRICS",
                        "entity": "matchMetrics",
                        "ratingSequence": ledger.rating_sequence,
                        "document": ledger.model_dump_json(by_alias=True),
                    }
                ),
                "ConditionExpression": "attribute_not_exists(PK)",
            }
        },
        _backfill_stats_update(
            table_name,
            match.black_player.id,
            black_stats,
            rating=ledger.black_rating_after,
            score=ledger.black_score,
            kills=ledger.black_kills,
        ),
        _backfill_stats_update(
            table_name,
            match.white_player.id,
            white_stats,
            rating=ledger.white_rating_after,
            score=1.0 - ledger.black_score,
            kills=ledger.white_kills,
        ),
        {
            "Update": {
                "TableName": table_name,
                "Key": _serialize({"PK": "CONTROL#METRICS", "SK": "STATE"}),
                "UpdateExpression": "SET globalVersion = :next",
                "ConditionExpression": (
                    "#state = :backfilling AND epoch = :epoch AND globalVersion = :version"
                ),
                "ExpressionAttributeNames": {"#state": "state"},
                "ExpressionAttributeValues": _serialize_values(
                    {
                        ":backfilling": MetricsControlState.backfilling.value,
                        ":epoch": control.epoch,
                        ":version": control.global_version,
                        ":next": ledger.rating_sequence,
                    }
                ),
            }
        },
    ]


def _backfill_stats_update(
    table_name: str,
    player_id: str,
    stats: StoredPlayerStats,
    *,
    rating: int,
    score: float,
    kills: int,
) -> dict[str, Any]:
    wins, losses, draws = _result_counters(score)
    condition = (
        "(attribute_not_exists(PK) OR #version = :version)"
        if stats.version == 0
        else "#version = :version"
    )
    return {
        "Update": {
            "TableName": table_name,
            "Key": _serialize({"PK": f"PLAYER#{player_id}", "SK": "STATS"}),
            "UpdateExpression": (
                "SET entity = :entity, playerId = :playerId, rating = :rating "
                "ADD games :one, wins :wins, losses :losses, draws :draws, "
                "kills :kills, #version :one"
            ),
            "ConditionExpression": condition,
            "ExpressionAttributeNames": {"#version": "version"},
            "ExpressionAttributeValues": _serialize_values(
                {
                    ":entity": "playerStats",
                    ":playerId": player_id,
                    ":rating": rating,
                    ":one": 1,
                    ":wins": wins,
                    ":losses": losses,
                    ":draws": draws,
                    ":kills": kills,
                    ":version": stats.version,
                }
            ),
        }
    }


def _match_items(table: DynamoTable) -> Iterator[dict[str, Any]]:
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
            yield MoveEvent.model_validate_json(item["document"])
        last_key = response.get("LastEvaluatedKey")
        if not isinstance(last_key, dict):
            return
        request["ExclusiveStartKey"] = last_key


def _stats_items(table: DynamoTable) -> Iterator[dict[str, Any]]:
    request: dict[str, Any] = {
        "FilterExpression": "#entity = :stats",
        "ExpressionAttributeNames": {"#entity": "entity"},
        "ExpressionAttributeValues": {":stats": "playerStats"},
        "ConsistentRead": True,
    }
    while True:
        response = table.scan(**request)
        yield from (item for item in response.get("Items", []) if isinstance(item, dict))
        last_key = response.get("LastEvaluatedKey")
        if not isinstance(last_key, dict):
            return
        request["ExclusiveStartKey"] = last_key


def _stats(table: DynamoTable, player_id: str) -> StoredPlayerStats:
    item = table.get_item(
        Key={"PK": f"PLAYER#{player_id}", "SK": "STATS"}, ConsistentRead=True
    ).get("Item")
    return _stats_from_item(item, player_id=player_id)


def _stats_from_item(
    item: dict[str, Any] | None,
    *,
    player_id: str | None = None,
) -> StoredPlayerStats:
    item = item or {}
    resolved_id = player_id or str(item.get("playerId", ""))
    return StoredPlayerStats(
        player_id=resolved_id,
        rating=int(item.get("rating", 1200)),
        games=int(item.get("games", 0)),
        wins=int(item.get("wins", 0)),
        losses=int(item.get("losses", 0)),
        draws=int(item.get("draws", 0)),
        kills=int(item.get("kills", 0)),
        spawns=int(item.get("spawns", 0)),
        version=int(item.get("version", 0)),
    )


def _control(table: DynamoTable) -> MetricsControl:
    item = table.get_item(Key={"PK": "CONTROL#METRICS", "SK": "STATE"}, ConsistentRead=True).get(
        "Item"
    )
    if item is None:
        raise ValueError("metrics control is missing; run begin first")
    return MetricsControl(
        state=MetricsControlState(str(item["state"])),
        epoch=int(item["epoch"]),
        global_version=int(item.get("globalVersion", 0)),
    )


def _ledger(table: DynamoTable, match_id: str) -> MatchMetricsLedger | None:
    item = table.get_item(
        Key={"PK": f"MATCH#{match_id}", "SK": "RESULT#METRICS"}, ConsistentRead=True
    ).get("Item")
    return MatchMetricsLedger.model_validate_json(item["document"]) if item is not None else None


def _all_ledgers(table: DynamoTable) -> tuple[dict[str, MatchMetricsLedger], int]:
    request: dict[str, Any] = {
        "FilterExpression": "#entity = :ledger",
        "ExpressionAttributeNames": {"#entity": "entity"},
        "ExpressionAttributeValues": {":ledger": "matchMetrics"},
        "ConsistentRead": True,
    }
    result: dict[str, MatchMetricsLedger] = {}
    invalid = 0
    while True:
        response = table.scan(**request)
        for item in response.get("Items", []):
            if not isinstance(item, dict) or not isinstance(item.get("document"), str):
                invalid += 1
                continue
            try:
                ledger = MatchMetricsLedger.model_validate_json(item["document"])
                storage_valid = (
                    item.get("PK") == f"MATCH#{ledger.match_id}"
                    and item.get("SK") == "RESULT#METRICS"
                    and int(item.get("ratingSequence", -1)) == ledger.rating_sequence
                )
            except (TypeError, ValueError):
                invalid += 1
            else:
                if not storage_valid or ledger.match_id in result:
                    invalid += 1
                else:
                    result[ledger.match_id] = ledger
        last_key = response.get("LastEvaluatedKey")
        if not isinstance(last_key, dict):
            return result, invalid
        request["ExclusiveStartKey"] = last_key


def _optional_control(table: DynamoTable) -> MetricsControl | None:
    item = table.get_item(Key={"PK": "CONTROL#METRICS", "SK": "STATE"}, ConsistentRead=True).get(
        "Item"
    )
    if item is None:
        return None
    return MetricsControl(
        state=MetricsControlState(str(item["state"])),
        epoch=int(item["epoch"]),
        global_version=int(item.get("globalVersion", 0)),
    )


def _confirmed_users(client: CognitoClient, user_pool_id: str) -> Iterator[dict[str, Any]]:
    request: dict[str, Any] = {"UserPoolId": user_pool_id, "Limit": 60}
    while True:
        response = client.list_users(**request)
        for user in response.get("Users", []):
            if user.get("Enabled", True) and user.get("UserStatus") in {
                "CONFIRMED",
                "EXTERNAL_PROVIDER",
            }:
                yield user
        token = response.get("PaginationToken")
        if not isinstance(token, str):
            return
        request["PaginationToken"] = token


def _has_federated_identity(raw: str | None) -> bool:
    if not raw:
        return False
    try:
        identities = json.loads(raw)
    except ValueError:
        return True
    return not isinstance(identities, list) or bool(identities)


def _result_counters(score: float) -> tuple[int, int, int]:
    if score == 1.0:
        return 1, 0, 0
    if score == 0.0:
        return 0, 1, 0
    if score == 0.5:
        return 0, 0, 1
    raise ValueError("score must be 0, 0.5, or 1")


def _serialize(item: dict[str, Any]) -> dict[str, Any]:
    serializer = TypeSerializer()
    return {key: serializer.serialize(value) for key, value in item.items()}


def _account_state_key(user_id: str) -> dict[str, str]:
    digest = hashlib.sha256(user_id.encode()).hexdigest()
    return {"PK": f"ACCOUNT#{digest}", "SK": "STATE"}


def _backfill_account_conditions(
    table_name: str,
    user_id: str,
) -> list[dict[str, Any]]:
    return [
        {
            "ConditionCheck": {
                "TableName": table_name,
                "Key": _serialize(_account_state_key(user_id)),
                "ConditionExpression": "attribute_not_exists(PK) OR #state = :active",
                "ExpressionAttributeNames": {"#state": "state"},
                "ExpressionAttributeValues": _serialize_values(
                    {":active": AccountState.active.value}
                ),
            }
        },
        {
            "ConditionCheck": {
                "TableName": table_name,
                "Key": _serialize({"PK": f"USER#{user_id}", "SK": "ACCOUNT_DELETED"}),
                "ConditionExpression": "attribute_not_exists(PK) OR expiresAt <= :now",
                "ExpressionAttributeValues": _serialize_values(
                    {":now": int(datetime.now().timestamp())}
                ),
            }
        },
    ]


def _account_is_deleting(table: DynamoTable, user_id: str) -> bool:
    state = table.get_item(Key=_account_state_key(user_id), ConsistentRead=True).get("Item")
    if state is not None and state.get("state") != AccountState.active.value:
        return True
    guard = table.get_item(
        Key={"PK": f"USER#{user_id}", "SK": "ACCOUNT_DELETED"},
        ConsistentRead=True,
    ).get("Item")
    return guard is not None and int(guard.get("expiresAt", 0)) > int(datetime.now().timestamp())


def _serialize_values(item: dict[str, Any]) -> dict[str, Any]:
    return _serialize(item)


def _replace_report(report: BackfillReport, **updates: int) -> BackfillReport:
    values = {
        "examined": report.examined,
        "excluded_legacy": report.excluded_legacy,
        "eligible": report.eligible,
        "already_finalized": report.already_finalized,
        "applied": report.applied,
        "would_apply": report.would_apply,
        "profiles_created": report.profiles_created,
        "conflicts": report.conflicts,
        "invalid": report.invalid,
    }
    values.update(updates)
    return BackfillReport(**values)


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


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Dry-run-first public-profile and chronological Elo backfill. "
            "Use phases plan, begin, apply, and finish in order."
        )
    )
    parser.add_argument("phase", choices=("plan", "begin", "apply", "finish"))
    parser.add_argument("--stack-name", required=True)
    parser.add_argument("--region", required=True)
    parser.add_argument("--profile")
    parser.add_argument(
        "--apply",
        action="store_true",
        help="perform conditional writes; omit for a read-only dry run",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    session = boto3.Session(profile_name=args.profile, region_name=args.region)
    table_name, user_pool_id = _stack_resources(session, args.stack_name)
    table = session.resource("dynamodb").Table(table_name)
    client = session.client("dynamodb")
    cognito = session.client("cognito-idp")
    if args.phase == "plan":
        report = plan_backfill(table)
        profiles = backfill_confirmed_profiles(
            table,
            client,
            cognito,
            user_pool_id,
            apply=False,
        )
        report = _replace_report(
            report,
            profiles_created=profiles.profiles_created,
            invalid=report.invalid + profiles.invalid,
        )
    elif args.phase == "begin":
        report = begin_backfill(table, apply=args.apply)
    elif args.phase == "apply":
        profiles = backfill_confirmed_profiles(
            table,
            client,
            cognito,
            user_pool_id,
            apply=args.apply,
        )
        report = apply_backfill(table, client, apply=args.apply)
        report = _replace_report(
            report,
            profiles_created=profiles.profiles_created,
            invalid=report.invalid + profiles.invalid,
        )
    else:
        profiles = backfill_confirmed_profiles(
            table,
            client,
            cognito,
            user_pool_id,
            apply=False,
        )
        if profiles.profiles_created or profiles.invalid:
            report = BackfillReport(
                profiles_created=profiles.profiles_created,
                invalid=profiles.invalid + (1 if profiles.profiles_created else 0),
            )
        else:
            report = finish_backfill(table, apply=args.apply)
    print(json.dumps(asdict(report), sort_keys=True))
    incomplete_finish = args.phase == "finish" and (report.eligible > 0 or report.would_apply > 0)
    return 1 if report.has_failures or incomplete_finish else 0


if __name__ == "__main__":
    raise SystemExit(main())
