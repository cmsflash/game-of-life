from __future__ import annotations

import pytest

from life_api.ratings import (
    _round_symmetric,
    accumulated_kills,
    accumulated_spawns,
    deaths_by_credit,
    elo_delta,
    spawns_by_color,
)


def test_elo_uses_symmetric_half_away_rounding_and_zero_sum() -> None:
    assert _round_symmetric(2.5) == 3
    assert _round_symmetric(-2.5) == -3
    assert elo_delta(1200, 1200, 1.0) == 16
    assert elo_delta(1200, 1200, 0.0) == -16
    delta = elo_delta(-500, 3200, 0.5)
    assert delta + -delta == 0


def test_deaths_credit_the_opposite_color_regardless_of_mover() -> None:
    delta = {
        "placed": {"player": "black", "row": 1, "column": 1},
        "evolution": {
            "deaths": [
                {"row": 1, "column": 1, "player": "black"},
                {"row": 2, "column": 2, "player": "white"},
                {"row": 3, "column": 3, "player": "black"},
            ]
        },
    }

    assert deaths_by_credit(delta) == (1, 2)


def test_kills_accumulate_by_dead_color_on_both_players_turns() -> None:
    black_turn = {
        "placement": {"player": "black", "coordinate": {"row": 0, "column": 0}},
        "evolution": {
            "births": [],
            "deaths": [{"player": "white", "coordinate": {"row": 1, "column": 1}}],
        },
    }
    white_turn = {
        "placement": {"player": "white", "coordinate": {"row": 0, "column": 1}},
        "evolution": {
            "births": [],
            "deaths": [{"player": "white", "coordinate": {"row": 1, "column": 2}}],
        },
    }

    assert accumulated_kills([black_turn, white_turn]) == (2, 0)


def test_spawns_accumulate_by_birth_color_on_both_players_turns() -> None:
    black_turn = {
        "placement": {"player": "black", "coordinate": {"row": 0, "column": 0}},
        "evolution": {
            "births": [
                {"player": "white", "coordinate": {"row": 1, "column": 1}},
                {"player": "black", "coordinate": {"row": 1, "column": 2}},
            ],
            "deaths": [],
        },
    }
    white_turn = {
        "placement": {"player": "white", "coordinate": {"row": 0, "column": 1}},
        "evolution": {
            "births": [
                {"player": "black", "coordinate": {"row": 2, "column": 1}},
                {"player": "black", "coordinate": {"row": 2, "column": 2}},
            ],
            "deaths": [],
        },
    }

    assert accumulated_spawns([black_turn, white_turn]) == (3, 1)


def test_legacy_spawn_fallback_excludes_explicit_manual_placement() -> None:
    delta = {
        "placed": {"player": "black", "row": 0, "column": 0},
        "changes": [
            {"row": 0, "column": 0, "from": 0, "to": 1},
            {"row": 1, "column": 1, "from": 0, "to": 1},
            {"row": 2, "column": 2, "from": 0, "to": 2},
        ],
    }

    assert spawns_by_color(delta) == (1, 1)


@pytest.mark.parametrize(
    "delta",
    [
        {"changes": [{"from": 0, "to": 1}]},
        {
            "placed": {"player": "black"},
            "changes": [{"row": 1, "column": 1, "from": 0, "to": 1}],
        },
    ],
)
def test_legacy_spawn_fallback_never_guesses_without_coordinates(
    delta: dict[str, object],
) -> None:
    with pytest.raises(ValueError):
        spawns_by_color(delta)


@pytest.mark.parametrize(
    "delta",
    [
        {},
        {"evolution": {}},
        {"evolution": {"deaths": "not-a-list"}},
        {"evolution": {"deaths": [{"player": "green"}]}},
    ],
)
def test_unknown_or_malformed_authoritative_death_shapes_fail_closed(
    delta: dict[str, object],
) -> None:
    with pytest.raises(ValueError):
        deaths_by_credit(delta)
