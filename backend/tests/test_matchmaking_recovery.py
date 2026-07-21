from __future__ import annotations

import pytest
from conftest import StubEngine

from life_api.models import QuickMatchRequest, User
from life_api.repository import InMemoryRepository
from life_api.service import MatchService


class FailingInitialEngine(StubEngine):
    def initial(self, rules: dict[str, object]) -> dict[str, object]:
        raise RuntimeError("engine unavailable")


def test_failed_match_creation_releases_the_opponent_claim() -> None:
    repository = InMemoryRepository()
    alice = User(
        id="alice-id",
        username="alice",
        email="alice@example.com",
        display_name="Alice",
        email_verified=True,
    )
    bob = User(
        id="bob-id",
        username="bob",
        email="bob@example.com",
        display_name="Bob",
        email_verified=True,
    )
    alice_ticket = "ticket-alice-000001"
    bob_ticket = "ticket-bob-00000001"

    waiting = MatchService(repository, StubEngine()).quick_match(
        alice,
        QuickMatchRequest(ticket_id=alice_ticket),
    )
    assert waiting.status == "waiting"

    with pytest.raises(RuntimeError, match="engine unavailable"):
        MatchService(repository, FailingInitialEngine()).quick_match(
            bob,
            QuickMatchRequest(ticket_id=bob_ticket),
        )

    recovered = repository.matchmaking_status(alice.id, alice_ticket)
    assert recovered is not None
    assert recovered.status == "waiting"
    assert repository.active_matchmaking(alice.id) == recovered


def test_claimed_ticket_remains_active_until_released() -> None:
    repository = InMemoryRepository()
    alice = User(
        id="alice-id",
        username="alice",
        email="alice@example.com",
        display_name="Alice",
        email_verified=True,
    )
    ticket = "ticket-alice-000001"
    repository.enqueue("rules-hash", alice, {"rules": 1}, ticket)

    opponent = repository.pop_opponent("rules-hash", "bob-id")

    assert opponent is not None
    claimed = repository.active_matchmaking(alice.id)
    assert claimed is not None
    assert claimed.status == "claimed"
    repository.release_matchmaking_claim(alice.id, ticket)
    released = repository.active_matchmaking(alice.id)
    assert released is not None
    assert released.status == "waiting"
