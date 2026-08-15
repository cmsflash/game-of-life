from __future__ import annotations

import hashlib
import json
import secrets
import threading
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any, Literal, Protocol
from uuid import uuid4

import boto3
from boto3.dynamodb.conditions import Key
from botocore.exceptions import ClientError

from .errors import ApiError
from .models import (
    AccountState,
    MatchMetricsLedger,
    MatchStatus,
    MetricsControl,
    MetricsControlState,
    MoveEvent,
    PlayerSummary,
    SocialRelationStatus,
    StoredChallenge,
    StoredExchange,
    StoredMatch,
    StoredOAuthTransaction,
    StoredPlayerStats,
    StoredPublicPlayer,
    StoredPushSubscription,
    StoredSocialRelation,
)
from .settings import Settings

_MATCHMAKING_WAIT_TTL = timedelta(minutes=10)
_MATCHMAKING_RESULT_TTL = timedelta(hours=1)


@dataclass(frozen=True, slots=True)
class MatchmakingRecord:
    ticket_id: str
    status: Literal["waiting", "claimed", "matched"]
    rules_hash: str | None
    queue_sk: str | None
    match_id: str | None
    expires_at: datetime


class Repository(Protocol):
    def account_state(self, user_id: str) -> AccountState: ...

    def begin_user_deletion(self, user_id: str) -> None: ...

    def upsert_public_player(self, player: StoredPublicPlayer) -> None: ...

    def set_player_discoverability(self, user_id: str, discoverable: bool) -> tuple[bool, int]: ...

    def set_player_avatar(
        self,
        user_id: str,
        *,
        avatar_key: str | None,
        expected_profile_version: int,
    ) -> StoredPublicPlayer: ...

    def get_public_player(self, player_id: str) -> StoredPublicPlayer | None: ...

    def get_public_players(self, player_ids: set[str]) -> dict[str, StoredPublicPlayer]: ...

    def search_public_players(
        self, normalized_prefix: str, *, limit: int
    ) -> list[StoredPublicPlayer]: ...

    def check_player_search_rate(self, user_id: str) -> None: ...

    def check_avatar_upload_rate(self, user_id: str) -> None: ...

    def get_player_stats(self, player_id: str) -> StoredPlayerStats: ...

    def get_metrics_control(self) -> MetricsControl: ...

    def get_metrics_ledger(self, match_id: str) -> MatchMetricsLedger | None: ...

    def social_records(
        self, user_id: str
    ) -> tuple[int, list[StoredSocialRelation], list[StoredChallenge]]: ...

    def get_social_relation(self, first_id: str, second_id: str) -> StoredSocialRelation | None: ...

    def create_friend_request(self, relation: StoredSocialRelation) -> StoredSocialRelation: ...

    def accept_friend_request(
        self, relation: StoredSocialRelation, recipient_id: str
    ) -> StoredSocialRelation: ...

    def delete_friend_request(self, relation: StoredSocialRelation, actor_id: str) -> None: ...

    def delete_friendship(self, relation: StoredSocialRelation, actor_id: str) -> None: ...

    def get_challenge(self, challenge_id: str) -> StoredChallenge | None: ...

    def challenge_result(self, challenge_id: str) -> str | None: ...

    def create_challenge(self, challenge: StoredChallenge) -> StoredChallenge: ...

    def accept_challenge(
        self, challenge: StoredChallenge, match: StoredMatch, accepting_user_id: str
    ) -> None: ...

    def cancel_challenge(self, challenge: StoredChallenge, actor_id: str) -> None: ...

    def create_match(self, match: StoredMatch) -> None: ...

    def get_match(self, match_id: str) -> StoredMatch | None: ...

    def find_by_join_code(self, join_code: str) -> StoredMatch | None: ...

    def list_matches(self, user_id: str) -> list[StoredMatch]: ...

    def join_match(self, match: StoredMatch, joining_user_id: str) -> None: ...

    def cancel_waiting_match(self, match: StoredMatch, user_id: str) -> None: ...

    def idempotent_result(
        self, user_id: str, key: str, request_fingerprint: str
    ) -> StoredMatch | None: ...

    def commit_move(
        self,
        *,
        match: StoredMatch,
        expected_version: int,
        event: MoveEvent,
        user_id: str,
        idempotency_key: str,
        request_fingerprint: str,
        metrics: MatchMetricsLedger | None = None,
        black_stats_version: int | None = None,
        white_stats_version: int | None = None,
        control_version: int | None = None,
    ) -> None: ...

    def commit_resignation(
        self,
        *,
        match: StoredMatch,
        expected_version: int,
        user_id: str,
        idempotency_key: str,
        request_fingerprint: str,
        metrics: MatchMetricsLedger,
        black_stats_version: int,
        white_stats_version: int,
        control_version: int,
        deleting_user_id: str | None = None,
    ) -> None: ...

    def list_moves(self, match_id: str) -> list[MoveEvent]: ...

    def enqueue(
        self,
        rules_hash: str,
        user_id: str,
        display_name: str,
        rules: dict[str, Any],
        ticket_id: str,
    ) -> None: ...

    def pop_opponent(
        self, rules_hash: str, user_id: str
    ) -> tuple[str, str, dict[str, Any], str] | None: ...

    def active_matchmaking(self, user_id: str) -> MatchmakingRecord | None: ...

    def matchmaking_status(self, user_id: str, ticket_id: str) -> MatchmakingRecord | None: ...

    def commit_quick_match(
        self,
        match: StoredMatch,
        joining_user_id: str,
        requester_ticket_id: str,
        opponent_ticket_id: str,
    ) -> None: ...

    def release_matchmaking_claim(self, user_id: str, ticket_id: str) -> None: ...

    def remove_from_queue(self, user_id: str, ticket_id: str) -> bool: ...

    def acquire_matchmaking_lock(self, user_id: str) -> str | None: ...

    def release_matchmaking_lock(self, user_id: str, token: str) -> None: ...

    def put_exchange(self, exchange: StoredExchange) -> None: ...

    def consume_exchange(self, code: str) -> StoredExchange | None: ...

    def put_oauth_transaction(self, transaction: StoredOAuthTransaction) -> None: ...

    def consume_oauth_transaction(self, transaction_id: str) -> StoredOAuthTransaction | None: ...

    def upsert_push_subscription(
        self, subscription: StoredPushSubscription
    ) -> StoredPushSubscription: ...

    def list_push_subscriptions(self, user_id: str) -> list[StoredPushSubscription]: ...

    def get_push_subscription(
        self, user_id: str, installation_id: str
    ) -> StoredPushSubscription | None: ...

    def delete_push_subscription(self, user_id: str, installation_id: str) -> None: ...

    def delete_push_subscription_if_unchanged(
        self, subscription: StoredPushSubscription
    ) -> bool: ...

    def claim_notification_delivery(self, delivery_id: str) -> str | None: ...

    def complete_notification_delivery(self, delivery_id: str, claim_token: str) -> None: ...

    def release_notification_delivery(self, delivery_id: str, claim_token: str) -> None: ...

    def delete_user_data(self, user_id: str) -> None: ...


class InMemoryRepository:
    def __init__(self) -> None:
        self._matches: dict[str, StoredMatch] = {}
        self._join_codes: dict[str, str] = {}
        self._memberships: dict[str, set[str]] = {}
        self._moves: dict[str, list[MoveEvent]] = {}
        self._idempotency: dict[tuple[str, str], tuple[str, StoredMatch]] = {}
        self._queues: dict[
            str,
            list[tuple[str, str, dict[str, Any], str, datetime]],
        ] = {}
        self._active_ticket_by_user: dict[str, str] = {}
        self._matchmaking_records: dict[tuple[str, str], MatchmakingRecord] = {}
        self._exchanges: dict[str, StoredExchange] = {}
        self._oauth_transactions: dict[str, StoredOAuthTransaction] = {}
        self._push_subscriptions: dict[tuple[str, str], StoredPushSubscription] = {}
        self._installation_owners: dict[str, str] = {}
        self._notification_deliveries: dict[str, tuple[str, datetime, str]] = {}
        self._deleted_users: set[str] = set()
        self._matchmaking_locks: dict[str, str] = {}
        self._account_states: dict[str, AccountState] = {}
        self._public_players: dict[str, StoredPublicPlayer] = {}
        self._player_stats: dict[str, StoredPlayerStats] = {}
        self._social_relations: dict[tuple[str, str], StoredSocialRelation] = {}
        self._social_versions: dict[str, int] = {}
        self._challenge_by_pair: dict[tuple[str, str], str] = {}
        self._challenges: dict[str, StoredChallenge] = {}
        self._challenge_results: dict[str, str] = {}
        self._metrics_control = MetricsControl(
            state=MetricsControlState.ready,
            epoch=1,
            global_version=0,
        )
        self._metrics_ledgers: dict[str, MatchMetricsLedger] = {}
        self._search_rates: dict[tuple[str, int], int] = {}
        self._avatar_upload_rates: dict[tuple[str, int], int] = {}
        self._lock = threading.RLock()

    def account_state(self, user_id: str) -> AccountState:
        with self._lock:
            return self._account_states.get(user_id, AccountState.active)

    def begin_user_deletion(self, user_id: str) -> None:
        with self._lock:
            self._account_states[user_id] = AccountState.deleting
            self._public_players.pop(user_id, None)

    def upsert_public_player(self, player: StoredPublicPlayer) -> None:
        with self._lock:
            self._require_active(player.id)
            self._account_states.setdefault(player.id, AccountState.active)
            existing = self._public_players.get(player.id)
            if existing is None:
                self._public_players[player.id] = player.model_copy(
                    update={
                        "discoverable": True,
                        "version": 0,
                    },
                    deep=True,
                )
            elif (
                existing.display_name != player.display_name
                or existing.normalized_display_name != player.normalized_display_name
                or not existing.discoverable
                or existing.discoverability_updated_at is not None
            ):
                self._public_players[player.id] = existing.model_copy(
                    update={
                        "display_name": player.display_name,
                        "normalized_display_name": player.normalized_display_name,
                        "discoverable": True,
                        "discoverability_updated_at": None,
                        "version": existing.version + 1,
                    },
                    deep=True,
                )
            self._player_stats.setdefault(player.id, _default_stats(player.id))

    def set_player_discoverability(self, user_id: str, discoverable: bool) -> tuple[bool, int]:
        with self._lock:
            self._require_active(user_id)
            player = self._public_players.get(user_id)
            if player is None:
                raise ApiError("playerUnavailable", "That player is unavailable.", status_code=404)
            if not player.discoverable:
                self._public_players[user_id] = player.model_copy(
                    update={"discoverable": True, "version": player.version + 1},
                    deep=True,
                )
            # Rolling-client compatibility only. Search privacy is not
            # configurable during this development phase.
            del discoverable
            return True, self._social_versions.get(user_id, 0)

    def set_player_avatar(
        self,
        user_id: str,
        *,
        avatar_key: str | None,
        expected_profile_version: int,
    ) -> StoredPublicPlayer:
        with self._lock:
            self._require_active(user_id)
            player = self._public_players.get(user_id)
            if player is None:
                raise ApiError("playerUnavailable", "That player is unavailable.", status_code=404)
            if player.version != expected_profile_version:
                raise ApiError(
                    "profileConflict", "The player profile changed. Retry.", status_code=409
                )
            updated = player.model_copy(
                update={
                    "avatar_key": avatar_key,
                    "avatar_version": player.avatar_version + 1,
                    "version": player.version + 1,
                    "discoverable": True,
                },
                deep=True,
            )
            self._public_players[user_id] = updated
            return updated.model_copy(deep=True)

    def get_public_player(self, player_id: str) -> StoredPublicPlayer | None:
        with self._lock:
            if self.account_state(player_id) != AccountState.active:
                return None
            player = self._public_players.get(player_id)
            return player.model_copy(deep=True) if player is not None else None

    def get_public_players(self, player_ids: set[str]) -> dict[str, StoredPublicPlayer]:
        return {
            player_id: player
            for player_id in player_ids
            if (player := self.get_public_player(player_id)) is not None
        }

    def search_public_players(
        self, normalized_prefix: str, *, limit: int
    ) -> list[StoredPublicPlayer]:
        with self._lock:
            matches = [
                player.model_copy(deep=True)
                for player in self._public_players.values()
                if player.normalized_display_name.startswith(normalized_prefix)
                and self.account_state(player.id) == AccountState.active
            ]
        return sorted(matches, key=lambda value: (value.normalized_display_name, value.id))[:limit]

    def check_player_search_rate(self, user_id: str) -> None:
        with self._lock:
            minute = int(datetime.now(UTC).timestamp()) // 60
            key = (user_id, minute)
            count = self._search_rates.get(key, 0) + 1
            if count > 30:
                raise ApiError("playerSearchRateLimited", "Search again later.", status_code=429)
            self._search_rates[key] = count

    def check_avatar_upload_rate(self, user_id: str) -> None:
        with self._lock:
            hour = int(datetime.now(UTC).timestamp()) // 3600
            key = (user_id, hour)
            count = self._avatar_upload_rates.get(key, 0) + 1
            if count > 10:
                raise ApiError(
                    "avatarUploadRateLimited",
                    "Too many profile-picture uploads. Try again later.",
                    status_code=429,
                )
            self._avatar_upload_rates[key] = count

    def get_player_stats(self, player_id: str) -> StoredPlayerStats:
        with self._lock:
            stats = self._player_stats.get(player_id, _default_stats(player_id))
            return stats.model_copy(deep=True)

    def get_metrics_control(self) -> MetricsControl:
        with self._lock:
            return self._metrics_control.model_copy(deep=True)

    def get_metrics_ledger(self, match_id: str) -> MatchMetricsLedger | None:
        with self._lock:
            ledger = self._metrics_ledgers.get(match_id)
            return ledger.model_copy(deep=True) if ledger is not None else None

    def social_records(
        self, user_id: str
    ) -> tuple[int, list[StoredSocialRelation], list[StoredChallenge]]:
        with self._lock:
            relations = [
                value.model_copy(deep=True)
                for value in self._social_relations.values()
                if value.includes(user_id)
            ]
            challenges = [
                value.model_copy(deep=True)
                for value in self._challenges.values()
                if user_id in {value.challenger.id, value.opponent.id}
                and value.expires_at > datetime.now(UTC)
            ]
            return self._social_versions.get(user_id, 0), relations, challenges

    def get_social_relation(self, first_id: str, second_id: str) -> StoredSocialRelation | None:
        with self._lock:
            relation = self._social_relations.get(_pair_key(first_id, second_id))
            return relation.model_copy(deep=True) if relation is not None else None

    def create_friend_request(self, relation: StoredSocialRelation) -> StoredSocialRelation:
        with self._lock:
            self._require_pair_active(relation.first_player_id, relation.second_player_id)
            key = _pair_key(relation.first_player_id, relation.second_player_id)
            target_id = relation.other(relation.requester_id)
            target = self._public_players.get(target_id)
            if target is None:
                raise ApiError("playerUnavailable", "That player is unavailable.", status_code=404)
            current = self._social_relations.get(key)
            if current is not None:
                if (
                    current.status == SocialRelationStatus.pending
                    and current.requester_id == relation.requester_id
                ):
                    return current.model_copy(deep=True)
                raise ApiError(
                    "friendRequestAlreadyPending",
                    "A friendship or friend request already exists.",
                    status_code=409,
                )
            for player_id in key:
                relations = [
                    value for value in self._social_relations.values() if value.includes(player_id)
                ]
                if sum(value.status == SocialRelationStatus.pending for value in relations) >= 100:
                    raise ApiError(
                        "socialLimitReached",
                        "Too many pending friend requests.",
                        status_code=409,
                    )
            self._social_relations[key] = relation.model_copy(deep=True)
            self._bump_social_versions(*key)
            return relation.model_copy(deep=True)

    def accept_friend_request(
        self, relation: StoredSocialRelation, recipient_id: str
    ) -> StoredSocialRelation:
        with self._lock:
            key = _pair_key(relation.first_player_id, relation.second_player_id)
            current = self._social_relations.get(key)
            if current is not None and current.status == SocialRelationStatus.friends:
                return current.model_copy(deep=True)
            if (
                current is None
                or current.id != relation.id
                or current.status != SocialRelationStatus.pending
                or current.requester_id == recipient_id
                or not current.includes(recipient_id)
            ):
                raise ApiError(
                    "friendRequestUnavailable", "The friend request changed.", status_code=409
                )
            self._require_pair_active(*key)
            for player_id in key:
                if (
                    sum(
                        value.status == SocialRelationStatus.friends and value.includes(player_id)
                        for value in self._social_relations.values()
                    )
                    >= 100
                ):
                    raise ApiError("socialLimitReached", "Too many friends.", status_code=409)
            updated = current.model_copy(
                update={
                    "status": SocialRelationStatus.friends,
                    "version": current.version + 1,
                    "updated_at": datetime.now(UTC),
                }
            )
            self._social_relations[key] = updated
            self._bump_social_versions(*key)
            return updated.model_copy(deep=True)

    def delete_friend_request(self, relation: StoredSocialRelation, actor_id: str) -> None:
        with self._lock:
            key = _pair_key(relation.first_player_id, relation.second_player_id)
            current = self._social_relations.get(key)
            if (
                current is None
                or current.id != relation.id
                or current.status != SocialRelationStatus.pending
                or not current.includes(actor_id)
            ):
                raise ApiError(
                    "friendRequestNotFound",
                    "The friend request was not found.",
                    status_code=404,
                )
            self._social_relations.pop(key, None)
            self._bump_social_versions(*key)

    def delete_friendship(self, relation: StoredSocialRelation, actor_id: str) -> None:
        with self._lock:
            key = _pair_key(relation.first_player_id, relation.second_player_id)
            current = self._social_relations.get(key)
            if (
                current is None
                or current.id != relation.id
                or current.version != relation.version
                or current.status != SocialRelationStatus.friends
                or not current.includes(actor_id)
            ):
                raise ApiError("friendNotFound", "That player is not a friend.", status_code=404)
            self._cancel_pair_challenge(key)
            self._social_relations.pop(key, None)
            self._bump_social_versions(*key)

    def get_challenge(self, challenge_id: str) -> StoredChallenge | None:
        with self._lock:
            challenge = self._challenges.get(challenge_id)
            return challenge.model_copy(deep=True) if challenge is not None else None

    def challenge_result(self, challenge_id: str) -> str | None:
        with self._lock:
            return self._challenge_results.get(challenge_id)

    def create_challenge(self, challenge: StoredChallenge) -> StoredChallenge:
        with self._lock:
            key = _pair_key(challenge.challenger.id, challenge.opponent.id)
            self._require_pair_active(*key)
            relation = self._social_relations.get(key)
            if relation is None or relation.status != SocialRelationStatus.friends:
                raise ApiError("friendRequired", "Only friends can be challenged.", status_code=409)
            existing_id = self._challenge_by_pair.get(key)
            if existing_id is not None:
                existing = self._challenges.get(existing_id)
                if existing is None or existing.expires_at <= datetime.now(UTC):
                    self._challenge_by_pair.pop(key, None)
                    if existing is not None:
                        self._challenges.pop(existing.id, None)
                    existing = None
                if existing is None:
                    existing_id = None
                elif existing.challenger.id == challenge.challenger.id:
                    return existing.model_copy(deep=True)
                else:
                    raise ApiError(
                        "challengeAlreadyPending",
                        "A challenge is already pending.",
                        status_code=409,
                    )
            for player_id in key:
                active_count = sum(
                    value.expires_at > datetime.now(UTC)
                    and player_id in {value.challenger.id, value.opponent.id}
                    for value in self._challenges.values()
                )
                if active_count >= 20:
                    raise ApiError(
                        "socialLimitReached", "Too many pending challenges.", status_code=409
                    )
            self._challenges[challenge.id] = challenge.model_copy(deep=True)
            self._challenge_by_pair[key] = challenge.id
            self._bump_social_versions(*key)
            return challenge.model_copy(deep=True)

    def accept_challenge(
        self, challenge: StoredChallenge, match: StoredMatch, accepting_user_id: str
    ) -> None:
        with self._lock:
            if challenge.id in self._challenge_results:
                return
            current = self._challenges.get(challenge.id)
            if current is None:
                raise ApiError("challengeNotFound", "The challenge was not found.", status_code=404)
            key = _pair_key(current.challenger.id, current.opponent.id)
            relation = self._social_relations.get(key)
            if (
                accepting_user_id != current.opponent.id
                or relation is None
                or relation.status != SocialRelationStatus.friends
                or current.expires_at <= datetime.now(UTC)
            ):
                raise ApiError(
                    "challengeUnavailable", "The challenge is unavailable.", status_code=409
                )
            self._require_pair_active(*key)
            self.create_match(match)
            self._memberships.setdefault(current.opponent.id, set()).add(match.id)
            self._challenges.pop(challenge.id, None)
            self._challenge_by_pair.pop(key, None)
            self._challenge_results[challenge.id] = match.id
            self._bump_social_versions(*key)

    def cancel_challenge(self, challenge: StoredChallenge, actor_id: str) -> None:
        with self._lock:
            current = self._challenges.get(challenge.id)
            if current is None:
                raise ApiError("challengeNotFound", "The challenge was not found.", status_code=404)
            if actor_id not in {current.challenger.id, current.opponent.id}:
                raise ApiError(
                    "challengeUnavailable", "The challenge is unavailable.", status_code=409
                )
            key = _pair_key(current.challenger.id, current.opponent.id)
            self._challenges.pop(current.id, None)
            self._challenge_by_pair.pop(key, None)
            self._bump_social_versions(*key)

    def _require_active(self, user_id: str) -> None:
        if self._account_states.get(user_id, AccountState.active) != AccountState.active:
            raise ApiError("accountDeleting", "That account is being deleted.", status_code=409)

    def _require_pair_active(self, first_id: str, second_id: str) -> None:
        self._require_active(first_id)
        self._require_active(second_id)

    def _bump_social_versions(self, first_id: str, second_id: str) -> None:
        self._social_versions[first_id] = self._social_versions.get(first_id, 0) + 1
        self._social_versions[second_id] = self._social_versions.get(second_id, 0) + 1

    def _cancel_pair_challenge(self, key: tuple[str, str]) -> None:
        challenge_id = self._challenge_by_pair.pop(key, None)
        if challenge_id is None:
            return
        self._challenges.pop(challenge_id, None)

    def create_match(self, match: StoredMatch) -> None:
        with self._lock:
            self._require_active(match.creator_id)
            if match.black_player is not None:
                self._require_active(match.black_player.id)
            if match.white_player is not None:
                self._require_active(match.white_player.id)
            if match.id in self._matches or match.join_code in self._join_codes:
                raise ApiError("conflict", "The match already exists.", status_code=409)
            self._matches[match.id] = match.model_copy(deep=True)
            self._join_codes[match.join_code] = match.id
            self._memberships.setdefault(match.creator_id, set()).add(match.id)
            self._moves[match.id] = []

    def get_match(self, match_id: str) -> StoredMatch | None:
        with self._lock:
            value = self._matches.get(match_id)
            return value.model_copy(deep=True) if value else None

    def find_by_join_code(self, join_code: str) -> StoredMatch | None:
        match_id = self._join_codes.get(join_code)
        return self.get_match(match_id) if match_id else None

    def list_matches(self, user_id: str) -> list[StoredMatch]:
        with self._lock:
            matches = [
                self._matches[mid].model_copy(deep=True)
                for mid in self._memberships.get(user_id, set())
            ]
        return sorted(matches, key=lambda item: item.updated_at, reverse=True)

    def join_match(self, match: StoredMatch, joining_user_id: str) -> None:
        with self._lock:
            current = self._matches.get(match.id)
            if current is None:
                raise ApiError("matchNotFound", "The match was not found.", status_code=404)
            if current.status.value != "waiting":
                raise ApiError(
                    "matchUnavailable", "The match is no longer waiting.", status_code=409
                )
            self._require_pair_active(current.creator_id, joining_user_id)
            if current.version != match.version - 1:
                raise ApiError(
                    "matchUnavailable", "The match is no longer waiting.", status_code=409
                )
            self._matches[match.id] = match.model_copy(deep=True)
            self._memberships.setdefault(joining_user_id, set()).add(match.id)

    def cancel_waiting_match(self, match: StoredMatch, user_id: str) -> None:
        with self._lock:
            current = self._matches.get(match.id)
            if (
                current is None
                or current.creator_id != user_id
                or current.status.value != "waiting"
                or current.version != match.version
            ):
                raise ApiError(
                    "matchUnavailable",
                    "The waiting match can no longer be cancelled.",
                    status_code=409,
                )
            self._matches.pop(match.id, None)
            self._join_codes.pop(match.join_code, None)
            self._memberships.get(user_id, set()).discard(match.id)
            self._moves.pop(match.id, None)

    def idempotent_result(
        self, user_id: str, key: str, request_fingerprint: str
    ) -> StoredMatch | None:
        with self._lock:
            entry = self._idempotency.get((user_id, key))
            if entry is None:
                return None
            fingerprint, result = entry
            if fingerprint != request_fingerprint:
                raise ApiError(
                    "idempotencyConflict",
                    "That idempotency key was used for a different request.",
                    status_code=409,
                )
            return result.model_copy(deep=True)

    def commit_move(
        self,
        *,
        match: StoredMatch,
        expected_version: int,
        event: MoveEvent,
        user_id: str,
        idempotency_key: str,
        request_fingerprint: str,
        metrics: MatchMetricsLedger | None = None,
        black_stats_version: int | None = None,
        white_stats_version: int | None = None,
        control_version: int | None = None,
    ) -> None:
        with self._lock:
            existing = self._idempotency.get((user_id, idempotency_key))
            if existing is not None:
                if existing[0] != request_fingerprint:
                    raise ApiError(
                        "idempotencyConflict",
                        "That idempotency key was used for a different request.",
                        status_code=409,
                    )
                return
            current = self._matches.get(match.id)
            if current is None:
                raise ApiError("matchNotFound", "The match was not found.", status_code=404)
            if current.version != expected_version:
                raise ApiError(
                    "staleRevision",
                    "The match changed before this move was committed.",
                    status_code=409,
                    details={"currentRevision": current.revision},
                )
            if match.black_player is None or match.white_player is None:
                raise ValueError("an active match requires two players")
            self._require_pair_active(match.black_player.id, match.white_player.id)
            if match.status == MatchStatus.completed and metrics is None:
                raise ApiError(
                    "metricsRequired", "Completed matches require metrics.", status_code=503
                )
            if metrics is not None:
                if (
                    black_stats_version is None
                    or white_stats_version is None
                    or control_version is None
                ):
                    raise ValueError("terminal metrics require expected versions")
                self._validate_metrics_commit(
                    match,
                    metrics,
                    black_stats_version,
                    white_stats_version,
                    control_version,
                )
            self._matches[match.id] = match.model_copy(deep=True)
            self._moves.setdefault(match.id, []).append(event.model_copy(deep=True))
            self._idempotency[(user_id, idempotency_key)] = (
                request_fingerprint,
                match.model_copy(deep=True),
            )
            if metrics is not None:
                self._apply_metrics(match, metrics)

    def commit_resignation(
        self,
        *,
        match: StoredMatch,
        expected_version: int,
        user_id: str,
        idempotency_key: str,
        request_fingerprint: str,
        metrics: MatchMetricsLedger,
        black_stats_version: int,
        white_stats_version: int,
        control_version: int,
        deleting_user_id: str | None = None,
    ) -> None:
        with self._lock:
            existing = self._idempotency.get((user_id, idempotency_key))
            if existing is not None:
                if existing[0] != request_fingerprint:
                    raise ApiError(
                        "idempotencyConflict",
                        "That idempotency key was used for a different request.",
                        status_code=409,
                    )
                return
            current = self._matches.get(match.id)
            if current is None:
                raise ApiError("matchNotFound", "The match was not found.", status_code=404)
            if current.version != expected_version:
                raise ApiError("staleRevision", "The match changed.", status_code=409)
            self._validate_metrics_commit(
                match,
                metrics,
                black_stats_version,
                white_stats_version,
                control_version,
                deleting_user_id=deleting_user_id,
            )
            self._matches[match.id] = match.model_copy(deep=True)
            self._idempotency[(user_id, idempotency_key)] = (
                request_fingerprint,
                match.model_copy(deep=True),
            )
            self._apply_metrics(match, metrics)

    def _validate_metrics_commit(
        self,
        match: StoredMatch,
        metrics: MatchMetricsLedger,
        black_stats_version: int,
        white_stats_version: int,
        control_version: int,
        *,
        deleting_user_id: str | None = None,
    ) -> None:
        _validate_metrics_payload(match, metrics)
        if self._metrics_control.state != MetricsControlState.ready:
            raise ApiError(
                "metricsBackfillInProgress",
                "Rated results are temporarily paused.",
                status_code=503,
            )
        if self._metrics_control.global_version != control_version:
            raise ApiError("metricsConflict", "Rating state changed.", status_code=409)
        if metrics.epoch != self._metrics_control.epoch or metrics.rating_sequence != (
            control_version + 1
        ):
            raise ApiError("metricsConflict", "Rating state changed.", status_code=409)
        if match.id in self._metrics_ledgers:
            raise ApiError("metricsConflict", "Match metrics already exist.", status_code=409)
        if match.black_player is None or match.white_player is None:
            raise ValueError("rated match requires two players")
        for player_id in (match.black_player.id, match.white_player.id):
            state = self._account_states.get(player_id, AccountState.active)
            allowed = (
                {AccountState.active, AccountState.deleting}
                if deleting_user_id is not None
                else {AccountState.active}
            )
            if state not in allowed:
                raise ApiError("metricsConflict", "Player account state changed.", status_code=409)
        black = self._player_stats.get(
            match.black_player.id,
            _default_stats(match.black_player.id),
        )
        white = self._player_stats.get(
            match.white_player.id,
            _default_stats(match.white_player.id),
        )
        if black.version != black_stats_version or white.version != white_stats_version:
            raise ApiError("metricsConflict", "Player rating state changed.", status_code=409)
        if (
            black.rating != metrics.black_rating_before
            or white.rating != metrics.white_rating_before
        ):
            raise ApiError("metricsConflict", "Player rating state changed.", status_code=409)

    def _apply_metrics(self, match: StoredMatch, metrics: MatchMetricsLedger) -> None:
        if match.black_player is None or match.white_player is None:
            raise ValueError("rated match requires two players")
        black = self._player_stats.get(
            match.black_player.id,
            _default_stats(match.black_player.id),
        )
        white = self._player_stats.get(
            match.white_player.id,
            _default_stats(match.white_player.id),
        )
        black_result = _result_counters(metrics.black_score)
        white_result = _result_counters(1.0 - metrics.black_score)
        self._player_stats[black.player_id] = black.model_copy(
            update={
                "rating": metrics.black_rating_after,
                "games": black.games + 1,
                "wins": black.wins + black_result[0],
                "losses": black.losses + black_result[1],
                "draws": black.draws + black_result[2],
                "kills": black.kills + metrics.black_kills,
                "version": black.version + 1,
            }
        )
        self._player_stats[white.player_id] = white.model_copy(
            update={
                "rating": metrics.white_rating_after,
                "games": white.games + 1,
                "wins": white.wins + white_result[0],
                "losses": white.losses + white_result[1],
                "draws": white.draws + white_result[2],
                "kills": white.kills + metrics.white_kills,
                "version": white.version + 1,
            }
        )
        self._metrics_ledgers[match.id] = metrics.model_copy(deep=True)
        self._metrics_control = self._metrics_control.model_copy(
            update={"global_version": metrics.rating_sequence}
        )

    def list_moves(self, match_id: str) -> list[MoveEvent]:
        with self._lock:
            return [move.model_copy(deep=True) for move in self._moves.get(match_id, [])]

    def enqueue(
        self,
        rules_hash: str,
        user_id: str,
        display_name: str,
        rules: dict[str, Any],
        ticket_id: str,
    ) -> None:
        with self._lock:
            self._require_active(user_id)
            active = self.active_matchmaking(user_id)
            if active is not None:
                if active.ticket_id == ticket_id:
                    return
                raise ApiError(
                    "matchmakingConflict",
                    "The player already has an active matchmaking request.",
                    status_code=409,
                    details={"ticketId": active.ticket_id},
                )
            expires_at = datetime.now(UTC) + _MATCHMAKING_WAIT_TTL
            self._queues.setdefault(rules_hash, []).append(
                (user_id, display_name, rules, ticket_id, expires_at)
            )
            self._active_ticket_by_user[user_id] = ticket_id
            self._matchmaking_records[(user_id, ticket_id)] = MatchmakingRecord(
                ticket_id=ticket_id,
                status="waiting",
                rules_hash=rules_hash,
                queue_sk=ticket_id,
                match_id=None,
                expires_at=expires_at,
            )

    def pop_opponent(
        self, rules_hash: str, user_id: str
    ) -> tuple[str, str, dict[str, Any], str] | None:
        with self._lock:
            queue = self._queues.setdefault(rules_hash, [])
            now = datetime.now(UTC)
            queue[:] = [
                candidate for candidate in queue if self._keep_live_candidate(candidate, now)
            ]
            for candidate in queue:
                opponent_id, opponent_name, opponent_rules, ticket_id, _ = candidate
                record = self._matchmaking_records.get((opponent_id, ticket_id))
                if opponent_id != user_id and record is not None and record.status == "waiting":
                    self._matchmaking_records[(opponent_id, ticket_id)] = MatchmakingRecord(
                        ticket_id=ticket_id,
                        status="claimed",
                        rules_hash=rules_hash,
                        queue_sk=record.queue_sk,
                        match_id=None,
                        expires_at=now + _MATCHMAKING_WAIT_TTL,
                    )
                    return opponent_id, opponent_name, opponent_rules, ticket_id
            return None

    def _keep_live_candidate(
        self,
        candidate: tuple[str, str, dict[str, Any], str, datetime],
        now: datetime,
    ) -> bool:
        user_id, _, _, ticket_id, expires_at = candidate
        if expires_at > now:
            return True
        if self._active_ticket_by_user.get(user_id) == ticket_id:
            self._active_ticket_by_user.pop(user_id, None)
        self._matchmaking_records.pop((user_id, ticket_id), None)
        return False

    def active_matchmaking(self, user_id: str) -> MatchmakingRecord | None:
        with self._lock:
            ticket_id = self._active_ticket_by_user.get(user_id)
            if ticket_id is None:
                return None
            return self.matchmaking_status(user_id, ticket_id)

    def matchmaking_status(self, user_id: str, ticket_id: str) -> MatchmakingRecord | None:
        with self._lock:
            record = self._matchmaking_records.get((user_id, ticket_id))
            if record is None:
                return None
            if record.expires_at > datetime.now(UTC):
                return record
            self.remove_from_queue(user_id, ticket_id)
            self._matchmaking_records.pop((user_id, ticket_id), None)
            return None

    def commit_quick_match(
        self,
        match: StoredMatch,
        joining_user_id: str,
        requester_ticket_id: str,
        opponent_ticket_id: str,
    ) -> None:
        with self._lock:
            opponent_id = match.creator_id
            self._require_pair_active(opponent_id, joining_user_id)
            claimed = self._matchmaking_records.get((opponent_id, opponent_ticket_id))
            if claimed is None or claimed.status != "claimed":
                raise ApiError(
                    "matchmakingConflict",
                    "The opponent is no longer reserved for this match.",
                    status_code=409,
                )
            if match.id in self._matches or match.join_code in self._join_codes:
                raise ApiError("conflict", "The match already exists.", status_code=409)

            self._matches[match.id] = match.model_copy(deep=True)
            self._join_codes[match.join_code] = match.id
            self._memberships.setdefault(opponent_id, set()).add(match.id)
            self._memberships.setdefault(joining_user_id, set()).add(match.id)
            self._moves[match.id] = []
            if claimed.rules_hash is not None:
                self._queues[claimed.rules_hash] = [
                    entry
                    for entry in self._queues.get(claimed.rules_hash, [])
                    if not (entry[0] == opponent_id and entry[3] == opponent_ticket_id)
                ]
            if self._active_ticket_by_user.get(opponent_id) == opponent_ticket_id:
                self._active_ticket_by_user.pop(opponent_id, None)
            expires_at = datetime.now(UTC) + _MATCHMAKING_RESULT_TTL
            self._matchmaking_records[(opponent_id, opponent_ticket_id)] = MatchmakingRecord(
                ticket_id=opponent_ticket_id,
                status="matched",
                rules_hash=claimed.rules_hash,
                queue_sk=claimed.queue_sk,
                match_id=match.id,
                expires_at=expires_at,
            )
            self._matchmaking_records[(joining_user_id, requester_ticket_id)] = MatchmakingRecord(
                ticket_id=requester_ticket_id,
                status="matched",
                rules_hash=claimed.rules_hash,
                queue_sk=None,
                match_id=match.id,
                expires_at=expires_at,
            )

    def release_matchmaking_claim(self, user_id: str, ticket_id: str) -> None:
        with self._lock:
            current = self._matchmaking_records.get((user_id, ticket_id))
            if current is None or current.status != "claimed":
                return
            expires_at = datetime.now(UTC) + _MATCHMAKING_WAIT_TTL
            self._matchmaking_records[(user_id, ticket_id)] = MatchmakingRecord(
                ticket_id=ticket_id,
                status="waiting",
                rules_hash=current.rules_hash,
                queue_sk=current.queue_sk,
                match_id=None,
                expires_at=expires_at,
            )
            if current.rules_hash is not None:
                queue = self._queues.get(current.rules_hash, [])
                for index, entry in enumerate(queue):
                    if entry[0] == user_id and entry[3] == ticket_id:
                        queue[index] = (*entry[:4], expires_at)
                        break

    def remove_from_queue(self, user_id: str, ticket_id: str) -> bool:
        with self._lock:
            if self._active_ticket_by_user.get(user_id) != ticket_id:
                return False
            record = self._matchmaking_records.get((user_id, ticket_id))
            if record is None or record.status not in {"waiting", "claimed"}:
                return False
            self._active_ticket_by_user.pop(user_id, None)
            if record is not None and record.rules_hash is not None:
                rules_hash = record.rules_hash
                self._queues[rules_hash] = [
                    entry
                    for entry in self._queues.get(rules_hash, [])
                    if not (entry[0] == user_id and entry[3] == ticket_id)
                ]
            self._matchmaking_records.pop((user_id, ticket_id), None)
            return True

    def acquire_matchmaking_lock(self, user_id: str) -> str | None:
        with self._lock:
            if user_id in self._matchmaking_locks:
                return None
            token = secrets.token_urlsafe(18)
            self._matchmaking_locks[user_id] = token
            return token

    def release_matchmaking_lock(self, user_id: str, token: str) -> None:
        with self._lock:
            if self._matchmaking_locks.get(user_id) == token:
                self._matchmaking_locks.pop(user_id, None)

    def put_exchange(self, exchange: StoredExchange) -> None:
        with self._lock:
            self._exchanges[exchange.code] = exchange

    def consume_exchange(self, code: str) -> StoredExchange | None:
        with self._lock:
            exchange = self._exchanges.pop(code, None)
            if exchange is None or exchange.expires_at <= datetime.now(UTC):
                return None
            return exchange

    def put_oauth_transaction(self, transaction: StoredOAuthTransaction) -> None:
        with self._lock:
            self._oauth_transactions[transaction.id] = transaction.model_copy(deep=True)

    def consume_oauth_transaction(self, transaction_id: str) -> StoredOAuthTransaction | None:
        with self._lock:
            transaction = self._oauth_transactions.pop(transaction_id, None)
            if transaction is None or transaction.expires_at <= datetime.now(UTC):
                return None
            return transaction

    def upsert_push_subscription(
        self, subscription: StoredPushSubscription
    ) -> StoredPushSubscription:
        with self._lock:
            if (
                subscription.user_id in self._deleted_users
                or self.account_state(subscription.user_id) != AccountState.active
            ):
                raise ApiError(
                    "pushSubscriptionConflict",
                    "That account can no longer register notifications.",
                    status_code=409,
                )
            previous_owner = self._installation_owners.get(subscription.installation_id)
            if previous_owner is not None and previous_owner != subscription.user_id:
                self._push_subscriptions.pop(
                    (previous_owner, subscription.installation_id),
                    None,
                )
            existing = self._push_subscriptions.get(
                (subscription.user_id, subscription.installation_id)
            )
            stored = subscription.model_copy(
                update={"created_at": existing.created_at if existing else subscription.created_at}
            )
            self._push_subscriptions[(subscription.user_id, subscription.installation_id)] = (
                stored.model_copy(deep=True)
            )
            self._installation_owners[subscription.installation_id] = subscription.user_id
            return stored.model_copy(deep=True)

    def list_push_subscriptions(self, user_id: str) -> list[StoredPushSubscription]:
        with self._lock:
            subscriptions = [
                subscription.model_copy(deep=True)
                for (owner_id, _), subscription in self._push_subscriptions.items()
                if owner_id == user_id
            ]
        return sorted(subscriptions, key=lambda value: value.created_at)

    def get_push_subscription(
        self, user_id: str, installation_id: str
    ) -> StoredPushSubscription | None:
        with self._lock:
            subscription = self._push_subscriptions.get((user_id, installation_id))
            return subscription.model_copy(deep=True) if subscription is not None else None

    def delete_push_subscription(self, user_id: str, installation_id: str) -> None:
        with self._lock:
            self._push_subscriptions.pop((user_id, installation_id), None)
            if self._installation_owners.get(installation_id) == user_id:
                self._installation_owners.pop(installation_id, None)

    def delete_push_subscription_if_unchanged(self, subscription: StoredPushSubscription) -> bool:
        with self._lock:
            key = (subscription.user_id, subscription.installation_id)
            if self._push_subscriptions.get(key) != subscription:
                return False
            self._push_subscriptions.pop(key, None)
            if self._installation_owners.get(subscription.installation_id) == subscription.user_id:
                self._installation_owners.pop(subscription.installation_id, None)
            return True

    def claim_notification_delivery(self, delivery_id: str) -> str | None:
        with self._lock:
            now = datetime.now(UTC)
            existing = self._notification_deliveries.get(delivery_id)
            if existing is not None:
                state, lease_expires_at, _ = existing
                if state == "delivered" or lease_expires_at > now:
                    return None
            claim_token = secrets.token_urlsafe(18)
            self._notification_deliveries[delivery_id] = (
                "sending",
                now + timedelta(minutes=5),
                claim_token,
            )
            return claim_token

    def complete_notification_delivery(self, delivery_id: str, claim_token: str) -> None:
        with self._lock:
            current = self._notification_deliveries.get(delivery_id)
            if current is None or current[2] != claim_token:
                return
            self._notification_deliveries[delivery_id] = (
                "delivered",
                datetime.now(UTC) + timedelta(days=7),
                claim_token,
            )

    def release_notification_delivery(self, delivery_id: str, claim_token: str) -> None:
        with self._lock:
            current = self._notification_deliveries.get(delivery_id)
            if current is not None and current[0] == "sending" and current[2] == claim_token:
                self._notification_deliveries.pop(delivery_id, None)

    def delete_user_data(self, user_id: str) -> None:
        with self._lock:
            matches = [
                self._matches[match_id]
                for match_id in self._memberships.get(user_id, set())
                if match_id in self._matches
            ]
            if any(match.status != MatchStatus.completed for match in matches):
                raise ApiError(
                    "accountDeletionConflict",
                    "All active matches must end before account data can be deleted.",
                    status_code=409,
                )

            self._deleted_users.add(user_id)
            anonymous_ids: dict[str, str] = {}
            for match in matches:
                anonymous_id = f"deleted-{uuid4()}"
                anonymous_ids[match.id] = anonymous_id
                anonymized = _anonymize_match(match, user_id, anonymous_id)
                self._matches[match.id] = anonymized
                self._moves[match.id] = [
                    _anonymize_move(move, user_id, anonymous_id)
                    for move in self._moves.get(match.id, [])
                ]

            self._memberships.pop(user_id, None)
            retained_idempotency: dict[tuple[str, str], tuple[str, StoredMatch]] = {}
            for key, value in self._idempotency.items():
                if key[0] == user_id:
                    continue
                fingerprint, snapshot = value
                snapshot_anonymous_id = anonymous_ids.get(snapshot.id)
                if snapshot_anonymous_id is not None:
                    snapshot = _anonymize_match(snapshot, user_id, snapshot_anonymous_id)
                retained_idempotency[key] = (fingerprint, snapshot)
            self._idempotency = retained_idempotency
            for rules_hash, queue in self._queues.items():
                self._queues[rules_hash] = [entry for entry in queue if entry[0] != user_id]
            self._active_ticket_by_user.pop(user_id, None)
            self._matchmaking_records = {
                key: value for key, value in self._matchmaking_records.items() if key[0] != user_id
            }
            self._matchmaking_locks.pop(user_id, None)

            relation_keys = [
                key
                for key, relation in self._social_relations.items()
                if relation.includes(user_id)
            ]
            for key in relation_keys:
                other_id = key[1] if key[0] == user_id else key[0]
                self._cancel_pair_challenge(key)
                self._social_relations.pop(key, None)
                self._social_versions[other_id] = self._social_versions.get(other_id, 0) + 1
            challenge_ids = [
                challenge.id
                for challenge in self._challenges.values()
                if user_id in {challenge.challenger.id, challenge.opponent.id}
            ]
            for challenge_id in challenge_ids:
                challenge = self._challenges.pop(challenge_id)
                key = _pair_key(challenge.challenger.id, challenge.opponent.id)
                self._challenge_by_pair.pop(key, None)
                other_id = (
                    challenge.opponent.id
                    if challenge.challenger.id == user_id
                    else challenge.challenger.id
                )
                self._social_versions[other_id] = self._social_versions.get(other_id, 0) + 1
            # Accepted challenge results contain only challengeId -> matchId,
            # matching Dynamo's seven-day recovery pointer. They remain useful
            # after anonymization and carry no account identity.
            self._public_players.pop(user_id, None)
            self._player_stats.pop(user_id, None)
            self._social_versions.pop(user_id, None)
            self._search_rates = {
                key: count for key, count in self._search_rates.items() if key[0] != user_id
            }
            self._avatar_upload_rates = {
                key: count for key, count in self._avatar_upload_rates.items() if key[0] != user_id
            }

            installation_ids = [
                installation_id
                for owner_id, installation_id in self._push_subscriptions
                if owner_id == user_id
            ]
            for installation_id in installation_ids:
                self._push_subscriptions.pop((user_id, installation_id), None)
                if self._installation_owners.get(installation_id) == user_id:
                    self._installation_owners.pop(installation_id, None)


class DynamoRepository:
    """Single-table DynamoDB implementation used by the Lambda deployment."""

    def __init__(self, settings: Settings) -> None:
        self._dynamodb = boto3.resource("dynamodb", region_name=settings.aws_region)
        self._table = self._dynamodb.Table(settings.table_name)
        # Transaction payloads below use explicit DynamoDB AttributeValue maps.
        # A resource-backed Table client installs an additional serializer and
        # would encode those maps a second time (for example, S keys as M).
        self._client = boto3.client("dynamodb", region_name=settings.aws_region)
        self._table_name = settings.table_name

    @staticmethod
    def _match_item(match: StoredMatch) -> dict[str, Any]:
        return {
            "PK": f"MATCH#{match.id}",
            "SK": "STATE",
            "entity": "match",
            "revision": match.revision,
            "version": match.version,
            "status": match.status.value,
            "creatorId": match.creator_id,
            "document": match.model_dump_json(by_alias=True),
        }

    @staticmethod
    def _parse_match(item: dict[str, Any] | None) -> StoredMatch | None:
        if not item:
            return None
        return StoredMatch.model_validate_json(item["document"])

    @staticmethod
    def _account_key(user_id: str) -> dict[str, str]:
        # Retain a durable anti-reactivation fence without retaining the raw
        # Cognito subject after the account's data has been removed.
        digest = hashlib.sha256(user_id.encode()).hexdigest()
        return {"PK": f"ACCOUNT#{digest}", "SK": "STATE"}

    @staticmethod
    def _profile_key(user_id: str) -> dict[str, str]:
        return {"PK": f"PLAYER#{user_id}", "SK": "PROFILE"}

    @staticmethod
    def _stats_key(user_id: str) -> dict[str, str]:
        return {"PK": f"PLAYER#{user_id}", "SK": "STATS"}

    @staticmethod
    def _avatar_pointer_key(user_id: str) -> dict[str, str]:
        digest = hashlib.sha256(user_id.encode()).hexdigest()
        return {"PK": f"ACCOUNT#{digest}", "SK": "AVATAR"}

    @staticmethod
    def _search_keys(player: StoredPublicPlayer) -> list[dict[str, str]]:
        name = player.normalized_display_name
        return [
            {
                "PK": f"SEARCH#{name[:length]}",
                "SK": f"{name}#{player.id}",
            }
            for length in range(1, min(3, len(name)) + 1)
        ]

    @staticmethod
    def _pair_partition(first_id: str, second_id: str) -> str:
        first, second = _pair_key(first_id, second_id)
        return f"PAIR#{first}#{second}"

    @classmethod
    def _relation_key(cls, first_id: str, second_id: str) -> dict[str, str]:
        return {"PK": cls._pair_partition(first_id, second_id), "SK": "RELATION"}

    @classmethod
    def _challenge_pointer_key(cls, first_id: str, second_id: str) -> dict[str, str]:
        return {"PK": cls._pair_partition(first_id, second_id), "SK": "CHALLENGE"}

    @staticmethod
    def _challenge_key(challenge_id: str) -> dict[str, str]:
        return {"PK": f"CHALLENGE#{challenge_id}", "SK": "STATE"}

    @staticmethod
    def _challenge_result_key(challenge_id: str) -> dict[str, str]:
        return {"PK": f"CHALLENGE#{challenge_id}", "SK": "RESULT"}

    @staticmethod
    def _social_state_key(user_id: str) -> dict[str, str]:
        return {"PK": f"USER#{user_id}", "SK": "SOCIAL#STATE"}

    @staticmethod
    def _relation_projection_key(user_id: str, other_id: str) -> dict[str, str]:
        return {"PK": f"USER#{user_id}", "SK": f"SOCIAL#RELATION#{other_id}"}

    @staticmethod
    def _challenge_projection_key(user_id: str, challenge_id: str) -> dict[str, str]:
        return {"PK": f"USER#{user_id}", "SK": f"SOCIAL#CHALLENGE#{challenge_id}"}

    def _account_conditions(self, user_id: str) -> list[dict[str, Any]]:
        return [
            {
                "ConditionCheck": {
                    "TableName": self._table_name,
                    "Key": _serialize(self._account_key(user_id)),
                    "ConditionExpression": ("attribute_not_exists(PK) OR #accountState = :active"),
                    "ExpressionAttributeNames": {"#accountState": "state"},
                    "ExpressionAttributeValues": _serialize_values({":active": "active"}),
                }
            },
            {
                # Rolling-deploy compatibility: the previous Lambda writes only
                # this short-lived raw-sub guard when deletion starts.
                "ConditionCheck": {
                    "TableName": self._table_name,
                    "Key": _serialize({"PK": f"USER#{user_id}", "SK": "ACCOUNT_DELETED"}),
                    "ConditionExpression": ("attribute_not_exists(PK) OR expiresAt <= :now"),
                    "ExpressionAttributeValues": _serialize_values(
                        {":now": int(datetime.now(UTC).timestamp())}
                    ),
                }
            },
        ]

    def _social_state(self, user_id: str) -> dict[str, int]:
        item = self._table.get_item(Key=self._social_state_key(user_id), ConsistentRead=True).get(
            "Item", {}
        )
        return {
            "version": int(item.get("version", 0)),
            "pendingCount": int(item.get("pendingCount", 0)),
            "friendCount": int(item.get("friendCount", 0)),
            "challengeCount": int(item.get("challengeCount", 0)),
        }

    def _social_state_update(
        self,
        user_id: str,
        *,
        version: int,
        pending_delta: int = 0,
        friend_delta: int = 0,
        challenge_delta: int = 0,
        pending_limit: int | None = None,
        friend_limit: int | None = None,
        challenge_limit: int | None = None,
    ) -> dict[str, Any]:
        names = {
            "#version": "version",
            "#pending": "pendingCount",
            "#friends": "friendCount",
            "#challenges": "challengeCount",
        }
        values: dict[str, Any] = {
            ":zero": 0,
            ":one": 1,
            ":version": version,
            ":pendingDelta": pending_delta,
            ":friendDelta": friend_delta,
            ":challengeDelta": challenge_delta,
        }
        conditions = ["(attribute_not_exists(#version) OR #version = :version)"]
        if pending_delta < 0:
            conditions.append("#pending >= :pendingRequired")
            values[":pendingRequired"] = -pending_delta
        elif pending_limit is not None:
            conditions.append("(attribute_not_exists(#pending) OR #pending < :pendingLimit)")
            values[":pendingLimit"] = pending_limit
        if friend_delta < 0:
            conditions.append("#friends >= :friendRequired")
            values[":friendRequired"] = -friend_delta
        elif friend_limit is not None:
            conditions.append("(attribute_not_exists(#friends) OR #friends < :friendLimit)")
            values[":friendLimit"] = friend_limit
        if challenge_delta < 0:
            conditions.append("#challenges >= :challengeRequired")
            values[":challengeRequired"] = -challenge_delta
        elif challenge_limit is not None:
            conditions.append(
                "(attribute_not_exists(#challenges) OR #challenges < :challengeLimit)"
            )
            values[":challengeLimit"] = challenge_limit
        return {
            "Update": {
                "TableName": self._table_name,
                "Key": _serialize(self._social_state_key(user_id)),
                "UpdateExpression": (
                    "SET entity = :entity, #version = if_not_exists(#version, :zero) + :one, "
                    "#pending = if_not_exists(#pending, :zero) + :pendingDelta, "
                    "#friends = if_not_exists(#friends, :zero) + :friendDelta, "
                    "#challenges = if_not_exists(#challenges, :zero) + :challengeDelta"
                ),
                "ConditionExpression": " AND ".join(conditions),
                "ExpressionAttributeNames": names,
                "ExpressionAttributeValues": _serialize_values(
                    {**values, ":entity": "socialState"}
                ),
            }
        }

    def account_state(self, user_id: str) -> AccountState:
        item = self._table.get_item(Key=self._account_key(user_id), ConsistentRead=True).get("Item")
        if item is not None:
            state = AccountState(str(item.get("state", AccountState.active.value)))
            if state != AccountState.active:
                return state
        legacy = self._table.get_item(
            Key={"PK": f"USER#{user_id}", "SK": "ACCOUNT_DELETED"},
            ConsistentRead=True,
        ).get("Item")
        if legacy is not None and int(legacy.get("expiresAt", 0)) > int(
            datetime.now(UTC).timestamp()
        ):
            return AccountState.deleting
        return AccountState.active

    def begin_user_deletion(self, user_id: str) -> None:
        profile_item = self._table.get_item(
            Key=self._profile_key(user_id), ConsistentRead=True
        ).get("Item")
        transaction: list[dict[str, Any]] = [
            {
                "Put": {
                    "TableName": self._table_name,
                    "Item": _serialize(
                        {
                            **self._account_key(user_id),
                            "entity": "accountState",
                            "state": AccountState.deleting.value,
                            "updatedAt": datetime.now(UTC).isoformat(),
                        }
                    ),
                    "ConditionExpression": (
                        "attribute_not_exists(PK) OR #accountState IN (:active, :deleting)"
                    ),
                    "ExpressionAttributeNames": {"#accountState": "state"},
                    "ExpressionAttributeValues": _serialize_values(
                        {":active": "active", ":deleting": "deleting"}
                    ),
                }
            },
            {
                "Put": {
                    "TableName": self._table_name,
                    "Item": _serialize(
                        {
                            "PK": f"USER#{user_id}",
                            "SK": "ACCOUNT_DELETED",
                            "entity": "accountDeletionGuard",
                            "expiresAt": int((datetime.now(UTC) + timedelta(days=1)).timestamp()),
                        }
                    ),
                }
            },
            {
                "Delete": {
                    "TableName": self._table_name,
                    "Key": _serialize(self._avatar_pointer_key(user_id)),
                }
            },
        ]
        if profile_item is not None:
            profile = StoredPublicPlayer.model_validate_json(profile_item["document"])
            transaction.extend(
                {
                    "Delete": {
                        "TableName": self._table_name,
                        "Key": _serialize(key),
                    }
                }
                for key in self._search_keys(profile)
            )
        self._client.transact_write_items(TransactItems=transaction)
        # The profile may have changed after the pre-fence read but before this
        # transaction won. Once ACCOUNT_STATE is deleting, profile/index writes
        # cannot commit, so a strong post-fence read identifies the final key.
        current_profile_item = self._table.get_item(
            Key=self._profile_key(user_id), ConsistentRead=True
        ).get("Item")
        if current_profile_item is not None:
            current_profile = StoredPublicPlayer.model_validate_json(
                current_profile_item["document"]
            )
            for key in self._search_keys(current_profile):
                try:
                    self._table.delete_item(
                        Key=key,
                        ConditionExpression="playerId = :playerId",
                        ExpressionAttributeValues={":playerId": user_id},
                    )
                except ClientError as error:
                    if error.response["Error"]["Code"] != "ConditionalCheckFailedException":
                        raise

    def upsert_public_player(self, player: StoredPublicPlayer) -> None:
        for _ in range(4):
            existing_item = self._table.get_item(
                Key=self._profile_key(player.id), ConsistentRead=True
            ).get("Item")
            existing = (
                StoredPublicPlayer.model_validate_json(existing_item["document"])
                if existing_item is not None
                else None
            )
            profile_changed = existing is None or (
                existing.display_name != player.display_name
                or existing.normalized_display_name != player.normalized_display_name
                or not existing.discoverable
                or existing.discoverability_updated_at is not None
            )
            if existing is None:
                stored = player.model_copy(
                    update={
                        "discoverable": True,
                        "discoverability_updated_at": None,
                        "version": 0,
                        "avatar_key": None,
                        "avatar_version": 0,
                    },
                    deep=True,
                )
            elif profile_changed:
                stored = existing.model_copy(
                    update={
                        "display_name": player.display_name,
                        "normalized_display_name": player.normalized_display_name,
                        "discoverable": True,
                        "discoverability_updated_at": None,
                        "version": existing.version + 1,
                    },
                    deep=True,
                )
            else:
                # Login and /me may index the same authenticated profile from
                # several tabs. A literal no-op avoids racing an avatar CAS and
                # needlessly consuming a DynamoDB transaction. The public
                # cutover migration is responsible for repairing legacy rows.
                return
            if existing is None:
                profile_operation: dict[str, Any] = {
                    "Put": {
                        "TableName": self._table_name,
                        "Item": _serialize(
                            {
                                **self._profile_key(player.id),
                                "entity": "publicPlayer",
                                "version": stored.version,
                                "discoverable": True,
                                "document": stored.model_dump_json(by_alias=True),
                            }
                        ),
                        "ConditionExpression": "attribute_not_exists(PK)",
                    }
                }
            else:
                guard = {
                    "ConditionExpression": (
                        "#version = :expectedVersion AND #document = :expectedDocument"
                    ),
                    "ExpressionAttributeNames": {
                        "#version": "version",
                        "#document": "document",
                    },
                    "ExpressionAttributeValues": _serialize_values(
                        {
                            ":expectedVersion": existing.version,
                            ":expectedDocument": str(existing_item["document"]),
                        }
                    ),
                }
                profile_operation = {
                    "Put": {
                        "TableName": self._table_name,
                        "Item": _serialize(
                            {
                                **self._profile_key(player.id),
                                "entity": "publicPlayer",
                                "version": stored.version,
                                "discoverable": True,
                                "document": stored.model_dump_json(by_alias=True),
                            }
                        ),
                        **guard,
                    }
                }
            transaction: list[dict[str, Any]] = [
                *self._account_conditions(player.id),
                profile_operation,
                {
                    "Update": {
                        "TableName": self._table_name,
                        "Key": _serialize(self._stats_key(player.id)),
                        "UpdateExpression": (
                            "SET entity = if_not_exists(entity, :entity), "
                            "playerId = if_not_exists(playerId, :playerId), "
                            "rating = if_not_exists(rating, :rating), "
                            "games = if_not_exists(games, :zero), "
                            "wins = if_not_exists(wins, :zero), "
                            "losses = if_not_exists(losses, :zero), "
                            "draws = if_not_exists(draws, :zero), "
                            "kills = if_not_exists(kills, :zero), "
                            "#version = if_not_exists(#version, :zero)"
                        ),
                        "ExpressionAttributeNames": {"#version": "version"},
                        "ExpressionAttributeValues": _serialize_values(
                            {
                                ":entity": "playerStats",
                                ":playerId": player.id,
                                ":rating": 1200,
                                ":zero": 0,
                            }
                        ),
                    }
                },
            ]
            new_search_keys = self._search_keys(stored)
            new_search_pairs = {(value["PK"], value["SK"]) for value in new_search_keys}
            if existing is not None:
                transaction.extend(
                    {
                        "Delete": {
                            "TableName": self._table_name,
                            "Key": _serialize(key),
                        }
                    }
                    for key in self._search_keys(existing)
                    if (key["PK"], key["SK"]) not in new_search_pairs
                )
            transaction.extend(
                {
                    "Put": {
                        "TableName": self._table_name,
                        "Item": _serialize(
                            {
                                **key,
                                "entity": "playerSearch",
                                "playerId": stored.id,
                                "document": stored.model_dump_json(by_alias=True),
                            }
                        ),
                    }
                }
                for key in new_search_keys
            )
            try:
                self._client.transact_write_items(TransactItems=transaction)
                return
            except ClientError as error:
                if error.response["Error"]["Code"] != "TransactionCanceledException":
                    raise
                if self.account_state(player.id) == AccountState.deleting:
                    raise ApiError(
                        "accountDeleting",
                        "That account is being deleted.",
                        status_code=409,
                    ) from error
        raise ApiError("profileConflict", "The player profile changed. Retry.", status_code=409)

    def get_public_player(self, player_id: str) -> StoredPublicPlayer | None:
        if self.account_state(player_id) != AccountState.active:
            return None
        item = self._table.get_item(Key=self._profile_key(player_id), ConsistentRead=True).get(
            "Item"
        )
        if item is None:
            return None
        return StoredPublicPlayer.model_validate_json(item["document"])

    def get_public_players(self, player_ids: set[str]) -> dict[str, StoredPublicPlayer]:
        if not player_ids:
            return {}
        keys: list[dict[str, str]] = []
        now = int(datetime.now(UTC).timestamp())
        for player_id in sorted(player_ids):
            keys.extend(
                [
                    self._profile_key(player_id),
                    self._account_key(player_id),
                    {"PK": f"USER#{player_id}", "SK": "ACCOUNT_DELETED"},
                ]
            )
        items = self._batch_get(keys)
        by_key = {(str(item["PK"]), str(item["SK"])): item for item in items}
        found: dict[str, StoredPublicPlayer] = {}
        for player_id in player_ids:
            account = by_key.get(
                (f"ACCOUNT#{hashlib.sha256(player_id.encode()).hexdigest()}", "STATE")
            )
            legacy = by_key.get((f"USER#{player_id}", "ACCOUNT_DELETED"))
            if account is not None and account.get("state") != AccountState.active.value:
                continue
            if legacy is not None and int(legacy.get("expiresAt", 0)) > now:
                continue
            item = by_key.get((f"PLAYER#{player_id}", "PROFILE"))
            if item is not None and isinstance(item.get("document"), str):
                found[player_id] = StoredPublicPlayer.model_validate_json(item["document"])
        return found

    def set_player_discoverability(self, user_id: str, discoverable: bool) -> tuple[bool, int]:
        del discoverable
        for _ in range(4):
            item = self._table.get_item(Key=self._profile_key(user_id), ConsistentRead=True).get(
                "Item"
            )
            if item is None:
                raise ApiError("playerUnavailable", "That player is unavailable.", status_code=404)
            player = StoredPublicPlayer.model_validate_json(item["document"])
            state = self._social_state(user_id)
            if player.discoverable:
                return True, state["version"]
            updated = player.model_copy(
                update={
                    "discoverable": True,
                    "discoverability_updated_at": None,
                    "version": player.version + 1,
                }
            )
            transaction: list[dict[str, Any]] = [
                *self._account_conditions(user_id),
                {
                    "Put": {
                        "TableName": self._table_name,
                        "Item": _serialize(
                            {
                                **self._profile_key(user_id),
                                "entity": "publicPlayer",
                                "version": updated.version,
                                "discoverable": True,
                                "document": updated.model_dump_json(by_alias=True),
                            }
                        ),
                        "ConditionExpression": "#version = :version",
                        "ExpressionAttributeNames": {"#version": "version"},
                        "ExpressionAttributeValues": _serialize_values(
                            {":version": player.version}
                        ),
                    }
                },
                self._social_state_update(user_id, version=state["version"]),
            ]
            transaction.extend(
                {
                    "Put": {
                        "TableName": self._table_name,
                        "Item": _serialize(
                            {
                                **key,
                                "entity": "playerSearch",
                                "playerId": user_id,
                                "document": updated.model_dump_json(by_alias=True),
                            }
                        ),
                    }
                }
                for key in self._search_keys(updated)
            )
            try:
                self._client.transact_write_items(TransactItems=transaction)
                return True, state["version"] + 1
            except ClientError as error:
                if error.response["Error"]["Code"] != "TransactionCanceledException":
                    raise
                if self.account_state(user_id) == AccountState.deleting:
                    raise ApiError(
                        "accountDeleting",
                        "That account is being deleted.",
                        status_code=409,
                    ) from error
        raise ApiError("socialConflict", "The social profile changed. Retry.", status_code=409)

    def set_player_avatar(
        self,
        user_id: str,
        *,
        avatar_key: str | None,
        expected_profile_version: int,
    ) -> StoredPublicPlayer:
        item = self._table.get_item(Key=self._profile_key(user_id), ConsistentRead=True).get("Item")
        if item is None:
            raise ApiError("playerUnavailable", "That player is unavailable.", status_code=404)
        player = StoredPublicPlayer.model_validate_json(item["document"])
        if player.version != expected_profile_version:
            raise ApiError("profileConflict", "The player profile changed. Retry.", status_code=409)
        updated = player.model_copy(
            update={
                "avatar_key": avatar_key,
                "avatar_version": player.avatar_version + 1,
                "version": player.version + 1,
                "discoverable": True,
                "discoverability_updated_at": None,
            },
            deep=True,
        )
        transaction = [
            *self._account_conditions(user_id),
            {
                "Put": {
                    "TableName": self._table_name,
                    "Item": _serialize(
                        {
                            **self._profile_key(user_id),
                            "entity": "publicPlayer",
                            "version": updated.version,
                            "discoverable": True,
                            "document": updated.model_dump_json(by_alias=True),
                        }
                    ),
                    "ConditionExpression": "#version = :version",
                    "ExpressionAttributeNames": {"#version": "version"},
                    "ExpressionAttributeValues": _serialize_values(
                        {":version": expected_profile_version}
                    ),
                }
            },
            *[
                {
                    "Put": {
                        "TableName": self._table_name,
                        "Item": _serialize(
                            {
                                **key,
                                "entity": "playerSearch",
                                "playerId": user_id,
                                "document": updated.model_dump_json(by_alias=True),
                            }
                        ),
                    }
                }
                for key in self._search_keys(updated)
            ],
        ]
        transaction.append(
            {
                "Put": {
                    "TableName": self._table_name,
                    "Item": _serialize(
                        {
                            **self._avatar_pointer_key(user_id),
                            "entity": "avatarPointer",
                            "avatarKey": avatar_key,
                            "avatarVersion": updated.avatar_version,
                        }
                    ),
                }
            }
            if avatar_key is not None
            else {
                "Delete": {
                    "TableName": self._table_name,
                    "Key": _serialize(self._avatar_pointer_key(user_id)),
                }
            }
        )
        try:
            self._client.transact_write_items(TransactItems=transaction)
        except ClientError as error:
            if error.response["Error"]["Code"] != "TransactionCanceledException":
                raise
            if self.account_state(user_id) == AccountState.deleting:
                raise ApiError(
                    "accountDeleting",
                    "That account is being deleted.",
                    status_code=409,
                ) from error
            raise ApiError(
                "profileConflict", "The player profile changed. Retry.", status_code=409
            ) from error
        return updated

    def search_public_players(
        self, normalized_prefix: str, *, limit: int
    ) -> list[StoredPublicPlayer]:
        prefix = normalized_prefix[: min(3, len(normalized_prefix))]
        query: dict[str, Any] = {
            "KeyConditionExpression": Key("PK").eq(f"SEARCH#{prefix}")
            & Key("SK").begins_with(normalized_prefix),
            "ConsistentRead": True,
            "Limit": max(limit * 2, 20),
        }
        found: list[StoredPublicPlayer] = []
        seen: set[str] = set()
        while len(found) < limit:
            response = self._table.query(**query)
            candidates = [str(item["playerId"]) for item in response.get("Items", [])]
            profiles = self.get_public_players(set(candidates))
            for player_id in candidates:
                player = profiles.get(player_id)
                if (
                    player is not None
                    and player.normalized_display_name.startswith(normalized_prefix)
                    and player_id not in seen
                ):
                    found.append(player)
                    seen.add(player_id)
                    if len(found) == limit:
                        break
            last_key = response.get("LastEvaluatedKey")
            if not last_key or len(found) == limit:
                break
            query["ExclusiveStartKey"] = last_key
        return found

    def check_player_search_rate(self, user_id: str) -> None:
        minute = int(datetime.now(UTC).timestamp()) // 60
        try:
            self._table.update_item(
                Key={"PK": f"RATE#{user_id}", "SK": f"PLAYER_SEARCH#{minute}"},
                UpdateExpression=(
                    "SET entity = :entity, expiresAt = :expiresAt ADD requestCount :one"
                ),
                ConditionExpression=("attribute_not_exists(requestCount) OR requestCount < :limit"),
                ExpressionAttributeValues={
                    ":entity": "playerSearchRate",
                    ":expiresAt": (minute + 2) * 60,
                    ":one": 1,
                    ":limit": 30,
                },
            )
        except ClientError as error:
            if error.response["Error"]["Code"] == "ConditionalCheckFailedException":
                raise ApiError(
                    "playerSearchRateLimited", "Search again later.", status_code=429
                ) from error
            raise

    def check_avatar_upload_rate(self, user_id: str) -> None:
        hour = int(datetime.now(UTC).timestamp()) // 3600
        try:
            self._table.update_item(
                Key={"PK": f"RATE#{user_id}", "SK": f"AVATAR_UPLOAD#{hour}"},
                UpdateExpression=(
                    "SET entity = :entity, expiresAt = :expiresAt ADD requestCount :one"
                ),
                ConditionExpression=("attribute_not_exists(requestCount) OR requestCount < :limit"),
                ExpressionAttributeValues={
                    ":entity": "avatarUploadRate",
                    ":expiresAt": (hour + 2) * 3600,
                    ":one": 1,
                    ":limit": 10,
                },
            )
        except ClientError as error:
            if error.response["Error"]["Code"] == "ConditionalCheckFailedException":
                raise ApiError(
                    "avatarUploadRateLimited",
                    "Too many profile-picture uploads. Try again later.",
                    status_code=429,
                ) from error
            raise

    def get_player_stats(self, player_id: str) -> StoredPlayerStats:
        item = self._table.get_item(Key=self._stats_key(player_id), ConsistentRead=True).get("Item")
        if item is None:
            return _default_stats(player_id)
        return StoredPlayerStats.model_validate(
            {
                "playerId": player_id,
                "rating": int(item.get("rating", 1200)),
                "games": int(item.get("games", 0)),
                "wins": int(item.get("wins", 0)),
                "losses": int(item.get("losses", 0)),
                "draws": int(item.get("draws", 0)),
                "kills": int(item.get("kills", 0)),
                "version": int(item.get("version", 0)),
            }
        )

    def get_metrics_control(self) -> MetricsControl:
        item = self._table.get_item(
            Key={"PK": "CONTROL#METRICS", "SK": "STATE"}, ConsistentRead=True
        ).get("Item")
        if item is None:
            return MetricsControl(
                state=MetricsControlState.backfilling,
                epoch=1,
                global_version=0,
            )
        return MetricsControl(
            state=MetricsControlState(str(item["state"])),
            epoch=int(item["epoch"]),
            global_version=int(item.get("globalVersion", 0)),
        )

    def get_metrics_ledger(self, match_id: str) -> MatchMetricsLedger | None:
        item = self._table.get_item(
            Key={"PK": f"MATCH#{match_id}", "SK": "RESULT#METRICS"},
            ConsistentRead=True,
        ).get("Item")
        if item is None:
            return None
        return MatchMetricsLedger.model_validate_json(item["document"])

    def social_records(
        self, user_id: str
    ) -> tuple[int, list[StoredSocialRelation], list[StoredChallenge]]:
        for _ in range(4):
            before_state = self._social_state(user_id)
            before = before_state["version"]
            items = self._partition_items(f"USER#{user_id}", sk_prefix="SOCIAL#")
            after = self._social_state(user_id)["version"]
            if before != after:
                continue
            relations = [
                StoredSocialRelation.model_validate_json(item["document"])
                for item in items
                if item.get("entity") == "socialRelation"
            ]
            now = datetime.now(UTC)
            challenges: list[StoredChallenge] = []
            expired: list[StoredChallenge] = []
            for item in items:
                if item.get("entity") != "socialChallenge":
                    continue
                challenge = StoredChallenge.model_validate_json(item["document"])
                if challenge.expires_at > now:
                    challenges.append(challenge)
                else:
                    expired.append(challenge)
            if expired:
                for challenge in expired:
                    self._expire_challenge(challenge)
                continue
            pending_count = sum(
                relation.status == SocialRelationStatus.pending for relation in relations
            )
            friend_count = sum(
                relation.status == SocialRelationStatus.friends for relation in relations
            )
            if (
                before_state["pendingCount"] != pending_count
                or before_state["friendCount"] != friend_count
                or before_state["challengeCount"] != len(challenges)
            ):
                self._repair_social_state(
                    user_id,
                    version=before,
                    pending_count=pending_count,
                    friend_count=friend_count,
                    challenge_count=len(challenges),
                )
                continue
            return before, relations, challenges
        raise ApiError(
            "socialSnapshotBusy",
            "Social data changed while loading. Retry.",
            status_code=503,
        )

    def _repair_social_state(
        self,
        user_id: str,
        *,
        version: int,
        pending_count: int,
        friend_count: int,
        challenge_count: int,
    ) -> None:
        try:
            self._table.update_item(
                Key=self._social_state_key(user_id),
                UpdateExpression=(
                    "SET entity = :entity, #version = :next, pendingCount = :pending, "
                    "friendCount = :friends, challengeCount = :challenges"
                ),
                ConditionExpression=("attribute_not_exists(#version) OR #version = :version"),
                ExpressionAttributeNames={"#version": "version"},
                ExpressionAttributeValues={
                    ":entity": "socialState",
                    ":version": version,
                    ":next": version + 1,
                    ":pending": pending_count,
                    ":friends": friend_count,
                    ":challenges": challenge_count,
                },
            )
        except ClientError as error:
            if error.response["Error"]["Code"] != "ConditionalCheckFailedException":
                raise

    def get_social_relation(self, first_id: str, second_id: str) -> StoredSocialRelation | None:
        item = self._table.get_item(
            Key=self._relation_key(first_id, second_id), ConsistentRead=True
        ).get("Item")
        if item is None:
            return None
        return StoredSocialRelation.model_validate_json(item["document"])

    def _relation_projection_item(
        self, relation: StoredSocialRelation, owner_id: str
    ) -> dict[str, Any]:
        return {
            **self._relation_projection_key(owner_id, relation.other(owner_id)),
            "entity": "socialRelation",
            "relationId": relation.id,
            "document": relation.model_dump_json(by_alias=True),
        }

    def _challenge_projection_item(
        self, challenge: StoredChallenge, owner_id: str
    ) -> dict[str, Any]:
        return {
            **self._challenge_projection_key(owner_id, challenge.id),
            "entity": "socialChallenge",
            "challengeId": challenge.id,
            "expiresAt": int(challenge.expires_at.timestamp()),
            "document": challenge.model_dump_json(by_alias=True),
        }

    def create_friend_request(self, relation: StoredSocialRelation) -> StoredSocialRelation:
        current = self.get_social_relation(relation.first_player_id, relation.second_player_id)
        if current is not None:
            if (
                current.status == SocialRelationStatus.pending
                and current.requester_id == relation.requester_id
            ):
                return current
            raise ApiError(
                "friendRequestAlreadyPending",
                "A friendship or friend request already exists.",
                status_code=409,
            )
        first, second = _pair_key(relation.first_player_id, relation.second_player_id)
        target_id = relation.other(relation.requester_id)
        first_state = self._social_state(first)
        second_state = self._social_state(second)
        transaction = [
            *self._account_conditions(first),
            *self._account_conditions(second),
            {
                "ConditionCheck": {
                    "TableName": self._table_name,
                    "Key": _serialize(self._profile_key(target_id)),
                    "ConditionExpression": "attribute_exists(PK)",
                }
            },
            {
                "Put": {
                    "TableName": self._table_name,
                    "Item": _serialize(
                        {
                            **self._relation_key(first, second),
                            "entity": "socialRelationCanonical",
                            "relationId": relation.id,
                            "status": relation.status.value,
                            "requesterId": relation.requester_id,
                            "version": relation.version,
                            "document": relation.model_dump_json(by_alias=True),
                        }
                    ),
                    "ConditionExpression": "attribute_not_exists(PK)",
                }
            },
            {
                "Put": {
                    "TableName": self._table_name,
                    "Item": _serialize(self._relation_projection_item(relation, first)),
                }
            },
            {
                "Put": {
                    "TableName": self._table_name,
                    "Item": _serialize(self._relation_projection_item(relation, second)),
                }
            },
            self._social_state_update(
                first,
                version=first_state["version"],
                pending_delta=1,
                pending_limit=100,
            ),
            self._social_state_update(
                second,
                version=second_state["version"],
                pending_delta=1,
                pending_limit=100,
            ),
        ]
        try:
            self._client.transact_write_items(TransactItems=transaction)
            return relation
        except ClientError as error:
            if error.response["Error"]["Code"] != "TransactionCanceledException":
                raise
            recovered = self.get_social_relation(first, second)
            if (
                recovered is not None
                and recovered.status == SocialRelationStatus.pending
                and recovered.requester_id == relation.requester_id
            ):
                return recovered
            target = self.get_public_player(target_id)
            if target is None:
                raise ApiError(
                    "playerUnavailable", "That player is unavailable.", status_code=404
                ) from error
            raise ApiError(
                "friendRequestAlreadyPending",
                "A friendship or friend request already exists, or a social limit was reached.",
                status_code=409,
            ) from error

    def accept_friend_request(
        self, relation: StoredSocialRelation, recipient_id: str
    ) -> StoredSocialRelation:
        current = self.get_social_relation(relation.first_player_id, relation.second_player_id)
        if current is not None and current.status == SocialRelationStatus.friends:
            return current
        if (
            current is None
            or current.id != relation.id
            or current.status != SocialRelationStatus.pending
            or current.requester_id == recipient_id
            or not current.includes(recipient_id)
        ):
            raise ApiError(
                "friendRequestUnavailable", "The friend request changed.", status_code=409
            )
        first, second = _pair_key(current.first_player_id, current.second_player_id)
        updated = current.model_copy(
            update={
                "status": SocialRelationStatus.friends,
                "version": current.version + 1,
                "updated_at": datetime.now(UTC),
            }
        )
        first_state = self._social_state(first)
        second_state = self._social_state(second)
        transaction = [
            *self._account_conditions(first),
            *self._account_conditions(second),
            {
                "Put": {
                    "TableName": self._table_name,
                    "Item": _serialize(
                        {
                            **self._relation_key(first, second),
                            "entity": "socialRelationCanonical",
                            "relationId": updated.id,
                            "status": updated.status.value,
                            "requesterId": updated.requester_id,
                            "version": updated.version,
                            "document": updated.model_dump_json(by_alias=True),
                        }
                    ),
                    "ConditionExpression": (
                        "relationId = :relationId AND #status = :pending "
                        "AND #version = :version AND requesterId <> :recipient"
                    ),
                    "ExpressionAttributeNames": {
                        "#status": "status",
                        "#version": "version",
                    },
                    "ExpressionAttributeValues": _serialize_values(
                        {
                            ":relationId": current.id,
                            ":pending": "pending",
                            ":version": current.version,
                            ":recipient": recipient_id,
                        }
                    ),
                }
            },
            {
                "Put": {
                    "TableName": self._table_name,
                    "Item": _serialize(self._relation_projection_item(updated, first)),
                }
            },
            {
                "Put": {
                    "TableName": self._table_name,
                    "Item": _serialize(self._relation_projection_item(updated, second)),
                }
            },
            self._social_state_update(
                first,
                version=first_state["version"],
                pending_delta=-1,
                friend_delta=1,
                friend_limit=100,
            ),
            self._social_state_update(
                second,
                version=second_state["version"],
                pending_delta=-1,
                friend_delta=1,
                friend_limit=100,
            ),
        ]
        try:
            self._client.transact_write_items(TransactItems=transaction)
            return updated
        except ClientError as error:
            if error.response["Error"]["Code"] != "TransactionCanceledException":
                raise
            recovered = self.get_social_relation(first, second)
            if recovered is not None and recovered.status == SocialRelationStatus.friends:
                return recovered
            raise ApiError(
                "friendRequestUnavailable", "The friend request changed.", status_code=409
            ) from error

    def delete_friend_request(self, relation: StoredSocialRelation, actor_id: str) -> None:
        if relation.status != SocialRelationStatus.pending or not relation.includes(actor_id):
            raise ApiError(
                "friendRequestNotFound", "The friend request was not found.", status_code=404
            )
        first, second = _pair_key(relation.first_player_id, relation.second_player_id)
        first_state = self._social_state(first)
        second_state = self._social_state(second)
        transaction = [
            {
                "Delete": {
                    "TableName": self._table_name,
                    "Key": _serialize(self._relation_key(first, second)),
                    "ConditionExpression": (
                        "relationId = :id AND #status = :pending AND #version = :version"
                    ),
                    "ExpressionAttributeNames": {
                        "#status": "status",
                        "#version": "version",
                    },
                    "ExpressionAttributeValues": _serialize_values(
                        {
                            ":id": relation.id,
                            ":pending": "pending",
                            ":version": relation.version,
                        }
                    ),
                }
            },
            {
                "Delete": {
                    "TableName": self._table_name,
                    "Key": _serialize(self._relation_projection_key(first, second)),
                }
            },
            {
                "Delete": {
                    "TableName": self._table_name,
                    "Key": _serialize(self._relation_projection_key(second, first)),
                }
            },
            self._social_state_update(first, version=first_state["version"], pending_delta=-1),
            self._social_state_update(second, version=second_state["version"], pending_delta=-1),
        ]
        try:
            self._client.transact_write_items(TransactItems=transaction)
        except ClientError as error:
            if error.response["Error"]["Code"] == "TransactionCanceledException":
                raise ApiError(
                    "friendRequestNotFound",
                    "The friend request was not found.",
                    status_code=404,
                ) from error
            raise

    def delete_friendship(self, relation: StoredSocialRelation, actor_id: str) -> None:
        if relation.status != SocialRelationStatus.friends or not relation.includes(actor_id):
            raise ApiError("friendNotFound", "That player is not a friend.", status_code=404)
        first, second = _pair_key(relation.first_player_id, relation.second_player_id)
        pointer = self._table.get_item(
            Key=self._challenge_pointer_key(first, second), ConsistentRead=True
        ).get("Item")
        first_state = self._social_state(first)
        second_state = self._social_state(second)
        transaction: list[dict[str, Any]] = [
            {
                "Delete": {
                    "TableName": self._table_name,
                    "Key": _serialize(self._relation_key(first, second)),
                    "ConditionExpression": (
                        "relationId = :id AND #status = :friends AND #version = :version"
                    ),
                    "ExpressionAttributeNames": {
                        "#status": "status",
                        "#version": "version",
                    },
                    "ExpressionAttributeValues": _serialize_values(
                        {
                            ":id": relation.id,
                            ":friends": "friends",
                            ":version": relation.version,
                        }
                    ),
                }
            },
            {
                "Delete": {
                    "TableName": self._table_name,
                    "Key": _serialize(self._relation_projection_key(first, second)),
                }
            },
            {
                "Delete": {
                    "TableName": self._table_name,
                    "Key": _serialize(self._relation_projection_key(second, first)),
                }
            },
        ]
        challenge_delta = 0
        if pointer is not None:
            challenge_id = str(pointer["challengeId"])
            challenge_deletes = self._challenge_delete_operations(first, second, challenge_id)
            challenge_deletes[1]["Delete"].update(
                {
                    "ConditionExpression": "challengeId = :challengeId",
                    "ExpressionAttributeValues": _serialize_values({":challengeId": challenge_id}),
                }
            )
            transaction.extend(challenge_deletes)
            challenge_delta = -1
        transaction.extend(
            [
                self._social_state_update(
                    first,
                    version=first_state["version"],
                    friend_delta=-1,
                    challenge_delta=challenge_delta,
                ),
                self._social_state_update(
                    second,
                    version=second_state["version"],
                    friend_delta=-1,
                    challenge_delta=challenge_delta,
                ),
            ]
        )
        try:
            self._client.transact_write_items(TransactItems=transaction)
        except ClientError as error:
            if error.response["Error"]["Code"] == "TransactionCanceledException":
                raise ApiError(
                    "friendNotFound", "That player is not a friend.", status_code=404
                ) from error
            raise

    def get_challenge(self, challenge_id: str) -> StoredChallenge | None:
        item = self._table.get_item(Key=self._challenge_key(challenge_id), ConsistentRead=True).get(
            "Item"
        )
        if item is None:
            return None
        return StoredChallenge.model_validate_json(item["document"])

    def challenge_result(self, challenge_id: str) -> str | None:
        item = self._table.get_item(
            Key=self._challenge_result_key(challenge_id), ConsistentRead=True
        ).get("Item")
        return str(item["matchId"]) if item is not None else None

    def _challenge_delete_operations(
        self, first: str, second: str, challenge_id: str
    ) -> list[dict[str, Any]]:
        return [
            {
                "Delete": {
                    "TableName": self._table_name,
                    "Key": _serialize(self._challenge_key(challenge_id)),
                }
            },
            {
                "Delete": {
                    "TableName": self._table_name,
                    "Key": _serialize(self._challenge_pointer_key(first, second)),
                }
            },
            {
                "Delete": {
                    "TableName": self._table_name,
                    "Key": _serialize(self._challenge_projection_key(first, challenge_id)),
                }
            },
            {
                "Delete": {
                    "TableName": self._table_name,
                    "Key": _serialize(self._challenge_projection_key(second, challenge_id)),
                }
            },
        ]

    def _expire_challenge(self, challenge: StoredChallenge) -> None:
        if challenge.expires_at > datetime.now(UTC):
            return
        first, second = _pair_key(challenge.challenger.id, challenge.opponent.id)
        transaction = self._challenge_delete_operations(first, second, challenge.id)
        pointer = self._table.get_item(
            Key=self._challenge_pointer_key(first, second), ConsistentRead=True
        ).get("Item")
        if pointer is None or pointer.get("challengeId") != challenge.id:
            # TTL may already have removed the pointer, or a newer challenge
            # may have replaced it. Never let an old expiry delete the new one.
            transaction.pop(1)
        else:
            transaction[1]["Delete"].update(
                {
                    "ConditionExpression": (
                        "attribute_not_exists(PK) OR "
                        "(challengeId = :id AND challengeExpiresAt <= :now)"
                    ),
                    "ExpressionAttributeValues": _serialize_values(
                        {":id": challenge.id, ":now": int(datetime.now(UTC).timestamp())}
                    ),
                }
            )
        try:
            self._client.transact_write_items(TransactItems=transaction)
        except ClientError as error:
            if error.response["Error"]["Code"] != "TransactionCanceledException":
                raise

    def create_challenge(self, challenge: StoredChallenge) -> StoredChallenge:
        first, second = _pair_key(challenge.challenger.id, challenge.opponent.id)
        # Reconcile counters if DynamoDB TTL already removed expired projection
        # rows while either account was dormant.
        self.social_records(first)
        self.social_records(second)
        pointer = self._table.get_item(
            Key=self._challenge_pointer_key(first, second), ConsistentRead=True
        ).get("Item")
        expired_id: str | None = None
        if pointer is not None:
            existing_id = str(pointer["challengeId"])
            existing = self.get_challenge(existing_id)
            expires_at = int(pointer.get("challengeExpiresAt", 0))
            if existing is not None and expires_at > int(datetime.now(UTC).timestamp()):
                if existing.challenger.id == challenge.challenger.id:
                    return existing
                raise ApiError(
                    "challengeAlreadyPending",
                    "A challenge is already pending.",
                    status_code=409,
                )
            expired_id = existing_id
        relation = self.get_social_relation(first, second)
        if relation is None or relation.status != SocialRelationStatus.friends:
            raise ApiError("friendRequired", "Only friends can be challenged.", status_code=409)
        first_state = self._social_state(first)
        second_state = self._social_state(second)
        replacing = expired_id is not None
        transaction: list[dict[str, Any]] = [
            *self._account_conditions(first),
            *self._account_conditions(second),
            {
                "ConditionCheck": {
                    "TableName": self._table_name,
                    "Key": _serialize(self._relation_key(first, second)),
                    "ConditionExpression": "#status = :friends AND #version = :version",
                    "ExpressionAttributeNames": {
                        "#status": "status",
                        "#version": "version",
                    },
                    "ExpressionAttributeValues": _serialize_values(
                        {":friends": "friends", ":version": relation.version}
                    ),
                }
            },
        ]
        if expired_id is not None:
            expired_deletes = self._challenge_delete_operations(first, second, expired_id)
            transaction.extend(
                operation for index, operation in enumerate(expired_deletes) if index != 1
            )
        pointer_condition = (
            "challengeId = :expiredId AND challengeExpiresAt <= :now"
            if expired_id is not None
            else "attribute_not_exists(PK)"
        )
        pointer_values = (
            _serialize_values(
                {
                    ":expiredId": expired_id,
                    ":now": int(datetime.now(UTC).timestamp()),
                }
            )
            if expired_id is not None
            else None
        )
        transaction.extend(
            [
                {
                    "Put": {
                        "TableName": self._table_name,
                        "Item": _serialize(
                            {
                                **self._challenge_key(challenge.id),
                                "entity": "socialChallengeCanonical",
                                "expiresAt": int(challenge.expires_at.timestamp()),
                                "document": challenge.model_dump_json(by_alias=True),
                            }
                        ),
                        "ConditionExpression": "attribute_not_exists(PK)",
                    }
                },
                {
                    "Put": {
                        "TableName": self._table_name,
                        "Item": _serialize(
                            {
                                **self._challenge_pointer_key(first, second),
                                "entity": "socialChallengePointer",
                                "challengeId": challenge.id,
                                "challengeExpiresAt": int(challenge.expires_at.timestamp()),
                                "expiresAt": int(challenge.expires_at.timestamp()),
                            }
                        ),
                        "ConditionExpression": pointer_condition,
                        **(
                            {"ExpressionAttributeValues": pointer_values}
                            if pointer_values is not None
                            else {}
                        ),
                    }
                },
                {
                    "Put": {
                        "TableName": self._table_name,
                        "Item": _serialize(self._challenge_projection_item(challenge, first)),
                    }
                },
                {
                    "Put": {
                        "TableName": self._table_name,
                        "Item": _serialize(self._challenge_projection_item(challenge, second)),
                    }
                },
                self._social_state_update(
                    first,
                    version=first_state["version"],
                    challenge_delta=0 if replacing else 1,
                    challenge_limit=None if replacing else 20,
                ),
                self._social_state_update(
                    second,
                    version=second_state["version"],
                    challenge_delta=0 if replacing else 1,
                    challenge_limit=None if replacing else 20,
                ),
            ]
        )
        try:
            self._client.transact_write_items(TransactItems=transaction)
            return challenge
        except ClientError as error:
            if error.response["Error"]["Code"] != "TransactionCanceledException":
                raise
            pointer = self._table.get_item(
                Key=self._challenge_pointer_key(first, second), ConsistentRead=True
            ).get("Item")
            if pointer is not None:
                recovered = self.get_challenge(str(pointer["challengeId"]))
                if recovered is not None and recovered.challenger.id == challenge.challenger.id:
                    return recovered
            raise ApiError(
                "challengeAlreadyPending",
                "A challenge is already pending, or a social limit was reached.",
                status_code=409,
            ) from error

    def accept_challenge(
        self, challenge: StoredChallenge, match: StoredMatch, accepting_user_id: str
    ) -> None:
        existing_result = self.challenge_result(challenge.id)
        if existing_result is not None:
            return
        first, second = _pair_key(challenge.challenger.id, challenge.opponent.id)
        relation = self.get_social_relation(first, second)
        if (
            accepting_user_id != challenge.opponent.id
            or relation is None
            or relation.status != SocialRelationStatus.friends
            or challenge.expires_at <= datetime.now(UTC)
        ):
            raise ApiError("challengeUnavailable", "The challenge is unavailable.", status_code=409)
        first_state = self._social_state(first)
        second_state = self._social_state(second)
        transaction: list[dict[str, Any]] = [
            *self._account_conditions(first),
            *self._account_conditions(second),
            {
                "ConditionCheck": {
                    "TableName": self._table_name,
                    "Key": _serialize(self._relation_key(first, second)),
                    "ConditionExpression": "#status = :friends AND #version = :version",
                    "ExpressionAttributeNames": {
                        "#status": "status",
                        "#version": "version",
                    },
                    "ExpressionAttributeValues": _serialize_values(
                        {":friends": "friends", ":version": relation.version}
                    ),
                }
            },
            {
                "Delete": {
                    "TableName": self._table_name,
                    "Key": _serialize(self._challenge_key(challenge.id)),
                    "ConditionExpression": "document = :document",
                    "ExpressionAttributeValues": _serialize_values(
                        {":document": challenge.model_dump_json(by_alias=True)}
                    ),
                }
            },
            {
                "Delete": {
                    "TableName": self._table_name,
                    "Key": _serialize(self._challenge_pointer_key(first, second)),
                    "ConditionExpression": "challengeId = :id AND challengeExpiresAt > :now",
                    "ExpressionAttributeValues": _serialize_values(
                        {":id": challenge.id, ":now": int(datetime.now(UTC).timestamp())}
                    ),
                }
            },
            {
                "Delete": {
                    "TableName": self._table_name,
                    "Key": _serialize(self._challenge_projection_key(first, challenge.id)),
                }
            },
            {
                "Delete": {
                    "TableName": self._table_name,
                    "Key": _serialize(self._challenge_projection_key(second, challenge.id)),
                }
            },
            self._social_state_update(first, version=first_state["version"], challenge_delta=-1),
            self._social_state_update(second, version=second_state["version"], challenge_delta=-1),
            {
                "Put": {
                    "TableName": self._table_name,
                    "Item": _serialize(self._match_item(match)),
                    "ConditionExpression": "attribute_not_exists(PK)",
                }
            },
            {
                "Put": {
                    "TableName": self._table_name,
                    "Item": _serialize(
                        {
                            "PK": f"USER#{first}",
                            "SK": f"MATCH#{match.id}",
                            "entity": "membership",
                            "matchId": match.id,
                        }
                    ),
                }
            },
            {
                "Put": {
                    "TableName": self._table_name,
                    "Item": _serialize(
                        {
                            "PK": f"USER#{second}",
                            "SK": f"MATCH#{match.id}",
                            "entity": "membership",
                            "matchId": match.id,
                        }
                    ),
                }
            },
            {
                "Put": {
                    "TableName": self._table_name,
                    "Item": _serialize(
                        {
                            **self._challenge_result_key(challenge.id),
                            "entity": "socialChallengeResult",
                            "matchId": match.id,
                            "expiresAt": int((datetime.now(UTC) + timedelta(days=7)).timestamp()),
                        }
                    ),
                    "ConditionExpression": "attribute_not_exists(PK)",
                }
            },
        ]
        try:
            self._client.transact_write_items(TransactItems=transaction)
        except ClientError as error:
            if error.response["Error"]["Code"] != "TransactionCanceledException":
                raise
            if self.challenge_result(challenge.id) is not None:
                return
            raise ApiError(
                "challengeUnavailable", "The challenge is unavailable.", status_code=409
            ) from error

    def cancel_challenge(self, challenge: StoredChallenge, actor_id: str) -> None:
        if actor_id not in {challenge.challenger.id, challenge.opponent.id}:
            raise ApiError("challengeUnavailable", "The challenge is unavailable.", status_code=409)
        first, second = _pair_key(challenge.challenger.id, challenge.opponent.id)
        first_state = self._social_state(first)
        second_state = self._social_state(second)
        transaction = self._challenge_delete_operations(first, second, challenge.id)
        transaction[0]["Delete"].update(
            {
                "ConditionExpression": "document = :document",
                "ExpressionAttributeValues": _serialize_values(
                    {":document": challenge.model_dump_json(by_alias=True)}
                ),
            }
        )
        transaction.extend(
            [
                self._social_state_update(
                    first, version=first_state["version"], challenge_delta=-1
                ),
                self._social_state_update(
                    second, version=second_state["version"], challenge_delta=-1
                ),
            ]
        )
        try:
            self._client.transact_write_items(TransactItems=transaction)
        except ClientError as error:
            if error.response["Error"]["Code"] == "TransactionCanceledException":
                raise ApiError(
                    "challengeNotFound", "The challenge was not found.", status_code=404
                ) from error
            raise

    def create_match(self, match: StoredMatch) -> None:
        membership = {
            "PK": f"USER#{match.creator_id}",
            "SK": f"MATCH#{match.id}",
            "entity": "membership",
            "matchId": match.id,
        }
        join = {
            "PK": f"JOIN#{match.join_code}",
            "SK": "JOIN",
            "entity": "joinCode",
            "matchId": match.id,
        }
        participant_ids = {match.creator_id}
        if match.black_player is not None:
            participant_ids.add(match.black_player.id)
        if match.white_player is not None:
            participant_ids.add(match.white_player.id)
        try:
            self._client.transact_write_items(
                TransactItems=[
                    *(
                        condition
                        for player_id in participant_ids
                        for condition in self._account_conditions(player_id)
                    ),
                    {
                        "Put": {
                            "TableName": self._table_name,
                            "Item": _serialize(self._match_item(match)),
                            "ConditionExpression": "attribute_not_exists(PK)",
                        }
                    },
                    {"Put": {"TableName": self._table_name, "Item": _serialize(membership)}},
                    {
                        "Put": {
                            "TableName": self._table_name,
                            "Item": _serialize(join),
                            "ConditionExpression": "attribute_not_exists(PK)",
                        }
                    },
                ]
            )
        except ClientError as error:
            if error.response["Error"]["Code"] == "TransactionCanceledException":
                raise ApiError(
                    "conflict", "The match could not be created.", status_code=409
                ) from error
            raise

    def get_match(self, match_id: str) -> StoredMatch | None:
        response = self._table.get_item(
            Key={"PK": f"MATCH#{match_id}", "SK": "STATE"}, ConsistentRead=True
        )
        return self._parse_match(response.get("Item"))

    def find_by_join_code(self, join_code: str) -> StoredMatch | None:
        response = self._table.get_item(
            Key={"PK": f"JOIN#{join_code}", "SK": "JOIN"}, ConsistentRead=True
        )
        item = response.get("Item")
        return self.get_match(item["matchId"]) if item else None

    def list_matches(self, user_id: str) -> list[StoredMatch]:
        items: list[dict[str, Any]] = []
        query: dict[str, Any] = {
            "KeyConditionExpression": Key("PK").eq(f"USER#{user_id}")
            & Key("SK").begins_with("MATCH#")
        }
        while True:
            response = self._table.query(**query)
            items.extend(response.get("Items", []))
            last_key = response.get("LastEvaluatedKey")
            if not last_key:
                break
            query["ExclusiveStartKey"] = last_key
        match_items = self._batch_get(
            [{"PK": f"MATCH#{item['matchId']!s}", "SK": "STATE"} for item in items]
        )
        matches = [self._parse_match(item) for item in match_items]
        return sorted(
            (match for match in matches if match), key=lambda item: item.updated_at, reverse=True
        )

    def _batch_get(self, keys: list[dict[str, str]]) -> list[dict[str, Any]]:
        found: list[dict[str, Any]] = []
        for offset in range(0, len(keys), 100):
            pending = keys[offset : offset + 100]
            for _ in range(4):
                response = self._dynamodb.batch_get_item(
                    RequestItems={
                        self._table_name: {
                            "Keys": pending,
                            "ConsistentRead": True,
                        }
                    }
                )
                found.extend(response.get("Responses", {}).get(self._table_name, []))
                pending = (
                    response.get("UnprocessedKeys", {}).get(self._table_name, {}).get("Keys", [])
                )
                if not pending:
                    break
            if pending:
                raise ApiError(
                    "databaseBusy", "Player data is temporarily unavailable.", status_code=503
                )
        return found

    def join_match(self, match: StoredMatch, joining_user_id: str) -> None:
        try:
            self._client.transact_write_items(
                TransactItems=[
                    *self._account_conditions(match.creator_id),
                    *self._account_conditions(joining_user_id),
                    {
                        "Put": {
                            "TableName": self._table_name,
                            "Item": _serialize(self._match_item(match)),
                            "ConditionExpression": ("#status = :waiting AND #version = :version"),
                            "ExpressionAttributeNames": {
                                "#status": "status",
                                "#version": "version",
                            },
                            "ExpressionAttributeValues": _serialize_values(
                                {":waiting": "waiting", ":version": match.version - 1}
                            ),
                        }
                    },
                    {
                        "Put": {
                            "TableName": self._table_name,
                            "Item": _serialize(
                                {
                                    "PK": f"USER#{joining_user_id}",
                                    "SK": f"MATCH#{match.id}",
                                    "entity": "membership",
                                    "matchId": match.id,
                                }
                            ),
                        }
                    },
                ]
            )
        except ClientError as error:
            if error.response["Error"]["Code"] == "TransactionCanceledException":
                raise ApiError(
                    "matchUnavailable", "The match is no longer waiting.", status_code=409
                ) from error
            raise

    def cancel_waiting_match(self, match: StoredMatch, user_id: str) -> None:
        try:
            self._client.transact_write_items(
                TransactItems=[
                    {
                        "Delete": {
                            "TableName": self._table_name,
                            "Key": _serialize({"PK": f"MATCH#{match.id}", "SK": "STATE"}),
                            "ConditionExpression": (
                                "#status = :waiting AND #version = :version "
                                "AND creatorId = :creator"
                            ),
                            "ExpressionAttributeNames": {
                                "#status": "status",
                                "#version": "version",
                            },
                            "ExpressionAttributeValues": _serialize_values(
                                {
                                    ":waiting": "waiting",
                                    ":version": match.version,
                                    ":creator": user_id,
                                }
                            ),
                        }
                    },
                    {
                        "Delete": {
                            "TableName": self._table_name,
                            "Key": _serialize({"PK": f"JOIN#{match.join_code}", "SK": "JOIN"}),
                        }
                    },
                    {
                        "Delete": {
                            "TableName": self._table_name,
                            "Key": _serialize({"PK": f"USER#{user_id}", "SK": f"MATCH#{match.id}"}),
                        }
                    },
                ]
            )
        except ClientError as error:
            if error.response["Error"]["Code"] == "TransactionCanceledException":
                raise ApiError(
                    "matchUnavailable",
                    "The waiting match can no longer be cancelled.",
                    status_code=409,
                ) from error
            raise

    def idempotent_result(
        self, user_id: str, key: str, request_fingerprint: str
    ) -> StoredMatch | None:
        response = self._table.get_item(
            Key={"PK": f"IDEMP#{user_id}", "SK": key}, ConsistentRead=True
        )
        item = response.get("Item")
        if not item:
            return None
        if item.get("requestFingerprint") != request_fingerprint:
            raise ApiError(
                "idempotencyConflict",
                "That idempotency key was used for a different request.",
                status_code=409,
            )
        return StoredMatch.model_validate_json(item["document"])

    def commit_move(
        self,
        *,
        match: StoredMatch,
        expected_version: int,
        event: MoveEvent,
        user_id: str,
        idempotency_key: str,
        request_fingerprint: str,
        metrics: MatchMetricsLedger | None = None,
        black_stats_version: int | None = None,
        white_stats_version: int | None = None,
        control_version: int | None = None,
    ) -> None:
        if match.status == MatchStatus.completed and metrics is None:
            raise ApiError("metricsRequired", "Completed matches require metrics.", status_code=503)
        metrics_operations: list[dict[str, Any]] = []
        account_operations: list[dict[str, Any]] = []
        if metrics is not None:
            if (
                black_stats_version is None
                or white_stats_version is None
                or control_version is None
            ):
                raise ValueError("terminal metrics require expected versions")
            metrics_operations = self._metrics_transaction_operations(
                match,
                metrics,
                black_stats_version=black_stats_version,
                white_stats_version=white_stats_version,
                control_version=control_version,
            )
        else:
            if match.black_player is None or match.white_player is None:
                raise ValueError("an active match requires two players")
            account_operations = [
                *self._account_conditions(match.black_player.id),
                *self._account_conditions(match.white_player.id),
            ]
        try:
            self._client.transact_write_items(
                TransactItems=[
                    *account_operations,
                    {
                        "Put": {
                            "TableName": self._table_name,
                            "Item": _serialize(self._match_item(match)),
                            "ConditionExpression": ("#version = :version AND #status = :active"),
                            "ExpressionAttributeNames": {
                                "#version": "version",
                                "#status": "status",
                            },
                            "ExpressionAttributeValues": _serialize_values(
                                {":version": expected_version, ":active": "active"}
                            ),
                        }
                    },
                    {
                        "Put": {
                            "TableName": self._table_name,
                            "Item": _serialize(
                                {
                                    "PK": f"MATCH#{match.id}",
                                    "SK": f"MOVE#{event.revision:08d}",
                                    "entity": "move",
                                    "document": event.model_dump_json(by_alias=True),
                                }
                            ),
                            "ConditionExpression": "attribute_not_exists(PK)",
                        }
                    },
                    {
                        "Put": {
                            "TableName": self._table_name,
                            "Item": _serialize(
                                {
                                    "PK": f"IDEMP#{user_id}",
                                    "SK": idempotency_key,
                                    "entity": "idempotency",
                                    "document": match.model_dump_json(by_alias=True),
                                    "requestFingerprint": request_fingerprint,
                                    "expiresAt": int(datetime.now(UTC).timestamp()) + 86400,
                                }
                            ),
                            "ConditionExpression": "attribute_not_exists(PK)",
                        }
                    },
                    *metrics_operations,
                ]
            )
        except ClientError as error:
            if error.response["Error"]["Code"] == "TransactionCanceledException":
                existing = self.idempotent_result(user_id, idempotency_key, request_fingerprint)
                if existing is not None:
                    return
                current = self.get_match(match.id)
                if (
                    match.black_player is not None
                    and match.white_player is not None
                    and any(
                        self.account_state(player.id) != AccountState.active
                        for player in (match.black_player, match.white_player)
                    )
                ):
                    raise ApiError(
                        "accountDeleting",
                        "A player account is being deleted.",
                        status_code=409,
                    ) from error
                if metrics is not None:
                    control = self.get_metrics_control()
                    if control.state != MetricsControlState.ready:
                        raise ApiError(
                            "metricsBackfillInProgress",
                            "Rated results are temporarily paused.",
                            status_code=503,
                        ) from error
                    if current is not None and current.version == expected_version:
                        raise ApiError(
                            "metricsConflict", "Rating state changed.", status_code=409
                        ) from error
                raise ApiError(
                    "staleRevision",
                    "The match changed before this move was committed.",
                    status_code=409,
                    details={"currentRevision": current.revision if current else None},
                ) from error
            raise

    def commit_resignation(
        self,
        *,
        match: StoredMatch,
        expected_version: int,
        user_id: str,
        idempotency_key: str,
        request_fingerprint: str,
        metrics: MatchMetricsLedger,
        black_stats_version: int,
        white_stats_version: int,
        control_version: int,
        deleting_user_id: str | None = None,
    ) -> None:
        metrics_operations = self._metrics_transaction_operations(
            match,
            metrics,
            black_stats_version=black_stats_version,
            white_stats_version=white_stats_version,
            control_version=control_version,
            deleting_user_id=deleting_user_id,
        )
        try:
            self._client.transact_write_items(
                TransactItems=[
                    {
                        "Put": {
                            "TableName": self._table_name,
                            "Item": _serialize(self._match_item(match)),
                            "ConditionExpression": ("#version = :version AND #status = :active"),
                            "ExpressionAttributeNames": {
                                "#version": "version",
                                "#status": "status",
                            },
                            "ExpressionAttributeValues": _serialize_values(
                                {":version": expected_version, ":active": "active"}
                            ),
                        }
                    },
                    {
                        "Put": {
                            "TableName": self._table_name,
                            "Item": _serialize(
                                {
                                    "PK": f"IDEMP#{user_id}",
                                    "SK": idempotency_key,
                                    "entity": "idempotency",
                                    "document": match.model_dump_json(by_alias=True),
                                    "requestFingerprint": request_fingerprint,
                                    "expiresAt": int(datetime.now(UTC).timestamp()) + 86400,
                                }
                            ),
                            "ConditionExpression": "attribute_not_exists(PK)",
                        }
                    },
                    *metrics_operations,
                ]
            )
        except ClientError as error:
            if error.response["Error"]["Code"] == "TransactionCanceledException":
                existing = self.idempotent_result(user_id, idempotency_key, request_fingerprint)
                if existing is not None:
                    return
                control = self.get_metrics_control()
                if control.state != MetricsControlState.ready:
                    raise ApiError(
                        "metricsBackfillInProgress",
                        "Rated results are temporarily paused.",
                        status_code=503,
                    ) from error
                current = self.get_match(match.id)
                if current is not None and current.version == expected_version:
                    raise ApiError(
                        "metricsConflict", "Rating state changed.", status_code=409
                    ) from error
                raise ApiError("staleRevision", "The match changed.", status_code=409) from error
            raise

    def _metrics_transaction_operations(
        self,
        match: StoredMatch,
        metrics: MatchMetricsLedger,
        *,
        black_stats_version: int,
        white_stats_version: int,
        control_version: int,
        deleting_user_id: str | None = None,
    ) -> list[dict[str, Any]]:
        _validate_metrics_payload(match, metrics)
        if metrics.rating_sequence != control_version + 1:
            raise ValueError("metrics rating sequence must follow the control version")
        if match.black_player is None or match.white_player is None:
            raise ValueError("rated match requires two players")

        def stats_update(
            player_id: str,
            *,
            expected_version: int,
            rating_after: int,
            score: float,
            kills: int,
        ) -> dict[str, Any]:
            wins, losses, draws = _result_counters(score)
            condition = (
                "(attribute_not_exists(PK) OR #version = :expectedVersion)"
                if expected_version == 0
                else "#version = :expectedVersion"
            )
            return {
                "Update": {
                    "TableName": self._table_name,
                    "Key": _serialize(self._stats_key(player_id)),
                    "UpdateExpression": (
                        "SET entity = :entity, playerId = :playerId, rating = :rating "
                        "ADD games :one, wins :wins, losses :losses, draws :draws, "
                        "kills :kills, #version :one"
                    ),
                    "ConditionExpression": condition,
                    "ExpressionAttributeNames": {"#version": "version"},
                    "ExpressionAttributeValues": _serialize_values(
                        {
                            ":entity": "playerStats",
                            ":playerId": player_id,
                            ":rating": rating_after,
                            ":one": 1,
                            ":wins": wins,
                            ":losses": losses,
                            ":draws": draws,
                            ":kills": kills,
                            ":expectedVersion": expected_version,
                        }
                    ),
                }
            }

        account_conditions: list[dict[str, Any]] = []
        for player_id in (match.black_player.id, match.white_player.id):
            if deleting_user_id is None:
                account_conditions.extend(self._account_conditions(player_id))
                continue
            account_conditions.append(
                {
                    "ConditionCheck": {
                        "TableName": self._table_name,
                        "Key": _serialize(self._account_key(player_id)),
                        "ConditionExpression": (
                            "attribute_not_exists(PK) OR #accountState IN (:active, :deleting)"
                        ),
                        "ExpressionAttributeNames": {"#accountState": "state"},
                        "ExpressionAttributeValues": _serialize_values(
                            {
                                ":active": AccountState.active.value,
                                ":deleting": AccountState.deleting.value,
                            }
                        ),
                    }
                }
            )

        return [
            *account_conditions,
            {
                "Put": {
                    "TableName": self._table_name,
                    "Item": _serialize(
                        {
                            "PK": f"MATCH#{match.id}",
                            "SK": "RESULT#METRICS",
                            "entity": "matchMetrics",
                            "ratingSequence": metrics.rating_sequence,
                            "document": metrics.model_dump_json(by_alias=True),
                        }
                    ),
                    "ConditionExpression": "attribute_not_exists(PK)",
                }
            },
            stats_update(
                match.black_player.id,
                expected_version=black_stats_version,
                rating_after=metrics.black_rating_after,
                score=metrics.black_score,
                kills=metrics.black_kills,
            ),
            stats_update(
                match.white_player.id,
                expected_version=white_stats_version,
                rating_after=metrics.white_rating_after,
                score=1.0 - metrics.black_score,
                kills=metrics.white_kills,
            ),
            {
                "Update": {
                    "TableName": self._table_name,
                    "Key": _serialize({"PK": "CONTROL#METRICS", "SK": "STATE"}),
                    "UpdateExpression": "SET globalVersion = :nextVersion",
                    "ConditionExpression": (
                        "#state = :ready AND epoch = :epoch AND globalVersion = :controlVersion"
                    ),
                    "ExpressionAttributeNames": {"#state": "state"},
                    "ExpressionAttributeValues": _serialize_values(
                        {
                            ":ready": "ready",
                            ":epoch": metrics.epoch,
                            ":controlVersion": control_version,
                            ":nextVersion": metrics.rating_sequence,
                        }
                    ),
                }
            },
        ]

    def list_moves(self, match_id: str) -> list[MoveEvent]:
        items: list[dict[str, Any]] = []
        query: dict[str, Any] = {
            "KeyConditionExpression": Key("PK").eq(f"MATCH#{match_id}")
            & Key("SK").begins_with("MOVE#")
        }
        while True:
            response = self._table.query(**query)
            items.extend(response.get("Items", []))
            last_key = response.get("LastEvaluatedKey")
            if not last_key:
                break
            query["ExclusiveStartKey"] = last_key
        return [MoveEvent.model_validate_json(item["document"]) for item in items]

    def enqueue(
        self,
        rules_hash: str,
        user_id: str,
        display_name: str,
        rules: dict[str, Any],
        ticket_id: str,
    ) -> None:
        now = datetime.now(UTC)
        queue_sk = f"{now.isoformat()}#{user_id}"
        expires_at = int((now + _MATCHMAKING_WAIT_TTL).timestamp())
        try:
            self._client.transact_write_items(
                TransactItems=[
                    *self._account_conditions(user_id),
                    {
                        "Put": {
                            "TableName": self._table_name,
                            "Item": _serialize(
                                {
                                    "PK": f"QUEUE#{rules_hash}",
                                    "SK": queue_sk,
                                    "entity": "queue",
                                    "userId": user_id,
                                    "displayName": display_name,
                                    "ticketId": ticket_id,
                                    "status": "waiting",
                                    "rules": json.dumps(
                                        rules, separators=(",", ":"), sort_keys=True
                                    ),
                                    "expiresAt": expires_at,
                                }
                            ),
                            "ConditionExpression": "attribute_not_exists(PK)",
                        }
                    },
                    {
                        "Put": {
                            "TableName": self._table_name,
                            "Item": _serialize(
                                {
                                    "PK": f"USER#{user_id}",
                                    "SK": "QUEUE",
                                    "entity": "queuePointer",
                                    "ticketId": ticket_id,
                                    "status": "waiting",
                                    "rulesHash": rules_hash,
                                    "queueSk": queue_sk,
                                    "expiresAt": expires_at,
                                }
                            ),
                            "ConditionExpression": "attribute_not_exists(PK)",
                        }
                    },
                    {
                        "Put": {
                            "TableName": self._table_name,
                            "Item": _serialize(
                                {
                                    "PK": f"USER#{user_id}",
                                    "SK": f"TICKET#{ticket_id}",
                                    "entity": "matchmakingTicket",
                                    "ticketId": ticket_id,
                                    "status": "waiting",
                                    "rulesHash": rules_hash,
                                    "queueSk": queue_sk,
                                    "expiresAt": expires_at,
                                }
                            ),
                            "ConditionExpression": "attribute_not_exists(PK)",
                        }
                    },
                ]
            )
        except ClientError as error:
            if error.response["Error"]["Code"] == "TransactionCanceledException":
                existing = self.matchmaking_status(user_id, ticket_id)
                if existing is not None:
                    return
                raise ApiError(
                    "matchmakingConflict",
                    "The matchmaking request conflicted with another request.",
                    status_code=409,
                ) from error
            raise

    def pop_opponent(
        self, rules_hash: str, user_id: str
    ) -> tuple[str, str, dict[str, Any], str] | None:
        query: dict[str, Any] = {
            "KeyConditionExpression": Key("PK").eq(f"QUEUE#{rules_hash}"),
            "ConsistentRead": True,
        }
        now = int(datetime.now(UTC).timestamp())
        claimed_until = int((datetime.now(UTC) + _MATCHMAKING_WAIT_TTL).timestamp())
        while True:
            response = self._table.query(**query)
            for item in response.get("Items", []):
                if (
                    item["userId"] == user_id
                    or item.get("status") != "waiting"
                    or int(item.get("expiresAt", 0)) <= now
                ):
                    continue
                raw_display_name = item.get("displayName")
                if isinstance(raw_display_name, str) and raw_display_name.strip():
                    candidate_display_name = raw_display_name.strip()
                else:
                    legacy_player = self.get_public_player(str(item["userId"]))
                    if legacy_player is None:
                        continue
                    candidate_display_name = legacy_player.display_name
                ticket_id = str(item["ticketId"])
                try:
                    self._client.transact_write_items(
                        TransactItems=[
                            *self._account_conditions(str(item["userId"])),
                            {
                                "Update": {
                                    "TableName": self._table_name,
                                    "Key": _serialize({"PK": item["PK"], "SK": item["SK"]}),
                                    "UpdateExpression": (
                                        "SET #status = :claimed, expiresAt = :expiresAt, "
                                        "displayName = :displayName"
                                    ),
                                    "ConditionExpression": (
                                        "userId = :userId AND ticketId = :ticketId "
                                        "AND #status = :waiting AND expiresAt > :now"
                                    ),
                                    "ExpressionAttributeNames": {"#status": "status"},
                                    "ExpressionAttributeValues": _serialize_values(
                                        {
                                            ":userId": item["userId"],
                                            ":ticketId": ticket_id,
                                            ":waiting": "waiting",
                                            ":claimed": "claimed",
                                            ":now": now,
                                            ":expiresAt": claimed_until,
                                            ":displayName": candidate_display_name,
                                        }
                                    ),
                                }
                            },
                            {
                                "Update": {
                                    "TableName": self._table_name,
                                    "Key": _serialize(
                                        {"PK": f"USER#{item['userId']}", "SK": "QUEUE"}
                                    ),
                                    "UpdateExpression": (
                                        "SET #status = :claimed, expiresAt = :expiresAt"
                                    ),
                                    "ConditionExpression": (
                                        "ticketId = :ticketId AND rulesHash = :rulesHash "
                                        "AND queueSk = :queueSk AND #status = :waiting"
                                    ),
                                    "ExpressionAttributeNames": {"#status": "status"},
                                    "ExpressionAttributeValues": _serialize_values(
                                        {
                                            ":ticketId": ticket_id,
                                            ":rulesHash": rules_hash,
                                            ":queueSk": item["SK"],
                                            ":waiting": "waiting",
                                            ":claimed": "claimed",
                                            ":expiresAt": claimed_until,
                                        }
                                    ),
                                }
                            },
                            {
                                "Update": {
                                    "TableName": self._table_name,
                                    "Key": _serialize(
                                        {
                                            "PK": f"USER#{item['userId']}",
                                            "SK": f"TICKET#{ticket_id}",
                                        }
                                    ),
                                    "UpdateExpression": (
                                        "SET #status = :claimed, expiresAt = :expiresAt"
                                    ),
                                    "ConditionExpression": (
                                        "#status = :waiting AND queueSk = :queueSk"
                                    ),
                                    "ExpressionAttributeNames": {"#status": "status"},
                                    "ExpressionAttributeValues": _serialize_values(
                                        {
                                            ":claimed": "claimed",
                                            ":waiting": "waiting",
                                            ":queueSk": item["SK"],
                                            ":expiresAt": claimed_until,
                                        }
                                    ),
                                }
                            },
                        ]
                    )
                    return (
                        str(item["userId"]),
                        candidate_display_name,
                        json.loads(item["rules"]),
                        ticket_id,
                    )
                except ClientError as error:
                    if error.response["Error"]["Code"] == "TransactionCanceledException":
                        continue
                    raise
            last_key = response.get("LastEvaluatedKey")
            if not last_key:
                break
            query["ExclusiveStartKey"] = last_key
        return None

    def active_matchmaking(self, user_id: str) -> MatchmakingRecord | None:
        response = self._table.get_item(
            Key={"PK": f"USER#{user_id}", "SK": "QUEUE"}, ConsistentRead=True
        )
        item = response.get("Item")
        if not item:
            return None
        now = int(datetime.now(UTC).timestamp())
        if int(item.get("expiresAt", 0)) <= now:
            self._delete_expired_queue(user_id, item, now)
            return None
        raw_status = item.get("status")
        if raw_status == "claimed":
            status: Literal["waiting", "claimed", "matched"] = "claimed"
        elif raw_status == "waiting":
            status = "waiting"
        else:
            return None
        return MatchmakingRecord(
            ticket_id=str(item["ticketId"]),
            status=status,
            rules_hash=str(item["rulesHash"]),
            queue_sk=str(item["queueSk"]),
            match_id=None,
            expires_at=datetime.fromtimestamp(int(item["expiresAt"]), UTC),
        )

    def matchmaking_status(self, user_id: str, ticket_id: str) -> MatchmakingRecord | None:
        response = self._table.get_item(
            Key={"PK": f"USER#{user_id}", "SK": f"TICKET#{ticket_id}"},
            ConsistentRead=True,
        )
        item = response.get("Item")
        if not item:
            return None
        expires_at = int(item.get("expiresAt", 0))
        now = int(datetime.now(UTC).timestamp())
        if expires_at <= now:
            try:
                self._table.delete_item(
                    Key={"PK": f"USER#{user_id}", "SK": f"TICKET#{ticket_id}"},
                    ConditionExpression=("ticketId = :ticketId AND expiresAt <= :now"),
                    ExpressionAttributeValues={
                        ":ticketId": ticket_id,
                        ":now": now,
                    },
                )
            except ClientError as error:
                if error.response["Error"]["Code"] == "ConditionalCheckFailedException":
                    return self.matchmaking_status(user_id, ticket_id)
                raise
            return None
        raw_status = item.get("status")
        if raw_status == "waiting":
            status: Literal["waiting", "claimed", "matched"] = "waiting"
        elif raw_status == "claimed":
            status = "claimed"
        elif raw_status == "matched":
            status = "matched"
        else:
            return None
        return MatchmakingRecord(
            ticket_id=ticket_id,
            status=status,
            rules_hash=item.get("rulesHash"),
            queue_sk=item.get("queueSk"),
            match_id=item.get("matchId"),
            expires_at=datetime.fromtimestamp(expires_at, UTC),
        )

    def commit_quick_match(
        self,
        match: StoredMatch,
        joining_user_id: str,
        requester_ticket_id: str,
        opponent_ticket_id: str,
    ) -> None:
        opponent_id = match.creator_id
        pointer = self._table.get_item(
            Key={"PK": f"USER#{opponent_id}", "SK": "QUEUE"},
            ConsistentRead=True,
        ).get("Item")
        if (
            not pointer
            or pointer.get("ticketId") != opponent_ticket_id
            or pointer.get("status") != "claimed"
        ):
            raise ApiError(
                "matchmakingConflict",
                "The opponent is no longer reserved for this match.",
                status_code=409,
            )
        rules_hash = str(pointer["rulesHash"])
        queue_sk = str(pointer["queueSk"])
        expires_at = int((datetime.now(UTC) + _MATCHMAKING_RESULT_TTL).timestamp())
        try:
            self._client.transact_write_items(
                TransactItems=[
                    *self._account_conditions(opponent_id),
                    *self._account_conditions(joining_user_id),
                    {
                        "Put": {
                            "TableName": self._table_name,
                            "Item": _serialize(self._match_item(match)),
                            "ConditionExpression": "attribute_not_exists(PK)",
                        }
                    },
                    {
                        "Put": {
                            "TableName": self._table_name,
                            "Item": _serialize(
                                {
                                    "PK": f"JOIN#{match.join_code}",
                                    "SK": "JOIN",
                                    "entity": "joinCode",
                                    "matchId": match.id,
                                }
                            ),
                            "ConditionExpression": "attribute_not_exists(PK)",
                        }
                    },
                    {
                        "Put": {
                            "TableName": self._table_name,
                            "Item": _serialize(
                                {
                                    "PK": f"USER#{opponent_id}",
                                    "SK": f"MATCH#{match.id}",
                                    "entity": "membership",
                                    "matchId": match.id,
                                }
                            ),
                        }
                    },
                    {
                        "Put": {
                            "TableName": self._table_name,
                            "Item": _serialize(
                                {
                                    "PK": f"USER#{joining_user_id}",
                                    "SK": f"MATCH#{match.id}",
                                    "entity": "membership",
                                    "matchId": match.id,
                                }
                            ),
                        }
                    },
                    {
                        "Delete": {
                            "TableName": self._table_name,
                            "Key": _serialize({"PK": f"QUEUE#{rules_hash}", "SK": queue_sk}),
                            "ConditionExpression": ("ticketId = :ticketId AND #status = :claimed"),
                            "ExpressionAttributeNames": {"#status": "status"},
                            "ExpressionAttributeValues": _serialize_values(
                                {
                                    ":ticketId": opponent_ticket_id,
                                    ":claimed": "claimed",
                                }
                            ),
                        }
                    },
                    {
                        "Delete": {
                            "TableName": self._table_name,
                            "Key": _serialize({"PK": f"USER#{opponent_id}", "SK": "QUEUE"}),
                            "ConditionExpression": (
                                "ticketId = :ticketId AND queueSk = :queueSk AND #status = :claimed"
                            ),
                            "ExpressionAttributeNames": {"#status": "status"},
                            "ExpressionAttributeValues": _serialize_values(
                                {
                                    ":ticketId": opponent_ticket_id,
                                    ":queueSk": queue_sk,
                                    ":claimed": "claimed",
                                }
                            ),
                        }
                    },
                    {
                        "Update": {
                            "TableName": self._table_name,
                            "Key": _serialize(
                                {
                                    "PK": f"USER#{opponent_id}",
                                    "SK": f"TICKET#{opponent_ticket_id}",
                                }
                            ),
                            "UpdateExpression": (
                                "SET #status = :matched, matchId = :matchId, expiresAt = :expiresAt"
                            ),
                            "ConditionExpression": ("#status = :claimed AND queueSk = :queueSk"),
                            "ExpressionAttributeNames": {"#status": "status"},
                            "ExpressionAttributeValues": _serialize_values(
                                {
                                    ":matched": "matched",
                                    ":claimed": "claimed",
                                    ":queueSk": queue_sk,
                                    ":matchId": match.id,
                                    ":expiresAt": expires_at,
                                }
                            ),
                        }
                    },
                    {
                        "Put": {
                            "TableName": self._table_name,
                            "Item": _serialize(
                                {
                                    "PK": f"USER#{joining_user_id}",
                                    "SK": f"TICKET#{requester_ticket_id}",
                                    "entity": "matchmakingTicket",
                                    "ticketId": requester_ticket_id,
                                    "status": "matched",
                                    "rulesHash": rules_hash,
                                    "matchId": match.id,
                                    "expiresAt": expires_at,
                                }
                            ),
                            "ConditionExpression": "attribute_not_exists(PK)",
                        }
                    },
                ]
            )
        except ClientError as error:
            if error.response["Error"]["Code"] == "TransactionCanceledException":
                existing = self.matchmaking_status(joining_user_id, requester_ticket_id)
                if existing is not None and existing.match_id == match.id:
                    return
                raise ApiError(
                    "matchmakingConflict",
                    "The quick match could not be committed.",
                    status_code=409,
                ) from error
            raise

    def release_matchmaking_claim(self, user_id: str, ticket_id: str) -> None:
        pointer = self._table.get_item(
            Key={"PK": f"USER#{user_id}", "SK": "QUEUE"}, ConsistentRead=True
        ).get("Item")
        if (
            not pointer
            or pointer.get("ticketId") != ticket_id
            or pointer.get("status") != "claimed"
        ):
            return
        expires_at = int((datetime.now(UTC) + _MATCHMAKING_WAIT_TTL).timestamp())
        try:
            self._client.transact_write_items(
                TransactItems=[
                    {
                        "Update": {
                            "TableName": self._table_name,
                            "Key": _serialize(
                                {
                                    "PK": f"QUEUE#{pointer['rulesHash']}",
                                    "SK": pointer["queueSk"],
                                }
                            ),
                            "UpdateExpression": ("SET #status = :waiting, expiresAt = :expiresAt"),
                            "ConditionExpression": ("ticketId = :ticketId AND #status = :claimed"),
                            "ExpressionAttributeNames": {"#status": "status"},
                            "ExpressionAttributeValues": _serialize_values(
                                {
                                    ":waiting": "waiting",
                                    ":claimed": "claimed",
                                    ":ticketId": ticket_id,
                                    ":expiresAt": expires_at,
                                }
                            ),
                        }
                    },
                    {
                        "Update": {
                            "TableName": self._table_name,
                            "Key": _serialize({"PK": f"USER#{user_id}", "SK": "QUEUE"}),
                            "UpdateExpression": ("SET #status = :waiting, expiresAt = :expiresAt"),
                            "ConditionExpression": (
                                "ticketId = :ticketId AND queueSk = :queueSk AND #status = :claimed"
                            ),
                            "ExpressionAttributeNames": {"#status": "status"},
                            "ExpressionAttributeValues": _serialize_values(
                                {
                                    ":waiting": "waiting",
                                    ":claimed": "claimed",
                                    ":ticketId": ticket_id,
                                    ":queueSk": pointer["queueSk"],
                                    ":expiresAt": expires_at,
                                }
                            ),
                        }
                    },
                    {
                        "Update": {
                            "TableName": self._table_name,
                            "Key": _serialize(
                                {
                                    "PK": f"USER#{user_id}",
                                    "SK": f"TICKET#{ticket_id}",
                                }
                            ),
                            "UpdateExpression": ("SET #status = :waiting, expiresAt = :expiresAt"),
                            "ConditionExpression": ("queueSk = :queueSk AND #status = :claimed"),
                            "ExpressionAttributeNames": {"#status": "status"},
                            "ExpressionAttributeValues": _serialize_values(
                                {
                                    ":waiting": "waiting",
                                    ":claimed": "claimed",
                                    ":queueSk": pointer["queueSk"],
                                    ":expiresAt": expires_at,
                                }
                            ),
                        }
                    },
                ]
            )
        except ClientError as error:
            if error.response["Error"]["Code"] != "TransactionCanceledException":
                raise

    def remove_from_queue(self, user_id: str, ticket_id: str) -> bool:
        response = self._table.get_item(
            Key={"PK": f"USER#{user_id}", "SK": "QUEUE"}, ConsistentRead=True
        )
        pointer = response.get("Item")
        if pointer and pointer.get("ticketId") == ticket_id:
            try:
                self._client.transact_write_items(
                    TransactItems=[
                        {
                            "Delete": {
                                "TableName": self._table_name,
                                "Key": _serialize(
                                    {
                                        "PK": f"QUEUE#{pointer['rulesHash']}",
                                        "SK": pointer["queueSk"],
                                    }
                                ),
                                "ConditionExpression": (
                                    "ticketId = :ticketId AND #status IN (:waiting, :claimed)"
                                ),
                                "ExpressionAttributeNames": {"#status": "status"},
                                "ExpressionAttributeValues": _serialize_values(
                                    {
                                        ":ticketId": ticket_id,
                                        ":waiting": "waiting",
                                        ":claimed": "claimed",
                                    }
                                ),
                            }
                        },
                        {
                            "Delete": {
                                "TableName": self._table_name,
                                "Key": _serialize({"PK": f"USER#{user_id}", "SK": "QUEUE"}),
                                "ConditionExpression": (
                                    "ticketId = :ticketId AND queueSk = :queueSk "
                                    "AND #status IN (:waiting, :claimed)"
                                ),
                                "ExpressionAttributeNames": {"#status": "status"},
                                "ExpressionAttributeValues": _serialize_values(
                                    {
                                        ":ticketId": ticket_id,
                                        ":queueSk": pointer["queueSk"],
                                        ":waiting": "waiting",
                                        ":claimed": "claimed",
                                    }
                                ),
                            }
                        },
                    ]
                )
                try:
                    self._table.delete_item(
                        Key={
                            "PK": f"USER#{user_id}",
                            "SK": f"TICKET#{ticket_id}",
                        },
                        ConditionExpression="#status IN (:waiting, :claimed)",
                        ExpressionAttributeNames={"#status": "status"},
                        ExpressionAttributeValues={
                            ":waiting": "waiting",
                            ":claimed": "claimed",
                        },
                    )
                except ClientError as error:
                    if error.response["Error"]["Code"] != "ConditionalCheckFailedException":
                        raise
                return True
            except ClientError as error:
                if error.response["Error"]["Code"] != "TransactionCanceledException":
                    raise
        return False

    def _delete_expired_queue(
        self,
        user_id: str,
        pointer: dict[str, Any],
        now: int,
    ) -> None:
        ticket_id = str(pointer["ticketId"])
        targets = [
            {
                "PK": f"QUEUE#{pointer['rulesHash']}",
                "SK": str(pointer["queueSk"]),
            },
            {"PK": f"USER#{user_id}", "SK": "QUEUE"},
            {"PK": f"USER#{user_id}", "SK": f"TICKET#{ticket_id}"},
        ]
        for key in targets:
            try:
                self._table.delete_item(
                    Key=key,
                    ConditionExpression="ticketId = :ticketId AND expiresAt <= :now",
                    ExpressionAttributeValues={
                        ":ticketId": ticket_id,
                        ":now": now,
                    },
                )
            except ClientError as error:
                if error.response["Error"]["Code"] != "ConditionalCheckFailedException":
                    raise

    def acquire_matchmaking_lock(self, user_id: str) -> str | None:
        token = secrets.token_urlsafe(18)
        now = int(datetime.now(UTC).timestamp())
        try:
            self._table.put_item(
                Item={
                    "PK": f"USER#{user_id}",
                    "SK": "MATCHMAKING_LOCK",
                    "entity": "matchmakingLock",
                    "token": token,
                    "expiresAt": int((datetime.now(UTC) + timedelta(seconds=30)).timestamp()),
                },
                ConditionExpression="attribute_not_exists(PK) OR expiresAt < :now",
                ExpressionAttributeValues={":now": now},
            )
            return token
        except ClientError as error:
            if error.response["Error"]["Code"] == "ConditionalCheckFailedException":
                return None
            raise

    def release_matchmaking_lock(self, user_id: str, token: str) -> None:
        try:
            self._table.delete_item(
                Key={"PK": f"USER#{user_id}", "SK": "MATCHMAKING_LOCK"},
                ConditionExpression="#token = :token",
                ExpressionAttributeNames={"#token": "token"},
                ExpressionAttributeValues={":token": token},
            )
        except ClientError as error:
            if error.response["Error"]["Code"] != "ConditionalCheckFailedException":
                raise

    def put_exchange(self, exchange: StoredExchange) -> None:
        self._table.put_item(
            Item={
                "PK": f"OAUTH#{exchange.code}",
                "SK": "TOKEN",
                "entity": "oauthExchange",
                "document": exchange.model_dump_json(by_alias=True),
                "expiresAt": int(exchange.expires_at.timestamp()),
            }
        )

    def consume_exchange(self, code: str) -> StoredExchange | None:
        response = self._table.delete_item(
            Key={"PK": f"OAUTH#{code}", "SK": "TOKEN"},
            ReturnValues="ALL_OLD",
        )
        item = response.get("Attributes")
        if not item:
            return None
        exchange = StoredExchange.model_validate_json(item["document"])
        return exchange if exchange.expires_at > datetime.now(UTC) else None

    def put_oauth_transaction(self, transaction: StoredOAuthTransaction) -> None:
        self._table.put_item(
            Item={
                "PK": f"OAUTH_TX#{transaction.id}",
                "SK": "STATE",
                "entity": "oauthTransaction",
                "document": transaction.model_dump_json(by_alias=True),
                "expiresAt": int(transaction.expires_at.timestamp()),
            },
            ConditionExpression="attribute_not_exists(PK)",
        )

    def consume_oauth_transaction(self, transaction_id: str) -> StoredOAuthTransaction | None:
        response = self._table.delete_item(
            Key={"PK": f"OAUTH_TX#{transaction_id}", "SK": "STATE"},
            ReturnValues="ALL_OLD",
        )
        item = response.get("Attributes")
        if not item:
            return None
        transaction = StoredOAuthTransaction.model_validate_json(item["document"])
        return transaction if transaction.expires_at > datetime.now(UTC) else None

    def upsert_push_subscription(
        self, subscription: StoredPushSubscription
    ) -> StoredPushSubscription:
        subscription_key = {
            "PK": f"USER#{subscription.user_id}",
            "SK": f"PUSH#{subscription.installation_id}",
        }
        existing_item = self._table.get_item(
            Key=subscription_key,
            ConsistentRead=True,
        ).get("Item")
        existing = (
            StoredPushSubscription.model_validate_json(existing_item["document"])
            if existing_item
            else None
        )
        stored = subscription.model_copy(
            update={"created_at": existing.created_at if existing else subscription.created_at}
        )
        owner_key = {
            "PK": f"INSTALLATION#{subscription.installation_id}",
            "SK": "OWNER",
        }
        previous_owner = self._table.get_item(
            Key=owner_key,
            ConsistentRead=True,
        ).get("Item")
        owner_condition = "attribute_not_exists(PK)"
        owner_values: dict[str, Any] = {}
        if previous_owner is not None:
            owner_condition = "userId = :previousUser AND installationId = :installationId"
            owner_values = {
                ":previousUser": str(previous_owner["userId"]),
                ":installationId": subscription.installation_id,
            }

        transaction: list[dict[str, Any]] = [*self._account_conditions(subscription.user_id)]
        if previous_owner is not None and previous_owner["userId"] != subscription.user_id:
            transaction.append(
                {
                    "Delete": {
                        "TableName": self._table_name,
                        "Key": _serialize(
                            {
                                "PK": f"USER#{previous_owner['userId']}",
                                "SK": f"PUSH#{subscription.installation_id}",
                            }
                        ),
                    }
                }
            )
        transaction.extend(
            [
                {
                    "Put": {
                        "TableName": self._table_name,
                        "Item": _serialize(
                            {
                                **subscription_key,
                                "entity": "pushSubscription",
                                "userId": subscription.user_id,
                                "installationId": subscription.installation_id,
                                "document": stored.model_dump_json(by_alias=True),
                            }
                        ),
                    }
                },
                {
                    "Put": {
                        "TableName": self._table_name,
                        "Item": _serialize(
                            {
                                **owner_key,
                                "entity": "pushInstallationOwner",
                                "userId": subscription.user_id,
                                "installationId": subscription.installation_id,
                            }
                        ),
                        "ConditionExpression": owner_condition,
                        **(
                            {"ExpressionAttributeValues": _serialize_values(owner_values)}
                            if owner_values
                            else {}
                        ),
                    }
                },
            ]
        )
        try:
            self._client.transact_write_items(TransactItems=transaction)
        except ClientError as error:
            if error.response["Error"]["Code"] == "TransactionCanceledException":
                raise ApiError(
                    "pushSubscriptionConflict",
                    "The push subscription changed during registration. Try again.",
                    status_code=409,
                ) from error
            raise
        return stored

    def list_push_subscriptions(self, user_id: str) -> list[StoredPushSubscription]:
        items = self._partition_items(f"USER#{user_id}", sk_prefix="PUSH#")
        subscriptions = [
            StoredPushSubscription.model_validate_json(item["document"]) for item in items
        ]
        return sorted(subscriptions, key=lambda value: value.created_at)

    def get_push_subscription(
        self, user_id: str, installation_id: str
    ) -> StoredPushSubscription | None:
        item = self._table.get_item(
            Key={"PK": f"USER#{user_id}", "SK": f"PUSH#{installation_id}"},
            ConsistentRead=True,
        ).get("Item")
        if item is None:
            return None
        return StoredPushSubscription.model_validate_json(item["document"])

    def delete_push_subscription(self, user_id: str, installation_id: str) -> None:
        subscription_key = {"PK": f"USER#{user_id}", "SK": f"PUSH#{installation_id}"}
        owner_key = {"PK": f"INSTALLATION#{installation_id}", "SK": "OWNER"}
        owner = self._table.get_item(Key=owner_key, ConsistentRead=True).get("Item")
        if owner is None or owner.get("userId") != user_id:
            self._table.delete_item(Key=subscription_key)
            return
        try:
            self._client.transact_write_items(
                TransactItems=[
                    {
                        "Delete": {
                            "TableName": self._table_name,
                            "Key": _serialize(subscription_key),
                        }
                    },
                    {
                        "Delete": {
                            "TableName": self._table_name,
                            "Key": _serialize(owner_key),
                            "ConditionExpression": (
                                "userId = :userId AND installationId = :installationId"
                            ),
                            "ExpressionAttributeValues": _serialize_values(
                                {":userId": user_id, ":installationId": installation_id}
                            ),
                        }
                    },
                ]
            )
        except ClientError as error:
            if error.response["Error"]["Code"] == "TransactionCanceledException":
                return
            raise

    def delete_push_subscription_if_unchanged(self, subscription: StoredPushSubscription) -> bool:
        subscription_key = {
            "PK": f"USER#{subscription.user_id}",
            "SK": f"PUSH#{subscription.installation_id}",
        }
        owner_key = {"PK": f"INSTALLATION#{subscription.installation_id}", "SK": "OWNER"}
        try:
            self._client.transact_write_items(
                TransactItems=[
                    {
                        "Delete": {
                            "TableName": self._table_name,
                            "Key": _serialize(subscription_key),
                            "ConditionExpression": "document = :document",
                            "ExpressionAttributeValues": _serialize_values(
                                {":document": subscription.model_dump_json(by_alias=True)}
                            ),
                        }
                    },
                    {
                        "Delete": {
                            "TableName": self._table_name,
                            "Key": _serialize(owner_key),
                            "ConditionExpression": (
                                "userId = :userId AND installationId = :installationId"
                            ),
                            "ExpressionAttributeValues": _serialize_values(
                                {
                                    ":userId": subscription.user_id,
                                    ":installationId": subscription.installation_id,
                                }
                            ),
                        }
                    },
                ]
            )
        except ClientError as error:
            if error.response["Error"]["Code"] == "TransactionCanceledException":
                return False
            raise
        return True

    def claim_notification_delivery(self, delivery_id: str) -> str | None:
        now = datetime.now(UTC)
        claim_token = secrets.token_urlsafe(18)
        try:
            self._table.put_item(
                Item={
                    "PK": f"DELIVERY#{delivery_id}",
                    "SK": "STATE",
                    "entity": "notificationDelivery",
                    "status": "sending",
                    "claimToken": claim_token,
                    "leaseExpiresAt": int((now + timedelta(minutes=5)).timestamp()),
                    "expiresAt": int((now + timedelta(days=7)).timestamp()),
                },
                ConditionExpression=(
                    "attribute_not_exists(PK) OR (#status = :sending AND leaseExpiresAt < :now)"
                ),
                ExpressionAttributeNames={"#status": "status"},
                ExpressionAttributeValues={":sending": "sending", ":now": int(now.timestamp())},
            )
        except ClientError as error:
            if error.response["Error"]["Code"] == "ConditionalCheckFailedException":
                return None
            raise
        return claim_token

    def complete_notification_delivery(self, delivery_id: str, claim_token: str) -> None:
        try:
            self._table.update_item(
                Key={"PK": f"DELIVERY#{delivery_id}", "SK": "STATE"},
                UpdateExpression=(
                    "SET #status = :delivered, expiresAt = :expiresAt REMOVE leaseExpiresAt"
                ),
                ConditionExpression="#status = :sending AND claimToken = :claimToken",
                ExpressionAttributeNames={"#status": "status"},
                ExpressionAttributeValues={
                    ":delivered": "delivered",
                    ":sending": "sending",
                    ":claimToken": claim_token,
                    ":expiresAt": int((datetime.now(UTC) + timedelta(days=7)).timestamp()),
                },
            )
        except ClientError as error:
            if error.response["Error"]["Code"] != "ConditionalCheckFailedException":
                raise

    def release_notification_delivery(self, delivery_id: str, claim_token: str) -> None:
        try:
            self._table.delete_item(
                Key={"PK": f"DELIVERY#{delivery_id}", "SK": "STATE"},
                ConditionExpression="#status = :sending AND claimToken = :claimToken",
                ExpressionAttributeNames={"#status": "status"},
                ExpressionAttributeValues={
                    ":sending": "sending",
                    ":claimToken": claim_token,
                },
            )
        except ClientError as error:
            if error.response["Error"]["Code"] != "ConditionalCheckFailedException":
                raise

    def _anonymize_match_cas(
        self, match_id: str, user_id: str, anonymous_id: str
    ) -> StoredMatch | None:
        for _ in range(8):
            item = self._table.get_item(
                Key={"PK": f"MATCH#{match_id}", "SK": "STATE"}, ConsistentRead=True
            ).get("Item")
            if item is None:
                return None
            current = self._parse_match(item)
            if current is None:
                return None
            updated = _anonymize_match(current, user_id, anonymous_id)
            if updated == current:
                return current
            try:
                self._table.put_item(
                    Item=self._match_item(updated),
                    ConditionExpression="#version = :version AND document = :document",
                    ExpressionAttributeNames={"#version": "version"},
                    ExpressionAttributeValues={
                        ":version": current.version,
                        ":document": str(item["document"]),
                    },
                )
                return updated
            except ClientError as error:
                if error.response["Error"]["Code"] != "ConditionalCheckFailedException":
                    raise
        raise ApiError(
            "accountDeletionBusy",
            "The match changed during account deletion. Retry.",
            status_code=409,
        )

    def _anonymize_move_cas(
        self,
        match_id: str,
        sort_key: str,
        user_id: str,
        anonymous_id: str,
        initial_item: dict[str, Any] | None = None,
    ) -> None:
        item = initial_item
        for _ in range(8):
            if item is None:
                item = self._table.get_item(
                    Key={"PK": f"MATCH#{match_id}", "SK": sort_key},
                    ConsistentRead=True,
                ).get("Item")
            if item is None:
                return
            raw_document = str(item["document"])
            current = MoveEvent.model_validate_json(raw_document)
            updated = _anonymize_move(current, user_id, anonymous_id)
            if updated == current:
                return
            try:
                self._table.put_item(
                    Item={
                        **item,
                        "document": updated.model_dump_json(by_alias=True),
                    },
                    ConditionExpression="document = :document",
                    ExpressionAttributeValues={":document": raw_document},
                )
                return
            except ClientError as error:
                if error.response["Error"]["Code"] != "ConditionalCheckFailedException":
                    raise
                item = None
        raise ApiError(
            "accountDeletionBusy",
            "Move history changed during account deletion. Retry.",
            status_code=409,
        )

    def _anonymize_counterpart_idempotency(
        self,
        owner_id: str,
        match_id: str,
        user_id: str,
        anonymous_id: str,
    ) -> None:
        for initial in self._partition_items(f"IDEMP#{owner_id}"):
            key = {"PK": initial["PK"], "SK": initial["SK"]}
            for _ in range(8):
                item = self._table.get_item(Key=key, ConsistentRead=True).get("Item")
                if item is None:
                    break
                document = item.get("document")
                if not isinstance(document, str):
                    break
                try:
                    snapshot = StoredMatch.model_validate_json(document)
                except ValueError:
                    break
                if snapshot.id != match_id:
                    break
                updated = _anonymize_match(snapshot, user_id, anonymous_id)
                if updated == snapshot:
                    break
                try:
                    self._table.put_item(
                        Item={
                            **item,
                            "document": updated.model_dump_json(by_alias=True),
                        },
                        ConditionExpression="document = :document",
                        ExpressionAttributeValues={":document": document},
                    )
                    break
                except ClientError as error:
                    if error.response["Error"]["Code"] != "ConditionalCheckFailedException":
                        raise
            else:
                raise ApiError(
                    "accountDeletionBusy",
                    "A retained command snapshot changed during account deletion. Retry.",
                    status_code=409,
                )

    def _remove_social_edges_for_deletion(self, user_id: str) -> None:
        for _ in range(4):
            _, relations, challenges = self.social_records(user_id)
            changed = False
            for relation in relations:
                try:
                    if relation.status == SocialRelationStatus.friends:
                        self.delete_friendship(relation, user_id)
                    else:
                        self.delete_friend_request(relation, user_id)
                    changed = True
                except ApiError as error:
                    if error.code not in {"friendNotFound", "friendRequestNotFound"}:
                        raise
            for challenge in challenges:
                try:
                    self.cancel_challenge(challenge, user_id)
                    changed = True
                except ApiError as error:
                    if error.code != "challengeNotFound":
                        raise
            if not changed:
                return
        _, relations, challenges = self.social_records(user_id)
        if relations or challenges:
            raise ApiError(
                "accountDeletionBusy",
                "Social data changed during account deletion. Retry.",
                status_code=409,
            )

    def delete_user_data(self, user_id: str) -> None:
        user_items = self._partition_items(f"USER#{user_id}")
        matches = [
            match
            for item in user_items
            if item.get("entity") == "membership"
            if (match := self.get_match(str(item["matchId"]))) is not None
        ]
        if any(match.status != MatchStatus.completed for match in matches):
            raise ApiError(
                "accountDeletionConflict",
                "All active matches must end before account data can be deleted.",
                status_code=409,
            )

        if self.account_state(user_id) != AccountState.deleting:
            raise ApiError(
                "accountDeletionConflict",
                "Account deletion must be fenced before cleanup.",
                status_code=409,
            )

        self._remove_social_edges_for_deletion(user_id)
        user_items = self._partition_items(f"USER#{user_id}")

        counterpart_ids_by_match: dict[str, set[str]] = {}
        for match in matches:
            anonymous_id = f"deleted-{uuid4()}"
            counterpart_ids_by_match[match.id] = {
                player.id
                for player in (match.black_player, match.white_player)
                if player is not None
                and player.id != user_id
                and not player.id.startswith("deleted-")
            }
            self._anonymize_match_cas(match.id, user_id, anonymous_id)
            for item in self._partition_items(f"MATCH#{match.id}", sk_prefix="MOVE#"):
                self._anonymize_move_cas(
                    match.id,
                    str(item["SK"]),
                    user_id,
                    anonymous_id,
                    initial_item=item,
                )
            for counterpart_id in counterpart_ids_by_match[match.id]:
                self._anonymize_counterpart_idempotency(
                    counterpart_id,
                    match.id,
                    user_id,
                    anonymous_id,
                )

        queue_pointer = next(
            (item for item in user_items if item.get("entity") == "queuePointer"),
            None,
        )
        if queue_pointer is not None:
            self._table.delete_item(
                Key={
                    "PK": f"QUEUE#{queue_pointer['rulesHash']}",
                    "SK": str(queue_pointer["queueSk"]),
                }
            )

        for subscription_item in (
            item for item in user_items if item.get("entity") == "pushSubscription"
        ):
            try:
                self._table.delete_item(
                    Key={
                        "PK": f"INSTALLATION#{subscription_item['installationId']}",
                        "SK": "OWNER",
                    },
                    ConditionExpression="userId = :userId",
                    ExpressionAttributeValues={":userId": user_id},
                )
            except ClientError as error:
                if error.response["Error"]["Code"] != "ConditionalCheckFailedException":
                    raise

        self._delete_items(self._partition_items(f"IDEMP#{user_id}"))
        self._delete_items(self._partition_items(f"PLAYER#{user_id}"))
        self._delete_items(self._partition_items(f"RATE#{user_id}"))
        self._delete_items([item for item in user_items if item.get("SK") != "ACCOUNT_DELETED"])

    def _partition_items(
        self,
        partition_key: str,
        *,
        sk_prefix: str | None = None,
    ) -> list[dict[str, Any]]:
        items: list[dict[str, Any]] = []
        expression = Key("PK").eq(partition_key)
        if sk_prefix is not None:
            expression &= Key("SK").begins_with(sk_prefix)
        query: dict[str, Any] = {
            "KeyConditionExpression": expression,
            "ConsistentRead": True,
        }
        while True:
            response = self._table.query(**query)
            items.extend(response.get("Items", []))
            last_key = response.get("LastEvaluatedKey")
            if not last_key:
                return items
            query["ExclusiveStartKey"] = last_key

    def _delete_items(self, items: list[dict[str, Any]]) -> None:
        for item in items:
            self._table.delete_item(Key={"PK": item["PK"], "SK": item["SK"]})


def _serialize(item: dict[str, Any]) -> dict[str, Any]:
    from boto3.dynamodb.types import TypeSerializer

    serializer = TypeSerializer()
    return {key: serializer.serialize(value) for key, value in item.items()}


def _serialize_values(item: dict[str, Any]) -> dict[str, Any]:
    return _serialize(item)


def _anonymize_match(match: StoredMatch, user_id: str, anonymous_id: str) -> StoredMatch:
    update: dict[str, Any] = {}
    if match.creator_id == user_id:
        update["creator_id"] = anonymous_id
        update["creator_name"] = "Deleted player"
    if match.black_player is not None and match.black_player.id == user_id:
        update["black_player"] = PlayerSummary(
            id=anonymous_id,
            display_name="Deleted player",
        )
    if match.white_player is not None and match.white_player.id == user_id:
        update["white_player"] = PlayerSummary(
            id=anonymous_id,
            display_name="Deleted player",
        )
    if not update:
        return match
    update["version"] = match.version + 1
    update["updated_at"] = datetime.now(UTC)
    return match.model_copy(update=update, deep=True)


def _anonymize_move(move: MoveEvent, user_id: str, anonymous_id: str) -> MoveEvent:
    if move.actor_id != user_id:
        return move
    return move.model_copy(update={"actor_id": anonymous_id}, deep=True)


def _pair_key(first_id: str, second_id: str) -> tuple[str, str]:
    first, second = sorted((first_id, second_id))
    return first, second


def _default_stats(player_id: str) -> StoredPlayerStats:
    return StoredPlayerStats(
        player_id=player_id,
        rating=1200,
        games=0,
        wins=0,
        losses=0,
        draws=0,
        kills=0,
        version=0,
    )


def _result_counters(score: float) -> tuple[int, int, int]:
    if score == 1.0:
        return 1, 0, 0
    if score == 0.0:
        return 0, 1, 0
    if score == 0.5:
        return 0, 0, 1
    raise ValueError("A completed match score must be 0, 0.5, or 1")


def _validate_metrics_payload(match: StoredMatch, metrics: MatchMetricsLedger) -> None:
    if match.status != MatchStatus.completed or not match.stats_finalized:
        raise ValueError("metrics require a finalized completed match")
    if match.completed_at is None or metrics.completed_at != match.completed_at:
        raise ValueError("metrics completion time must match the terminal match")
    if metrics.match_id != match.id:
        raise ValueError("metrics match ID must match the terminal match")
    if (metrics.black_kills, metrics.white_kills) != (
        match.black_kills,
        match.white_kills,
    ):
        raise ValueError("metrics kills must match the terminal match")
    result = match.result
    if result is None:
        raise ValueError("metrics require a terminal result")
    if result.get("type") == "draw":
        expected_score = 0.5
    elif result.get("type") == "win" and result.get("winner") == "black":
        expected_score = 1.0
    elif result.get("type") == "win" and result.get("winner") == "white":
        expected_score = 0.0
    else:
        raise ValueError("metrics require a supported terminal result")
    if metrics.black_score != expected_score:
        raise ValueError("metrics score must match the terminal result")
    if metrics.black_rating_delta != -metrics.white_rating_delta:
        raise ValueError("rating deltas must be zero-sum")
    if (
        metrics.black_rating_after != metrics.black_rating_before + metrics.black_rating_delta
        or metrics.white_rating_after != metrics.white_rating_before + metrics.white_rating_delta
    ):
        raise ValueError("rating before/after values must match their deltas")


def build_repository(settings: Settings) -> Repository:
    if settings.is_production:
        return DynamoRepository(settings)
    return InMemoryRepository()
