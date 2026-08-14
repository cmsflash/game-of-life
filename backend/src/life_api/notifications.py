from __future__ import annotations

import hashlib
import ipaddress
import json
import logging
import time
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any, Protocol, cast
from urllib.parse import quote, urlsplit

import boto3
import httpx
import jwt
from botocore.exceptions import ClientError
from py_vapid import Vapid02
from pywebpush import WebPushException, webpush

from .errors import ApiError
from .models import (
    FirebasePushSubscriptionRequest,
    MatchStatus,
    PushNotificationConfig,
    PushProviderName,
    PushSubscriptionDocument,
    PushSubscriptionRequest,
    StoredMatch,
    StoredPushSubscription,
    TurnNotificationJob,
    User,
    WebPushSubscriptionRequest,
)
from .repository import Repository, build_repository
from .settings import Settings

LOGGER = logging.getLogger("life_api.notifications")
_REMINDER_HOURS = (8, 24, 72)
_MAX_SUBSCRIPTIONS_PER_USER = 5
_PROVIDER_QUEUE_TTL_SECONDS = 0


class PushEndpointGone(Exception):
    """The provider no longer recognizes a device/browser subscription."""


class PushDeliveryError(Exception):
    """A provider failed without exposing endpoint or credential details."""


@dataclass(frozen=True, slots=True)
class NotificationMessage:
    title: str
    body: str
    data: dict[str, str]
    collapse_key: str


class PushProvider(Protocol):
    name: PushProviderName

    def send(
        self,
        subscription: StoredPushSubscription,
        message: NotificationMessage,
    ) -> None: ...


class ReminderScheduler(Protocol):
    def schedule(self, job: TurnNotificationJob, deliver_at: datetime) -> None: ...


class AwsSecretReader:
    def __init__(self, region_name: str) -> None:
        self._client = boto3.client("secretsmanager", region_name=region_name)
        self._cache: dict[str, str] = {}

    def read(self, secret_arn: str) -> str:
        cached = self._cache.get(secret_arn)
        if cached is not None:
            return cached
        response = self._client.get_secret_value(SecretId=secret_arn)
        value = response.get("SecretString")
        if not isinstance(value, str) or not value:
            raise RuntimeError("push credential secret must contain a non-empty SecretString")
        self._cache[secret_arn] = value
        return value


class WebPushProvider:
    name = PushProviderName.web_push

    def __init__(
        self,
        *,
        private_key_secret_arn: str,
        subject: str,
        secrets_reader: AwsSecretReader,
    ) -> None:
        self._private_key_secret_arn = private_key_secret_arn
        self._subject = subject
        self._secrets = secrets_reader
        self._private_key: Vapid02 | None = None

    def send(
        self,
        subscription: StoredPushSubscription,
        message: NotificationMessage,
    ) -> None:
        if not subscription.endpoint or not subscription.p256dh or not subscription.auth:
            raise PushEndpointGone("Web Push subscription is incomplete")
        payload = {
            "title": message.title,
            "body": message.body,
            "data": message.data,
            "tag": message.collapse_key,
        }
        try:
            webpush(
                subscription_info={
                    "endpoint": subscription.endpoint,
                    "keys": {
                        "p256dh": subscription.p256dh,
                        "auth": subscription.auth,
                    },
                },
                data=json.dumps(payload, separators=(",", ":")),
                vapid_private_key=self._vapid_private_key(),
                vapid_claims={"sub": self._subject},
                # A turn can become stale at any moment. Do not let a push
                # service retain and deliver this alert after the send attempt.
                ttl=_PROVIDER_QUEUE_TTL_SECONDS,
                timeout=4.0,
                headers={"Topic": message.collapse_key},
            )
        except WebPushException as error:
            response = getattr(error, "response", None)
            if response is not None and response.status_code in {404, 410}:
                raise PushEndpointGone("Web Push subscription expired") from None
            status = response.status_code if response is not None else "unknown"
            raise PushDeliveryError(f"Web Push delivery failed with HTTP {status}") from None

    def _vapid_private_key(self) -> Vapid02:
        if self._private_key is not None:
            return self._private_key
        encoded = self._secrets.read(self._private_key_secret_arn).strip()
        try:
            if encoded.startswith("-----BEGIN"):
                private_key = Vapid02.from_pem(encoded.encode())
            else:
                private_key = Vapid02.from_string(encoded)
        except (TypeError, ValueError):
            raise PushDeliveryError("Web Push VAPID private key is invalid") from None
        self._private_key = private_key
        return private_key


class FirebasePushProvider:
    name = PushProviderName.firebase

    def __init__(
        self,
        *,
        service_account_secret_arn: str,
        secrets_reader: AwsSecretReader,
        client: httpx.Client | None = None,
    ) -> None:
        self._secret_arn = service_account_secret_arn
        self._secrets = secrets_reader
        self._client = client or httpx.Client(timeout=5.0)
        self._credentials: dict[str, str] | None = None
        self._access_token: str | None = None
        self._access_token_expires_at = 0.0

    def send(
        self,
        subscription: StoredPushSubscription,
        message: NotificationMessage,
    ) -> None:
        if not subscription.token:
            raise PushEndpointGone("Firebase registration token is missing")
        credentials = self._service_account()
        project_id = quote(credentials["project_id"], safe="")
        response = self._client.post(
            f"https://fcm.googleapis.com/v1/projects/{project_id}/messages:send",
            headers={
                "Authorization": f"Bearer {self._oauth_access_token()}",
                "Content-Type": "application/json",
            },
            json={
                "message": {
                    "token": subscription.token,
                    "notification": {"title": message.title, "body": message.body},
                    "data": message.data,
                    "android": {
                        "collapseKey": message.collapse_key,
                        "priority": "HIGH",
                        "ttl": f"{_PROVIDER_QUEUE_TTL_SECONDS}s",
                    },
                    "apns": {
                        "headers": {
                            "apns-collapse-id": message.collapse_key,
                            "apns-expiration": str(_PROVIDER_QUEUE_TTL_SECONDS),
                            "apns-priority": "10",
                            "apns-push-type": "alert",
                        },
                        "payload": {
                            "aps": {
                                "sound": "default",
                                "thread-id": message.data["matchId"],
                            }
                        },
                    },
                }
            },
        )
        if response.status_code < 300:
            return
        if _is_unregistered_fcm_response(response):
            raise PushEndpointGone("Firebase registration token expired")
        raise PushDeliveryError(f"Firebase delivery failed with HTTP {response.status_code}")

    def _service_account(self) -> dict[str, str]:
        if self._credentials is not None:
            return self._credentials
        raw = json.loads(self._secrets.read(self._secret_arn))
        required = ("project_id", "client_email", "private_key")
        if not isinstance(raw, dict) or any(not isinstance(raw.get(key), str) for key in required):
            raise RuntimeError("Firebase service-account secret has an invalid JSON shape")
        self._credentials = cast(dict[str, str], raw)
        return self._credentials

    def _oauth_access_token(self) -> str:
        now = time.time()
        if self._access_token and now < self._access_token_expires_at - 300:
            return self._access_token
        credentials = self._service_account()
        assertion = jwt.encode(
            {
                "iss": credentials["client_email"],
                "scope": "https://www.googleapis.com/auth/firebase.messaging",
                "aud": "https://oauth2.googleapis.com/token",
                "iat": int(now),
                "exp": int(now) + 3600,
            },
            credentials["private_key"],
            algorithm="RS256",
        )
        response = self._client.post(
            "https://oauth2.googleapis.com/token",
            data={
                "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
                "assertion": assertion,
            },
        )
        response.raise_for_status()
        payload = response.json()
        token = payload.get("access_token")
        if not isinstance(token, str) or not token:
            raise RuntimeError("Firebase OAuth response did not include an access token")
        self._access_token = token
        self._access_token_expires_at = now + int(payload.get("expires_in", 3600))
        return token


class AwsReminderScheduler:
    def __init__(self, settings: Settings) -> None:
        if (
            not settings.notification_function_arn
            or not settings.notification_scheduler_role_arn
            or not settings.notification_schedule_group_name
        ):
            raise RuntimeError("notification scheduler settings are incomplete")
        self._client = boto3.client("scheduler", region_name=settings.aws_region)
        self._function_arn = settings.notification_function_arn
        self._role_arn = settings.notification_scheduler_role_arn
        self._group_name = settings.notification_schedule_group_name
        self._dead_letter_queue_arn = settings.notification_dead_letter_queue_arn

    def schedule(self, job: TurnNotificationJob, deliver_at: datetime) -> None:
        canonical = job.model_dump_json(by_alias=True)
        digest = hashlib.sha256(canonical.encode()).hexdigest()[:40]
        try:
            target: dict[str, Any] = {
                "Arn": self._function_arn,
                "RoleArn": self._role_arn,
                "Input": canonical,
                "RetryPolicy": {
                    "MaximumEventAgeInSeconds": 3600,
                    "MaximumRetryAttempts": 4,
                },
            }
            if self._dead_letter_queue_arn:
                target["DeadLetterConfig"] = {"Arn": self._dead_letter_queue_arn}
            self._client.create_schedule(
                Name=f"turn-{digest}",
                GroupName=self._group_name,
                ScheduleExpression=f"at({deliver_at.astimezone(UTC):%Y-%m-%dT%H:%M:%S})",
                ScheduleExpressionTimezone="UTC",
                FlexibleTimeWindow={"Mode": "OFF"},
                ActionAfterCompletion="DELETE",
                Target=target,
                Description=(
                    f"Turn reminder for revision {job.revision} after {job.reminder_hours} hours"
                ),
            )
        except ClientError as error:
            if error.response["Error"]["Code"] != "ConflictException":
                raise


@dataclass(slots=True)
class PushSubscriptionService:
    repository: Repository
    settings: Settings

    def config(self) -> PushNotificationConfig:
        providers = [PushProviderName(value) for value in self.settings.push_providers]
        return PushNotificationConfig(
            providers=providers,
            web_push_vapid_public_key=(
                self.settings.web_push_vapid_public_key
                if PushProviderName.web_push in providers
                else None
            ),
        )

    def register(
        self,
        user: User,
        request: PushSubscriptionRequest,
    ) -> PushSubscriptionDocument:
        if request.provider.value not in self.settings.push_providers:
            raise ApiError(
                "pushProviderUnavailable",
                "That push-notification provider is not configured.",
                status_code=503,
            )
        if isinstance(request, WebPushSubscriptionRequest):
            self._validate_web_push_endpoint(request.endpoint)
        lock_token = self.repository.acquire_matchmaking_lock(user.id)
        if lock_token is None:
            raise ApiError(
                "accountUpdateBusy",
                "Another request is updating this account. Try again.",
                status_code=409,
            )
        try:
            now = datetime.now(UTC)
            subscriptions = self.repository.list_push_subscriptions(user.id)
            existing = next(
                (
                    value
                    for value in subscriptions
                    if value.installation_id == request.installation_id
                ),
                None,
            )
            if existing is None and len(subscriptions) >= _MAX_SUBSCRIPTIONS_PER_USER:
                raise ApiError(
                    "pushSubscriptionLimit",
                    "Remove an older notification installation before adding another.",
                    status_code=409,
                )
            subscription = StoredPushSubscription(
                user_id=user.id,
                installation_id=request.installation_id,
                platform=request.platform,
                provider=request.provider,
                token=(
                    request.token if isinstance(request, FirebasePushSubscriptionRequest) else None
                ),
                endpoint=(
                    request.endpoint if isinstance(request, WebPushSubscriptionRequest) else None
                ),
                p256dh=(
                    request.p256dh if isinstance(request, WebPushSubscriptionRequest) else None
                ),
                auth=(request.auth if isinstance(request, WebPushSubscriptionRequest) else None),
                locale=request.locale,
                time_zone=request.time_zone,
                created_at=existing.created_at if existing else now,
                updated_at=now,
            )
            return self.repository.upsert_push_subscription(subscription).document()
        finally:
            self.repository.release_matchmaking_lock(user.id, lock_token)

    def list(self, user: User) -> list[PushSubscriptionDocument]:
        return [value.document() for value in self.repository.list_push_subscriptions(user.id)]

    def delete(self, user: User, installation_id: str) -> None:
        self.repository.delete_push_subscription(user.id, installation_id)

    def _validate_web_push_endpoint(self, endpoint: str) -> None:
        hostname = urlsplit(endpoint).hostname
        if hostname is None or _is_ip_address(hostname):
            raise ApiError(
                "invalidPushEndpoint",
                "The browser push endpoint is not an allowed push service.",
                status_code=422,
            )
        normalized = hostname.casefold().rstrip(".")
        if not any(
            normalized == suffix.casefold().lstrip(".")
            or normalized.endswith(f".{suffix.casefold().lstrip('.')}")
            for suffix in self.settings.web_push_allowed_host_suffixes
        ):
            raise ApiError(
                "invalidPushEndpoint",
                "The browser push endpoint is not an allowed push service.",
                status_code=422,
            )


@dataclass(slots=True)
class TurnNotificationService:
    repository: Repository
    providers: dict[PushProviderName, PushProvider]
    scheduler: ReminderScheduler

    def process_turn_start(self, job: TurnNotificationJob) -> None:
        match = self._current_match(job)
        if match is None:
            return
        delivery_error: Exception | None = None
        try:
            self._deliver(job)
        except Exception as error:  # schedules must survive a provider outage
            delivery_error = error
        now = datetime.now(UTC)
        for hours in _REMINDER_HOURS:
            deliver_at = job.turn_started_at + timedelta(hours=hours)
            if deliver_at <= now:
                continue
            self.scheduler.schedule(
                job.model_copy(update={"reminder_hours": hours}),
                deliver_at,
            )
        if delivery_error is not None:
            raise delivery_error

    def process_reminder(self, job: TurnNotificationJob) -> None:
        if self._current_match(job) is not None:
            self._deliver(job)

    def _current_match(self, job: TurnNotificationJob) -> StoredMatch | None:
        match = self.repository.get_match(job.match_id)
        if match is None or match.status != MatchStatus.active or match.revision != job.revision:
            return None
        to_move = match.state.get("toMove")
        if to_move not in {"black", "white"}:
            return None
        player = match.black_player if to_move == "black" else match.white_player
        if player is None or player.id != job.recipient_user_id:
            return None
        return match

    def _deliver(self, job: TurnNotificationJob) -> None:
        message = _message(job)
        subscriptions = self.repository.list_push_subscriptions(job.recipient_user_id)
        first_error: Exception | None = None
        for snapshot in subscriptions[:_MAX_SUBSCRIPTIONS_PER_USER]:
            delivery_id = _delivery_id(job, snapshot.installation_id)
            claim_token = self.repository.claim_notification_delivery(delivery_id)
            if claim_token is None:
                continue
            # Close the stream/scheduler-to-provider race as tightly as
            # possible. External push acceptance cannot share a transaction
            # with DynamoDB, so this is the final authoritative read.
            if self._current_match(job) is None:
                self.repository.complete_notification_delivery(delivery_id, claim_token)
                return
            subscription = self.repository.get_push_subscription(
                snapshot.user_id,
                snapshot.installation_id,
            )
            if subscription is None:
                self.repository.complete_notification_delivery(delivery_id, claim_token)
                continue
            provider = self.providers.get(subscription.provider)
            if provider is None:
                self.repository.complete_notification_delivery(delivery_id, claim_token)
                continue
            try:
                provider.send(subscription, message)
            except PushEndpointGone:
                if self.repository.delete_push_subscription_if_unchanged(subscription):
                    self.repository.complete_notification_delivery(delivery_id, claim_token)
                else:
                    # A refreshed credential won the race with the provider
                    # response. Release the claim so a retry can use it.
                    self.repository.release_notification_delivery(delivery_id, claim_token)
                    if first_error is None:
                        first_error = PushDeliveryError(
                            f"{subscription.provider.value} subscription changed during delivery"
                        )
            except Exception:
                self.repository.release_notification_delivery(delivery_id, claim_token)
                if first_error is None:
                    first_error = PushDeliveryError(
                        f"{subscription.provider.value} delivery failed"
                    )
            else:
                self.repository.complete_notification_delivery(delivery_id, claim_token)
        if first_error is not None:
            raise first_error


def build_turn_notification_service(settings: Settings) -> TurnNotificationService:
    repository = build_repository(settings)
    secrets_reader = AwsSecretReader(settings.aws_region)
    providers: dict[PushProviderName, PushProvider] = {}
    if "webPush" in settings.push_providers:
        assert settings.web_push_vapid_private_key_secret_arn
        assert settings.web_push_vapid_subject
        providers[PushProviderName.web_push] = WebPushProvider(
            private_key_secret_arn=settings.web_push_vapid_private_key_secret_arn,
            subject=settings.web_push_vapid_subject,
            secrets_reader=secrets_reader,
        )
    if "firebase" in settings.push_providers:
        assert settings.firebase_service_account_secret_arn
        providers[PushProviderName.firebase] = FirebasePushProvider(
            service_account_secret_arn=settings.firebase_service_account_secret_arn,
            secrets_reader=secrets_reader,
        )
    return TurnNotificationService(
        repository=repository,
        providers=providers,
        scheduler=AwsReminderScheduler(settings),
    )


def turn_job_for_match(match: StoredMatch) -> TurnNotificationJob | None:
    if match.status != MatchStatus.active:
        return None
    to_move = match.state.get("toMove")
    if to_move not in {"black", "white"}:
        return None
    player = match.black_player if to_move == "black" else match.white_player
    if player is None or player.id.startswith("deleted-"):
        return None
    return TurnNotificationJob(
        match_id=match.id,
        revision=match.revision,
        recipient_user_id=player.id,
        reminder_hours=0,
        turn_started_at=match.updated_at,
    )


def is_new_turn(previous: StoredMatch | None, current: StoredMatch) -> bool:
    if current.status != MatchStatus.active:
        return False
    return (
        previous is None
        or previous.status != MatchStatus.active
        or previous.revision != current.revision
        or previous.state.get("toMove") != current.state.get("toMove")
    )


def _message(job: TurnNotificationJob) -> NotificationMessage:
    if job.reminder_hours == 0:
        title = "It's your turn"
        body = "Your Game of Life match is ready for your move."
    else:
        title = "Your turn is waiting"
        body = f"It has been {job.reminder_hours} hours. Your opponent is waiting."
    # Collapse all turn alerts for a match together. The delivery ledger still
    # distinguishes revisions/reminders, while provider queues cannot build up
    # an obsolete burst for the same match.
    collapse_key = hashlib.sha256(job.match_id.encode()).hexdigest()[:32]
    return NotificationMessage(
        title=title,
        body=body,
        collapse_key=collapse_key,
        data={
            "type": "turn",
            "matchId": job.match_id,
            "revision": str(job.revision),
            "reminderHours": str(job.reminder_hours),
            "path": f"/online/match/{job.match_id}",
        },
    )


def _delivery_id(job: TurnNotificationJob, installation_id: str) -> str:
    canonical = (
        f"{job.match_id}:{job.revision}:{job.recipient_user_id}:"
        f"{job.reminder_hours}:{installation_id}"
    )
    return hashlib.sha256(canonical.encode()).hexdigest()


def _is_ip_address(hostname: str) -> bool:
    try:
        ipaddress.ip_address(hostname)
    except ValueError:
        return False
    return True


def _is_unregistered_fcm_response(response: httpx.Response) -> bool:
    if response.status_code != 404:
        return False
    try:
        payload = response.json()
    except ValueError:
        return False
    if not isinstance(payload, dict) or not isinstance(payload.get("error"), dict):
        return False
    details = payload["error"].get("details", [])
    if not isinstance(details, list):
        return False
    return any(
        isinstance(detail, dict)
        and detail.get("@type") == "type.googleapis.com/google.firebase.fcm.v1.FcmError"
        and detail.get("errorCode") == "UNREGISTERED"
        for detail in details
    )
