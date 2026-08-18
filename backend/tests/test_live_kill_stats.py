from __future__ import annotations

from copy import deepcopy
from datetime import UTC, datetime
from typing import Any

import pytest

from life_api.avatars import AvatarService, InMemoryAvatarObjectStore
from life_api.errors import ApiError
from life_api.models import (
    MatchStatus,
    MoveEvent,
    MoveRequest,
    PlayerSummary,
    ResignRequest,
    StoredMatch,
    StoredPlayerStats,
    User,
)
from life_api.repository import InMemoryRepository
from life_api.service import MatchService
from life_api.social import SocialService


class UnusedEngine:
    def initial(self, rules: dict[str, Any]) -> dict[str, Any]:
        raise AssertionError("not used")

    def apply_move(self, *args: Any, **kwargs: Any) -> dict[str, Any]:
        raise AssertionError("not used")

    def replay(self, rules: dict[str, Any], moves: list[dict[str, Any]]) -> dict[str, Any]:
        raise AssertionError("not used")


class TerminalEngine(UnusedEngine):
    def apply_move(
        self,
        state: dict[str, Any],
        *,
        player: str,
        row: int,
        column: int,
        expected_revision: int,
    ) -> dict[str, Any]:
        assert expected_revision == state["revision"]
        assert player == state["toMove"]
        updated = deepcopy(state)
        updated.update(
            {
                "revision": expected_revision + 1,
                "toMove": "white" if player == "black" else "black",
                "stateHash": f"state-{expected_revision + 1}",
                "outcome": {"type": "win", "winner": "black", "reason": "elimination"},
            }
        )
        return {
            "state": updated,
            "delta": {
                "placed": {"row": row, "column": column, "player": player},
                "evolution": {
                    "deaths": [
                        {"row": 1, "column": 1, "player": "white"},
                        {"row": 1, "column": 2, "player": "white"},
                    ]
                },
            },
        }


class ActiveEngine(TerminalEngine):
    def apply_move(
        self,
        state: dict[str, Any],
        *,
        player: str,
        row: int,
        column: int,
        expected_revision: int,
    ) -> dict[str, Any]:
        turn = super().apply_move(
            state,
            player=player,
            row=row,
            column=column,
            expected_revision=expected_revision,
        )
        turn["state"]["outcome"] = None
        if expected_revision > 0:
            turn["delta"]["evolution"]["deaths"] = []
        return turn


class OrderedRepository(InMemoryRepository):
    def __init__(self) -> None:
        super().__init__()
        self.stats_read_order: list[str] = []

    def get_player_stats(self, player_id: str) -> StoredPlayerStats:
        self.stats_read_order.append("stored")
        return super().get_player_stats(player_id)

    def list_matches(self, user_id: str) -> list[StoredMatch]:
        self.stats_read_order.append("matches")
        return super().list_matches(user_id)


def _user(user_id: str) -> User:
    return User(
        id=user_id,
        username=user_id,
        email=f"{user_id}@example.com",
        display_name=user_id.title(),
        email_verified=True,
    )


def _social(repository: InMemoryRepository) -> SocialService:
    avatars = AvatarService(
        repository,
        InMemoryAvatarObjectStore(),
        "http://testserver",
    )
    return SocialService(repository, UnusedEngine(), avatars)


def _active_match(
    repository: InMemoryRepository,
    *,
    suffix: str,
    black_id: str,
    white_id: str,
    black_kills: int = 0,
    white_kills: int = 0,
    kill_counts_complete: bool = True,
    rated: bool = True,
) -> StoredMatch:
    waiting = StoredMatch(
        id=f"00000000-0000-4000-8000-{int(suffix):012d}",
        join_code=f"A{int(suffix):05d}",
        rules={},
        state={"revision": 0, "toMove": "black", "stateHash": "state-0"},
        creator_id=black_id,
        creator_name=black_id.title(),
        status=MatchStatus.waiting,
        black_kills=black_kills,
        white_kills=white_kills,
        kill_counts_complete=kill_counts_complete,
        rated=rated,
    )
    repository.create_match(waiting)
    active = waiting.model_copy(
        update={
            "black_player": PlayerSummary(id=black_id, display_name=black_id.title()),
            "white_player": PlayerSummary(id=white_id, display_name=white_id.title()),
            "status": MatchStatus.active,
            "version": 1,
        }
    )
    repository.join_match(active, white_id)
    return active


def _commit_legacy_move(
    repository: InMemoryRepository,
    match: StoredMatch,
    *,
    revision: int,
    actor_id: str,
    player: str,
    delta: dict[str, Any],
    state_revision: int | None = None,
) -> StoredMatch:
    updated = match.model_copy(
        update={
            "state": {
                **match.state,
                "revision": state_revision or revision,
                "toMove": "white" if player == "black" else "black",
                "stateHash": f"state-{state_revision or revision}",
            },
            "version": match.version + 1,
        }
    )
    repository.commit_move(
        match=updated,
        expected_version=match.version,
        event=MoveEvent(
            revision=revision,
            actor_id=actor_id,
            player=player,
            row=0,
            column=revision,
            delta=delta,
            state_hash=f"state-{state_revision or revision}",
            created_at=datetime.now(UTC),
        ),
        user_id=actor_id,
        idempotency_key=f"legacy-move-{match.id}-{revision}",
        request_fingerprint=f"fingerprint-{revision}",
    )
    return updated


def test_active_kills_are_live_for_both_colors_and_multiple_matches() -> None:
    repository = OrderedRepository()
    _active_match(
        repository,
        suffix="1",
        black_id="alice",
        white_id="bob",
        black_kills=4,
        white_kills=2,
    )
    _active_match(
        repository,
        suffix="2",
        black_id="carol",
        white_id="alice",
        black_kills=7,
        white_kills=3,
    )
    _active_match(
        repository,
        suffix="3",
        black_id="alice",
        white_id="dave",
        black_kills=100,
        rated=False,
    )
    _active_match(
        repository,
        suffix="4",
        black_id="alice",
        white_id="deleted-opponent",
        black_kills=100,
    )
    repository.create_match(
        StoredMatch(
            id="00000000-0000-4000-8000-000000000010",
            join_code="A00010",
            rules={},
            state={"revision": 0},
            creator_id="alice",
            creator_name="Alice",
            status=MatchStatus.waiting,
            black_kills=100,
            kill_counts_complete=True,
        )
    )
    social = _social(repository)

    assert social.stats(_user("alice")).kills == 7
    assert social.stats(_user("alice")).kills == 7
    assert repository.get_player_stats("alice").kills == 0
    assert repository.stats_read_order[:2] == ["stored", "matches"]


def test_legacy_active_match_kills_reconstruct_from_contiguous_history() -> None:
    repository = InMemoryRepository()
    match = _active_match(
        repository,
        suffix="5",
        black_id="alice",
        white_id="bob",
        kill_counts_complete=False,
    )
    match = _commit_legacy_move(
        repository,
        match,
        revision=1,
        actor_id="alice",
        player="black",
        delta={"changes": [{"from": 1, "to": 0}]},
    )
    _commit_legacy_move(
        repository,
        match,
        revision=2,
        actor_id="bob",
        player="white",
        delta={
            "changes": [
                {"from": 2, "to": 0},
                {"from": 2, "to": 0},
            ]
        },
    )

    social = _social(repository)
    assert social.stats(_user("alice")).kills == 2
    assert social.stats(_user("bob")).kills == 1


def test_legacy_snapshot_ignores_a_concurrently_committed_later_move() -> None:
    repository = InMemoryRepository()
    match = _active_match(
        repository,
        suffix="11",
        black_id="alice",
        white_id="bob",
        kill_counts_complete=False,
    )
    snapshot = _commit_legacy_move(
        repository,
        match,
        revision=1,
        actor_id="alice",
        player="black",
        delta={"changes": [{"from": 2, "to": 0}]},
    )
    _commit_legacy_move(
        repository,
        snapshot,
        revision=2,
        actor_id="bob",
        player="white",
        delta={"changes": [{"from": 2, "to": 0}]},
    )

    assert _social(repository)._match_kills(snapshot) == (1, 0)


def test_legacy_active_match_history_gaps_fail_closed() -> None:
    repository = InMemoryRepository()
    match = _active_match(
        repository,
        suffix="6",
        black_id="alice",
        white_id="bob",
        kill_counts_complete=False,
    )
    _commit_legacy_move(
        repository,
        match,
        revision=1,
        actor_id="alice",
        player="black",
        delta={"changes": []},
        state_revision=2,
    )

    with pytest.raises(ApiError) as captured:
        _social(repository).stats(_user("alice"))

    assert captured.value.code == "invalidMatchMetrics"


def test_terminal_move_hands_live_kills_to_finalized_stats_exactly_once() -> None:
    repository = InMemoryRepository()
    match = _active_match(
        repository,
        suffix="7",
        black_id="alice",
        white_id="bob",
        black_kills=1,
    )
    social = _social(repository)
    service = MatchService(repository, TerminalEngine())
    request = MoveRequest(
        row=0,
        column=0,
        expected_revision=0,
        idempotency_key="terminal-move-0001",
    )

    assert social.stats(_user("alice")).kills == 1
    service.move(_user("alice"), match.id, request)
    assert social.stats(_user("alice")).kills == 3
    assert repository.get_player_stats("alice").kills == 3

    service.move(_user("alice"), match.id, request)
    assert social.stats(_user("alice")).kills == 3
    assert repository.get_player_stats("alice").games == 1


def test_nonterminal_and_zero_death_moves_refresh_kills_without_double_counting() -> None:
    repository = InMemoryRepository()
    match = _active_match(
        repository,
        suffix="9",
        black_id="alice",
        white_id="bob",
    )
    social = _social(repository)
    service = MatchService(repository, ActiveEngine())
    first = MoveRequest(
        row=0,
        column=0,
        expected_revision=0,
        idempotency_key="active-move-0001",
    )

    service.move(_user("alice"), match.id, first)
    assert social.stats(_user("alice")).kills == 2
    assert repository.get_player_stats("alice").kills == 0

    service.move(
        _user("bob"),
        match.id,
        MoveRequest(
            row=0,
            column=1,
            expected_revision=1,
            idempotency_key="active-move-0002",
        ),
    )
    service.move(_user("alice"), match.id, first)
    assert social.stats(_user("alice")).kills == 2
    assert social.stats(_user("bob")).kills == 0


def test_resignation_hands_existing_live_kills_to_finalized_stats_once() -> None:
    repository = InMemoryRepository()
    match = _active_match(
        repository,
        suffix="8",
        black_id="alice",
        white_id="bob",
        black_kills=4,
        white_kills=2,
    )
    social = _social(repository)
    service = MatchService(repository, UnusedEngine())
    request = ResignRequest(expected_revision=0, idempotency_key="resign-live-kills-0001")

    assert social.stats(_user("alice")).kills == 4
    assert social.stats(_user("bob")).kills == 2
    service.resign(_user("bob"), match.id, request)
    assert social.stats(_user("alice")).kills == 4
    assert social.stats(_user("bob")).kills == 2

    service.resign(_user("bob"), match.id, request)
    assert social.stats(_user("alice")).kills == 4
    assert social.stats(_user("bob")).kills == 2
