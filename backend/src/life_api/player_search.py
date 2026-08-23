from __future__ import annotations

import unicodedata

from .models import StoredPublicPlayer

SEARCH_INDEX_VERSION = 2
SEARCH_PARTITION_PREFIX = "SEARCH_TEXT#"


def canonical_display_name(value: str) -> str:
    return " ".join(unicodedata.normalize("NFKC", value).split())


def normalize_search_text(value: str) -> str:
    return canonical_display_name(value).casefold()


def normalize_player_query(value: str) -> str:
    normalized = normalize_search_text(value)
    if normalized.startswith("@"):
        normalized = normalized[1:]
    return normalized


def search_index_keys(player: StoredPublicPlayer) -> list[dict[str, str]]:
    pairs: set[tuple[str, str]] = set()
    for value in searchable_values(player):
        for offset in range(len(value)):
            suffix = value[offset:]
            partition = suffix[0]
            pairs.add(
                (
                    f"{SEARCH_PARTITION_PREFIX}{partition}",
                    f"{suffix}#{player.id}",
                )
            )
    return [{"PK": pk, "SK": sk} for pk, sk in sorted(pairs)]


def search_partition(normalized_query: str) -> str:
    return f"{SEARCH_PARTITION_PREFIX}{normalized_query[0]}"


def searchable_values(player: StoredPublicPlayer) -> tuple[str, ...]:
    values = [player.normalized_display_name]
    if player.normalized_username:
        values.append(player.normalized_username)
    return tuple(dict.fromkeys(value for value in values if value))


def player_matches_query(player: StoredPublicPlayer, normalized_query: str) -> bool:
    return any(normalized_query in value for value in searchable_values(player))


def player_search_sort_key(
    player: StoredPublicPlayer,
    normalized_query: str,
) -> tuple[int, int, str, str, str]:
    username = player.normalized_username or ""
    display_name = player.normalized_display_name
    if username == normalized_query:
        category, position = 0, 0
    elif display_name == normalized_query:
        category, position = 1, 0
    elif username.startswith(normalized_query):
        category, position = 2, 0
    elif display_name.startswith(normalized_query):
        category, position = 3, 0
    elif username and normalized_query in username:
        category, position = 4, username.index(normalized_query)
    else:
        category, position = 5, display_name.index(normalized_query)
    return category, position, display_name, username, player.id
