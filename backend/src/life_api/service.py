from __future__ import annotations

import hashlib
import json
import secrets
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any
from uuid import uuid4

from .avatars import AvatarService, InMemoryAvatarObjectStore
from .engine import Engine
from .errors import ApiError
from .models import (
    CreateMatchRequest,
    LastMove,
    MatchDocument,
    MatchMetricsLedger,
    MatchOrigin,
    MatchPlayerDocument,
    MatchRulesRequest,
    MatchStatus,
    MoveEvent,
    MoveRequest,
    PlayerSummary,
    QuickMatchRequest,
    QuickMatchResponse,
    ReplayResponse,
    ResignRequest,
    StoredMatch,
    StoredPublicPlayer,
    User,
)
from .ratings import accumulated_kills, build_metrics_ledger, deaths_by_credit
from .repository import Repository


@dataclass(slots=True)
class MatchService:
    repository: Repository
    engine: Engine
    avatars: AvatarService | None = None

    def __post_init__(self) -> None:
        if self.avatars is None:
            self.avatars = AvatarService(
                self.repository,
                InMemoryAvatarObjectStore(),
                "http://testserver",
            )

    def create(self, user: User, request: CreateMatchRequest) -> MatchDocument:
        return self._create_waiting(user, request.rules)

    def _create_waiting(self, user: User, rules_request: MatchRulesRequest) -> MatchDocument:
        rules = rules_request.engine_rules()
        state = self.engine.initial(rules)
        match = StoredMatch(
            id=str(uuid4()),
            join_code=self._new_join_code(),
            rules=rules,
            state=state,
            creator_id=user.id,
            creator_name=user.display_name,
            status=MatchStatus.waiting,
            origin=MatchOrigin.private,
            rated=True,
            kill_counts_complete=True,
        )
        self.repository.create_match(match)
        return self.document(match, user.id)

    def join(self, user: User, join_code: str) -> MatchDocument:
        match = self.repository.find_by_join_code(join_code)
        if match is None:
            raise ApiError("matchNotFound", "No match has that join code.", status_code=404)
        if match.creator_id == user.id:
            raise ApiError(
                "cannotJoinOwnMatch", "A second player must join this match.", status_code=409
            )
        if match.status != MatchStatus.waiting:
            raise ApiError("matchUnavailable", "The match is no longer waiting.", status_code=409)
        if match.origin == MatchOrigin.friend_challenge:
            raise ApiError(
                "challengeJoinForbidden",
                "Friend challenges must be accepted through the challenge endpoint.",
                status_code=403,
            )
        black, white = self._assign_colors(
            PlayerSummary(id=match.creator_id, display_name=match.creator_name),
            PlayerSummary(id=user.id, display_name=user.display_name),
        )
        updated = match.model_copy(
            update={
                "black_player": black,
                "white_player": white,
                "status": MatchStatus.active,
                "version": match.version + 1,
                "updated_at": datetime.now(UTC),
            }
        )
        self.repository.join_match(updated, user.id)
        return self.document(updated, user.id)

    def quick_match(self, user: User, request: QuickMatchRequest) -> QuickMatchResponse:
        existing = self.repository.matchmaking_status(user.id, request.ticket_id)
        if existing is not None:
            return self._quick_response(existing.ticket_id, existing.status, existing.match_id)
        active_request = self.repository.active_matchmaking(user.id)
        if active_request is not None:
            return self._quick_response(
                active_request.ticket_id,
                active_request.status,
                active_request.match_id,
            )
        lock_token = self.repository.acquire_matchmaking_lock(user.id)
        if lock_token is None:
            raise ApiError(
                "matchmakingBusy",
                "Another matchmaking request is still being processed.",
                status_code=409,
            )
        try:
            return self._quick_match_locked(user, request)
        finally:
            self.repository.release_matchmaking_lock(user.id, lock_token)

    def _quick_match_locked(self, user: User, request: QuickMatchRequest) -> QuickMatchResponse:
        existing = self.repository.matchmaking_status(user.id, request.ticket_id)
        if existing is not None:
            return self._quick_response(existing.ticket_id, existing.status, existing.match_id)
        active_request = self.repository.active_matchmaking(user.id)
        if active_request is not None:
            return self._quick_response(
                active_request.ticket_id,
                active_request.status,
                active_request.match_id,
            )
        rules = request.rules.engine_rules()
        rules_hash = _stable_hash(rules)
        opponent_entry = self.repository.pop_opponent(rules_hash, user.id)
        if opponent_entry is None:
            self.repository.enqueue(
                rules_hash,
                user.id,
                user.display_name,
                rules,
                request.ticket_id,
            )
            return QuickMatchResponse(ticket_id=request.ticket_id, status="waiting")
        opponent_id, opponent_name, opponent_rules, opponent_ticket_id = opponent_entry
        try:
            state = self.engine.initial(opponent_rules)
            black, white = self._assign_colors(
                PlayerSummary(id=opponent_id, display_name=opponent_name),
                PlayerSummary(id=user.id, display_name=user.display_name),
            )
            active_match = StoredMatch(
                id=str(uuid4()),
                join_code=self._new_join_code(),
                rules=opponent_rules,
                state=state,
                creator_id=opponent_id,
                creator_name=opponent_name,
                black_player=black,
                white_player=white,
                status=MatchStatus.active,
                version=1,
                origin=MatchOrigin.quick,
                rated=True,
                kill_counts_complete=True,
            )
            self.repository.commit_quick_match(
                active_match,
                user.id,
                request.ticket_id,
                opponent_ticket_id,
            )
        except Exception:
            self.repository.release_matchmaking_claim(opponent_id, opponent_ticket_id)
            raise
        return QuickMatchResponse(
            ticket_id=request.ticket_id,
            status="matched",
            match_id=active_match.id,
        )

    def quick_status(self, user: User, ticket_id: str) -> QuickMatchResponse:
        record = self.repository.matchmaking_status(user.id, ticket_id)
        if record is None:
            raise ApiError(
                "matchmakingTicketNotFound",
                "That matchmaking ticket was not found or has expired.",
                status_code=404,
            )
        return self._quick_response(record.ticket_id, record.status, record.match_id)

    def cancel_quick_match(self, user: User, ticket_id: str) -> None:
        if self.repository.remove_from_queue(user.id, ticket_id):
            return
        record = self.repository.matchmaking_status(user.id, ticket_id)
        if record is not None and record.status == "matched" and record.match_id:
            raise ApiError(
                "matchAlreadyFound",
                "A match was found before cancellation completed.",
                status_code=409,
                details={"matchId": record.match_id},
            )

    def delete_account_data(self, user: User) -> None:
        if self.repository.get_metrics_control().state.value != "ready":
            raise ApiError(
                "metricsBackfillInProgress",
                "Account deletion is temporarily paused during rating migration.",
                status_code=503,
            )
        lock_token = self.repository.acquire_matchmaking_lock(user.id)
        if lock_token is None:
            raise ApiError(
                "accountDeletionBusy",
                "Another request is still updating this account. Try again.",
                status_code=409,
            )
        try:
            self.repository.begin_user_deletion(user.id)
            active_request = self.repository.active_matchmaking(user.id)
            if active_request is not None:
                self.repository.remove_from_queue(user.id, active_request.ticket_id)

            for match in self.repository.list_matches(user.id):
                if match.status == MatchStatus.waiting:
                    try:
                        self.cancel_waiting(user, match.id)
                        continue
                    except ApiError as error:
                        current = self.repository.get_match(match.id)
                        if current is None or current.status == MatchStatus.completed:
                            continue
                        if error.code != "matchUnavailable" or current.status != MatchStatus.active:
                            raise
                        # The invited player joined between the deletion scan
                        # and cancellation. Reconcile it as an active game.
                        match = current
                if match.status == MatchStatus.active:
                    try:
                        self.resign(
                            user,
                            match.id,
                            ResignRequest(
                                expected_revision=match.revision,
                                idempotency_key=f"account-delete-{uuid4()}",
                            ),
                            deleting_user_id=user.id,
                        )
                    except ApiError as error:
                        current = self.repository.get_match(match.id)
                        if (
                            error.code not in {"gameOver", "staleRevision"}
                            or current is None
                            or current.status != MatchStatus.completed
                        ):
                            raise

            self.repository.delete_user_data(user.id)
        finally:
            self.repository.release_matchmaking_lock(user.id, lock_token)

    @staticmethod
    def _quick_response(
        ticket_id: str,
        status: str,
        match_id: str | None,
    ) -> QuickMatchResponse:
        if status == "matched" and match_id is not None:
            return QuickMatchResponse(
                ticket_id=ticket_id,
                status="matched",
                match_id=match_id,
            )
        return QuickMatchResponse(ticket_id=ticket_id, status="waiting")

    def get(self, user: User, match_id: str) -> MatchDocument:
        match = self._authorized_match(user, match_id)
        return self.document(match, user.id)

    def list_matches(self, user: User) -> list[MatchDocument]:
        matches = self.repository.list_matches(user.id)
        player_ids = {
            player.id
            for match in matches
            for player in (match.black_player, match.white_player)
            if player is not None and not player.id.startswith("deleted-")
        }
        profiles = self.repository.get_public_players(player_ids)
        return [self.document(match, user.id, profiles=profiles) for match in matches]

    def cancel_waiting(self, user: User, match_id: str) -> None:
        match = self._authorized_match(user, match_id)
        if match.creator_id != user.id:
            raise ApiError(
                "matchForbidden",
                "Only the player who created this match may cancel it.",
                status_code=403,
            )
        if match.status != MatchStatus.waiting:
            raise ApiError(
                "matchUnavailable",
                "Only a waiting match may be cancelled.",
                status_code=409,
            )
        self.repository.cancel_waiting_match(match, user.id)

    def move(self, user: User, match_id: str, request: MoveRequest) -> MatchDocument:
        for attempt in range(3):
            try:
                return self._move_once(user, match_id, request)
            except ApiError as error:
                if error.code != "metricsConflict":
                    raise
                if attempt == 2:
                    raise ApiError(
                        "metricsBusy",
                        "Rating state is busy. Retry the move.",
                        status_code=503,
                    ) from error
        raise AssertionError("unreachable")

    def _move_once(self, user: User, match_id: str, request: MoveRequest) -> MatchDocument:
        request_fingerprint = _stable_hash(
            {
                "operation": "move",
                "matchId": match_id,
                "row": request.row,
                "column": request.column,
                "expectedRevision": request.expected_revision,
            }
        )
        previous = self.repository.idempotent_result(
            user.id, request.idempotency_key, request_fingerprint
        )
        if previous is not None:
            if previous.id != match_id:
                raise ApiError(
                    "idempotencyConflict",
                    "That idempotency key was used for another match.",
                    status_code=409,
                )
            return self.document(previous, user.id)
        match = self._authorized_match(user, match_id)
        if match.status != MatchStatus.active:
            raise ApiError("gameOver", "The match is not active.", status_code=409)
        color = match.color_for(user.id)
        if color is None:
            raise ApiError("notAPlayer", "Only a player may submit a move.", status_code=403)
        if request.expected_revision != match.revision:
            raise ApiError(
                "staleRevision",
                "The match has changed.",
                status_code=409,
                details={"currentRevision": match.revision},
            )
        turn = self.engine.apply_move(
            match.state,
            player=color,
            row=request.row,
            column=request.column,
            expected_revision=request.expected_revision,
        )
        state = turn["state"]
        outcome = state.get("outcome")
        now = datetime.now(UTC)
        black_kills = match.black_kills
        white_kills = match.white_kills
        if not match.kill_counts_complete:
            historical = [move.delta for move in self.repository.list_moves(match.id)]
            black_kills, white_kills = accumulated_kills(historical)
        turn_black_kills, turn_white_kills = deaths_by_credit(turn["delta"])
        black_kills += turn_black_kills
        white_kills += turn_white_kills
        updated = match.model_copy(
            update={
                "state": state,
                "status": MatchStatus.completed if outcome else MatchStatus.active,
                "last_move": LastMove(
                    revision=int(state["revision"]),
                    player=color,
                    row=request.row,
                    column=request.column,
                ),
                "result": outcome,
                "black_kills": black_kills,
                "white_kills": white_kills,
                "kill_counts_complete": True,
                "completed_at": now if outcome else None,
                "version": match.version + 1,
                "updated_at": now,
            }
        )
        event = MoveEvent(
            revision=int(state["revision"]),
            actor_id=user.id,
            player=color,
            row=request.row,
            column=request.column,
            delta=turn["delta"],
            state_hash=str(state["stateHash"]),
            created_at=now,
        )
        metrics, black_version, white_version, control_version = self._terminal_metrics(
            updated,
            now,
        )
        if metrics is not None:
            updated = updated.model_copy(update={"stats_finalized": True})
        self.repository.commit_move(
            match=updated,
            expected_version=match.version,
            event=event,
            user_id=user.id,
            idempotency_key=request.idempotency_key,
            request_fingerprint=request_fingerprint,
            metrics=metrics,
            black_stats_version=black_version,
            white_stats_version=white_version,
            control_version=control_version,
        )
        committed = self.repository.idempotent_result(
            user.id, request.idempotency_key, request_fingerprint
        )
        if committed is not None and committed.id != match_id:
            raise ApiError(
                "idempotencyConflict",
                "That idempotency key was used for another match.",
                status_code=409,
            )
        return self.document(committed or updated, user.id)

    def resign(
        self,
        user: User,
        match_id: str,
        request: ResignRequest,
        *,
        deleting_user_id: str | None = None,
    ) -> MatchDocument:
        for attempt in range(3):
            try:
                return self._resign_once(
                    user,
                    match_id,
                    request,
                    deleting_user_id=deleting_user_id,
                )
            except ApiError as error:
                if error.code != "metricsConflict":
                    raise
                if attempt == 2:
                    raise ApiError(
                        "metricsBusy",
                        "Rating state is busy. Retry the resignation.",
                        status_code=503,
                    ) from error
        raise AssertionError("unreachable")

    def _resign_once(
        self,
        user: User,
        match_id: str,
        request: ResignRequest,
        *,
        deleting_user_id: str | None = None,
    ) -> MatchDocument:
        request_fingerprint = _stable_hash(
            {
                "operation": "resign",
                "matchId": match_id,
                "expectedRevision": request.expected_revision,
            }
        )
        previous = self.repository.idempotent_result(
            user.id, request.idempotency_key, request_fingerprint
        )
        if previous is not None:
            if previous.id != match_id:
                raise ApiError(
                    "idempotencyConflict",
                    "That idempotency key was used for another match.",
                    status_code=409,
                )
            return self.document(previous, user.id)
        match = self._authorized_match(user, match_id)
        if match.status != MatchStatus.active:
            raise ApiError("gameOver", "The match is not active.", status_code=409)
        color = match.color_for(user.id)
        if color is None:
            raise ApiError("notAPlayer", "Only a player may resign.", status_code=403)
        if request.expected_revision != match.revision:
            raise ApiError(
                "staleRevision",
                "The match has changed.",
                status_code=409,
                details={"currentRevision": match.revision},
            )
        winner = "white" if color == "black" else "black"
        now = datetime.now(UTC)
        black_kills = match.black_kills
        white_kills = match.white_kills
        if not match.kill_counts_complete:
            historical = [move.delta for move in self.repository.list_moves(match.id)]
            black_kills, white_kills = accumulated_kills(historical)
        updated = match.model_copy(
            update={
                "status": MatchStatus.completed,
                "result": {"type": "win", "winner": winner, "reason": "resignation"},
                "black_kills": black_kills,
                "white_kills": white_kills,
                "kill_counts_complete": True,
                "stats_finalized": True,
                "completed_at": now,
                "version": match.version + 1,
                "updated_at": now,
            }
        )
        metrics, black_version, white_version, control_version = self._terminal_metrics(
            updated, now
        )
        if (
            metrics is None
            or black_version is None
            or white_version is None
            or control_version is None
        ):
            raise AssertionError("resignation must finalize rated metrics")
        self.repository.commit_resignation(
            match=updated,
            expected_version=match.version,
            user_id=user.id,
            idempotency_key=request.idempotency_key,
            request_fingerprint=request_fingerprint,
            metrics=metrics,
            black_stats_version=black_version,
            white_stats_version=white_version,
            control_version=control_version,
            deleting_user_id=deleting_user_id,
        )
        committed = self.repository.idempotent_result(
            user.id, request.idempotency_key, request_fingerprint
        )
        return self.document(committed or updated, user.id)

    def history(self, user: User, match_id: str) -> list[MoveEvent]:
        self._authorized_match(user, match_id)
        return self.repository.list_moves(match_id)

    def replay(self, user: User, match_id: str) -> ReplayResponse:
        match = self._authorized_match(user, match_id)
        moves = self.repository.list_moves(match_id)
        replay_moves = [
            {"player": move.player, "row": move.row, "column": move.column} for move in moves
        ]
        replay = self.engine.replay(match.rules, replay_moves)
        return ReplayResponse(
            match_id=match.id,
            rules=match.rules,
            initial_state=self.engine.initial(match.rules),
            moves=moves,
            final_state=replay["state"],
            result=match.result,
            origin=match.origin,
            rated=match.rated,
            completed_at=match.completed_at,
        )

    def document(
        self,
        match: StoredMatch,
        user_id: str,
        *,
        profiles: dict[str, StoredPublicPlayer] | None = None,
    ) -> MatchDocument:
        return MatchDocument(
            id=match.id,
            join_code=(None if match.origin == MatchOrigin.friend_challenge else match.join_code),
            rules=match.rules,
            state=match.state,
            black_player=self._public_player(match.black_player, profiles=profiles),
            white_player=self._public_player(match.white_player, profiles=profiles),
            your_color=match.color_for(user_id),
            status=match.status,
            version=match.version,
            last_move=match.last_move,
            result=match.result,
            origin=match.origin,
            rated=match.rated,
            completed_at=match.completed_at,
            created_at=match.created_at,
            updated_at=match.updated_at,
        )

    def _authorized_match(self, user: User, match_id: str) -> StoredMatch:
        match = self.repository.get_match(match_id)
        if match is None:
            raise ApiError("matchNotFound", "The match was not found.", status_code=404)
        participant_ids = {
            match.creator_id,
            match.black_player.id if match.black_player else None,
            match.white_player.id if match.white_player else None,
        }
        if user.id not in participant_ids:
            raise ApiError(
                "matchForbidden", "You do not have access to this match.", status_code=403
            )
        return match

    def _new_join_code(self) -> str:
        alphabet = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
        for _ in range(20):
            code = "".join(secrets.choice(alphabet) for _ in range(6))
            if self.repository.find_by_join_code(code) is None:
                return code
        raise ApiError("capacityError", "A join code could not be allocated.", status_code=503)

    @staticmethod
    def _assign_colors(
        first_player: PlayerSummary,
        second_player: PlayerSummary,
    ) -> tuple[PlayerSummary, PlayerSummary]:
        return (
            (first_player, second_player)
            if secrets.randbelow(2) == 0
            else (second_player, first_player)
        )

    def _public_player(
        self,
        player: PlayerSummary | None,
        *,
        profiles: dict[str, StoredPublicPlayer] | None = None,
    ) -> MatchPlayerDocument | None:
        if player is None:
            return None
        if player.id.startswith("deleted-"):
            return MatchPlayerDocument(
                id=player.id,
                display_name="Deleted player",
            )
        current = (
            profiles.get(player.id)
            if profiles is not None
            else self.repository.get_public_player(player.id)
        )
        if current is None:
            return MatchPlayerDocument(id=player.id, display_name=player.display_name)
        return MatchPlayerDocument(
            id=current.id,
            display_name=current.display_name,
            avatar_url=self._avatars.url(current),
            avatar_version=current.avatar_version,
        )

    @property
    def _avatars(self) -> AvatarService:
        if self.avatars is None:
            raise AssertionError("avatar service was not initialized")
        return self.avatars

    def _terminal_metrics(
        self,
        match: StoredMatch,
        completed_at: datetime,
    ) -> tuple[MatchMetricsLedger | None, int | None, int | None, int | None]:
        if match.status != MatchStatus.completed:
            return None, None, None, None
        if not match.rated:
            raise ApiError("unratedRemoteMatch", "Remote matches must be rated.", status_code=500)
        if match.black_player is None or match.white_player is None:
            raise ApiError("invalidMatch", "A rated match requires two players.", status_code=500)
        control = self.repository.get_metrics_control()
        if control.state.value != "ready":
            raise ApiError(
                "metricsBackfillInProgress",
                "Rated results are temporarily paused.",
                status_code=503,
            )
        black_stats = self.repository.get_player_stats(match.black_player.id)
        white_stats = self.repository.get_player_stats(match.white_player.id)
        return (
            build_metrics_ledger(match, black_stats, white_stats, control, completed_at),
            black_stats.version,
            white_stats.version,
            control.global_version,
        )


def _stable_hash(value: dict[str, Any]) -> str:
    canonical = json.dumps(value, separators=(",", ":"), sort_keys=True)
    return hashlib.sha256(canonical.encode()).hexdigest()
