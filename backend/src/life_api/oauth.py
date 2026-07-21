from __future__ import annotations

import base64
import hashlib
import secrets
from datetime import UTC, datetime, timedelta
from typing import Any
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

import httpx
import jwt

from .auth import IdentityProvider
from .errors import ApiError
from .models import StoredExchange, StoredOAuthTransaction, TokenSet
from .repository import Repository
from .settings import Settings


class GoogleOAuthService:
    def __init__(
        self,
        settings: Settings,
        identity: IdentityProvider,
        repository: Repository,
    ) -> None:
        self._settings = settings
        self._identity = identity
        self._repository = repository

    def start_url(self, return_to: str) -> str:
        if not self._settings.google_login_enabled:
            raise ApiError(
                "googleLoginDisabled",
                "Google login is not configured for this deployment.",
                status_code=404,
            )
        self._validate_return_url(return_to)
        if not self._settings.is_production:
            tokens = self._identity.development_google_login()
            code = self._store_exchange(tokens)
            return _append_query(return_to, {"code": code})

        transaction_id = secrets.token_urlsafe(24)
        verifier = secrets.token_urlsafe(64)
        challenge = (
            base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest())
            .rstrip(b"=")
            .decode()
        )
        self._repository.put_oauth_transaction(
            StoredOAuthTransaction(
                id=transaction_id,
                verifier=verifier,
                return_to=return_to,
                expires_at=datetime.now(UTC) + timedelta(minutes=10),
            )
        )
        state = jwt.encode(
            {
                "transactionId": transaction_id,
                "nonce": secrets.token_urlsafe(18),
                "iat": datetime.now(UTC),
                "exp": datetime.now(UTC) + timedelta(minutes=10),
            },
            self._settings.oauth_state_secret,
            algorithm="HS256",
        )

        assert self._settings.cognito_hosted_ui_base
        assert self._settings.cognito_client_id
        assert self._settings.cognito_oauth_callback_url
        query = urlencode(
            {
                "identity_provider": "Google",
                "response_type": "code",
                "client_id": self._settings.cognito_client_id,
                "redirect_uri": self._settings.cognito_oauth_callback_url,
                "scope": "openid email profile aws.cognito.signin.user.admin",
                "state": state,
                "code_challenge": challenge,
                "code_challenge_method": "S256",
            }
        )
        return f"{self._settings.cognito_hosted_ui_base.rstrip('/')}/oauth2/authorize?{query}"

    def complete(self, code: str, state: str) -> str:
        if not self._settings.is_production:
            raise ApiError(
                "notAvailable", "The local flow completes during start.", status_code=404
            )
        payload = self._decode_state(state)
        transaction = self._repository.consume_oauth_transaction(
            str(payload.get("transactionId", ""))
        )
        if transaction is None:
            raise ApiError(
                "invalidOAuthState",
                "The login state is invalid, expired, or already used.",
            )
        return_to = transaction.return_to
        self._validate_return_url(return_to)
        tokens = self._exchange_cognito_code(code, transaction.verifier)
        exchange_code = self._store_exchange(tokens)
        return _append_query(return_to, {"code": exchange_code})

    def exchange(self, code: str) -> TokenSet:
        exchange = self._repository.consume_exchange(code)
        if exchange is None:
            raise ApiError(
                "invalidExchangeCode",
                "The Google login exchange code is invalid or expired.",
                status_code=400,
            )
        return exchange.tokens

    def _decode_state(self, state: str) -> dict[str, Any]:
        try:
            return jwt.decode(
                state,
                self._settings.oauth_state_secret,
                algorithms=["HS256"],
            )
        except jwt.PyJWTError as error:
            raise ApiError("invalidOAuthState", "The login state is invalid or expired.") from error

    def _exchange_cognito_code(self, code: str, verifier: str) -> TokenSet:
        assert self._settings.cognito_hosted_ui_base
        assert self._settings.cognito_client_id
        assert self._settings.cognito_oauth_callback_url
        data = {
            "grant_type": "authorization_code",
            "client_id": self._settings.cognito_client_id,
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": self._settings.cognito_oauth_callback_url,
        }
        auth = None
        if self._settings.cognito_client_secret:
            auth = (
                self._settings.cognito_client_id,
                self._settings.cognito_client_secret,
            )
        try:
            response = httpx.post(
                f"{self._settings.cognito_hosted_ui_base.rstrip('/')}/oauth2/token",
                data=data,
                auth=auth,
                headers={"content-type": "application/x-www-form-urlencoded"},
                timeout=15,
            )
            response.raise_for_status()
            value = response.json()
        except (httpx.HTTPError, ValueError) as error:
            raise ApiError(
                "googleLoginFailed",
                "Google login could not be completed.",
                status_code=401,
            ) from error
        user = self._identity.authenticate(str(value["access_token"]))
        return TokenSet(
            access_token=str(value["access_token"]),
            id_token=str(value["id_token"]),
            refresh_token=value.get("refresh_token"),
            expires_in=int(value.get("expires_in", 3600)),
            token_type=str(value.get("token_type", "Bearer")),
            user=user,
        )

    def _store_exchange(self, tokens: TokenSet) -> str:
        code = secrets.token_urlsafe(32)
        self._repository.put_exchange(
            StoredExchange(
                code=code,
                tokens=tokens,
                expires_at=datetime.now(UTC) + timedelta(minutes=3),
            )
        )
        return code

    def _validate_return_url(self, return_to: str) -> None:
        if return_to not in self._settings.allowed_return_urls:
            raise ApiError("invalidReturnUrl", "That login return URL is not allowed.")


def _append_query(url: str, values: dict[str, str]) -> str:
    parts = urlsplit(url)
    query = dict(parse_qsl(parts.query, keep_blank_values=True))
    query.update(values)
    return urlunsplit((parts.scheme, parts.netloc, parts.path, urlencode(query), parts.fragment))
