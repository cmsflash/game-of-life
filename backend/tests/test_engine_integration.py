from __future__ import annotations

import shutil
from copy import deepcopy

import pytest

from life_api.engine import DartEngine
from life_api.models import MatchRulesRequest
from life_api.settings import Settings


@pytest.mark.skipif(shutil.which("dart") is None, reason="Dart SDK is not installed")
def test_python_adapter_matches_real_cli_protocol(settings: Settings) -> None:
    engine = DartEngine(settings)
    rules = MatchRulesRequest().engine_rules()
    assert rules["rulesVersion"] == 2
    assert rules["evolution"]["birthOwner"] == "movingPlayer"
    initial = engine.initial(rules)
    assert initial["revision"] == 0
    assert initial["toMove"] == "black"
    assert initial["cells"].count(1) == 2
    assert initial["cells"].count(2) == 2

    turn = engine.apply_move(
        initial,
        player="black",
        row=0,
        column=0,
        expected_revision=0,
    )
    assert turn["state"]["revision"] == 1
    assert turn["state"]["toMove"] == "white"
    assert turn["delta"] == {
        "placement": {
            "coordinate": {"row": 0, "column": 0},
            "player": "black",
        },
        "evolution": {
            "births": [],
            "deaths": [
                {
                    "coordinate": {"row": 0, "column": 0},
                    "player": "black",
                }
            ],
        },
    }


@pytest.mark.skipif(shutil.which("dart") is None, reason="Dart SDK is not installed")
def test_python_adapter_replays_stored_rules_version_1(settings: Settings) -> None:
    engine = DartEngine(settings)
    rules = deepcopy(MatchRulesRequest().engine_rules())
    rules["rulesVersion"] = 1
    rules["evolution"]["birthOwner"] = "strictNeighborMajority"
    initial = engine.initial(rules)

    black_turn = engine.apply_move(
        initial,
        player="black",
        row=7,
        column=8,
        expected_revision=0,
    )
    white_turn = engine.apply_move(
        black_turn["state"],
        player="white",
        row=0,
        column=0,
        expected_revision=1,
    )

    assert white_turn["state"]["cells"][8 * 20 + 10] == 1
    assert white_turn["state"]["cells"][9 * 20 + 8] == 1
