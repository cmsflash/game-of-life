from __future__ import annotations

import math
from datetime import datetime

from .models import MatchMetricsLedger, MetricsControl, StoredMatch, StoredPlayerStats

INITIAL_RATING = 1200
ELO_K_FACTOR = 32


def deaths_by_credit(delta: dict[str, object]) -> tuple[int, int]:
    """Return (black kills, white kills) from authoritative death colors."""
    evolution = delta.get("evolution")
    if evolution is not None:
        if not isinstance(evolution, dict):
            raise ValueError("move delta evolution must be an object")
        deaths = evolution.get("deaths")
        if not isinstance(deaths, list):
            raise ValueError("move delta evolution.deaths must be a list")
        black_kills = 0
        white_kills = 0
        for death in deaths:
            if not isinstance(death, dict) or death.get("player") not in {"black", "white"}:
                raise ValueError("each move death must identify black or white")
            if death["player"] == "black":
                white_kills += 1
            else:
                black_kills += 1
        return black_kills, white_kills

    # Compatibility with early test/fixture deltas. A transition from a live
    # numeric cell to zero is a death; 1 is Black and 2 is White.
    changes = delta.get("changes")
    if not isinstance(changes, list):
        raise ValueError("move delta must contain evolution.deaths or legacy changes")
    black_kills = 0
    white_kills = 0
    for change in changes:
        if not isinstance(change, dict) or "from" not in change or "to" not in change:
            raise ValueError("each legacy move change must contain from and to values")
        if change.get("to") != 0:
            continue
        if change.get("from") == 1:
            white_kills += 1
        elif change.get("from") == 2:
            black_kills += 1
    return black_kills, white_kills


def accumulated_kills(deltas: list[dict[str, object]]) -> tuple[int, int]:
    black = 0
    white = 0
    for delta in deltas:
        black_delta, white_delta = deaths_by_credit(delta)
        black += black_delta
        white += white_delta
    return black, white


def black_score(result: dict[str, object] | None) -> float:
    if result is None:
        raise ValueError("a completed rated match requires a result")
    if result.get("type") == "draw":
        return 0.5
    if result.get("type") == "win":
        winner = result.get("winner")
        if winner == "black":
            return 1.0
        if winner == "white":
            return 0.0
    raise ValueError("unsupported terminal result")


def elo_delta(black_rating: int, white_rating: int, score: float) -> int:
    expected = 1.0 / (1.0 + 10.0 ** ((white_rating - black_rating) / 400.0))
    raw = ELO_K_FACTOR * (score - expected)
    return _round_symmetric(raw)


def _round_symmetric(value: float) -> int:
    """Round exact halves away from zero for color-symmetric Elo updates."""
    return int(math.floor(value + 0.5) if value >= 0 else math.ceil(value - 0.5))


def build_metrics_ledger(
    match: StoredMatch,
    black_stats: StoredPlayerStats,
    white_stats: StoredPlayerStats,
    control: MetricsControl,
    completed_at: datetime,
) -> MatchMetricsLedger:
    score = black_score(match.result)
    black_delta = elo_delta(black_stats.rating, white_stats.rating, score)
    return MatchMetricsLedger(
        match_id=match.id,
        epoch=control.epoch,
        rating_sequence=control.global_version + 1,
        completed_at=completed_at,
        black_kills=match.black_kills,
        white_kills=match.white_kills,
        black_rating_before=black_stats.rating,
        white_rating_before=white_stats.rating,
        black_rating_after=black_stats.rating + black_delta,
        white_rating_after=white_stats.rating - black_delta,
        black_rating_delta=black_delta,
        white_rating_delta=-black_delta,
        black_score=score,
    )
