from __future__ import annotations

from datetime import UTC, datetime, timedelta
from typing import Any

import boto3

from life_api.models import (
    MatchStatus,
    PushPlatform,
    PushProviderName,
    StoredMatch,
    StoredPushSubscription,
)
from life_api.repository import DynamoRepository
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


class TableResource:
    def __init__(self, table: EmptyTable) -> None:
        self.table = table

    def Table(self, name: str) -> EmptyTable:
        del name
        return self.table


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
    assert transaction[0]["Put"]["Item"]["PK"] == {"S": "MATCH#match-1"}
    assert transaction[1]["Put"]["Item"]["PK"] == {"S": "USER#user-1"}
    assert transaction[2]["Put"]["Item"]["PK"] == {"S": "JOIN#ABC123"}


def test_matchmaking_queue_stores_only_user_id_and_utc_epoch_ttls(
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
        {"mode": "elimination"},
        "ticket-alice-000001",
    )

    after = datetime.now(UTC) + timedelta(minutes=10)
    transaction = client.transactions[0]["TransactItems"]
    queue_item = transaction[0]["Put"]["Item"]
    assert queue_item["userId"] == {"S": "user-1"}
    assert "user" not in queue_item
    assert "email" not in queue_item
    assert "username" not in queue_item

    assert len(transaction) == 3
    assert all("displayName" not in operation["Put"]["Item"] for operation in transaction)

    expires_at = int(queue_item["expiresAt"]["N"])
    assert int(before.timestamp()) <= expires_at <= int(after.timestamp())
    assert {
        int(item["Put"]["Item"]["expiresAt"]["N"])
        for item in transaction
        if "expiresAt" in item["Put"]["Item"]
    } == {expires_at}


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
    assert transaction[0]["ConditionCheck"]["Key"] == {
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
