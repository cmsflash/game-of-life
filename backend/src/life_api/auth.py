from __future__ import annotations

import base64
import contextlib
import hashlib
import hmac
import secrets
import threading
import time
from dataclasses import dataclass
from typing import Any, Protocol, cast
from uuid import uuid4

import boto3
import jwt
from botocore.exceptions import ClientError

from .errors import ApiError
from .models import RegisterRequest, RegisterResponse, TokenSet, User
from .settings import Settings


class IdentityProvider(Protocol):
    def register(self, request: RegisterRequest) -> RegisterResponse: ...

    def confirm(self, username: str, code: str) -> None: ...

    def resend(self, username: str) -> str | None: ...

    def login(self, username: str, password: str) -> TokenSet: ...

    def refresh(self, refresh_token: str) -> TokenSet: ...

    def forgot_password(self, username: str) -> str | None: ...

    def reset_password(self, username: str, code: str, new_password: str) -> None: ...

    def logout(self, access_token: str) -> None: ...

    def authenticate(self, access_token: str) -> User: ...

    def delete_account(self, access_token: str) -> None: ...

    def development_google_login(self) -> TokenSet: ...


@dataclass(slots=True)
class _LocalAccount:
    user: User
    password_salt: bytes
    password_hash: bytes
    confirmation_code: str
    reset_code: str | None = None


class LocalIdentityProvider:
    """A process-local provider used only when APP_ENV is not production."""

    def __init__(self, secret: str) -> None:
        self._secret = secret
        self._accounts: dict[str, _LocalAccount] = {}
        self._accounts_by_id: dict[str, _LocalAccount] = {}
        self._lock = threading.RLock()

    @staticmethod
    def _password_hash(password: str, salt: bytes) -> bytes:
        return hashlib.scrypt(password.encode(), salt=salt, n=2**14, r=8, p=1, dklen=32)

    def register(self, request: RegisterRequest) -> RegisterResponse:
        key = request.username.casefold()
        with self._lock:
            if key in self._accounts:
                raise ApiError(
                    "usernameExists", "That username is already registered.", status_code=409
                )
            if any(
                account.user.email.casefold() == request.email.casefold()
                for account in self._accounts.values()
            ):
                raise ApiError("emailExists", "That email is already registered.", status_code=409)
            salt = secrets.token_bytes(16)
            code = f"{secrets.randbelow(1_000_000):06d}"
            user = User(
                id=str(uuid4()),
                username=request.username,
                email=str(request.email),
                display_name=request.display_name,
                email_verified=False,
            )
            account = _LocalAccount(
                user=user,
                password_salt=salt,
                password_hash=self._password_hash(request.password, salt),
                confirmation_code=code,
            )
            self._accounts[key] = account
            self._accounts_by_id[user.id] = account
        return RegisterResponse(
            user_id=user.id,
            username=user.username,
            confirmation_required=True,
            debug_confirmation_code=code,
        )

    def confirm(self, username: str, code: str) -> None:
        account = self._account(username)
        if not hmac.compare_digest(account.confirmation_code, code):
            raise ApiError("invalidConfirmationCode", "The confirmation code is invalid.")
        account.user = account.user.model_copy(update={"email_verified": True})

    def resend(self, username: str) -> str | None:
        account = self._account(username)
        if account.user.email_verified:
            return None
        account.confirmation_code = f"{secrets.randbelow(1_000_000):06d}"
        return account.confirmation_code

    def login(self, username: str, password: str) -> TokenSet:
        account = self._account(username, hide_missing=True)
        actual = self._password_hash(password, account.password_salt)
        if not hmac.compare_digest(actual, account.password_hash):
            raise ApiError(
                "invalidCredentials", "The username or password is incorrect.", status_code=401
            )
        if not account.user.email_verified:
            raise ApiError(
                "confirmationRequired", "Confirm your email before signing in.", status_code=403
            )
        return self._issue_tokens(account.user)

    def refresh(self, refresh_token: str) -> TokenSet:
        payload = self._decode(refresh_token, expected_kind="refresh")
        account = self._accounts_by_id.get(str(payload["sub"]))
        if account is None:
            raise ApiError("invalidRefreshToken", "The refresh token is invalid.", status_code=401)
        return self._issue_tokens(account.user)

    def forgot_password(self, username: str) -> str | None:
        account = self._accounts.get(username.casefold())
        if account is None:
            return None
        account.reset_code = f"{secrets.randbelow(1_000_000):06d}"
        return account.reset_code

    def reset_password(self, username: str, code: str, new_password: str) -> None:
        account = self._account(username)
        if account.reset_code is None or not hmac.compare_digest(account.reset_code, code):
            raise ApiError("invalidResetCode", "The password reset code is invalid.")
        salt = secrets.token_bytes(16)
        account.password_salt = salt
        account.password_hash = self._password_hash(new_password, salt)
        account.reset_code = None

    def logout(self, access_token: str) -> None:
        self._decode(access_token, expected_kind="access")

    def authenticate(self, access_token: str) -> User:
        payload = self._decode(access_token, expected_kind="access")
        account = self._accounts_by_id.get(str(payload["sub"]))
        if account is None:
            raise ApiError("invalidToken", "The access token is invalid.", status_code=401)
        return account.user

    def delete_account(self, access_token: str) -> None:
        payload = self._decode(access_token, expected_kind="access")
        user_id = str(payload["sub"])
        with self._lock:
            account = self._accounts_by_id.pop(user_id, None)
            if account is None:
                raise ApiError("invalidToken", "The access token is invalid.", status_code=401)
            self._accounts.pop(account.user.username.casefold(), None)

    def development_google_login(self) -> TokenSet:
        username = "google.dev"
        with self._lock:
            account = self._accounts.get(username)
            if account is None:
                salt = secrets.token_bytes(16)
                user = User(
                    id=str(uuid4()),
                    username=username,
                    email="google.dev@example.test",
                    display_name="Google Dev Player",
                    email_verified=True,
                )
                account = _LocalAccount(
                    user=user,
                    password_salt=salt,
                    password_hash=self._password_hash(secrets.token_urlsafe(32), salt),
                    confirmation_code="000000",
                )
                self._accounts[username] = account
                self._accounts_by_id[user.id] = account
        return self._issue_tokens(account.user)

    def _account(self, username: str, *, hide_missing: bool = False) -> _LocalAccount:
        account = self._accounts.get(username.casefold())
        if account is None:
            if hide_missing:
                raise ApiError(
                    "invalidCredentials", "The username or password is incorrect.", status_code=401
                )
            raise ApiError("userNotFound", "The account was not found.", status_code=404)
        return account

    def _issue_tokens(self, user: User) -> TokenSet:
        now = int(time.time())
        common = {
            "sub": user.id,
            "username": user.username,
            "email": user.email,
            "name": user.display_name,
            "iat": now,
        }
        access = jwt.encode(
            {**common, "kind": "access", "exp": now + 3600}, self._secret, algorithm="HS256"
        )
        identity = jwt.encode(
            {**common, "kind": "id", "exp": now + 3600}, self._secret, algorithm="HS256"
        )
        refresh = jwt.encode(
            {**common, "kind": "refresh", "exp": now + 30 * 86400}, self._secret, algorithm="HS256"
        )
        return TokenSet(
            access_token=access,
            id_token=identity,
            refresh_token=refresh,
            expires_in=3600,
            token_type="Bearer",
            user=user,
        )

    def _decode(self, token: str, *, expected_kind: str) -> dict[str, Any]:
        try:
            payload = jwt.decode(token, self._secret, algorithms=["HS256"])
        except jwt.PyJWTError as error:
            raise ApiError(
                "invalidToken", "The token is invalid or expired.", status_code=401
            ) from error
        if payload.get("kind") != expected_kind:
            raise ApiError("invalidToken", "The token has the wrong purpose.", status_code=401)
        return payload


class CognitoIdentityProvider:
    def __init__(self, settings: Settings) -> None:
        assert settings.cognito_client_id
        self._client_id = settings.cognito_client_id
        self._client_secret = settings.cognito_client_secret
        self._client = boto3.client("cognito-idp", region_name=settings.aws_region)

    def _secret_hash(self, username: str) -> str | None:
        if self._client_secret is None:
            return None
        digest = hmac.new(
            self._client_secret.encode(),
            f"{username}{self._client_id}".encode(),
            hashlib.sha256,
        ).digest()
        return base64.b64encode(digest).decode()

    def _with_secret_hash(self, username: str, values: dict[str, Any]) -> dict[str, Any]:
        secret_hash = self._secret_hash(username)
        if secret_hash is not None:
            values["SecretHash"] = secret_hash
        return values

    def register(self, request: RegisterRequest) -> RegisterResponse:
        try:
            response = self._client.sign_up(
                **self._with_secret_hash(
                    request.username,
                    {
                        "ClientId": self._client_id,
                        "Username": request.username,
                        "Password": request.password,
                        "UserAttributes": [
                            {"Name": "email", "Value": str(request.email)},
                            {"Name": "name", "Value": request.display_name},
                        ],
                    },
                )
            )
        except ClientError as error:
            raise _cognito_error(error) from error
        return RegisterResponse(
            user_id=response["UserSub"],
            username=request.username,
            confirmation_required=not bool(response.get("UserConfirmed")),
        )

    def confirm(self, username: str, code: str) -> None:
        self._call(
            "confirm_sign_up",
            **self._with_secret_hash(
                username,
                {
                    "ClientId": self._client_id,
                    "Username": username,
                    "ConfirmationCode": code,
                },
            ),
        )

    def resend(self, username: str) -> str | None:
        self._call(
            "resend_confirmation_code",
            **self._with_secret_hash(
                username,
                {"ClientId": self._client_id, "Username": username},
            ),
        )
        return None

    def login(self, username: str, password: str) -> TokenSet:
        parameters = {"USERNAME": username, "PASSWORD": password}
        secret_hash = self._secret_hash(username)
        if secret_hash is not None:
            parameters["SECRET_HASH"] = secret_hash
        response = self._call(
            "initiate_auth",
            ClientId=self._client_id,
            AuthFlow="USER_PASSWORD_AUTH",
            AuthParameters=parameters,
        )
        result = response.get("AuthenticationResult")
        if not result:
            raise ApiError(
                "authenticationChallenge",
                "An unsupported authentication challenge was returned.",
                status_code=409,
            )
        return self._token_set(result)

    def refresh(self, refresh_token: str) -> TokenSet:
        parameters = {"REFRESH_TOKEN": refresh_token}
        if self._client_secret is not None:
            raise ApiError(
                "serverConfigurationError",
                "Refresh requires a public Cognito app client.",
                status_code=503,
            )
        response = self._call(
            "initiate_auth",
            ClientId=self._client_id,
            AuthFlow="REFRESH_TOKEN_AUTH",
            AuthParameters=parameters,
        )
        result = response.get("AuthenticationResult")
        if not result:
            raise ApiError("invalidRefreshToken", "The refresh token is invalid.", status_code=401)
        result["RefreshToken"] = refresh_token
        return self._token_set(result)

    def forgot_password(self, username: str) -> str | None:
        with contextlib.suppress(self._client.exceptions.UserNotFoundException):
            self._client.forgot_password(
                **self._with_secret_hash(
                    username,
                    {"ClientId": self._client_id, "Username": username},
                )
            )
        return None

    def reset_password(self, username: str, code: str, new_password: str) -> None:
        self._call(
            "confirm_forgot_password",
            **self._with_secret_hash(
                username,
                {
                    "ClientId": self._client_id,
                    "Username": username,
                    "ConfirmationCode": code,
                    "Password": new_password,
                },
            ),
        )

    def logout(self, access_token: str) -> None:
        self._call("global_sign_out", AccessToken=access_token)

    def authenticate(self, access_token: str) -> User:
        response = self._call("get_user", AccessToken=access_token)
        attributes = {item["Name"]: item["Value"] for item in response["UserAttributes"]}
        return User(
            id=attributes["sub"],
            username=response["Username"],
            email=attributes.get("email", ""),
            display_name=attributes.get("name") or response["Username"],
            email_verified=attributes.get("email_verified") == "true",
        )

    def delete_account(self, access_token: str) -> None:
        self._call("delete_user", AccessToken=access_token)

    def development_google_login(self) -> TokenSet:
        raise ApiError("notAvailable", "Development Google login is disabled.", status_code=404)

    def _token_set(self, result: dict[str, Any]) -> TokenSet:
        access_token = str(result["AccessToken"])
        return TokenSet(
            access_token=access_token,
            id_token=str(result["IdToken"]),
            refresh_token=result.get("RefreshToken"),
            expires_in=int(result.get("ExpiresIn", 3600)),
            token_type=str(result.get("TokenType", "Bearer")),
            user=self.authenticate(access_token),
        )

    def _call(self, method: str, **kwargs: Any) -> dict[str, Any]:
        try:
            return cast(dict[str, Any], getattr(self._client, method)(**kwargs))
        except ClientError as error:
            raise _cognito_error(error) from error


def _cognito_error(error: ClientError) -> ApiError:
    code = error.response.get("Error", {}).get("Code", "CognitoError")
    message = error.response.get("Error", {}).get("Message", "Authentication failed.")
    mapping: dict[str, tuple[str, int]] = {
        "UsernameExistsException": ("usernameExists", 409),
        "AliasExistsException": ("emailExists", 409),
        "UserNotFoundException": ("userNotFound", 404),
        "UserNotConfirmedException": ("confirmationRequired", 403),
        "NotAuthorizedException": ("invalidCredentials", 401),
        "CodeMismatchException": ("invalidConfirmationCode", 400),
        "ExpiredCodeException": ("expiredCode", 400),
        "InvalidPasswordException": ("invalidPassword", 400),
        "LimitExceededException": ("rateLimited", 429),
        "TooManyRequestsException": ("rateLimited", 429),
    }
    stable_code, status = mapping.get(code, ("authenticationError", 400))
    return ApiError(stable_code, message, status_code=status)


def build_identity_provider(settings: Settings) -> IdentityProvider:
    if settings.is_production:
        return CognitoIdentityProvider(settings)
    return LocalIdentityProvider(settings.local_token_secret)
