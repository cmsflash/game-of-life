from __future__ import annotations

import shutil

import pytest

from life_api.engine import DartEngine
from life_api.models import MatchRulesRequest
from life_api.settings import Settings


@pytest.mark.skipif(shutil.which("dart") is None, reason="Dart SDK is not installed")
def test_python_adapter_matches_real_cli_protocol(settings: Settings) -> None:
    engine = DartEngine(settings)
    rules = MatchRulesRequest().engine_rules()
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
