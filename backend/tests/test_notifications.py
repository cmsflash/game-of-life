from __future__ import annotations

import time
from dataclasses import dataclass, field, replace
from datetime import UTC, datetime
from typing import Any

import pytest
from boto3.dynamodb.types import TypeSerializer
from botocore.exceptions import ClientError
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from py_vapid import Vapid02

from life_api import notification_handler
from life_api.models import (
    MatchStatus,
    PlayerSummary,
    PushPlatform,
    PushProviderName,
    StoredMatch,
    StoredPushSubscription,
    TurnNotificationJob,
)
from life_api.notifications import (
    AwsReminderScheduler,
    FirebasePushProvider,
    NotificationMessage,
    PushDeliveryError,
    PushEndpointGone,
    TurnNotificationService,
    WebPushProvider,
    turn_job_for_match,
)
from life_api.repository import InMemoryRepository
from life_api.settings import Settings


@dataclass
class RecordingProvider:
    name: PushProviderName = PushProviderName.web_push
    messages: list[NotificationMessage] = field(default_factory=list)
    endpoint_gone: bool = False

    def send(
        self,
        subscription: StoredPushSubscription,
        message: NotificationMessage,
    ) -> None:
        del subscription
        if self.endpoint_gone:
            raise PushEndpointGone
        self.messages.append(message)


@dataclass
class OneInstallationFailsProvider:
    name: PushProviderName = PushProviderName.web_push
    delivered_installations: list[str] = field(default_factory=list)

    def send(
        self,
        subscription: StoredPushSubscription,
        message: NotificationMessage,
    ) -> None:
        del message
        if subscription.installation_id == "installation-0001":
            raise RuntimeError("provider failed")
        self.delivered_installations.append(subscription.installation_id)


@dataclass
class CapturingProvider:
    name: PushProviderName = PushProviderName.web_push
    subscriptions: list[StoredPushSubscription] = field(default_factory=list)

    def send(
        self,
        subscription: StoredPushSubscription,
        message: NotificationMessage,
    ) -> None:
        del message
        self.subscriptions.append(subscription)


@dataclass
class RefreshingGoneProvider:
    repository: InMemoryRepository
    refreshed: StoredPushSubscription
    name: PushProviderName = PushProviderName.web_push
    subscriptions: list[StoredPushSubscription] = field(default_factory=list)

    def send(
        self,
        subscription: StoredPushSubscription,
        message: NotificationMessage,
    ) -> None:
        del message
        self.subscriptions.append(subscription)
        if len(self.subscriptions) == 1:
            self.repository.upsert_push_subscription(self.refreshed)
            raise PushEndpointGone


@dataclass
class RecordingScheduler:
    jobs: list[tuple[TurnNotificationJob, datetime]] = field(default_factory=list)

    def schedule(self, job: TurnNotificationJob, deliver_at: datetime) -> None:
        self.jobs.append((job, deliver_at))


@dataclass
class DeleteDuringScheduling(RecordingScheduler):
    repository: InMemoryRepository = field(default_factory=InMemoryRepository)

    def schedule(self, job: TurnNotificationJob, deliver_at: datetime) -> None:
        if not self.jobs:
            self.repository.begin_user_deletion("user-white")
        super().schedule(job, deliver_at)


class StubSecretReader:
    def read(self, secret_arn: str) -> str:
        del secret_arn
        return "{}"


class StaticSecretReader:
    def __init__(self, value: str) -> None:
        self._value = value

    def read(self, secret_arn: str) -> str:
        del secret_arn
        return self._value


class StubHttpResponse:
    def __init__(self, status_code: int = 200, payload: object | None = None) -> None:
        self.status_code = status_code
        self._payload = payload

    def json(self) -> object:
        if self._payload is None:
            raise ValueError("not JSON")
        return self._payload


class RecordingHttpClient:
    def __init__(self) -> None:
        self.requests: list[tuple[str, dict[str, Any]]] = []
        self.response = StubHttpResponse()

    def post(self, url: str, **kwargs: Any) -> StubHttpResponse:
        self.requests.append((url, kwargs))
        return self.response


class IdempotentSchedulerClient:
    def __init__(self) -> None:
        self.requests: list[dict[str, Any]] = []

    def create_schedule(self, **kwargs: Any) -> None:
        if self.requests:
            raise ClientError(
                {"Error": {"Code": "ConflictException", "Message": "already exists"}},
                "CreateSchedule",
            )
        self.requests.append(kwargs)


class TurnChangesBeforeSendRepository(InMemoryRepository):
    def __init__(self, initial: StoredMatch, changed: StoredMatch) -> None:
        super().__init__()
        self.create_match(initial)
        self._changed = changed
        self._reads = 0

    def get_match(self, match_id: str) -> StoredMatch | None:
        self._reads += 1
        if self._reads >= 2:
            return self._changed.model_copy(deep=True)
        return super().get_match(match_id)


class RefreshBeforeSendRepository(InMemoryRepository):
    def __init__(self, refreshed: StoredPushSubscription) -> None:
        super().__init__()
        self._refreshed = refreshed
        self._refresh_pending = True

    def get_push_subscription(
        self,
        user_id: str,
        installation_id: str,
    ) -> StoredPushSubscription | None:
        if self._refresh_pending:
            self._refresh_pending = False
            self.upsert_push_subscription(self._refreshed)
        return super().get_push_subscription(user_id, installation_id)


class UnsubscribeBeforeSendRepository(InMemoryRepository):
    def __init__(self) -> None:
        super().__init__()
        self._unsubscribe_pending = True

    def get_push_subscription(
        self,
        user_id: str,
        installation_id: str,
    ) -> StoredPushSubscription | None:
        if self._unsubscribe_pending:
            self._unsubscribe_pending = False
            self.delete_push_subscription(user_id, installation_id)
        return super().get_push_subscription(user_id, installation_id)


def _active_match(*, revision: int = 3, to_move: str = "white") -> StoredMatch:
    return StoredMatch(
        id="00000000-0000-4000-8000-000000000001",
        join_code="ABC123",
        rules={},
        state={"revision": revision, "toMove": to_move},
        creator_id="user-black",
        creator_name="Player",
        black_player=PlayerSummary(id="user-black", display_name="Black player"),
        white_player=PlayerSummary(id="user-white", display_name="White player"),
        status=MatchStatus.active,
        version=revision + 1,
    )


def _subscription() -> StoredPushSubscription:
    return StoredPushSubscription(
        user_id="user-white",
        installation_id="installation-0001",
        platform=PushPlatform.web,
        provider=PushProviderName.web_push,
        endpoint="https://fcm.googleapis.com/fcm/send/secret",
        p256dh="p" * 64,
        auth="a" * 24,
    )


def _service(
    repository: InMemoryRepository,
    provider: RecordingProvider,
    scheduler: RecordingScheduler,
) -> TurnNotificationService:
    return TurnNotificationService(
        repository=repository,
        providers={PushProviderName.web_push: provider},
        scheduler=scheduler,
    )


def test_turn_start_delivers_once_and_schedules_all_reminders() -> None:
    repository = InMemoryRepository()
    match = _active_match()
    repository.create_match(match)
    repository.upsert_push_subscription(_subscription())
    provider = RecordingProvider()
    scheduler = RecordingScheduler()
    service = _service(repository, provider, scheduler)
    job = turn_job_for_match(match)
    assert job is not None

    service.process_turn_start(job)
    service.process_turn_start(job)

    assert len(provider.messages) == 1
    assert provider.messages[0].data["matchId"] == match.id
    assert {entry.reminder_hours for entry, _ in scheduler.jobs} == {8, 24, 72}
    assert all(entry.recipient_user_id is None for entry, _ in scheduler.jobs)


def test_deletion_racing_schedule_creation_never_persists_recipient_identity() -> None:
    repository = InMemoryRepository()
    match = _active_match()
    repository.create_match(match)
    scheduler = DeleteDuringScheduling(repository=repository)
    service = _service(repository, RecordingProvider(), scheduler)
    job = turn_job_for_match(match)
    assert job is not None

    service.process_turn_start(job)

    assert len(scheduler.jobs) == 3
    assert all(
        "recipientUserId" not in entry.model_dump(by_alias=True, exclude_none=True)
        for entry, _ in scheduler.jobs
    )


def test_stale_revision_is_silently_skipped() -> None:
    repository = InMemoryRepository()
    current = _active_match(revision=4, to_move="black")
    repository.create_match(current)
    repository.upsert_push_subscription(_subscription())
    provider = RecordingProvider()
    scheduler = RecordingScheduler()
    service = _service(repository, provider, scheduler)
    stale = TurnNotificationJob(
        match_id=current.id,
        revision=3,
        recipient_user_id="user-white",
        reminder_hours=24,
        turn_started_at=datetime.now(UTC),
    )

    service.process_reminder(stale)

    assert provider.messages == []
    assert scheduler.jobs == []


def test_stale_recipient_is_silently_skipped_at_same_revision() -> None:
    repository = InMemoryRepository()
    current = _active_match(revision=3, to_move="black")
    repository.create_match(current)
    repository.upsert_push_subscription(_subscription())
    provider = RecordingProvider()
    service = _service(repository, provider, RecordingScheduler())
    stale = TurnNotificationJob(
        match_id=current.id,
        revision=3,
        recipient_user_id="user-white",
        reminder_hours=8,
        turn_started_at=datetime.now(UTC),
    )

    service.process_reminder(stale)

    assert provider.messages == []


def test_turn_is_rechecked_immediately_before_provider_send() -> None:
    initial = _active_match(revision=3, to_move="white")
    changed = _active_match(revision=4, to_move="black")
    repository = TurnChangesBeforeSendRepository(initial, changed)
    repository.upsert_push_subscription(_subscription())
    provider = RecordingProvider()
    service = _service(repository, provider, RecordingScheduler())
    job = turn_job_for_match(initial)
    assert job is not None

    service.process_reminder(job)

    assert provider.messages == []


def test_expired_provider_token_is_removed_without_retrying() -> None:
    repository = InMemoryRepository()
    match = _active_match()
    repository.create_match(match)
    repository.upsert_push_subscription(_subscription())
    provider = RecordingProvider(endpoint_gone=True)
    service = _service(repository, provider, RecordingScheduler())
    job = turn_job_for_match(match)
    assert job is not None

    service.process_reminder(job)
    service.process_reminder(job)

    assert repository.list_push_subscriptions("user-white") == []


def test_one_failed_installation_does_not_block_another() -> None:
    repository = InMemoryRepository()
    match = _active_match()
    repository.create_match(match)
    repository.upsert_push_subscription(_subscription())
    repository.upsert_push_subscription(
        _subscription().model_copy(update={"installation_id": "installation-0002"})
    )
    provider = OneInstallationFailsProvider()
    service = TurnNotificationService(
        repository=repository,
        providers={PushProviderName.web_push: provider},
        scheduler=RecordingScheduler(),
    )
    job = turn_job_for_match(match)
    assert job is not None

    with pytest.raises(PushDeliveryError, match="webPush delivery failed"):
        service.process_reminder(job)

    assert provider.delivered_installations == ["installation-0002"]


def test_refreshed_subscription_is_reread_immediately_before_send() -> None:
    refreshed = _subscription().model_copy(
        update={
            "endpoint": "https://fcm.googleapis.com/fcm/send/refreshed",
            "updated_at": datetime.now(UTC),
        }
    )
    repository = RefreshBeforeSendRepository(refreshed)
    match = _active_match()
    repository.create_match(match)
    repository.upsert_push_subscription(_subscription())
    provider = CapturingProvider()
    service = TurnNotificationService(
        repository=repository,
        providers={PushProviderName.web_push: provider},
        scheduler=RecordingScheduler(),
    )
    job = turn_job_for_match(match)
    assert job is not None

    service.process_reminder(job)

    assert [value.endpoint for value in provider.subscriptions] == [refreshed.endpoint]


def test_unsubscribed_installation_is_not_sent_after_snapshot() -> None:
    repository = UnsubscribeBeforeSendRepository()
    match = _active_match()
    repository.create_match(match)
    repository.upsert_push_subscription(_subscription())
    provider = CapturingProvider()
    service = TurnNotificationService(
        repository=repository,
        providers={PushProviderName.web_push: provider},
        scheduler=RecordingScheduler(),
    )
    job = turn_job_for_match(match)
    assert job is not None

    service.process_reminder(job)

    assert provider.subscriptions == []


def test_old_endpoint_failure_cannot_delete_refresh_and_retries_new_value() -> None:
    repository = InMemoryRepository()
    match = _active_match()
    repository.create_match(match)
    original = _subscription()
    refreshed = original.model_copy(
        update={
            "endpoint": "https://fcm.googleapis.com/fcm/send/refreshed-after-send",
            "updated_at": datetime.now(UTC),
        }
    )
    repository.upsert_push_subscription(original)
    provider = RefreshingGoneProvider(repository, refreshed)
    service = TurnNotificationService(
        repository=repository,
        providers={PushProviderName.web_push: provider},
        scheduler=RecordingScheduler(),
    )
    job = turn_job_for_match(match)
    assert job is not None

    with pytest.raises(PushDeliveryError, match="subscription changed during delivery"):
        service.process_reminder(job)
    assert (
        repository.get_push_subscription(refreshed.user_id, refreshed.installation_id) == refreshed
    )

    service.process_reminder(job)

    assert [value.endpoint for value in provider.subscriptions] == [
        original.endpoint,
        refreshed.endpoint,
    ]


def test_stream_handler_only_dispatches_a_new_active_turn(monkeypatch: Any) -> None:
    repository = InMemoryRepository()
    current = _active_match(revision=0, to_move="white")
    repository.create_match(current)
    provider = RecordingProvider()
    scheduler = RecordingScheduler()
    service = _service(repository, provider, scheduler)
    monkeypatch.setattr(notification_handler, "_SERVICE", service)
    previous = current.model_copy(update={"status": MatchStatus.waiting, "version": 0})
    serializer = TypeSerializer()

    def image(match: StoredMatch) -> dict[str, dict[str, Any]]:
        item = {"entity": "match", "document": match.model_dump_json(by_alias=True)}
        return {key: serializer.serialize(value) for key, value in item.items()}

    result = notification_handler.handler(
        {
            "Records": [
                {
                    "eventID": "event-1",
                    "eventName": "MODIFY",
                    "dynamodb": {
                        "OldImage": image(previous),
                        "NewImage": image(current),
                    },
                }
            ]
        },
        None,
    )

    assert result == {"batchItemFailures": []}
    assert {entry.reminder_hours for entry, _ in scheduler.jobs} == {8, 24, 72}


def test_firebase_provider_uses_http_v1_collapse_fields() -> None:
    client = RecordingHttpClient()
    provider = FirebasePushProvider(
        service_account_secret_arn="secret-arn",
        secrets_reader=StubSecretReader(),  # type: ignore[arg-type]
        client=client,  # type: ignore[arg-type]
    )
    provider._credentials = {
        "project_id": "life-project",
        "client_email": "notifications@example.com",
        "private_key": "unused-cached-token",
    }
    provider._access_token = "oauth-token"
    provider._access_token_expires_at = time.time() + 3600
    subscription = StoredPushSubscription(
        user_id="user-white",
        installation_id="installation-mobile-1",
        platform=PushPlatform.android,
        provider=PushProviderName.firebase,
        token="firebase-device-token-long-enough",
    )
    message = NotificationMessage(
        title="It's your turn",
        body="Make a move.",
        data={"matchId": "match-1"},
        collapse_key="collapse-key",
    )

    provider.send(subscription, message)

    payload = client.requests[0][1]["json"]["message"]
    assert payload["android"]["collapseKey"] == "collapse-key"
    assert payload["android"]["ttl"] == "0s"
    assert payload["apns"]["headers"]["apns-collapse-id"] == "collapse-key"
    assert payload["apns"]["headers"]["apns-expiration"] == "0"


@pytest.mark.parametrize(
    ("payload", "is_gone"),
    [
        ({"error": {"status": "NOT_FOUND", "details": []}}, False),
        (
            {
                "error": {
                    "status": "NOT_FOUND",
                    "details": [
                        {
                            "@type": ("type.googleapis.com/google.firebase.fcm.v1.FcmError"),
                            "errorCode": "UNREGISTERED",
                        }
                    ],
                }
            },
            True,
        ),
    ],
)
def test_firebase_only_removes_explicitly_unregistered_tokens(
    payload: object,
    is_gone: bool,
) -> None:
    client = RecordingHttpClient()
    client.response = StubHttpResponse(status_code=404, payload=payload)
    provider = FirebasePushProvider(
        service_account_secret_arn="secret-arn",
        secrets_reader=StubSecretReader(),  # type: ignore[arg-type]
        client=client,  # type: ignore[arg-type]
    )
    provider._credentials = {
        "project_id": "life-project",
        "client_email": "notifications@example.com",
        "private_key": "unused-cached-token",
    }
    provider._access_token = "oauth-token"
    provider._access_token_expires_at = time.time() + 3600
    subscription = StoredPushSubscription(
        user_id="user-white",
        installation_id="installation-mobile-1",
        platform=PushPlatform.android,
        provider=PushProviderName.firebase,
        token="firebase-device-token-long-enough",
    )
    message = NotificationMessage(
        title="It's your turn",
        body="Make a move.",
        data={"matchId": "match-1"},
        collapse_key="collapse-key",
    )

    expected_error = PushEndpointGone if is_gone else PushDeliveryError
    with pytest.raises(expected_error):
        provider.send(subscription, message)


def test_web_push_provider_disables_provider_queueing(monkeypatch: Any) -> None:
    pem = (
        ec.generate_private_key(ec.SECP256R1())
        .private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        )
        .decode()
    )
    calls: list[dict[str, Any]] = []
    monkeypatch.setattr(
        "life_api.notifications.webpush",
        lambda **kwargs: calls.append(kwargs),
    )
    provider = WebPushProvider(
        private_key_secret_arn="secret-arn",
        subject="mailto:operations@example.com",
        secrets_reader=StaticSecretReader(pem),  # type: ignore[arg-type]
    )
    message = NotificationMessage(
        title="It's your turn",
        body="Make a move.",
        data={"matchId": "match-1"},
        collapse_key="collapse-key",
    )

    provider.send(_subscription(), message)

    assert calls[0]["ttl"] == 0
    assert calls[0]["headers"]["Topic"] == "collapse-key"


def test_web_push_provider_normalizes_pem_secret_before_transport(monkeypatch: Any) -> None:
    private_key = ec.generate_private_key(ec.SECP256R1())
    pem = private_key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    ).decode()
    calls: list[dict[str, Any]] = []
    monkeypatch.setattr(
        "life_api.notifications.webpush",
        lambda **kwargs: calls.append(kwargs),
    )
    provider = WebPushProvider(
        private_key_secret_arn="secret-arn",
        subject="mailto:operations@example.com",
        secrets_reader=StaticSecretReader(pem),  # type: ignore[arg-type]
    )
    message = NotificationMessage(
        title="It's your turn",
        body="Make a move.",
        data={"matchId": "match-1"},
        collapse_key="collapse-key",
    )

    provider.send(_subscription(), message)

    normalized = calls[0]["vapid_private_key"]
    assert isinstance(normalized, Vapid02)
    assert normalized.public_key.public_numbers() == private_key.public_key().public_numbers()


def test_turn_alerts_for_same_match_share_provider_collapse_key() -> None:
    repository = InMemoryRepository()
    match = _active_match()
    repository.create_match(match)
    repository.upsert_push_subscription(_subscription())
    provider = RecordingProvider()
    service = _service(repository, provider, RecordingScheduler())
    immediate = turn_job_for_match(match)
    assert immediate is not None

    service.process_reminder(immediate)
    service.process_reminder(immediate.model_copy(update={"reminder_hours": 8}))

    assert len(provider.messages) == 2
    assert provider.messages[0].collapse_key == provider.messages[1].collapse_key


def test_corrupt_to_move_never_notifies_white_by_default() -> None:
    repository = InMemoryRepository()
    match = _active_match().model_copy(update={"state": {"revision": 3, "toMove": "unknown"}})
    repository.create_match(match)
    repository.upsert_push_subscription(_subscription())
    provider = RecordingProvider()
    service = _service(repository, provider, RecordingScheduler())

    assert turn_job_for_match(match) is None
    service.process_reminder(
        TurnNotificationJob(
            match_id=match.id,
            revision=3,
            recipient_user_id="user-white",
            reminder_hours=8,
            turn_started_at=datetime.now(UTC),
        )
    )
    assert provider.messages == []


def test_scheduler_uses_deterministic_one_time_jobs(
    monkeypatch: Any,
    settings: Settings,
) -> None:
    client = IdempotentSchedulerClient()
    monkeypatch.setattr(
        "life_api.notifications.boto3.client",
        lambda service, region_name: client,
    )
    configured = replace(
        settings,
        notification_function_arn="arn:aws:lambda:test:1:function:notifications",
        notification_scheduler_role_arn="arn:aws:iam::1:role/scheduler",
        notification_schedule_group_name="turn-reminders",
        notification_dead_letter_queue_arn="arn:aws:sqs:test:1:notification-dlq",
    )
    scheduler = AwsReminderScheduler(configured)
    job = TurnNotificationJob(
        match_id="00000000-0000-4000-8000-000000000001",
        revision=4,
        recipient_user_id="user-white",
        reminder_hours=8,
        turn_started_at=datetime(2026, 8, 14, tzinfo=UTC),
    )
    deliver_at = datetime(2026, 8, 14, 8, tzinfo=UTC)

    scheduler.schedule(job, deliver_at)
    scheduler.schedule(job, deliver_at)

    request = client.requests[0]
    assert request["Name"].startswith("turn-")
    assert request["ScheduleExpression"] == "at(2026-08-14T08:00:00)"
    assert request["ActionAfterCompletion"] == "DELETE"
    assert request["Target"]["DeadLetterConfig"]["Arn"].endswith("notification-dlq")
    assert "recipientUserId" not in request["Target"]["Input"]
