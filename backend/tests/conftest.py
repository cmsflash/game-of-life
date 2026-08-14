from __future__ import annotations

from collections.abc import Iterator
from copy import deepcopy
from typing import Any

import pytest
from fastapi.testclient import TestClient

from life_api.auth import LocalIdentityProvider
from life_api.errors import ApiError
from life_api.main import create_app
from life_api.repository import InMemoryRepository
from life_api.settings import Settings


class StubEngine:
    """Small deterministic adapter for API tests; engine rules have their own suite."""

    def initial(self, rules: dict[str, Any]) -> dict[str, Any]:
        cells = [0] * 400
        cells[9 * 20 + 9] = 1
        cells[9 * 20 + 10] = 2
        cells[10 * 20 + 9] = 2
        cells[10 * 20 + 10] = 1
        return {
            "schemaVersion": 1,
            "rules": deepcopy(rules),
            "rulesHash": "stub-rules",
            "cells": cells,
            "ply": 0,
            "revision": 0,
            "toMove": "black",
            "status": "active",
            "outcome": None,
            "positionHash": "position-0",
            "stateHash": "state-0",
        }

    def apply_move(
        self,
        state: dict[str, Any],
        *,
        player: str,
        row: int,
        column: int,
        expected_revision: int,
    ) -> dict[str, Any]:
        if expected_revision != state["revision"]:
            raise ApiError("staleRevision", "The revision is stale.", status_code=409)
        if player != state["toMove"]:
            raise ApiError("wrongPlayer", "It is the other player's turn.", status_code=409)
        index = row * 20 + column
        if state["cells"][index] != 0:
            raise ApiError("occupied", "That cell is occupied.", status_code=409)
        updated = deepcopy(state)
        updated["cells"][index] = 1 if player == "black" else 2
        updated["revision"] += 1
        updated["ply"] += 1
        updated["toMove"] = "white" if player == "black" else "black"
        updated["positionHash"] = f"position-{updated['revision']}"
        updated["stateHash"] = f"state-{updated['revision']}"
        return {
            "state": updated,
            "delta": {
                "placed": {"row": row, "column": column, "player": player},
                "changes": [
                    {"row": row, "column": column, "from": 0, "to": updated["cells"][index]}
                ],
            },
        }

    def replay(
        self,
        rules: dict[str, Any],
        moves: list[dict[str, Any]],
    ) -> dict[str, Any]:
        state = self.initial(rules)
        for move in moves:
            state = self.apply_move(
                state,
                player=str(move["player"]),
                row=int(move["row"]),
                column=int(move["column"]),
                expected_revision=int(state["revision"]),
            )["state"]
        return {"state": state}


@pytest.fixture
def settings() -> Settings:
    return Settings(
        app_env="test",
        aws_region="ap-east-1",
        table_name="test",
        engine_executable=None,
        cors_origins=("http://localhost:3000",),
        allowed_return_urls=(
            "http://localhost:3000/auth/callback",
            "com.cmsflash.gameoflife://auth",
        ),
        local_token_secret="test-local-token-secret-with-enough-entropy",
        cognito_user_pool_id=None,
        cognito_client_id=None,
        cognito_client_secret=None,
        cognito_hosted_ui_base=None,
        cognito_oauth_callback_url=None,
        oauth_state_secret="test-oauth-state-secret-with-enough-entropy",
        google_login_enabled=True,
    )


@pytest.fixture
def client(settings: Settings) -> Iterator[TestClient]:
    app = create_app(
        settings=settings,
        repository=InMemoryRepository(),
        identity=LocalIdentityProvider(settings.local_token_secret),
        engine=StubEngine(),
    )
    with TestClient(app, raise_server_exceptions=True) as value:
        yield value


def register_and_login(
    client: TestClient,
    username: str,
    *,
    display_name: str | None = None,
) -> tuple[dict[str, Any], str]:
    registration = client.post(
        "/v1/auth/register",
        json={
            "username": username,
            "email": f"{username}@example.com",
            "password": "correct horse battery staple 1",
            "displayName": display_name or username.title(),
        },
    )
    assert registration.status_code == 201
    code = registration.json()["debugConfirmationCode"]
    assert (
        client.post(
            "/v1/auth/confirm",
            json={"username": username, "code": code},
        ).status_code
        == 200
    )
    login = client.post(
        "/v1/auth/login",
        json={"username": username, "password": "correct horse battery staple 1"},
    )
    assert login.status_code == 200
    tokens = login.json()
    return tokens, f"Bearer {tokens['accessToken']}"
