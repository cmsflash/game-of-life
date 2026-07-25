from __future__ import annotations

from typing import Any

import boto3

from life_api.models import MatchStatus, StoredMatch
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
