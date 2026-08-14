from __future__ import annotations

import pytest

from life_api.ratings import _round_symmetric, deaths_by_credit, elo_delta


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
