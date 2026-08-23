from __future__ import annotations

from life_api.models import StoredPublicPlayer
from life_api.player_search import (
    normalize_player_query,
    player_matches_query,
    player_search_sort_key,
    search_index_keys,
)


def _player(
    player_id: str,
    display_name: str,
    *,
    username: str | None = None,
) -> StoredPublicPlayer:
    return StoredPublicPlayer(
        id=player_id,
        username=username,
        normalized_username=username.casefold() if username is not None else None,
        display_name=display_name,
        normalized_display_name=display_name.casefold(),
        search_index_version=2,
    )


def test_search_index_contains_every_display_name_and_username_suffix() -> None:
    player = _player("player-1", "Shen Zhuoran", username="CMS_Flash")

    pairs = {(item["PK"], item["SK"]) for item in search_index_keys(player)}

    assert ("SEARCH_TEXT#s", "shen zhuoran#player-1") in pairs
    assert ("SEARCH_TEXT#z", "zhuoran#player-1") in pairs
    assert ("SEARCH_TEXT#c", "cms_flash#player-1") in pairs
    assert ("SEARCH_TEXT#f", "flash#player-1") in pairs
    assert len(pairs) == len("shen zhuoran") + len("cms_flash")


def test_duplicate_values_do_not_create_duplicate_index_rows() -> None:
    player = _player("player-1", "CMS", username="CMS")

    assert len(search_index_keys(player)) == len("cms")


def test_bounded_display_name_and_username_fit_one_dynamo_transaction() -> None:
    player = _player("player-1", "a" * 48, username="b" * 32)

    assert len(search_index_keys(player)) == 80


def test_query_normalization_supports_at_handles_unicode_and_whitespace() -> None:
    assert normalize_player_query("  @ＣＭＳ＿Ｆｌａｓｈ  ") == "cms_flash"  # noqa: RUF001
    assert normalize_player_query("  Shen   Zhuoran ") == "shen zhuoran"


def test_matching_and_ranking_cover_full_substrings_of_both_fields() -> None:
    exact_username = _player("1", "Someone", username="CMS")
    exact_display = _player("2", "CMS", username="other")
    username_prefix = _player("3", "Someone", username="CMS_Flash")
    display_prefix = _player("4", "CMS Player", username="other4")
    username_contains = _player("5", "Someone", username="The_CMS_Flash")
    display_contains = _player("6", "The CMS Player", username="other6")
    players = [
        display_contains,
        username_contains,
        display_prefix,
        username_prefix,
        exact_display,
        exact_username,
    ]

    assert all(player_matches_query(player, "cms") for player in players)
    assert [
        player.id
        for player in sorted(players, key=lambda value: player_search_sort_key(value, "cms"))
    ] == ["1", "2", "3", "4", "5", "6"]
