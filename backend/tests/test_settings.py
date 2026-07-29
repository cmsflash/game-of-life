from __future__ import annotations

from dataclasses import replace

import pytest

from life_api.settings import Settings


def _production_settings(settings: Settings) -> Settings:
    return replace(
        settings,
        app_env="production",
        cors_origins=("https://play.example.com",),
        allowed_return_urls=(
            "https://play.example.com/auth/callback",
            "com.cmsflash.gameoflife://auth",
        ),
        cognito_user_pool_id="pool-id",
        cognito_client_id="client-id",
        cognito_hosted_ui_base="https://life.auth.ap-east-1.amazoncognito.com",
        cognito_oauth_callback_url="https://api.example.com/v1/auth/google/callback",
    )


def test_production_settings_accept_only_secure_exact_urls(settings: Settings) -> None:
    _production_settings(settings).validate()


@pytest.mark.parametrize(
    "origin",
    [
        "*",
        "http://play.example.com",
        "https://localhost:3000",
        "https://127.0.0.1",
        "https://play.example.com/api",
    ],
)
def test_production_cors_rejects_insecure_or_non_origin_values(
    settings: Settings,
    origin: str,
) -> None:
    with pytest.raises(RuntimeError, match="CORS_ORIGINS"):
        replace(_production_settings(settings), cors_origins=(origin,)).validate()


@pytest.mark.parametrize(
    "return_url",
    [
        "https://*.example.com/auth/callback",
        "http://play.example.com/auth/callback",
        "https://localhost/auth/callback",
        "https://127.0.0.1/auth/callback",
        "javascript:alert(1)",
    ],
)
def test_production_return_urls_reject_insecure_values(
    settings: Settings,
    return_url: str,
) -> None:
    with pytest.raises(RuntimeError, match="ALLOWED_RETURN_URLS"):
        replace(
            _production_settings(settings),
            allowed_return_urls=(return_url,),
        ).validate()
