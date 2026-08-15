from __future__ import annotations

import base64
import binascii
from datetime import UTC, datetime
from enum import StrEnum
from typing import Annotated, Any, Literal
from urllib.parse import urlsplit

from cryptography.hazmat.primitives.asymmetric import ec
from pydantic import (
    AfterValidator,
    BaseModel,
    ConfigDict,
    EmailStr,
    Field,
    field_validator,
    model_validator,
)


def _normalize_utc(value: datetime) -> datetime:
    if value.tzinfo is None or value.utcoffset() is None:
        raise ValueError("datetime must include a timezone")
    return value.astimezone(UTC)


UtcDateTime = Annotated[datetime, AfterValidator(_normalize_utc)]


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)


class User(StrictModel):
    id: str
    username: str
    email: str
    display_name: str = Field(alias="displayName")
    email_verified: bool = Field(default=False, alias="emailVerified")
    avatar_url: str | None = Field(default=None, alias="avatarUrl")
    avatar_version: int = Field(default=0, ge=0, alias="avatarVersion")


class TokenSet(StrictModel):
    access_token: str = Field(alias="accessToken")
    id_token: str = Field(alias="idToken")
    refresh_token: str | None = Field(default=None, alias="refreshToken")
    expires_in: int = Field(alias="expiresIn")
    token_type: str = Field(default="Bearer", alias="tokenType")
    user: User


class RegisterRequest(StrictModel):
    username: str = Field(min_length=3, max_length=32, pattern=r"^[A-Za-z0-9_.-]+$")
    email: EmailStr
    password: str = Field(min_length=10, max_length=256)
    display_name: str = Field(min_length=1, max_length=48, alias="displayName")

    @field_validator("display_name")
    @classmethod
    def normalize_display_name(cls, value: str) -> str:
        normalized = " ".join(value.split())
        if not normalized:
            raise ValueError("displayName must contain a visible character")
        return normalized

    @field_validator("password")
    @classmethod
    def validate_password_complexity(cls, value: str) -> str:
        if not any(character.isalpha() for character in value) or not any(
            character.isdigit() for character in value
        ):
            raise ValueError("password must contain at least one letter and one number")
        return value


class RegisterResponse(StrictModel):
    user_id: str = Field(alias="userId")
    username: str
    confirmation_required: bool = Field(alias="confirmationRequired")
    debug_confirmation_code: str | None = Field(default=None, alias="debugConfirmationCode")


class ConfirmRequest(StrictModel):
    username: str
    code: str = Field(min_length=4, max_length=12)


class UsernameRequest(StrictModel):
    username: str


class LoginRequest(StrictModel):
    username: str
    password: str


class RefreshRequest(StrictModel):
    refresh_token: str = Field(alias="refreshToken")


class ForgotPasswordRequest(StrictModel):
    username: str


class ForgotPasswordResponse(StrictModel):
    accepted: bool = True
    debug_reset_code: str | None = Field(default=None, alias="debugResetCode")


class ResetPasswordRequest(StrictModel):
    username: str
    code: str
    new_password: str = Field(min_length=10, max_length=256, alias="newPassword")

    @field_validator("new_password")
    @classmethod
    def validate_password_complexity(cls, value: str) -> str:
        if not any(character.isalpha() for character in value) or not any(
            character.isdigit() for character in value
        ):
            raise ValueError("password must contain at least one letter and one number")
        return value


class LogoutRequest(StrictModel):
    access_token: str | None = Field(default=None, alias="accessToken")


class ExchangeRequest(StrictModel):
    code: str = Field(min_length=16, max_length=256)


class MessageResponse(StrictModel):
    message: str


class PushPlatform(StrEnum):
    web = "web"
    android = "android"
    ios = "ios"


class PushProviderName(StrEnum):
    web_push = "webPush"
    firebase = "firebase"


class WebPushSubscriptionRequest(StrictModel):
    installation_id: str = Field(
        alias="installationId",
        min_length=16,
        max_length=128,
        pattern=r"^[A-Za-z0-9_.-]+$",
    )
    platform: Literal[PushPlatform.web] = PushPlatform.web
    provider: Literal[PushProviderName.web_push] = PushProviderName.web_push
    endpoint: str = Field(min_length=16, max_length=2048, repr=False)
    p256dh: str = Field(min_length=40, max_length=256, repr=False)
    auth: str = Field(min_length=8, max_length=128, repr=False)
    locale: str | None = Field(default=None, min_length=2, max_length=32)
    time_zone: str | None = Field(default=None, alias="timeZone", min_length=1, max_length=64)

    @field_validator("endpoint")
    @classmethod
    def validate_endpoint(cls, value: str) -> str:
        parts = urlsplit(value)
        if (
            parts.scheme.casefold() != "https"
            or not parts.netloc
            or parts.hostname is None
            or parts.username is not None
            or parts.password is not None
            or parts.fragment
        ):
            raise ValueError("endpoint must be an HTTPS push-service URL")
        return value

    @field_validator("p256dh")
    @classmethod
    def validate_p256dh(cls, value: str) -> str:
        decoded = _decode_urlsafe_base64(value, "p256dh")
        if len(decoded) != 65 or decoded[0] != 4:
            raise ValueError("p256dh must be an uncompressed P-256 public key")
        try:
            ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), decoded)
        except ValueError as error:
            raise ValueError("p256dh must contain a valid P-256 point") from error
        return value

    @field_validator("auth")
    @classmethod
    def validate_auth_secret(cls, value: str) -> str:
        if len(_decode_urlsafe_base64(value, "auth")) != 16:
            raise ValueError("auth must decode to 16 bytes")
        return value


class FirebasePushSubscriptionRequest(StrictModel):
    installation_id: str = Field(
        alias="installationId",
        min_length=16,
        max_length=128,
        pattern=r"^[A-Za-z0-9_.-]+$",
    )
    platform: Literal[PushPlatform.android, PushPlatform.ios]
    provider: Literal[PushProviderName.firebase] = PushProviderName.firebase
    token: str = Field(min_length=20, max_length=4096, repr=False)
    locale: str | None = Field(default=None, min_length=2, max_length=32)
    time_zone: str | None = Field(default=None, alias="timeZone", min_length=1, max_length=64)


PushSubscriptionRequest = Annotated[
    WebPushSubscriptionRequest | FirebasePushSubscriptionRequest,
    Field(discriminator="provider"),
]


class PushSubscriptionDocument(StrictModel):
    installation_id: str = Field(alias="installationId")
    platform: PushPlatform
    provider: PushProviderName
    locale: str | None = None
    time_zone: str | None = Field(default=None, alias="timeZone")
    created_at: UtcDateTime = Field(alias="createdAt")
    updated_at: UtcDateTime = Field(alias="updatedAt")


class PushSubscriptionListResponse(StrictModel):
    items: list[PushSubscriptionDocument]


class PushNotificationConfig(StrictModel):
    providers: list[PushProviderName]
    web_push_vapid_public_key: str | None = Field(
        default=None,
        alias="webPushVapidPublicKey",
    )


class VictoryMode(StrEnum):
    elimination = "elimination"
    turn_limit_population = "turnLimitPopulation"
    population_target = "populationTarget"


class MatchRulesRequest(StrictModel):
    mode: VictoryMode = VictoryMode.elimination
    max_plies: int | None = Field(default=None, alias="maxPlies")
    target: int | None = None

    @model_validator(mode="after")
    def validate_mode_options(self) -> MatchRulesRequest:
        if self.mode == VictoryMode.turn_limit_population:
            if self.max_plies is None or self.max_plies <= 0 or self.max_plies % 2:
                raise ValueError("maxPlies must be a positive even integer")
        elif self.max_plies is not None:
            raise ValueError("maxPlies is only valid for turnLimitPopulation")
        if self.mode == VictoryMode.population_target:
            if self.target is None or not 3 <= self.target <= 400:
                raise ValueError("target must be between 3 and 400")
        elif self.target is not None:
            raise ValueError("target is only valid for populationTarget")
        return self

    def engine_rules(self) -> dict[str, Any]:
        victory: dict[str, Any] = {"mode": self.mode.value}
        if self.max_plies is not None:
            victory["maxPlies"] = self.max_plies
        if self.target is not None:
            victory["target"] = self.target
        return {
            "schemaVersion": 1,
            "rulesetId": "life-duel",
            "rulesVersion": 3,
            "board": {"rows": 20, "columns": 20, "boundary": "finiteDead"},
            "neighborhood": "moore8",
            "evolution": {
                "birth": [3],
                "survival": [2, 3],
                "birthOwner": "strictNeighborMajority",
            },
            "turn": {
                "placement": "emptyOnly",
                "passAllowed": False,
                "firstPlayer": "black",
                "evolveAfterPlacement": True,
            },
            "initialPosition": "centered2x2Diagonal",
            "victory": victory,
            "noLegalMove": "draw",
        }


class CreateMatchRequest(StrictModel):
    rules: MatchRulesRequest = Field(default_factory=MatchRulesRequest)


class JoinMatchRequest(StrictModel):
    join_code: str = Field(alias="joinCode", min_length=6, max_length=8)

    @field_validator("join_code")
    @classmethod
    def normalize_code(cls, value: str) -> str:
        return value.replace("-", "").strip().upper()


class QuickMatchRequest(StrictModel):
    ticket_id: str = Field(
        alias="ticketId",
        min_length=16,
        max_length=64,
        pattern=r"^[A-Za-z0-9_-]+$",
    )
    rules: MatchRulesRequest = Field(default_factory=MatchRulesRequest)


class MoveRequest(StrictModel):
    row: int = Field(ge=0, le=19)
    column: int = Field(ge=0, le=19)
    expected_revision: int = Field(alias="expectedRevision", ge=0)
    idempotency_key: str = Field(alias="idempotencyKey", min_length=8, max_length=128)


class ResignRequest(StrictModel):
    expected_revision: int = Field(alias="expectedRevision", ge=0)
    idempotency_key: str = Field(alias="idempotencyKey", min_length=8, max_length=128)


class PlayerSummary(StrictModel):
    id: str
    display_name: str = Field(alias="displayName")


class PublicPlayerDocument(PlayerSummary):
    rating: int
    avatar_url: str | None = Field(default=None, alias="avatarUrl")
    avatar_version: int = Field(default=0, ge=0, alias="avatarVersion")


class MatchPlayerDocument(PlayerSummary):
    avatar_url: str | None = Field(default=None, alias="avatarUrl")
    avatar_version: int = Field(default=0, ge=0, alias="avatarVersion")


class PlayerSearchResponse(StrictModel):
    items: list[PublicPlayerDocument]


class PlayerIdRequest(StrictModel):
    player_id: str = Field(
        alias="playerId",
        min_length=1,
        max_length=128,
        pattern=r"^[A-Za-z0-9_.:-]+$",
    )


class OpponentIdRequest(StrictModel):
    opponent_id: str = Field(
        alias="opponentId",
        min_length=1,
        max_length=128,
        pattern=r"^[A-Za-z0-9_.:-]+$",
    )


class FriendRequestDocument(StrictModel):
    id: str
    player: PublicPlayerDocument
    created_at: UtcDateTime = Field(alias="createdAt")


class FriendListResponse(StrictModel):
    items: list[PublicPlayerDocument]


class FriendRequestListResponse(StrictModel):
    incoming: list[FriendRequestDocument]
    outgoing: list[FriendRequestDocument]


class ChallengeDocument(StrictModel):
    id: str
    challenger: PublicPlayerDocument
    opponent: PublicPlayerDocument
    created_at: UtcDateTime = Field(alias="createdAt")
    expires_at: UtcDateTime = Field(alias="expiresAt")


class ChallengeListResponse(StrictModel):
    incoming: list[ChallengeDocument]
    outgoing: list[ChallengeDocument]


class ChallengeAcceptResponse(StrictModel):
    match_id: str = Field(alias="matchId")


class DiscoverabilityRequest(StrictModel):
    discoverable: bool


class DiscoverabilityDocument(StrictModel):
    discoverable: bool
    version: int = Field(ge=0)


class AvatarDocument(StrictModel):
    avatar_url: str | None = Field(default=None, alias="avatarUrl")
    avatar_version: int = Field(ge=0, alias="avatarVersion")


class StoredChallenge(StrictModel):
    id: str
    challenger: PlayerSummary
    opponent: PlayerSummary
    created_at: UtcDateTime = Field(
        default_factory=lambda: datetime.now(UTC),
        alias="createdAt",
    )
    expires_at: UtcDateTime = Field(alias="expiresAt")


class PlayerStatsDocument(StrictModel):
    rating: int
    games: int = Field(ge=0)
    wins: int = Field(ge=0)
    losses: int = Field(ge=0)
    draws: int = Field(ge=0)
    kills: int = Field(ge=0)


class SocialSnapshot(StrictModel):
    version: int = Field(ge=0)
    discoverable: bool = True
    friends: list[PublicPlayerDocument]
    incoming_friend_requests: list[FriendRequestDocument] = Field(alias="incomingFriendRequests")
    outgoing_friend_requests: list[FriendRequestDocument] = Field(alias="outgoingFriendRequests")
    incoming_challenges: list[ChallengeDocument] = Field(alias="incomingChallenges")
    outgoing_challenges: list[ChallengeDocument] = Field(alias="outgoingChallenges")


class StoredPublicPlayer(StrictModel):
    id: str
    display_name: str = Field(alias="displayName")
    normalized_display_name: str = Field(alias="normalizedDisplayName")
    # Retained only so old rows and rolling clients remain readable. Discovery
    # is now always public for active profiles; false is migrated to true.
    discoverable: bool = True
    discoverability_updated_at: UtcDateTime | None = Field(
        default=None,
        alias="discoverabilityUpdatedAt",
    )
    version: int = Field(default=0, ge=0)
    avatar_key: str | None = Field(default=None, alias="avatarKey")
    avatar_version: int = Field(default=0, ge=0, alias="avatarVersion")


class AccountState(StrEnum):
    active = "active"
    deleting = "deleting"


class StoredPlayerStats(PlayerStatsDocument):
    player_id: str = Field(alias="playerId")
    version: int = Field(default=0, ge=0)


class SocialRelationStatus(StrEnum):
    pending = "pending"
    friends = "friends"


class StoredSocialRelation(StrictModel):
    id: str
    first_player_id: str = Field(alias="firstPlayerId")
    second_player_id: str = Field(alias="secondPlayerId")
    requester_id: str = Field(alias="requesterId")
    status: SocialRelationStatus
    version: int = Field(default=0, ge=0)
    created_at: UtcDateTime = Field(
        default_factory=lambda: datetime.now(UTC),
        alias="createdAt",
    )
    updated_at: UtcDateTime = Field(
        default_factory=lambda: datetime.now(UTC),
        alias="updatedAt",
    )

    def includes(self, player_id: str) -> bool:
        return player_id in {self.first_player_id, self.second_player_id}

    def other(self, player_id: str) -> str:
        if player_id == self.first_player_id:
            return self.second_player_id
        if player_id == self.second_player_id:
            return self.first_player_id
        raise ValueError("player is not part of this social relation")


class MetricsControlState(StrEnum):
    backfilling = "backfilling"
    ready = "ready"


class MetricsControl(StrictModel):
    state: MetricsControlState
    epoch: int = Field(ge=1)
    global_version: int = Field(default=0, ge=0, alias="globalVersion")


class MatchMetricsLedger(StrictModel):
    match_id: str = Field(alias="matchId")
    epoch: int = Field(ge=1)
    rating_sequence: int = Field(ge=1, alias="ratingSequence")
    completed_at: UtcDateTime = Field(alias="completedAt")
    black_kills: int = Field(ge=0, alias="blackKills")
    white_kills: int = Field(ge=0, alias="whiteKills")
    black_rating_before: int = Field(alias="blackRatingBefore")
    white_rating_before: int = Field(alias="whiteRatingBefore")
    black_rating_after: int = Field(alias="blackRatingAfter")
    white_rating_after: int = Field(alias="whiteRatingAfter")
    black_rating_delta: int = Field(alias="blackRatingDelta")
    white_rating_delta: int = Field(alias="whiteRatingDelta")
    black_score: float = Field(alias="blackScore", ge=0, le=1)


class MatchStatus(StrEnum):
    waiting = "waiting"
    active = "active"
    completed = "completed"


class MatchOrigin(StrEnum):
    private = "private"
    quick = "quick"
    friend_challenge = "friendChallenge"


class LastMove(StrictModel):
    revision: int = Field(ge=1)
    player: Literal["black", "white"]
    row: int = Field(ge=0, le=19)
    column: int = Field(ge=0, le=19)


class MatchDocument(StrictModel):
    id: str
    join_code: str | None = Field(default=None, alias="joinCode")
    rules: dict[str, Any]
    state: dict[str, Any]
    black_player: MatchPlayerDocument | None = Field(default=None, alias="blackPlayer")
    white_player: MatchPlayerDocument | None = Field(default=None, alias="whitePlayer")
    your_color: Literal["black", "white"] | None = Field(default=None, alias="yourColor")
    status: MatchStatus
    version: int = Field(ge=0)
    last_move: LastMove | None = Field(default=None, alias="lastMove")
    result: dict[str, Any] | None = None
    origin: MatchOrigin = MatchOrigin.private
    rated: bool = True
    completed_at: UtcDateTime | None = Field(default=None, alias="completedAt")
    created_at: UtcDateTime = Field(alias="createdAt")
    updated_at: UtcDateTime = Field(alias="updatedAt")


class MatchListResponse(StrictModel):
    items: list[MatchDocument]


class QuickMatchResponse(StrictModel):
    ticket_id: str = Field(alias="ticketId")
    status: Literal["waiting", "matched"]
    match_id: str | None = Field(default=None, alias="matchId")


class MoveEvent(StrictModel):
    revision: int
    actor_id: str = Field(alias="actorId")
    player: Literal["black", "white"]
    row: int
    column: int
    delta: dict[str, Any]
    state_hash: str = Field(alias="stateHash")
    created_at: UtcDateTime = Field(alias="createdAt")


class MoveHistoryResponse(StrictModel):
    items: list[MoveEvent]


class ReplayResponse(StrictModel):
    match_id: str = Field(alias="matchId")
    rules: dict[str, Any]
    initial_state: dict[str, Any] = Field(alias="initialState")
    moves: list[MoveEvent]
    final_state: dict[str, Any] = Field(alias="finalState")
    result: dict[str, Any] | None = None
    origin: MatchOrigin = MatchOrigin.private
    rated: bool = True
    completed_at: UtcDateTime | None = Field(default=None, alias="completedAt")


class StoredMatch(StrictModel):
    id: str
    join_code: str = Field(alias="joinCode")
    rules: dict[str, Any]
    state: dict[str, Any]
    creator_id: str = Field(alias="creatorId")
    creator_name: str = Field(alias="creatorName")
    black_player: PlayerSummary | None = Field(default=None, alias="blackPlayer")
    white_player: PlayerSummary | None = Field(default=None, alias="whitePlayer")
    status: MatchStatus
    version: int = Field(default=0, ge=0)
    last_move: LastMove | None = Field(default=None, alias="lastMove")
    result: dict[str, Any] | None = None
    origin: MatchOrigin = MatchOrigin.private
    rated: bool = True
    invited_player: PlayerSummary | None = Field(default=None, alias="invitedPlayer")
    challenge_expires_at: UtcDateTime | None = Field(default=None, alias="challengeExpiresAt")
    black_kills: int = Field(default=0, ge=0, alias="blackKills")
    white_kills: int = Field(default=0, ge=0, alias="whiteKills")
    kill_counts_complete: bool = Field(default=False, alias="killCountsComplete")
    stats_finalized: bool = Field(default=False, alias="statsFinalized")
    completed_at: UtcDateTime | None = Field(default=None, alias="completedAt")
    created_at: UtcDateTime = Field(
        default_factory=lambda: datetime.now(UTC),
        alias="createdAt",
    )
    updated_at: UtcDateTime = Field(
        default_factory=lambda: datetime.now(UTC),
        alias="updatedAt",
    )

    @property
    def revision(self) -> int:
        return int(self.state["revision"])

    def color_for(self, user_id: str) -> Literal["black", "white"] | None:
        if self.black_player and self.black_player.id == user_id:
            return "black"
        if self.white_player and self.white_player.id == user_id:
            return "white"
        return None


class StoredPushSubscription(StrictModel):
    user_id: str = Field(alias="userId")
    installation_id: str = Field(alias="installationId")
    platform: PushPlatform
    provider: PushProviderName
    token: str | None = Field(default=None, repr=False)
    endpoint: str | None = Field(default=None, repr=False)
    p256dh: str | None = Field(default=None, repr=False)
    auth: str | None = Field(default=None, repr=False)
    locale: str | None = None
    time_zone: str | None = Field(default=None, alias="timeZone")
    created_at: UtcDateTime = Field(
        default_factory=lambda: datetime.now(UTC),
        alias="createdAt",
    )
    updated_at: UtcDateTime = Field(
        default_factory=lambda: datetime.now(UTC),
        alias="updatedAt",
    )

    def document(self) -> PushSubscriptionDocument:
        return PushSubscriptionDocument(
            installation_id=self.installation_id,
            platform=self.platform,
            provider=self.provider,
            locale=self.locale,
            time_zone=self.time_zone,
            created_at=self.created_at,
            updated_at=self.updated_at,
        )


class TurnNotificationJob(StrictModel):
    kind: Literal["turnNotification"] = "turnNotification"
    match_id: str = Field(alias="matchId")
    revision: int = Field(ge=0)
    # Legacy scheduled jobs included the Cognito subject. New jobs deliberately
    # omit it and resolve the recipient from the authoritative match at run
    # time, so EventBridge Scheduler never persists a player's identity.
    recipient_user_id: str | None = Field(default=None, alias="recipientUserId")
    reminder_hours: Literal[0, 8, 24, 72] = Field(alias="reminderHours")
    turn_started_at: UtcDateTime = Field(alias="turnStartedAt")


class StoredExchange(StrictModel):
    code: str
    tokens: TokenSet
    expires_at: UtcDateTime = Field(alias="expiresAt")


class StoredOAuthTransaction(StrictModel):
    id: str
    verifier: str
    return_to: str = Field(alias="returnTo")
    expires_at: UtcDateTime = Field(alias="expiresAt")


def _decode_urlsafe_base64(value: str, field_name: str) -> bytes:
    try:
        return base64.b64decode(
            value + "=" * (-len(value) % 4),
            altchars=b"-_",
            validate=True,
        )
    except (binascii.Error, ValueError) as error:
        raise ValueError(f"{field_name} must be URL-safe base64") from error
