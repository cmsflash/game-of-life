from __future__ import annotations

from life_api.models import MatchRulesRequest


def test_new_matches_resolve_to_rules_version_2_with_mover_owned_births() -> None:
    rules = MatchRulesRequest().engine_rules()

    assert rules["rulesVersion"] == 2
    assert rules["evolution"]["birthOwner"] == "movingPlayer"
