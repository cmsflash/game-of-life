from __future__ import annotations

from life_api.models import MatchRulesRequest


def test_new_matches_resolve_to_rules_version_3_with_majority_births() -> None:
    rules = MatchRulesRequest().engine_rules()

    assert rules["rulesVersion"] == 3
    assert rules["evolution"]["birthOwner"] == "strictNeighborMajority"
