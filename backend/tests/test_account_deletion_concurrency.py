from __future__ import annotations

from dataclasses import replace
from typing import Any

from life_api.auth import LocalIdentityProvider
from life_api.main import AppServices
from life_api.models import MatchStatus, PlayerSummary, StoredMatch, User
from life_api.repository import InMemoryRepository
from life_api.service import MatchService
from life_api.settings import Settings


class UnusedEngine:
    def initial(self, rules: dict[str, Any]) -> dict[str, Any]:
        raise AssertionError("not used")

    def apply_move(self, *args: Any, **kwargs: Any) -> dict[str, Any]:
        raise AssertionError("not used")

    def replay(self, rules: dict[str, Any], moves: list[dict[str, Any]]) -> dict[str, Any]:
        raise AssertionError("not used")


def _user(user_id: str, name: str) -> User:
    return User(
        id=user_id,
        username=name.casefold(),
        email=f"{name.casefold()}@example.com",
        display_name=name,
        email_verified=True,
    )


def test_both_accounts_already_deleting_finalize_once_and_both_clean_up() -> None:
    repository = InMemoryRepository()
    waiting = StoredMatch(
        id="00000000-0000-4000-8000-000000000001",
        join_code="ABC123",
        rules={},
        state={"revision": 0, "toMove": "black"},
        creator_id="user-black",
        creator_name="Black",
        status=MatchStatus.waiting,
        kill_counts_complete=True,
    )
    repository.create_match(waiting)
    match = waiting.model_copy(
        update={
            "black_player": PlayerSummary(id="user-black", display_name="Black"),
            "white_player": PlayerSummary(id="user-white", display_name="White"),
            "status": MatchStatus.active,
            "version": 1,
        }
    )
    repository.join_match(match, "user-white")
    repository.begin_user_deletion("user-black")
    repository.begin_user_deletion("user-white")
    service = MatchService(repository=repository, engine=UnusedEngine())  # type: ignore[arg-type]

    service.delete_account_data(_user("user-black", "Black"))
    service.delete_account_data(_user("user-white", "White"))

    retained = repository.get_match(match.id)
    assert retained is not None
    assert retained.status == MatchStatus.completed
    assert retained.black_player is not None and retained.black_player.id.startswith("deleted-")
    assert retained.white_player is not None and retained.white_player.id.startswith("deleted-")
    assert repository.get_metrics_control().global_version == 1
    ledger = repository.get_metrics_ledger(match.id)
    assert ledger is not None
    assert "user-black" not in ledger.model_dump_json(by_alias=True)
    assert "user-white" not in ledger.model_dump_json(by_alias=True)


def test_account_deletion_never_scans_the_shared_scheduler_group(
    monkeypatch: Any,
    settings: Settings,
) -> None:
    scheduler_calls: list[str] = []

    def refuse_scheduler_client(service: str, **kwargs: Any) -> object:
        del kwargs
        scheduler_calls.append(service)
        raise AssertionError("the API deletion path must not construct a Scheduler client")

    monkeypatch.setattr("life_api.notifications.boto3.client", refuse_scheduler_client)
    configured = replace(
        settings,
        notification_function_arn="arn:aws:lambda:test:1:function:notifications",
        notification_scheduler_role_arn="arn:aws:iam::1:role/scheduler",
        notification_schedule_group_name="turn-reminders",
    )
    repository = InMemoryRepository()
    services = AppServices(
        settings=configured,
        repository=repository,
        identity=LocalIdentityProvider(configured.local_token_secret),
        engine=UnusedEngine(),  # type: ignore[arg-type]
    )

    services.matches.delete_account_data(_user("user-delete", "Delete"))

    assert scheduler_calls == []
