from __future__ import annotations

from datetime import UTC, datetime
from enum import StrEnum
from typing import Annotated, Any, Literal

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
            "rulesVersion": 1,
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


class MatchStatus(StrEnum):
    waiting = "waiting"
    active = "active"
    completed = "completed"


class MatchDocument(StrictModel):
    id: str
    join_code: str | None = Field(default=None, alias="joinCode")
    rules: dict[str, Any]
    state: dict[str, Any]
    black_player: PlayerSummary | None = Field(default=None, alias="blackPlayer")
    white_player: PlayerSummary | None = Field(default=None, alias="whitePlayer")
    your_color: Literal["black", "white"] | None = Field(default=None, alias="yourColor")
    status: MatchStatus
    version: int = Field(ge=0)
    result: dict[str, Any] | None = None
    created_at: UtcDateTime = Field(alias="createdAt")
    updated_at: UtcDateTime = Field(alias="updatedAt")


class MatchListResponse(StrictModel):
    items: list[MatchDocument]
    next_token: str | None = Field(default=None, alias="nextToken")


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
    result: dict[str, Any] | None = None
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


class StoredExchange(StrictModel):
    code: str
    tokens: TokenSet
    expires_at: UtcDateTime = Field(alias="expiresAt")


class StoredOAuthTransaction(StrictModel):
    id: str
    verifier: str
    return_to: str = Field(alias="returnTo")
    expires_at: UtcDateTime = Field(alias="expiresAt")
