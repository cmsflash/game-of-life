from __future__ import annotations

import hashlib
from datetime import UTC, datetime, timedelta
from typing import Any

import boto3
import pytest

from life_api.errors import ApiError
from life_api.models import (
    MatchStatus,
    MoveEvent,
    PlayerSummary,
    PushPlatform,
    PushProviderName,
    StoredChallenge,
    StoredMatch,
    StoredPublicPlayer,
    StoredPushSubscription,
)
from life_api.repository import DynamoRepository, InMemoryRepository
from life_api.settings import Settings


class RecordingClient:
    def __init__(self) -> None:
        self.transactions: list[dict[str, Any]] = []

    def transact_write_items(self, **kwargs: Any) -> None:
        self.transactions.append(kwargs)


class FakeResource:
    def Table(self, name: str) -> object:
        del name
        return object()


class EmptyTable:
    def get_item(self, **kwargs: Any) -> dict[str, Any]:
        del kwargs
        return {}


class LegacyDeletionGuardTable(EmptyTable):
    def get_item(self, **kwargs: Any) -> dict[str, Any]:
        if kwargs["Key"] == {"PK": "USER#user-1", "SK": "ACCOUNT_DELETED"}:
            return {
                "Item": {"expiresAt": int((datetime.now(UTC) + timedelta(hours=1)).timestamp())}
            }
        return {}


class LegacyQueueTable(EmptyTable):
    def query(self, **kwargs: Any) -> dict[str, Any]:
        del kwargs
        return {
            "Items": [
                {
                    "PK": "QUEUE#rules-hash",
                    "SK": "2026-08-14T00:00:00+00:00#legacy-user",
                    "entity": "queue",
                    "userId": "legacy-user",
                    "ticketId": "ticket-legacy-00001",
                    "status": "waiting",
                    "rules": '{"mode":"elimination"}',
                    "expiresAt": int((datetime.now(UTC) + timedelta(minutes=5)).timestamp()),
                }
            ]
        }


class ProfileTable(EmptyTable):
    def __init__(self, profile: StoredPublicPlayer) -> None:
        self.profile = profile

    def get_item(self, **kwargs: Any) -> dict[str, Any]:
        if kwargs["Key"] == {"PK": f"PLAYER#{self.profile.id}", "SK": "PROFILE"}:
            return {
                "Item": {
                    "PK": f"PLAYER#{self.profile.id}",
                    "SK": "PROFILE",
                    "entity": "publicPlayer",
                    "version": self.profile.version,
                    "discoverable": self.profile.discoverable,
                    "document": self.profile.model_dump_json(by_alias=True),
                }
            }
        return {}


class SearchTable(EmptyTable):
    def __init__(self, player_ids: list[str]) -> None:
        self.player_ids = player_ids
        self.get_calls = 0

    def get_item(self, **kwargs: Any) -> dict[str, Any]:
        del kwargs
        self.get_calls += 1
        raise AssertionError("search hydration must not issue sequential GetItem calls")

    def query(self, **kwargs: Any) -> dict[str, Any]:
        del kwargs
        return {
            "Items": [
                {
                    "PK": "SEARCH#ali",
                    "SK": f"alice#{player_id}",
                    "entity": "playerSearch",
                    "playerId": player_id,
                    "document": "legacy-snapshot",
                }
                for player_id in self.player_ids
            ]
        }


class TableResource:
    def __init__(self, table: EmptyTable) -> None:
        self.table = table

    def Table(self, name: str) -> EmptyTable:
        del name
        return self.table


class BatchResource(TableResource):
    def __init__(self, table: EmptyTable, items: list[dict[str, Any]]) -> None:
        super().__init__(table)
        self.items = {(str(item["PK"]), str(item["SK"])): item for item in items}
        self.batch_calls = 0

    def batch_get_item(self, **kwargs: Any) -> dict[str, Any]:
        self.batch_calls += 1
        request = kwargs["RequestItems"]["test"]
        found = [
            self.items[(str(key["PK"]), str(key["SK"]))]
            for key in request["Keys"]
            if (str(key["PK"]), str(key["SK"])) in self.items
        ]
        return {"Responses": {"test": found}, "UnprocessedKeys": {}}


def test_dynamo_transactions_use_the_low_level_client(
    monkeypatch,
    settings: Settings,
) -> None:
    client = RecordingClient()
    monkeypatch.setattr(boto3, "resource", lambda *args, **kwargs: FakeResource())
    monkeypatch.setattr(boto3, "client", lambda *args, **kwargs: client)
    repository = DynamoRepository(settings)
    match = StoredMatch(
        id="match-1",
        join_code="ABC123",
        rules={},
        state={"revision": 0},
        creator_id="user-1",
        creator_name="Player One",
        status=MatchStatus.waiting,
    )

    repository.create_match(match)

    transaction = client.transactions[0]["TransactItems"]
    account_pk = f"ACCOUNT#{hashlib.sha256(b'user-1').hexdigest()}"
    put_keys = [operation["Put"]["Item"]["PK"] for operation in transaction if "Put" in operation]
    assert {"S": "MATCH#match-1"} in put_keys
    assert {"S": "USER#user-1"} in put_keys
    assert {"S": "JOIN#ABC123"} in put_keys
    assert transaction[0]["ConditionCheck"]["Key"] == {
        "PK": {"S": account_pk},
        "SK": {"S": "STATE"},
    }


def test_unchanged_public_profile_upsert_is_a_literal_no_op(
    monkeypatch,
    settings: Settings,
) -> None:
    profile = StoredPublicPlayer(
        id="user-1",
        display_name="Alice Example",
        normalized_display_name="alice example",
        discoverable=True,
        version=7,
        avatar_key="avatars/owner/avatar.webp",
        avatar_version=4,
    )
    client = RecordingClient()
    monkeypatch.setattr(
        boto3,
        "resource",
        lambda *args, **kwargs: TableResource(ProfileTable(profile)),
    )
    monkeypatch.setattr(boto3, "client", lambda *args, **kwargs: client)
    repository = DynamoRepository(settings)

    repository.upsert_public_player(
        StoredPublicPlayer(
            id=profile.id,
            display_name=profile.display_name,
            normalized_display_name=profile.normalized_display_name,
        )
    )

    assert client.transactions == []


def test_player_search_batch_hydrates_and_filters_stale_or_deleting_rows(
    monkeypatch,
    settings: Settings,
) -> None:
    active = StoredPublicPlayer(
        id="active-player",
        display_name="Alice Active",
        normalized_display_name="alice active",
    )
    renamed = StoredPublicPlayer(
        id="renamed-player",
        display_name="Bob Renamed",
        normalized_display_name="bob renamed",
    )
    deleting = StoredPublicPlayer(
        id="deleting-player",
        display_name="Alice Deleting",
        normalized_display_name="alice deleting",
    )
    table = SearchTable([active.id, renamed.id, deleting.id])
    profile_items = [
        {
            "PK": f"PLAYER#{profile.id}",
            "SK": "PROFILE",
            "entity": "publicPlayer",
            "document": profile.model_dump_json(by_alias=True),
        }
        for profile in (active, renamed, deleting)
    ]
    deleting_digest = hashlib.sha256(deleting.id.encode()).hexdigest()
    resource = BatchResource(
        table,
        [
            *profile_items,
            {
                "PK": f"ACCOUNT#{deleting_digest}",
                "SK": "STATE",
                "entity": "accountState",
                "state": "deleting",
            },
        ],
    )
    monkeypatch.setattr(boto3, "resource", lambda *args, **kwargs: resource)
    monkeypatch.setattr(boto3, "client", lambda *args, **kwargs: RecordingClient())
    repository = DynamoRepository(settings)

    found = repository.search_public_players("ali", limit=20)

    assert [profile.id for profile in found] == [active.id]
    assert resource.batch_calls == 1
    assert table.get_calls == 0


def test_matchmaking_queue_stores_public_name_only_on_candidate_and_utc_epoch_ttls(
    monkeypatch,
    settings: Settings,
) -> None:
    client = RecordingClient()
    monkeypatch.setattr(boto3, "resource", lambda *args, **kwargs: FakeResource())
    monkeypatch.setattr(boto3, "client", lambda *args, **kwargs: client)
    repository = DynamoRepository(settings)
    before = datetime.now(UTC) + timedelta(minutes=10)

    repository.enqueue(
        "rules-hash",
        "user-1",
        "Alice Example",
        {"mode": "elimination"},
        "ticket-alice-000001",
    )

    after = datetime.now(UTC) + timedelta(minutes=10)
    transaction = client.transactions[0]["TransactItems"]
    put_items = [operation["Put"]["Item"] for operation in transaction if "Put" in operation]
    queue_item = next(item for item in put_items if item["entity"]["S"] == "queue")
    assert queue_item["userId"] == {"S": "user-1"}
    assert queue_item["displayName"] == {"S": "Alice Example"}
    assert "user" not in queue_item
    assert "email" not in queue_item
    assert "username" not in queue_item

    assert len(transaction) == 5
    assert all("displayName" not in item for item in put_items if item["entity"]["S"] != "queue")

    expires_at = int(queue_item["expiresAt"]["N"])
    assert int(before.timestamp()) <= expires_at <= int(after.timestamp())
    assert {int(item["expiresAt"]["N"]) for item in put_items if "expiresAt" in item} == {
        expires_at
    }


def test_matchmaking_skips_legacy_queue_rows_without_a_display_name(
    monkeypatch,
    settings: Settings,
) -> None:
    client = RecordingClient()
    table = LegacyQueueTable()
    monkeypatch.setattr(boto3, "resource", lambda *args, **kwargs: TableResource(table))
    monkeypatch.setattr(boto3, "client", lambda *args, **kwargs: client)
    repository = DynamoRepository(settings)

    assert repository.pop_opponent("rules-hash", "new-user") is None
    assert client.transactions == []


def test_push_subscription_transaction_keeps_credentials_in_user_record(
    monkeypatch,
    settings: Settings,
) -> None:
    client = RecordingClient()
    table = EmptyTable()
    monkeypatch.setattr(boto3, "resource", lambda *args, **kwargs: TableResource(table))
    monkeypatch.setattr(boto3, "client", lambda *args, **kwargs: client)
    repository = DynamoRepository(settings)
    subscription = StoredPushSubscription(
        user_id="user-1",
        installation_id="installation-0001",
        platform=PushPlatform.android,
        provider=PushProviderName.firebase,
        token="private-firebase-registration-token",
    )

    repository.upsert_push_subscription(subscription)

    transaction = client.transactions[0]["TransactItems"]
    account_pk = f"ACCOUNT#{hashlib.sha256(b'user-1').hexdigest()}"
    assert transaction[0]["ConditionCheck"]["Key"] == {
        "PK": {"S": account_pk},
        "SK": {"S": "STATE"},
    }
    assert transaction[0]["ConditionCheck"]["ConditionExpression"] == (
        "attribute_not_exists(PK) OR #accountState = :active"
    )
    assert transaction[1]["ConditionCheck"]["Key"] == {
        "PK": {"S": "USER#user-1"},
        "SK": {"S": "ACCOUNT_DELETED"},
    }
    put_items = [operation["Put"]["Item"] for operation in transaction if "Put" in operation]
    subscription_item = next(
        item for item in put_items if item["entity"]["S"] == "pushSubscription"
    )
    owner_item = next(item for item in put_items if item["entity"]["S"] == "pushInstallationOwner")
    assert subscription_item["PK"] == {"S": "USER#user-1"}
    assert "private-firebase-registration-token" in subscription_item["document"]["S"]
    assert owner_item["PK"] == {"S": "INSTALLATION#installation-0001"}
    assert "document" not in owner_item


def test_legacy_raw_deletion_guard_is_treated_as_deleting(
    monkeypatch,
    settings: Settings,
) -> None:
    table = LegacyDeletionGuardTable()
    monkeypatch.setattr(boto3, "resource", lambda *args, **kwargs: TableResource(table))
    monkeypatch.setattr(boto3, "client", lambda *args, **kwargs: RecordingClient())
    repository = DynamoRepository(settings)

    assert repository.account_state("user-1").value == "deleting"


def test_expired_push_cleanup_conditions_on_exact_subscription_document(
    monkeypatch,
    settings: Settings,
) -> None:
    client = RecordingClient()
    table = EmptyTable()
    monkeypatch.setattr(boto3, "resource", lambda *args, **kwargs: TableResource(table))
    monkeypatch.setattr(boto3, "client", lambda *args, **kwargs: client)
    repository = DynamoRepository(settings)
    subscription = StoredPushSubscription(
        user_id="user-1",
        installation_id="installation-0001",
        platform=PushPlatform.android,
        provider=PushProviderName.firebase,
        token="private-firebase-registration-token",
    )

    assert repository.delete_push_subscription_if_unchanged(subscription) is True

    transaction = client.transactions[0]["TransactItems"]
    subscription_delete = transaction[0]["Delete"]
    assert subscription_delete["Key"] == {
        "PK": {"S": "USER#user-1"},
        "SK": {"S": "PUSH#installation-0001"},
    }
    assert subscription_delete["ConditionExpression"] == "document = :document"
    assert subscription_delete["ExpressionAttributeValues"][":document"] == {
        "S": subscription.model_dump_json(by_alias=True)
    }


def test_nonterminal_moves_are_fenced_when_either_account_is_deleting() -> None:
    repository = InMemoryRepository()
    match = StoredMatch(
        id="match-delete-race",
        join_code="ABC123",
        rules={},
        state={"revision": 0, "toMove": "black"},
        creator_id="user-black",
        creator_name="Black",
        black_player=PlayerSummary(id="user-black", display_name="Black"),
        white_player=PlayerSummary(id="user-white", display_name="White"),
        status=MatchStatus.active,
        version=1,
    )
    repository.create_match(match)
    repository.begin_user_deletion("user-white")
    moved = match.model_copy(update={"state": {"revision": 1, "toMove": "white"}, "version": 2})
    event = MoveEvent(
        revision=1,
        actor_id="user-black",
        player="black",
        row=0,
        column=0,
        delta={"changes": []},
        state_hash="state-1",
        created_at=datetime.now(UTC),
    )

    with pytest.raises(ApiError, match="being deleted") as captured:
        repository.commit_move(
            match=moved,
            expected_version=1,
            event=event,
            user_id="user-black",
            idempotency_key="move-delete-race",
            request_fingerprint="fingerprint",
        )

    assert captured.value.code == "accountDeleting"


def test_expired_challenge_cleanup_tolerates_ttl_deleted_pointer(
    monkeypatch,
    settings: Settings,
) -> None:
    client = RecordingClient()
    table = EmptyTable()
    monkeypatch.setattr(boto3, "resource", lambda *args, **kwargs: TableResource(table))
    monkeypatch.setattr(boto3, "client", lambda *args, **kwargs: client)
    repository = DynamoRepository(settings)
    challenge = StoredChallenge(
        id="00000000-0000-4000-8000-000000000001",
        challenger=PlayerSummary(id="user-1", display_name="One"),
        opponent=PlayerSummary(id="user-2", display_name="Two"),
        created_at=datetime.now(UTC) - timedelta(days=8),
        expires_at=datetime.now(UTC) - timedelta(days=1),
    )

    repository._expire_challenge(challenge)

    deletes = [operation["Delete"] for operation in client.transactions[0]["TransactItems"]]
    deleted_keys = [delete["Key"] for delete in deletes]
    assert {"PK": {"S": f"CHALLENGE#{challenge.id}"}, "SK": {"S": "STATE"}} in deleted_keys
    assert not any(key["SK"] == {"S": "CHALLENGE"} for key in deleted_keys)
    assert len(deletes) == 3
