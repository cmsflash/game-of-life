from __future__ import annotations

from typing import Any
from urllib.parse import parse_qs, urlsplit

import httpx
import pytest

from life_api.errors import ApiError
from life_api.models import User
from life_api.oauth import GoogleOAuthService
from life_api.repository import InMemoryRepository
from life_api.settings import Settings


class _Identity:
    def authenticate(self, access_token: str) -> User:
        assert access_token == "access-token"
        return User(
            id="google-user",
            username="google-user",
            email="google@example.com",
            display_name="Google User",
            email_verified=True,
        )


class _TokenResponse:
    def raise_for_status(self) -> None:
        return None

    def json(self) -> dict[str, Any]:
        return {
            "access_token": "access-token",
            "id_token": "id-token",
            "refresh_token": "refresh-token",
            "expires_in": 3600,
            "token_type": "Bearer",
        }


def test_production_google_flow_uses_pkce_and_single_use_state(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    settings = Settings(
        app_env="production",
        aws_region="ap-east-1",
        table_name="test",
        engine_executable="/engine",
        cors_origins=("https://game.example.com",),
        allowed_return_urls=("com.cmsflash.gameoflife://auth",),
        local_token_secret="not-used-in-production-tests",
        cognito_user_pool_id="pool",
        cognito_client_id="client",
        cognito_client_secret=None,
        cognito_hosted_ui_base="https://life.auth.ap-east-1.amazoncognito.com",
        cognito_oauth_callback_url="https://api.example.com/v1/auth/google/callback",
        oauth_state_secret="oauth-state-secret-with-enough-entropy",
        google_login_enabled=True,
    )
    repository = InMemoryRepository()
    service = GoogleOAuthService(settings, _Identity(), repository)  # type: ignore[arg-type]
    start_url = urlsplit(service.start_url("com.cmsflash.gameoflife://auth"))
    query = parse_qs(start_url.query)
    assert query["code_challenge_method"] == ["S256"]
    assert len(query["code_challenge"][0]) == 43
    assert "code_verifier" not in query

    captured: dict[str, Any] = {}

    def fake_post(url: str, **kwargs: Any) -> _TokenResponse:
        captured["url"] = url
        captured.update(kwargs)
        return _TokenResponse()

    monkeypatch.setattr(httpx, "post", fake_post)
    destination = urlsplit(service.complete("authorization-code", query["state"][0]))
    assert captured["data"]["code_verifier"]
    assert captured["data"]["code"] == "authorization-code"
    exchange_code = parse_qs(destination.query)["code"][0]
    assert service.exchange(exchange_code).user.id == "google-user"

    with pytest.raises(ApiError) as replayed_state:
        service.complete("another-code", query["state"][0])
    assert replayed_state.value.code == "invalidOAuthState"
