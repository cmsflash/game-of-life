from __future__ import annotations

from dataclasses import replace
from typing import Any
from urllib.parse import parse_qs, urlsplit

import boto3
import pytest
from conftest import register_and_login
from fastapi.testclient import TestClient

from life_api.auth import CognitoIdentityProvider
from life_api.repository import InMemoryRepository
from life_api.settings import Settings


def test_health_and_validation_error_envelopes(client: TestClient) -> None:
    health = client.get("/v1/health")
    assert health.status_code == 200
    assert health.json() == {
        "status": "ok",
        "environment": "test",
        "engine": "StubEngine",
    }
    response = client.post("/v1/auth/register", json={"username": "x"})
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "validationError"
    assert response.json()["error"]["requestId"] == response.headers["x-request-id"]
    missing = client.get("/v1/does-not-exist")
    assert missing.status_code == 404
    assert missing.json()["error"]["code"] == "notFound"


def test_complete_password_account_lifecycle(client: TestClient) -> None:
    registration = client.post(
        "/v1/auth/register",
        json={
            "username": "alice",
            "email": "alice@example.com",
            "password": "correct horse battery staple 1",
            "displayName": "Alice",
        },
    )
    assert registration.status_code == 201
    payload = registration.json()
    assert payload["confirmationRequired"] is True
    assert payload["debugConfirmationCode"]

    unconfirmed = client.post(
        "/v1/auth/login",
        json={"username": "alice", "password": "correct horse battery staple 1"},
    )
    assert unconfirmed.status_code == 403
    assert unconfirmed.json()["error"]["code"] == "confirmationRequired"

    confirmation = client.post(
        "/v1/auth/confirm",
        json={"username": "alice", "code": payload["debugConfirmationCode"]},
    )
    assert confirmation.status_code == 200
    login = client.post(
        "/v1/auth/login",
        json={"username": "alice", "password": "correct horse battery staple 1"},
    )
    assert login.status_code == 200
    tokens = login.json()
    headers = {"Authorization": f"Bearer {tokens['accessToken']}"}
    assert client.get("/v1/me", headers=headers).json()["username"] == "alice"

    refreshed = client.post(
        "/v1/auth/refresh",
        json={"refreshToken": tokens["refreshToken"]},
    )
    assert refreshed.status_code == 200
    assert refreshed.json()["user"]["username"] == "alice"

    forgot = client.post("/v1/auth/forgot", json={"username": "alice"})
    assert forgot.status_code == 200
    reset_code = forgot.json()["debugResetCode"]
    reset = client.post(
        "/v1/auth/reset",
        json={
            "username": "alice",
            "code": reset_code,
            "newPassword": "another secure password 2",
        },
    )
    assert reset.status_code == 200
    assert (
        client.post(
            "/v1/auth/login",
            json={"username": "alice", "password": "correct horse battery staple 1"},
        ).status_code
        == 401
    )
    assert (
        client.post(
            "/v1/auth/login",
            json={"username": "alice", "password": "another secure password 2"},
        ).status_code
        == 200
    )
    assert client.post("/v1/auth/logout", json={}, headers=headers).status_code == 200


def test_authentication_required_and_duplicate_accounts(client: TestClient) -> None:
    assert client.get("/v1/me").status_code == 401
    register_and_login(client, "alice")
    duplicate = client.post(
        "/v1/auth/register",
        json={
            "username": "alice",
            "email": "different@example.com",
            "password": "correct horse battery staple 1",
            "displayName": "Alice II",
        },
    )
    assert duplicate.status_code == 409
    assert duplicate.json()["error"]["code"] == "usernameExists"


def test_local_google_login_uses_single_use_exchange_code(client: TestClient) -> None:
    start = client.get(
        "/v1/auth/google/start",
        params={"returnTo": "com.cmsflash.gameoflife://auth"},
        follow_redirects=False,
    )
    assert start.status_code == 302
    destination = urlsplit(start.headers["location"])
    assert (
        f"{destination.scheme}://{destination.netloc}{destination.path}"
        == "com.cmsflash.gameoflife://auth"
    )
    code = parse_qs(destination.query)["code"][0]

    exchange = client.post("/v1/auth/exchange", json={"code": code})
    assert exchange.status_code == 200
    assert exchange.json()["user"]["username"] == "google.dev"
    reused = client.post("/v1/auth/exchange", json={"code": code})
    assert reused.status_code == 400
    assert reused.json()["error"]["code"] == "invalidExchangeCode"


def test_google_return_url_is_exactly_allowlisted(client: TestClient) -> None:
    response = client.get(
        "/v1/auth/google/start",
        params={"returnTo": "https://evil.example/auth/callback"},
        follow_redirects=False,
    )
    assert response.status_code == 400
    assert response.json()["error"]["code"] == "invalidReturnUrl"


def test_delete_account_ends_games_anonymizes_history_and_revokes_local_identity(
    client: TestClient,
) -> None:
    alice_tokens, alice_auth = register_and_login(client, "alice")
    bob_tokens, bob_auth = register_and_login(client, "bob")
    headers = {
        "alice": {"Authorization": alice_auth},
        "bob": {"Authorization": bob_auth},
    }
    tokens = {"alice": alice_tokens, "bob": bob_tokens}

    created = client.post("/v1/matches", json={}, headers=headers["alice"]).json()
    joined = client.post(
        "/v1/matches/join",
        json={"joinCode": created["joinCode"]},
        headers=headers["bob"],
    ).json()
    black_username = (
        "alice"
        if client.get(
            f"/v1/matches/{joined['id']}",
            headers=headers["alice"],
        ).json()["yourColor"]
        == "black"
        else "bob"
    )
    opponent_username = "bob" if black_username == "alice" else "alice"
    moved = client.post(
        f"/v1/matches/{joined['id']}/moves",
        headers=headers[black_username],
        json={
            "row": 0,
            "column": 0,
            "expectedRevision": 0,
            "idempotencyKey": "delete-account-move-1",
        },
    )
    assert moved.status_code == 200

    waiting = client.post(
        "/v1/matches",
        json={},
        headers=headers[black_username],
    ).json()
    ticket_id = f"delete-{black_username}-000001"
    queued = client.post(
        "/v1/matchmaking",
        json={"ticketId": ticket_id},
        headers=headers[black_username],
    )
    assert queued.status_code == 200
    assert queued.json()["status"] == "waiting"

    deleted_user_id = tokens[black_username]["user"]["id"]
    deleted = client.delete("/v1/me", headers=headers[black_username])
    assert deleted.status_code == 204
    assert deleted.content == b""

    assert client.get("/v1/me", headers=headers[black_username]).status_code == 401
    assert (
        client.post(
            "/v1/auth/refresh",
            json={"refreshToken": tokens[black_username]["refreshToken"]},
        ).status_code
        == 401
    )
    assert (
        client.post(
            "/v1/auth/login",
            json={
                "username": black_username,
                "password": "correct horse battery staple 1",
            },
        ).status_code
        == 401
    )

    opponent_match = client.get(
        f"/v1/matches/{joined['id']}",
        headers=headers[opponent_username],
    )
    assert opponent_match.status_code == 200
    match_document = opponent_match.json()
    assert match_document["status"] == "completed"
    assert match_document["result"]["reason"] == "resignation"
    deleted_player = match_document["blackPlayer"]
    assert deleted_player["displayName"] == "Deleted player"
    assert deleted_player["id"].startswith("deleted-")
    assert deleted_player["id"] != deleted_user_id

    history = client.get(
        f"/v1/matches/{joined['id']}/moves",
        headers=headers[opponent_username],
    ).json()["items"]
    assert history[0]["actorId"] == deleted_player["id"]
    assert (
        client.post(
            "/v1/matches/join",
            json={"joinCode": waiting["joinCode"]},
            headers=headers[opponent_username],
        ).status_code
        == 404
    )

    repository = client.app.state.services.repository
    assert isinstance(repository, InMemoryRepository)
    assert repository.active_matchmaking(deleted_user_id) is None
    assert repository.matchmaking_status(deleted_user_id, ticket_id) is None
    assert not any(key[0] == deleted_user_id for key in repository._idempotency)

    reregistered = client.post(
        "/v1/auth/register",
        json={
            "username": black_username,
            "email": f"{black_username}@example.com",
            "password": "replacement password 3",
            "displayName": "Replacement Player",
        },
    )
    assert reregistered.status_code == 201


def test_match_routes_reject_non_uuid_path_values(
    client: TestClient,
) -> None:
    _, authorization = register_and_login(client, "alice")
    headers = {"Authorization": authorization}

    invalid = client.get("/v1/matches/not-a-uuid", headers=headers)
    assert invalid.status_code == 422
    assert invalid.json()["error"]["code"] == "validationError"

    invalid_shape = client.get(
        "/v1/matches/00000000-0000-0000-0000-00000000000Z",
        headers=headers,
    )
    assert invalid_shape.status_code == 422
    assert invalid_shape.json()["error"]["code"] == "validationError"


class _RecordingCognitoClient:
    def __init__(self) -> None:
        self.calls: list[dict[str, Any]] = []

    def delete_user(self, **kwargs: Any) -> dict[str, Any]:
        self.calls.append(kwargs)
        return {}


def test_cognito_account_deletion_uses_the_authenticated_access_token(
    monkeypatch: pytest.MonkeyPatch,
    settings: Settings,
) -> None:
    client = _RecordingCognitoClient()
    monkeypatch.setattr(boto3, "client", lambda *args, **kwargs: client)
    provider = CognitoIdentityProvider(
        replace(
            settings,
            cognito_client_id="client-id",
        )
    )

    provider.delete_account("current-access-token")

    assert client.calls == [{"AccessToken": "current-access-token"}]
