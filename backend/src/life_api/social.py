from __future__ import annotations

import secrets
import unicodedata
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from uuid import uuid4

from .avatars import AvatarService
from .engine import Engine
from .errors import ApiError
from .models import (
    ChallengeAcceptResponse,
    ChallengeDocument,
    ChallengeListResponse,
    DiscoverabilityDocument,
    FriendListResponse,
    FriendRequestDocument,
    FriendRequestListResponse,
    MatchOrigin,
    MatchRulesRequest,
    MatchStatus,
    PlayerSearchResponse,
    PlayerStatsDocument,
    PlayerSummary,
    PublicPlayerDocument,
    SocialRelationStatus,
    SocialSnapshot,
    StoredChallenge,
    StoredMatch,
    StoredPublicPlayer,
    StoredSocialRelation,
    User,
)
from .ratings import accumulated_kills
from .repository import Repository

_SEARCH_LIMIT = 20
_CHALLENGE_LIFETIME = timedelta(days=7)


@dataclass(slots=True)
class SocialService:
    repository: Repository
    engine: Engine
    avatars: AvatarService

    def index_user(self, user: User) -> None:
        normalized = normalize_display_name(user.display_name)
        if not normalized:
            raise ApiError(
                "invalidDisplayName", "A public display name is required.", status_code=422
            )
        self.repository.upsert_public_player(
            StoredPublicPlayer(
                id=user.id,
                display_name=user.display_name,
                normalized_display_name=normalized,
            )
        )

    def search(self, user: User, query: str) -> PlayerSearchResponse:
        self._require_metrics_ready()
        normalized = normalize_display_name(query)
        if len(normalized) < 1 or len(normalized) > 48:
            raise ApiError(
                "invalidPlayerSearch",
                "Search with 1 to 48 display-name characters.",
                status_code=422,
            )
        self.repository.check_player_search_rate(user.id)
        players = self.repository.search_public_players(normalized, limit=_SEARCH_LIMIT + 1)
        return PlayerSearchResponse(
            items=[self._public(player) for player in players if player.id != user.id][
                :_SEARCH_LIMIT
            ]
        )

    def stats(self, user: User) -> PlayerStatsDocument:
        self._require_metrics_ready()
        stored = self.repository.get_player_stats(user.id)
        return PlayerStatsDocument(
            rating=stored.rating,
            games=stored.games,
            wins=stored.wins,
            losses=stored.losses,
            draws=stored.draws,
            kills=stored.kills + self._active_kills(user.id),
        )

    def _active_kills(self, user_id: str) -> int:
        total = 0
        for match in self.repository.list_matches(user_id):
            if match.status != MatchStatus.active or not match.rated:
                continue
            players = (match.black_player, match.white_player)
            if any(player is None or player.id.startswith("deleted-") for player in players):
                continue
            color = match.color_for(user_id)
            if color is None:
                continue
            black_kills, white_kills = self._match_kills(match)
            total += black_kills if color == "black" else white_kills
        return total

    def _match_kills(self, match: StoredMatch) -> tuple[int, int]:
        if match.kill_counts_complete:
            return match.black_kills, match.white_kills
        moves = [
            move for move in self.repository.list_moves(match.id) if move.revision <= match.revision
        ]
        expected_revisions = list(range(1, match.revision + 1))
        if [move.revision for move in moves] != expected_revisions:
            raise ApiError(
                "invalidMatchMetrics",
                "The active match history is incomplete.",
                status_code=500,
            )
        try:
            return accumulated_kills([move.delta for move in moves])
        except ValueError as error:
            raise ApiError(
                "invalidMatchMetrics",
                "The active match history has invalid kill data.",
                status_code=500,
            ) from error

    def snapshot(self, user: User) -> SocialSnapshot:
        self._require_metrics_ready()
        version, relations, challenges = self.repository.social_records(user.id)
        friends: list[PublicPlayerDocument] = []
        incoming_requests: list[FriendRequestDocument] = []
        outgoing_requests: list[FriendRequestDocument] = []
        for relation in relations:
            other = self.repository.get_public_player(relation.other(user.id))
            if other is None:
                continue
            public = self._public(other)
            if relation.status == SocialRelationStatus.friends:
                friends.append(public)
                continue
            request = FriendRequestDocument(
                id=relation.id,
                player=public,
                created_at=relation.created_at,
            )
            if relation.requester_id == user.id:
                outgoing_requests.append(request)
            else:
                incoming_requests.append(request)

        incoming_challenges: list[ChallengeDocument] = []
        outgoing_challenges: list[ChallengeDocument] = []
        for challenge in challenges:
            try:
                document = self._challenge_document(challenge)
            except ApiError as error:
                if error.code == "playerUnavailable":
                    continue
                raise
            if challenge.challenger.id == user.id:
                outgoing_challenges.append(document)
            else:
                incoming_challenges.append(document)

        def by_created(value: FriendRequestDocument | ChallengeDocument) -> datetime:
            return value.created_at

        return SocialSnapshot(
            version=version,
            # Rolling-client compatibility only. Active profiles are always
            # searchable during this development phase.
            discoverable=True,
            friends=sorted(friends, key=lambda value: (value.display_name.casefold(), value.id)),
            incoming_friend_requests=sorted(incoming_requests, key=by_created, reverse=True),
            outgoing_friend_requests=sorted(outgoing_requests, key=by_created, reverse=True),
            incoming_challenges=sorted(incoming_challenges, key=by_created, reverse=True),
            outgoing_challenges=sorted(outgoing_challenges, key=by_created, reverse=True),
        )

    def friends(self, user: User) -> FriendListResponse:
        return FriendListResponse(items=self.snapshot(user).friends)

    def set_discoverability(self, user: User, discoverable: bool) -> DiscoverabilityDocument:
        self._require_metrics_ready()
        stored, version = self.repository.set_player_discoverability(user.id, discoverable)
        return DiscoverabilityDocument(discoverable=stored, version=version)

    def friend_requests(self, user: User) -> FriendRequestListResponse:
        snapshot = self.snapshot(user)
        return FriendRequestListResponse(
            incoming=snapshot.incoming_friend_requests,
            outgoing=snapshot.outgoing_friend_requests,
        )

    def send_friend_request(self, user: User, player_id: str) -> FriendRequestDocument:
        self._require_metrics_ready()
        if player_id == user.id:
            raise ApiError("cannotFriendSelf", "A player cannot friend themself.", status_code=409)
        target = self._available_player(player_id)
        _, relations, _ = self.repository.social_records(user.id)
        if sum(value.status == SocialRelationStatus.pending for value in relations) >= 100:
            raise ApiError(
                "socialLimitReached", "Too many pending friend requests.", status_code=409
            )
        relation = StoredSocialRelation(
            id=str(uuid4()),
            first_player_id=min(user.id, player_id),
            second_player_id=max(user.id, player_id),
            requester_id=user.id,
            status=SocialRelationStatus.pending,
        )
        stored = self.repository.create_friend_request(relation)
        return FriendRequestDocument(
            id=stored.id,
            player=self._public(target),
            created_at=stored.created_at,
        )

    def accept_friend_request(self, user: User, request_id: str) -> None:
        self._require_metrics_ready()
        relation = self._relation_by_request(user.id, request_id)
        if relation.status == SocialRelationStatus.friends:
            return
        if relation.requester_id == user.id:
            raise ApiError(
                "friendRequestForbidden", "Only the recipient may accept.", status_code=403
            )
        self.repository.accept_friend_request(relation, user.id)

    def delete_friend_request(self, user: User, request_id: str) -> None:
        self._require_metrics_ready()
        relation = self._relation_by_request(user.id, request_id)
        self.repository.delete_friend_request(relation, user.id)

    def unfriend(self, user: User, player_id: str) -> None:
        self._require_metrics_ready()
        relation = self.repository.get_social_relation(user.id, player_id)
        if relation is None:
            raise ApiError("friendNotFound", "That player is not a friend.", status_code=404)
        self.repository.delete_friendship(relation, user.id)

    def challenges(self, user: User) -> ChallengeListResponse:
        snapshot = self.snapshot(user)
        return ChallengeListResponse(
            incoming=snapshot.incoming_challenges,
            outgoing=snapshot.outgoing_challenges,
        )

    def create_challenge(self, user: User, opponent_id: str) -> ChallengeDocument:
        self._require_metrics_ready()
        if opponent_id == user.id:
            raise ApiError(
                "cannotChallengeSelf", "A player cannot challenge themself.", status_code=409
            )
        opponent = self._available_player(opponent_id)
        _, _, challenges = self.repository.social_records(user.id)
        if len(challenges) >= 20:
            raise ApiError("socialLimitReached", "Too many pending challenges.", status_code=409)
        relation = self.repository.get_social_relation(user.id, opponent_id)
        if relation is None or relation.status != SocialRelationStatus.friends:
            raise ApiError("playerUnavailable", "That player is unavailable.", status_code=404)
        now = datetime.now(UTC)
        challenge = StoredChallenge(
            id=str(uuid4()),
            challenger=PlayerSummary(id=user.id, display_name=user.display_name),
            opponent=PlayerSummary(id=opponent.id, display_name=opponent.display_name),
            created_at=now,
            expires_at=now + _CHALLENGE_LIFETIME,
        )
        return self._challenge_document(self.repository.create_challenge(challenge))

    def accept_challenge(self, user: User, challenge_id: str) -> ChallengeAcceptResponse:
        self._require_metrics_ready()
        previous_match_id = self.repository.challenge_result(challenge_id)
        if previous_match_id is not None:
            previous = self.repository.get_match(previous_match_id)
            if (
                previous is None
                or previous.creator_id == user.id
                or previous.color_for(user.id) is None
            ):
                raise ApiError("challengeNotFound", "The challenge was not found.", status_code=404)
            return ChallengeAcceptResponse(match_id=previous_match_id)

        challenge = self.repository.get_challenge(challenge_id)
        if challenge is None or challenge.opponent.id != user.id:
            raise ApiError("challengeNotFound", "The challenge was not found.", status_code=404)
        if challenge.expires_at <= datetime.now(UTC):
            raise ApiError("challengeExpired", "The challenge expired.", status_code=409)
        relation = self.repository.get_social_relation(
            challenge.challenger.id,
            challenge.opponent.id,
        )
        if relation is None or relation.status != SocialRelationStatus.friends:
            raise ApiError("challengeUnavailable", "The challenge is unavailable.", status_code=409)
        rules = MatchRulesRequest().engine_rules()
        first = challenge.challenger
        second = challenge.opponent
        black, white = (first, second) if secrets.randbelow(2) == 0 else (second, first)
        match = StoredMatch(
            id=str(uuid4()),
            join_code=self._new_join_code(),
            rules=rules,
            state=self.engine.initial(rules),
            creator_id=challenge.challenger.id,
            creator_name=challenge.challenger.display_name,
            black_player=black,
            white_player=white,
            status=MatchStatus.active,
            version=1,
            origin=MatchOrigin.friend_challenge,
            rated=True,
            kill_counts_complete=True,
        )
        self.repository.accept_challenge(challenge, match, user.id)
        recovered = self.repository.challenge_result(challenge_id)
        return ChallengeAcceptResponse(match_id=recovered or match.id)

    def delete_challenge(self, user: User, challenge_id: str) -> None:
        self._require_metrics_ready()
        challenge = self.repository.get_challenge(challenge_id)
        if challenge is None or user.id not in {challenge.challenger.id, challenge.opponent.id}:
            raise ApiError("challengeNotFound", "The challenge was not found.", status_code=404)
        self.repository.cancel_challenge(challenge, user.id)

    def _relation_by_request(self, user_id: str, request_id: str) -> StoredSocialRelation:
        _, relations, _ = self.repository.social_records(user_id)
        relation = next((value for value in relations if value.id == request_id), None)
        if relation is None:
            raise ApiError(
                "friendRequestNotFound", "The friend request was not found.", status_code=404
            )
        return relation

    def _available_player(self, player_id: str) -> StoredPublicPlayer:
        player = self.repository.get_public_player(player_id)
        if player is None:
            raise ApiError("playerUnavailable", "That player is unavailable.", status_code=404)
        return player

    def _public(self, player: StoredPublicPlayer) -> PublicPlayerDocument:
        self._require_metrics_ready()
        stats = self.repository.get_player_stats(player.id)
        return PublicPlayerDocument(
            id=player.id,
            display_name=player.display_name,
            rating=stats.rating,
            avatar_url=self.avatars.url(player),
            avatar_version=player.avatar_version,
        )

    def _challenge_document(self, challenge: StoredChallenge) -> ChallengeDocument:
        challenger = self._available_player(challenge.challenger.id)
        opponent = self._available_player(challenge.opponent.id)
        return ChallengeDocument(
            id=challenge.id,
            challenger=self._public(challenger),
            opponent=self._public(opponent),
            created_at=challenge.created_at,
            expires_at=challenge.expires_at,
        )

    def _new_join_code(self) -> str:
        alphabet = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
        for _ in range(20):
            code = "".join(secrets.choice(alphabet) for _ in range(6))
            if self.repository.find_by_join_code(code) is None:
                return code
        raise ApiError("capacityError", "A join code could not be allocated.", status_code=503)

    def _require_metrics_ready(self) -> None:
        if self.repository.get_metrics_control().state.value != "ready":
            raise ApiError(
                "metricsBackfillInProgress",
                "Player ratings are temporarily unavailable.",
                status_code=503,
            )


def normalize_display_name(value: str) -> str:
    return " ".join(unicodedata.normalize("NFKC", value).casefold().split())
