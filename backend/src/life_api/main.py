from __future__ import annotations

import logging
from collections.abc import Awaitable, Callable
from typing import Annotated, Any, cast
from uuid import uuid4

from fastapi import Depends, FastAPI, Header, Path, Query, Request, Response, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, RedirectResponse
from pydantic import BaseModel

from .auth import IdentityProvider, build_identity_provider
from .engine import Engine, build_engine
from .errors import ApiError, error_payload, install_error_handlers
from .models import (
    ChallengeAcceptResponse,
    ChallengeDocument,
    ChallengeListResponse,
    ConfirmRequest,
    CreateMatchRequest,
    DiscoverabilityDocument,
    DiscoverabilityRequest,
    ExchangeRequest,
    ForgotPasswordRequest,
    ForgotPasswordResponse,
    FriendListResponse,
    FriendRequestDocument,
    FriendRequestListResponse,
    JoinMatchRequest,
    LoginRequest,
    LogoutRequest,
    MatchDocument,
    MatchListResponse,
    MessageResponse,
    MoveHistoryResponse,
    MoveRequest,
    OpponentIdRequest,
    PlayerIdRequest,
    PlayerSearchResponse,
    PlayerStatsDocument,
    PushNotificationConfig,
    PushSubscriptionDocument,
    PushSubscriptionListResponse,
    PushSubscriptionRequest,
    QuickMatchRequest,
    QuickMatchResponse,
    RefreshRequest,
    RegisterRequest,
    RegisterResponse,
    ReplayResponse,
    ResetPasswordRequest,
    ResignRequest,
    SocialSnapshot,
    TokenSet,
    User,
    UsernameRequest,
)
from .notifications import PushSubscriptionService
from .oauth import GoogleOAuthService
from .repository import Repository, build_repository
from .service import MatchService
from .settings import Settings, get_settings
from .social import SocialService

LOGGER = logging.getLogger("life_api")


class AppServices:
    def __init__(
        self,
        *,
        settings: Settings,
        repository: Repository,
        identity: IdentityProvider,
        engine: Engine,
    ) -> None:
        self.settings = settings
        self.repository = repository
        self.identity = identity
        self.engine = engine
        self.oauth = GoogleOAuthService(settings, identity, repository)
        self.matches = MatchService(repository, engine)
        self.social = SocialService(repository, engine)
        self.notifications = PushSubscriptionService(repository, settings)


def current_services(request: Request) -> AppServices:
    return cast(AppServices, request.app.state.services)


Services = Annotated[AppServices, Depends(current_services)]


def current_user(
    request: Request,
    services: Services,
    authorization: Annotated[str | None, Header()] = None,
) -> User:
    if authorization is None or not authorization.startswith("Bearer "):
        raise ApiError(
            "authenticationRequired",
            "Sign in to continue.",
            status_code=401,
        )
    token = authorization.removeprefix("Bearer ").strip()
    if not token:
        raise ApiError("invalidToken", "The access token is invalid.", status_code=401)
    user = services.identity.authenticate(token)
    if services.repository.account_state(user.id).value == "deleting" and not (
        request.method == "DELETE" and request.url.path == "/v1/me"
    ):
        raise ApiError("accountDeleting", "That account is being deleted.", status_code=409)
    return user


CurrentUser = Annotated[User, Depends(current_user)]
MatchId = Annotated[
    str,
    Path(
        min_length=36,
        max_length=36,
        pattern=r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-"
        r"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$",
    ),
]
PlayerId = Annotated[
    str,
    Path(min_length=1, max_length=128, pattern=r"^[A-Za-z0-9_.:-]+$"),
]
SocialId = Annotated[
    str,
    Path(
        min_length=36,
        max_length=36,
        pattern=r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-"
        r"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$",
    ),
]


class HealthResponse(BaseModel):
    status: str
    environment: str
    engine: str


def create_app(
    *,
    settings: Settings | None = None,
    repository: Repository | None = None,
    identity: IdentityProvider | None = None,
    engine: Engine | None = None,
) -> FastAPI:
    resolved_settings = settings or get_settings()
    services = AppServices(
        settings=resolved_settings,
        repository=repository or build_repository(resolved_settings),
        identity=identity or build_identity_provider(resolved_settings),
        engine=engine or build_engine(resolved_settings),
    )
    app = FastAPI(
        title="The Game of Life API",
        version="1.0.0",
        docs_url=None if resolved_settings.is_production else "/docs",
        redoc_url=None,
        openapi_url=None if resolved_settings.is_production else "/openapi.json",
    )
    app.state.services = services
    app.add_middleware(
        CORSMiddleware,
        allow_origins=list(resolved_settings.cors_origins),
        allow_credentials=False,
        allow_methods=["GET", "POST", "PATCH", "DELETE", "OPTIONS"],
        allow_headers=[
            "Authorization",
            "Content-Type",
            "Idempotency-Key",
            "If-None-Match",
            "X-Request-Id",
        ],
        expose_headers=["ETag", "X-Request-Id"],
    )
    install_error_handlers(app)

    @app.exception_handler(Exception)
    async def unexpected_error_handler(request: Request, exc: Exception) -> JSONResponse:
        LOGGER.exception("Unhandled API error", exc_info=exc)
        return JSONResponse(
            status_code=500,
            content=error_payload(
                "internalError",
                "The server could not complete this request.",
                request_id=getattr(request.state, "request_id", None),
            ),
        )

    @app.middleware("http")
    async def request_context(
        request: Request,
        call_next: Callable[[Request], Awaitable[Response]],
    ) -> Response:
        supplied = request.headers.get("x-request-id", "")
        request.state.request_id = supplied[:128] if supplied else str(uuid4())
        response = await call_next(request)
        response.headers["X-Request-Id"] = request.state.request_id
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["Referrer-Policy"] = "no-referrer"
        response.headers["Cache-Control"] = "no-store"
        return response

    @app.get("/v1/health", response_model=HealthResponse, tags=["system"])
    def health(services: Services) -> HealthResponse:
        return HealthResponse(
            status="ok",
            environment=services.settings.app_env,
            engine=type(services.engine).__name__,
        )

    @app.post(
        "/v1/auth/register",
        response_model=RegisterResponse,
        status_code=status.HTTP_201_CREATED,
        tags=["authentication"],
    )
    def register(request: RegisterRequest, services: Services) -> RegisterResponse:
        return services.identity.register(request)

    @app.post(
        "/v1/auth/confirm",
        response_model=MessageResponse,
        tags=["authentication"],
    )
    def confirm(request: ConfirmRequest, services: Services) -> MessageResponse:
        services.identity.confirm(request.username, request.code)
        return MessageResponse(message="Account confirmed.")

    @app.post(
        "/v1/auth/resend",
        response_model=ForgotPasswordResponse,
        tags=["authentication"],
    )
    def resend(request: UsernameRequest, services: Services) -> ForgotPasswordResponse:
        code = services.identity.resend(request.username)
        return ForgotPasswordResponse(debug_reset_code=code)

    @app.post(
        "/v1/auth/login",
        response_model=TokenSet,
        tags=["authentication"],
    )
    def login(request: LoginRequest, services: Services) -> TokenSet:
        tokens = services.identity.login(request.username, request.password)
        if services.repository.account_state(tokens.user.id).value == "active":
            services.social.index_user(tokens.user)
        return tokens

    @app.post(
        "/v1/auth/refresh",
        response_model=TokenSet,
        tags=["authentication"],
    )
    def refresh(request: RefreshRequest, services: Services) -> TokenSet:
        tokens = services.identity.refresh(request.refresh_token)
        if services.repository.account_state(tokens.user.id).value == "active":
            services.social.index_user(tokens.user)
        return tokens

    @app.post(
        "/v1/auth/forgot",
        response_model=ForgotPasswordResponse,
        tags=["authentication"],
    )
    def forgot_password(
        request: ForgotPasswordRequest,
        services: Services,
    ) -> ForgotPasswordResponse:
        code = services.identity.forgot_password(request.username)
        return ForgotPasswordResponse(debug_reset_code=code)

    @app.post(
        "/v1/auth/reset",
        response_model=MessageResponse,
        tags=["authentication"],
    )
    def reset_password(
        request: ResetPasswordRequest,
        services: Services,
    ) -> MessageResponse:
        services.identity.reset_password(
            request.username,
            request.code,
            request.new_password,
        )
        return MessageResponse(message="Password reset.")

    @app.post(
        "/v1/auth/logout",
        response_model=MessageResponse,
        tags=["authentication"],
    )
    def logout(
        request: LogoutRequest,
        user: CurrentUser,
        services: Services,
        authorization: Annotated[str, Header()],
    ) -> MessageResponse:
        del request, user
        services.identity.logout(authorization.removeprefix("Bearer ").strip())
        return MessageResponse(message="Signed out.")

    @app.get("/v1/auth/google/start", tags=["authentication"])
    def google_start(
        services: Services,
        return_to: Annotated[str, Query(alias="returnTo")],
    ) -> RedirectResponse:
        return RedirectResponse(services.oauth.start_url(return_to), status_code=302)

    @app.get("/v1/auth/google/callback", tags=["authentication"])
    def google_callback(
        services: Services,
        code: str,
        state: str,
    ) -> RedirectResponse:
        return RedirectResponse(services.oauth.complete(code, state), status_code=302)

    @app.post(
        "/v1/auth/exchange",
        response_model=TokenSet,
        tags=["authentication"],
    )
    def google_exchange(request: ExchangeRequest, services: Services) -> TokenSet:
        tokens = services.oauth.exchange(request.code)
        if services.repository.account_state(tokens.user.id).value == "active":
            services.social.index_user(tokens.user)
        return tokens

    @app.get("/v1/me", response_model=User, tags=["profile"])
    def me(user: CurrentUser, services: Services) -> User:
        services.social.index_user(user)
        return user

    @app.get("/v1/stats/me", response_model=PlayerStatsDocument, tags=["social"])
    def my_stats(user: CurrentUser, services: Services) -> PlayerStatsDocument:
        return services.social.stats(user)

    @app.get("/v1/players/search", response_model=PlayerSearchResponse, tags=["social"])
    def search_players(
        q: Annotated[str, Query(min_length=3, max_length=48)],
        user: CurrentUser,
        services: Services,
    ) -> PlayerSearchResponse:
        return services.social.search(user, q)

    @app.get("/v1/social", response_model=SocialSnapshot, tags=["social"])
    def social_snapshot(user: CurrentUser, services: Services) -> SocialSnapshot:
        return services.social.snapshot(user)

    @app.patch(
        "/v1/social/discoverability",
        response_model=DiscoverabilityDocument,
        tags=["social"],
    )
    def set_discoverability(
        request: DiscoverabilityRequest,
        user: CurrentUser,
        services: Services,
    ) -> DiscoverabilityDocument:
        return services.social.set_discoverability(user, request.discoverable)

    @app.get("/v1/friends", response_model=FriendListResponse, tags=["social"])
    def friends(user: CurrentUser, services: Services) -> FriendListResponse:
        return services.social.friends(user)

    @app.delete(
        "/v1/friends/{player_id}",
        status_code=status.HTTP_204_NO_CONTENT,
        tags=["social"],
    )
    def unfriend(player_id: PlayerId, user: CurrentUser, services: Services) -> Response:
        services.social.unfriend(user, player_id)
        return Response(status_code=status.HTTP_204_NO_CONTENT)

    @app.get(
        "/v1/friends/requests",
        response_model=FriendRequestListResponse,
        tags=["social"],
    )
    def friend_requests(user: CurrentUser, services: Services) -> FriendRequestListResponse:
        return services.social.friend_requests(user)

    @app.post(
        "/v1/friends/requests",
        response_model=FriendRequestDocument,
        status_code=status.HTTP_201_CREATED,
        tags=["social"],
    )
    def send_friend_request(
        request: PlayerIdRequest,
        user: CurrentUser,
        services: Services,
    ) -> FriendRequestDocument:
        return services.social.send_friend_request(user, request.player_id)

    @app.post(
        "/v1/friends/requests/{request_id}/accept",
        status_code=status.HTTP_204_NO_CONTENT,
        tags=["social"],
    )
    def accept_friend_request(
        request_id: SocialId,
        user: CurrentUser,
        services: Services,
    ) -> Response:
        services.social.accept_friend_request(user, request_id)
        return Response(status_code=status.HTTP_204_NO_CONTENT)

    @app.delete(
        "/v1/friends/requests/{request_id}",
        status_code=status.HTTP_204_NO_CONTENT,
        tags=["social"],
    )
    def delete_friend_request(
        request_id: SocialId,
        user: CurrentUser,
        services: Services,
    ) -> Response:
        services.social.delete_friend_request(user, request_id)
        return Response(status_code=status.HTTP_204_NO_CONTENT)

    @app.get("/v1/challenges", response_model=ChallengeListResponse, tags=["social"])
    def challenges(user: CurrentUser, services: Services) -> ChallengeListResponse:
        return services.social.challenges(user)

    @app.post(
        "/v1/challenges",
        response_model=ChallengeDocument,
        status_code=status.HTTP_201_CREATED,
        tags=["social"],
    )
    def create_challenge(
        request: OpponentIdRequest,
        user: CurrentUser,
        services: Services,
    ) -> ChallengeDocument:
        return services.social.create_challenge(user, request.opponent_id)

    @app.post(
        "/v1/challenges/{challenge_id}/accept",
        response_model=ChallengeAcceptResponse,
        tags=["social"],
    )
    def accept_challenge(
        challenge_id: SocialId,
        user: CurrentUser,
        services: Services,
    ) -> ChallengeAcceptResponse:
        return services.social.accept_challenge(user, challenge_id)

    @app.delete(
        "/v1/challenges/{challenge_id}",
        status_code=status.HTTP_204_NO_CONTENT,
        tags=["social"],
    )
    def delete_challenge(
        challenge_id: SocialId,
        user: CurrentUser,
        services: Services,
    ) -> Response:
        services.social.delete_challenge(user, challenge_id)
        return Response(status_code=status.HTTP_204_NO_CONTENT)

    @app.delete("/v1/me", status_code=status.HTTP_204_NO_CONTENT, tags=["profile"])
    def delete_me(
        user: CurrentUser,
        services: Services,
        authorization: Annotated[str, Header()],
    ) -> Response:
        services.matches.delete_account_data(user)
        services.identity.delete_account(authorization.removeprefix("Bearer ").strip())
        return Response(status_code=status.HTTP_204_NO_CONTENT)

    @app.get(
        "/v1/notifications/config",
        response_model=PushNotificationConfig,
        tags=["notifications"],
    )
    def notification_config(services: Services) -> PushNotificationConfig:
        return services.notifications.config()

    @app.post(
        "/v1/notifications/subscriptions",
        response_model=PushSubscriptionDocument,
        tags=["notifications"],
    )
    def register_push_subscription(
        request: PushSubscriptionRequest,
        user: CurrentUser,
        services: Services,
    ) -> PushSubscriptionDocument:
        return services.notifications.register(user, request)

    @app.get(
        "/v1/notifications/subscriptions",
        response_model=PushSubscriptionListResponse,
        tags=["notifications"],
    )
    def list_push_subscriptions(
        user: CurrentUser,
        services: Services,
    ) -> PushSubscriptionListResponse:
        return PushSubscriptionListResponse(items=services.notifications.list(user))

    @app.delete(
        "/v1/notifications/subscriptions/{installation_id}",
        status_code=status.HTTP_204_NO_CONTENT,
        tags=["notifications"],
    )
    def delete_push_subscription(
        installation_id: Annotated[
            str,
            Path(
                min_length=16,
                max_length=128,
                pattern=r"^[A-Za-z0-9_.-]+$",
            ),
        ],
        user: CurrentUser,
        services: Services,
    ) -> Response:
        services.notifications.delete(user, installation_id)
        return Response(status_code=status.HTTP_204_NO_CONTENT)

    @app.post(
        "/v1/matches",
        response_model=MatchDocument,
        status_code=status.HTTP_201_CREATED,
        tags=["matches"],
    )
    def create_match(
        request: CreateMatchRequest,
        response: Response,
        user: CurrentUser,
        services: Services,
    ) -> MatchDocument:
        document = services.matches.create(user, request)
        response.headers["ETag"] = _etag(document)
        return document

    @app.post(
        "/v1/matches/join",
        response_model=MatchDocument,
        tags=["matches"],
    )
    def join_match(
        request: JoinMatchRequest,
        response: Response,
        user: CurrentUser,
        services: Services,
    ) -> MatchDocument:
        document = services.matches.join(user, request.join_code)
        response.headers["ETag"] = _etag(document)
        return document

    @app.get("/v1/matches", response_model=MatchListResponse, tags=["matches"])
    def list_matches(user: CurrentUser, services: Services) -> MatchListResponse:
        return MatchListResponse(items=services.matches.list_matches(user))

    @app.get("/v1/matches/{match_id}", response_model=MatchDocument, tags=["matches"])
    def get_match(
        match_id: MatchId,
        user: CurrentUser,
        services: Services,
        if_none_match: Annotated[str | None, Header(alias="If-None-Match")] = None,
    ) -> Response:
        document = services.matches.get(user, match_id)
        etag = _etag(document)
        if if_none_match == etag:
            return Response(status_code=304, headers={"ETag": etag})
        return JSONResponse(
            content=_json(document),
            headers={"ETag": etag},
        )

    @app.delete(
        "/v1/matches/{match_id}",
        response_model=MessageResponse,
        tags=["matches"],
    )
    def cancel_waiting_match(
        match_id: MatchId,
        user: CurrentUser,
        services: Services,
    ) -> MessageResponse:
        services.matches.cancel_waiting(user, match_id)
        return MessageResponse(message="Waiting match cancelled.")

    @app.post(
        "/v1/matches/{match_id}/moves",
        response_model=MatchDocument,
        tags=["matches"],
    )
    def submit_move(
        match_id: MatchId,
        request: MoveRequest,
        response: Response,
        user: CurrentUser,
        services: Services,
    ) -> MatchDocument:
        document = services.matches.move(user, match_id, request)
        response.headers["ETag"] = _etag(document)
        return document

    @app.post(
        "/v1/matches/{match_id}/resign",
        response_model=MatchDocument,
        tags=["matches"],
    )
    def resign(
        match_id: MatchId,
        request: ResignRequest,
        response: Response,
        user: CurrentUser,
        services: Services,
    ) -> MatchDocument:
        document = services.matches.resign(user, match_id, request)
        response.headers["ETag"] = _etag(document)
        return document

    @app.get(
        "/v1/matches/{match_id}/moves",
        response_model=MoveHistoryResponse,
        tags=["matches"],
    )
    def move_history(
        match_id: MatchId,
        user: CurrentUser,
        services: Services,
    ) -> MoveHistoryResponse:
        return MoveHistoryResponse(items=services.matches.history(user, match_id))

    @app.get(
        "/v1/matches/{match_id}/replay",
        response_model=ReplayResponse,
        tags=["matches"],
    )
    def replay(match_id: MatchId, user: CurrentUser, services: Services) -> ReplayResponse:
        return services.matches.replay(user, match_id)

    @app.post(
        "/v1/matchmaking",
        response_model=QuickMatchResponse,
        tags=["matchmaking"],
    )
    def quick_match(
        request: QuickMatchRequest,
        user: CurrentUser,
        services: Services,
    ) -> QuickMatchResponse:
        return services.matches.quick_match(user, request)

    @app.get(
        "/v1/matchmaking",
        response_model=QuickMatchResponse,
        tags=["matchmaking"],
    )
    def quick_status(
        ticket_id: Annotated[
            str,
            Query(
                alias="ticketId",
                min_length=16,
                max_length=64,
                pattern=r"^[A-Za-z0-9_-]+$",
            ),
        ],
        user: CurrentUser,
        services: Services,
    ) -> QuickMatchResponse:
        return services.matches.quick_status(user, ticket_id)

    @app.delete(
        "/v1/matchmaking",
        response_model=MessageResponse,
        tags=["matchmaking"],
    )
    def cancel_quick_match(
        ticket_id: Annotated[
            str,
            Query(
                alias="ticketId",
                min_length=16,
                max_length=64,
                pattern=r"^[A-Za-z0-9_-]+$",
            ),
        ],
        user: CurrentUser,
        services: Services,
    ) -> MessageResponse:
        services.matches.cancel_quick_match(user, ticket_id)
        return MessageResponse(message="Matchmaking cancelled.")

    return app


def _json(model: BaseModel) -> Any:
    return model.model_dump(mode="json", by_alias=True)


def _etag(document: MatchDocument) -> str:
    return f'"{document.version}"'


app = create_app()
