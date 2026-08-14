from __future__ import annotations

import base64
from collections.abc import Iterator
from dataclasses import replace

import pytest
from conftest import StubEngine, register_and_login
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi.testclient import TestClient

from life_api.auth import LocalIdentityProvider
from life_api.main import create_app
from life_api.repository import InMemoryRepository
from life_api.settings import Settings

_P256DH = (
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
_AUTH = base64.urlsafe_b64encode(b"a" * 16).decode().rstrip("=")


@pytest.fixture
def notification_client(settings: Settings) -> Iterator[TestClient]:
    configured = replace(
        settings,
        push_providers=("webPush", "firebase"),
        firebase_service_account_secret_arn="arn:aws:secretsmanager:test:1:secret:firebase",
        web_push_vapid_private_key_secret_arn="arn:aws:secretsmanager:test:1:secret:vapid",
        web_push_vapid_public_key=_P256DH,
        web_push_vapid_subject="mailto:operations@example.com",
        notification_function_arn="arn:aws:lambda:test:1:function:notifications",
        notification_scheduler_role_arn="arn:aws:iam::1:role/scheduler",
        notification_schedule_group_name="turn-reminders",
    )
    repository = InMemoryRepository()
    app = create_app(
        settings=configured,
        repository=repository,
        identity=LocalIdentityProvider(configured.local_token_secret),
        engine=StubEngine(),
    )
    with TestClient(app, raise_server_exceptions=True) as value:
        yield value


def test_notification_config_is_public_and_safe_when_disabled(client: TestClient) -> None:
    response = client.get("/v1/notifications/config")

    assert response.status_code == 200
    assert response.json() == {"providers": [], "webPushVapidPublicKey": None}
    unauthenticated = client.post(
        "/v1/notifications/subscriptions",
        json={
            "installationId": "installation-0001",
            "platform": "android",
            "provider": "firebase",
            "token": "firebase-token-long-enough",
        },
    )
    assert unauthenticated.status_code == 401


def test_authenticated_subscription_upsert_is_redacted_and_user_scoped(
    notification_client: TestClient,
) -> None:
    _, alice_auth = register_and_login(notification_client, "notify-alice")
    _, bob_auth = register_and_login(notification_client, "notify-bob")
    body = {
        "installationId": "shared-installation-0001",
        "platform": "web",
        "provider": "webPush",
        "endpoint": "https://fcm.googleapis.com/fcm/send/secret-endpoint",
        "p256dh": _P256DH,
        "auth": _AUTH,
        "locale": "en-US",
        "timeZone": "America/Los_Angeles",
    }

    created = notification_client.post(
        "/v1/notifications/subscriptions",
        headers={"Authorization": alice_auth},
        json=body,
    )

    assert created.status_code == 200
    assert created.json()["installationId"] == body["installationId"]
    assert "endpoint" not in created.json()
    assert "p256dh" not in created.json()
    assert "auth" not in created.json()
    listed = notification_client.get(
        "/v1/notifications/subscriptions",
        headers={"Authorization": alice_auth},
    )
    assert listed.status_code == 200
    assert len(listed.json()["items"]) == 1

    transferred = notification_client.post(
        "/v1/notifications/subscriptions",
        headers={"Authorization": bob_auth},
        json={
            **body,
            "auth": base64.urlsafe_b64encode(b"b" * 16).decode().rstrip("="),
        },
    )
    assert transferred.status_code == 200
    assert notification_client.get(
        "/v1/notifications/subscriptions",
        headers={"Authorization": alice_auth},
    ).json() == {"items": []}

    deleted = notification_client.delete(
        f"/v1/notifications/subscriptions/{body['installationId']}",
        headers={"Authorization": bob_auth},
    )
    assert deleted.status_code == 204
    assert notification_client.get(
        "/v1/notifications/subscriptions",
        headers={"Authorization": bob_auth},
    ).json() == {"items": []}


def test_web_push_registration_rejects_non_push_service_hosts(
    notification_client: TestClient,
) -> None:
    _, authorization = register_and_login(notification_client, "notify-endpoint")

    response = notification_client.post(
        "/v1/notifications/subscriptions",
        headers={"Authorization": authorization},
        json={
            "installationId": "installation-0002",
            "platform": "web",
            "provider": "webPush",
            "endpoint": "https://example.com/private-callback",
            "p256dh": _P256DH,
            "auth": _AUTH,
        },
    )

    assert response.status_code == 422
    assert response.json()["error"]["code"] == "invalidPushEndpoint"
    assert "private-callback" not in response.text


def test_provider_specific_subscription_fields_are_strict(
    notification_client: TestClient,
) -> None:
    _, authorization = register_and_login(notification_client, "notify-strict")

    response = notification_client.post(
        "/v1/notifications/subscriptions",
        headers={"Authorization": authorization},
        json={
            "installationId": "installation-0003",
            "platform": "web",
            "provider": "firebase",
            "token": "firebase-token-long-enough",
        },
    )

    assert response.status_code == 422
    assert "firebase-token-long-enough" not in response.text


def test_deleted_account_cannot_reregister_a_push_subscription(
    notification_client: TestClient,
) -> None:
    username = "notify-deleted"
    _, authorization = register_and_login(notification_client, username)
    repository = notification_client.app.state.services.repository
    user = notification_client.get("/v1/me", headers={"Authorization": authorization}).json()
    repository.delete_user_data(user["id"])

    response = notification_client.post(
        "/v1/notifications/subscriptions",
        headers={"Authorization": authorization},
        json={
            "installationId": "installation-after-delete",
            "platform": "android",
            "provider": "firebase",
            "token": "firebase-token-long-enough",
        },
    )

    assert response.status_code == 409
    assert response.json()["error"]["code"] == "pushSubscriptionConflict"
