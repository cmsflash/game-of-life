from __future__ import annotations

import os
from dataclasses import dataclass
from functools import lru_cache


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
        )
        settings.validate()
        return settings

    def validate(self) -> None:
        allowed_environments = {"local", "test", "production"}
        if self.app_env not in allowed_environments:
            raise RuntimeError(f"APP_ENV must be one of: {', '.join(sorted(allowed_environments))}")
        if self.is_production:
            required = {
                "COGNITO_USER_POOL_ID": self.cognito_user_pool_id,
                "COGNITO_CLIENT_ID": self.cognito_client_id,
                "COGNITO_HOSTED_UI_BASE": self.cognito_hosted_ui_base,
                "COGNITO_OAUTH_CALLBACK_URL": self.cognito_oauth_callback_url,
            }
            missing = [name for name, value in required.items() if not value]
            if missing:
                raise RuntimeError(f"missing production settings: {', '.join(missing)}")
            if self.local_token_secret == "local-development-only-secret":
                raise RuntimeError("LOCAL_TOKEN_SECRET must be replaced in production")


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings.from_env()
