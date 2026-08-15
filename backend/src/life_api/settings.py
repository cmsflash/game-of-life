from __future__ import annotations

import base64
import binascii
import ipaddress
import os
import re
from dataclasses import dataclass
from functools import lru_cache
from urllib.parse import urlsplit

from cryptography.hazmat.primitives.asymmetric import ec

_NATIVE_SCHEME_PATTERN = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*$")


def _csv(name: str, default: str = "") -> tuple[str, ...]:
    return tuple(value.strip() for value in os.getenv(name, default).split(",") if value.strip())


def _boolean(name: str, default: bool) -> bool:
    value = os.getenv(name)
    if value is None:
        return default
    normalized = value.strip().lower()
    if normalized in {"1", "true", "yes"}:
        return True
    if normalized in {"0", "false", "no"}:
        return False
    raise RuntimeError(f"{name} must be true or false")


@dataclass(frozen=True, slots=True)
class Settings:
    app_env: str
    aws_region: str
    table_name: str
    engine_executable: str | None
    cors_origins: tuple[str, ...]
    allowed_return_urls: tuple[str, ...]
    local_token_secret: str
    cognito_user_pool_id: str | None
    cognito_client_id: str | None
    cognito_client_secret: str | None
    cognito_hosted_ui_base: str | None
    cognito_oauth_callback_url: str | None
    oauth_state_secret: str
    google_login_enabled: bool
    push_providers: tuple[str, ...] = ()
    firebase_service_account_secret_arn: str | None = None
    web_push_vapid_private_key_secret_arn: str | None = None
    web_push_vapid_public_key: str | None = None
    web_push_vapid_subject: str | None = None
    web_push_allowed_host_suffixes: tuple[str, ...] = (
        "fcm.googleapis.com",
        "push.services.mozilla.com",
        "push.apple.com",
        "notify.windows.com",
    )
    notification_function_arn: str | None = None
    notification_scheduler_role_arn: str | None = None
    notification_schedule_group_name: str | None = None
    notification_dead_letter_queue_arn: str | None = None
    app_component: str = "api"
    avatar_bucket_name: str | None = None
    public_api_base_url: str | None = None
    avatar_cleanup_queue_url: str | None = None

    @property
    def is_production(self) -> bool:
        return self.app_env == "production"

    @classmethod
    def from_env(cls) -> Settings:
        app_env = os.getenv("APP_ENV", "local").strip().lower()
        local_secret = os.getenv("LOCAL_TOKEN_SECRET", "local-development-only-secret")
        oauth_secret = os.getenv("OAUTH_STATE_SECRET", local_secret)
        settings = cls(
            app_env=app_env,
            aws_region=os.getenv("AWS_REGION", "ap-east-1"),
            table_name=os.getenv("TABLE_NAME", "life-local"),
            engine_executable=os.getenv("ENGINE_EXECUTABLE") or None,
            cors_origins=_csv(
                "CORS_ORIGINS",
                "http://localhost:3000,http://localhost:5000,http://localhost:8081",
            ),
            allowed_return_urls=_csv(
                "ALLOWED_RETURN_URLS",
                "http://localhost:3000/auth/callback,"
                "http://localhost:5000/auth/callback,"
                "com.cmsflash.gameoflife://auth",
            ),
            local_token_secret=local_secret,
            cognito_user_pool_id=os.getenv("COGNITO_USER_POOL_ID") or None,
            cognito_client_id=os.getenv("COGNITO_CLIENT_ID") or None,
            cognito_client_secret=os.getenv("COGNITO_CLIENT_SECRET") or None,
            cognito_hosted_ui_base=os.getenv("COGNITO_HOSTED_UI_BASE") or None,
            cognito_oauth_callback_url=os.getenv("COGNITO_OAUTH_CALLBACK_URL") or None,
            oauth_state_secret=oauth_secret,
            google_login_enabled=_boolean("GOOGLE_LOGIN_ENABLED", app_env != "production"),
            push_providers=_csv("PUSH_PROVIDERS"),
            firebase_service_account_secret_arn=(
                os.getenv("FIREBASE_SERVICE_ACCOUNT_SECRET_ARN") or None
            ),
            web_push_vapid_private_key_secret_arn=(
                os.getenv("WEB_PUSH_VAPID_PRIVATE_KEY_SECRET_ARN") or None
            ),
            web_push_vapid_public_key=os.getenv("WEB_PUSH_VAPID_PUBLIC_KEY") or None,
            web_push_vapid_subject=os.getenv("WEB_PUSH_VAPID_SUBJECT") or None,
            web_push_allowed_host_suffixes=_csv(
                "WEB_PUSH_ALLOWED_HOST_SUFFIXES",
                ("fcm.googleapis.com,push.services.mozilla.com,push.apple.com,notify.windows.com"),
            ),
            notification_function_arn=os.getenv("NOTIFICATION_FUNCTION_ARN") or None,
            notification_scheduler_role_arn=(os.getenv("NOTIFICATION_SCHEDULER_ROLE_ARN") or None),
            notification_schedule_group_name=(
                os.getenv("NOTIFICATION_SCHEDULE_GROUP_NAME") or None
            ),
            notification_dead_letter_queue_arn=(
                os.getenv("NOTIFICATION_DEAD_LETTER_QUEUE_ARN") or None
            ),
            app_component=os.getenv("APP_COMPONENT", "api").strip().lower(),
            avatar_bucket_name=os.getenv("AVATAR_BUCKET_NAME") or None,
            public_api_base_url=os.getenv("PUBLIC_API_BASE_URL") or None,
            avatar_cleanup_queue_url=os.getenv("AVATAR_CLEANUP_QUEUE_URL") or None,
        )
        settings.validate()
        return settings

    def validate(self) -> None:
        allowed_environments = {"local", "test", "production"}
        if self.app_env not in allowed_environments:
            raise RuntimeError(f"APP_ENV must be one of: {', '.join(sorted(allowed_environments))}")
        if self.app_component not in {"api", "notifications"}:
            raise RuntimeError("APP_COMPONENT must be api or notifications")
        supported_push_providers = {"firebase", "webPush"}
        unknown_push_providers = set(self.push_providers) - supported_push_providers
        if unknown_push_providers:
            raise RuntimeError(
                "PUSH_PROVIDERS contains unsupported values: "
                + ", ".join(sorted(unknown_push_providers))
            )
        if "firebase" in self.push_providers and not self.firebase_service_account_secret_arn:
            raise RuntimeError(
                "FIREBASE_SERVICE_ACCOUNT_SECRET_ARN is required when firebase push is enabled"
            )
        if "webPush" in self.push_providers:
            missing_web_push = [
                name
                for name, value in {
                    "WEB_PUSH_VAPID_PRIVATE_KEY_SECRET_ARN": (
                        self.web_push_vapid_private_key_secret_arn
                    ),
                    "WEB_PUSH_VAPID_PUBLIC_KEY": self.web_push_vapid_public_key,
                    "WEB_PUSH_VAPID_SUBJECT": self.web_push_vapid_subject,
                }.items()
                if not value
            ]
            if missing_web_push:
                raise RuntimeError("missing Web Push settings: " + ", ".join(missing_web_push))
            if not self.web_push_allowed_host_suffixes:
                raise RuntimeError("WEB_PUSH_ALLOWED_HOST_SUFFIXES must not be empty")
            assert self.web_push_vapid_public_key
            try:
                decoded_public_key = base64.b64decode(
                    self.web_push_vapid_public_key
                    + "=" * (-len(self.web_push_vapid_public_key) % 4),
                    altchars=b"-_",
                    validate=True,
                )
            except (binascii.Error, ValueError) as error:
                raise RuntimeError("WEB_PUSH_VAPID_PUBLIC_KEY must be URL-safe base64") from error
            if len(decoded_public_key) != 65 or decoded_public_key[0] != 4:
                raise RuntimeError(
                    "WEB_PUSH_VAPID_PUBLIC_KEY must be an uncompressed P-256 public key"
                )
            try:
                ec.EllipticCurvePublicKey.from_encoded_point(
                    ec.SECP256R1(),
                    decoded_public_key,
                )
            except ValueError as error:
                raise RuntimeError(
                    "WEB_PUSH_VAPID_PUBLIC_KEY must contain a valid P-256 point"
                ) from error
            assert self.web_push_vapid_subject
            if not (
                (
                    self.web_push_vapid_subject.startswith("mailto:")
                    and "@" in self.web_push_vapid_subject.removeprefix("mailto:")
                )
                or self.web_push_vapid_subject.startswith("https://")
            ):
                raise RuntimeError("WEB_PUSH_VAPID_SUBJECT must be a mailto: or HTTPS URI")
        if self.push_providers and self.app_component == "notifications":
            missing_scheduler = [
                name
                for name, value in {
                    "NOTIFICATION_FUNCTION_ARN": self.notification_function_arn,
                    "NOTIFICATION_SCHEDULER_ROLE_ARN": self.notification_scheduler_role_arn,
                    "NOTIFICATION_SCHEDULE_GROUP_NAME": self.notification_schedule_group_name,
                }.items()
                if not value
            ]
            if missing_scheduler:
                raise RuntimeError(
                    "missing notification scheduler settings: " + ", ".join(missing_scheduler)
                )
        if self.is_production and self.app_component == "api":
            required = {
                "COGNITO_USER_POOL_ID": self.cognito_user_pool_id,
                "COGNITO_CLIENT_ID": self.cognito_client_id,
                "COGNITO_HOSTED_UI_BASE": self.cognito_hosted_ui_base,
                "COGNITO_OAUTH_CALLBACK_URL": self.cognito_oauth_callback_url,
                "AVATAR_BUCKET_NAME": self.avatar_bucket_name,
                "PUBLIC_API_BASE_URL": self.public_api_base_url,
                "AVATAR_CLEANUP_QUEUE_URL": self.avatar_cleanup_queue_url,
            }
            missing = [name for name, value in required.items() if not value]
            if missing:
                raise RuntimeError(f"missing production settings: {', '.join(missing)}")
            if self.local_token_secret == "local-development-only-secret":
                raise RuntimeError("LOCAL_TOKEN_SECRET must be replaced in production")
            self._validate_production_urls()

    def _validate_production_urls(self) -> None:
        if not self.cors_origins:
            raise RuntimeError("CORS_ORIGINS must contain at least one production HTTPS origin")
        for origin in self.cors_origins:
            _validate_production_https_url("CORS_ORIGINS", origin, origin_only=True)

        if not self.allowed_return_urls:
            raise RuntimeError("ALLOWED_RETURN_URLS must contain at least one production URL")
        for return_url in self.allowed_return_urls:
            _validate_production_return_url(return_url)

        assert self.cognito_hosted_ui_base
        assert self.cognito_oauth_callback_url
        assert self.public_api_base_url
        _validate_production_https_url(
            "COGNITO_HOSTED_UI_BASE",
            self.cognito_hosted_ui_base,
            origin_only=True,
        )
        _validate_production_https_url(
            "COGNITO_OAUTH_CALLBACK_URL",
            self.cognito_oauth_callback_url,
            origin_only=False,
        )
        _validate_production_https_url(
            "PUBLIC_API_BASE_URL",
            self.public_api_base_url,
            origin_only=False,
        )


def _validate_production_return_url(value: str) -> None:
    if "*" in value:
        raise RuntimeError("ALLOWED_RETURN_URLS must not contain wildcards in production")
    parts = urlsplit(value)
    scheme = parts.scheme.casefold()
    if scheme in {"http", "https"}:
        if scheme != "https":
            raise RuntimeError("ALLOWED_RETURN_URLS must not contain HTTP URLs in production")
        _validate_production_https_url("ALLOWED_RETURN_URLS", value, origin_only=False)
        return
    if (
        not scheme
        or not _NATIVE_SCHEME_PATTERN.fullmatch(parts.scheme)
        or "." not in scheme
        or not parts.netloc
        or parts.username is not None
        or parts.password is not None
    ):
        raise RuntimeError(
            "ALLOWED_RETURN_URLS entries must be HTTPS URLs or reverse-domain app URLs"
        )
    if _is_local_hostname(parts.hostname):
        raise RuntimeError("ALLOWED_RETURN_URLS must not contain localhost in production")


def _validate_production_https_url(name: str, value: str, *, origin_only: bool) -> None:
    if "*" in value:
        raise RuntimeError(f"{name} must not contain wildcards in production")
    parts = urlsplit(value)
    if parts.scheme.casefold() != "https":
        raise RuntimeError(f"{name} must use HTTPS in production")
    if (
        not parts.netloc
        or parts.hostname is None
        or parts.username is not None
        or parts.password is not None
    ):
        raise RuntimeError(f"{name} contains an invalid production URL")
    if _is_local_hostname(parts.hostname):
        raise RuntimeError(f"{name} must not contain localhost in production")
    if origin_only and (parts.path or parts.query or parts.fragment):
        raise RuntimeError(f"{name} entries must be origins without a path, query, or fragment")


def _is_local_hostname(hostname: str | None) -> bool:
    if hostname is None:
        return False
    normalized = hostname.casefold().rstrip(".")
    if normalized == "localhost" or normalized.endswith(".localhost"):
        return True
    try:
        return ipaddress.ip_address(normalized).is_loopback
    except ValueError:
        return False


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings.from_env()
