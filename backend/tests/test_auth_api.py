from __future__ import annotations

from urllib.parse import parse_qs, urlsplit

from conftest import register_and_login
from fastapi.testclient import TestClient


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
