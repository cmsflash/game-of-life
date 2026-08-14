from __future__ import annotations

import base64
from dataclasses import replace

import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

from life_api.settings import Settings

_VAPID_PUBLIC_KEY = (
    base64.urlsafe_b64encode(
        ec.generate_private_key(ec.SECP256R1())
        .public_key()
        .public_bytes(
            serialization.Encoding.X962,
            serialization.PublicFormat.UncompressedPoint,
        )
    )
    .decode()
    .rstrip("=")
)


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


def test_push_providers_require_credentials_and_scheduler(settings: Settings) -> None:
    with pytest.raises(RuntimeError, match="FIREBASE_SERVICE_ACCOUNT_SECRET_ARN"):
        replace(settings, push_providers=("firebase",)).validate()

    with pytest.raises(RuntimeError, match="missing Web Push settings"):
        replace(settings, push_providers=("webPush",)).validate()


def test_push_provider_configuration_accepts_hybrid_mode(settings: Settings) -> None:
    replace(
        settings,
        push_providers=("webPush", "firebase"),
        firebase_service_account_secret_arn="arn:aws:secretsmanager:test:1:secret:firebase",
        web_push_vapid_private_key_secret_arn="arn:aws:secretsmanager:test:1:secret:vapid",
        web_push_vapid_public_key=_VAPID_PUBLIC_KEY,
        web_push_vapid_subject="mailto:operations@example.com",
        notification_function_arn="arn:aws:lambda:test:1:function:notifications",
        notification_scheduler_role_arn="arn:aws:iam::1:role/scheduler",
        notification_schedule_group_name="turn-reminders",
    ).validate()


def test_production_notification_worker_does_not_require_api_auth_secrets(
    settings: Settings,
) -> None:
    replace(
        settings,
        app_env="production",
        app_component="notifications",
        local_token_secret="local-development-only-secret",
        cognito_user_pool_id=None,
        cognito_client_id=None,
        cognito_hosted_ui_base=None,
        cognito_oauth_callback_url=None,
        cors_origins=(),
        allowed_return_urls=(),
    ).validate()
