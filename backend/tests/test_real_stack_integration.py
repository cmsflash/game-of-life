from __future__ import annotations

import shutil
from typing import Any

import pytest
from fastapi.testclient import TestClient

from life_api.auth import LocalIdentityProvider
from life_api.engine import DartEngine
from life_api.main import create_app
from life_api.repository import InMemoryRepository
from life_api.settings import Settings


def _account(client: TestClient, username: str) -> tuple[dict[str, Any], dict[str, str]]:
    password = "integration password 1"
    registration = client.post(
        "/v1/auth/register",
        json={
            "username": username,
            "email": f"{username}@example.com",
            "password": password,
            "displayName": username.title(),
        },
    ).json()
    client.post(
        "/v1/auth/confirm",
        json={"username": username, "code": registration["debugConfirmationCode"]},
    )
    tokens = client.post(
        "/v1/auth/login",
        json={"username": username, "password": password},
    ).json()
    return tokens, {"Authorization": f"Bearer {tokens['accessToken']}"}


@pytest.mark.skipif(shutil.which("dart") is None, reason="Dart SDK is not installed")
def test_real_engine_through_auth_and_match_api(settings: Settings) -> None:
    repository = InMemoryRepository()
    app = create_app(
        settings=settings,
        repository=repository,
        identity=LocalIdentityProvider(settings.local_token_secret),
        engine=DartEngine(settings),
    )
    with TestClient(app) as client:
        _, alice = _account(client, "alice")
        _, bob = _account(client, "bob")
        waiting = client.post("/v1/matches", json={}, headers=alice).json()
        joined = client.post(
            "/v1/matches/join",
            json={"joinCode": waiting["joinCode"]},
            headers=bob,
        ).json()
        alice_match = client.get(f"/v1/matches/{joined['id']}", headers=alice).json()
        black = alice if alice_match["yourColor"] == "black" else bob
        white = bob if black is alice else alice
        moved = client.post(
            f"/v1/matches/{joined['id']}/moves",
            headers=black,
            json={
                "row": 7,
                "column": 8,
                "expectedRevision": 0,
                "idempotencyKey": "real-engine-move-1",
            },
        )
        assert moved.status_code == 200
        assert moved.json()["state"]["revision"] == 1
        assert moved.json()["state"]["toMove"] == "white"
        white_moved = client.post(
            f"/v1/matches/{joined['id']}/moves",
            headers=white,
            json={
                "row": 0,
                "column": 0,
                "expectedRevision": 1,
                "idempotencyKey": "real-engine-move-2",
            },
        )
        assert white_moved.status_code == 200
        assert white_moved.json()["state"]["revision"] == 2
        assert white_moved.json()["state"]["cells"][0] == 0
        assert white_moved.json()["state"]["toMove"] == "black"
        assert white_moved.json()["state"]["cells"][8 * 20 + 10] == 2
        assert white_moved.json()["state"]["cells"][9 * 20 + 8] == 2
        assert (
            client.get(f"/v1/matches/{joined['id']}/replay", headers=alice).json()["finalState"][
                "stateHash"
            ]
            == white_moved.json()["state"]["stateHash"]
        )
