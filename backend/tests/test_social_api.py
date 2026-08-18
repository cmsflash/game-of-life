from __future__ import annotations

from typing import Any

from conftest import register_and_login
from fastapi.testclient import TestClient


def _account(
    client: TestClient,
    username: str,
    display_name: str,
) -> tuple[dict[str, Any], dict[str, str]]:
    tokens, authorization = register_and_login(
        client,
        username,
        display_name=display_name,
    )
    return tokens["user"], {"Authorization": authorization}


def test_discovery_is_public_and_legacy_privacy_patch_is_a_no_op(
    client: TestClient,
) -> None:
    _, alice = _account(client, "alice", "Alice Strategist")
    bob_user, bob = _account(client, "bob", "Bob Builder")

    assert client.get("/v1/social", headers=bob).json()["discoverable"] is True

    legacy_disabled = client.patch(
        "/v1/social/discoverability",
        json={"discoverable": False},
        headers=bob,
    )
    assert legacy_disabled.status_code == 200
    assert legacy_disabled.json()["discoverable"] is True
    found = client.get(
        "/v1/players/search",
        params={"q": "  BOB   bu"},
        headers=alice,
    )
    assert found.status_code == 200
    assert found.json() == {
        "items": [
            {
                "id": bob_user["id"],
                "displayName": "Bob Builder",
                "rating": 1200,
                "avatarUrl": None,
                "avatarVersion": 0,
            }
        ]
    }
    assert "username" not in found.text
    assert "email" not in found.text

    request = client.post(
        "/v1/friends/requests",
        json={"playerId": bob_user["id"]},
        headers=alice,
    )
    assert request.status_code == 201


def test_friend_challenge_is_private_idempotent_and_updates_rated_stats(
    client: TestClient,
) -> None:
    alice_user, alice = _account(client, "alice", "Alice Strategist")
    bob_user, bob = _account(client, "bob", "Bob Builder")
    for headers in (alice, bob):
        assert (
            client.patch(
                "/v1/social/discoverability",
                json={"discoverable": True},
                headers=headers,
            ).status_code
            == 200
        )

    requested = client.post(
        "/v1/friends/requests",
        json={"playerId": bob_user["id"]},
        headers=alice,
    )
    assert requested.status_code == 201
    request_id = requested.json()["id"]
    incoming = client.get("/v1/social", headers=bob).json()
    assert incoming["incomingFriendRequests"][0]["id"] == request_id
    assert incoming["incomingFriendRequests"][0]["player"] == {
        "id": alice_user["id"],
        "displayName": "Alice Strategist",
        "rating": 1200,
        "avatarUrl": None,
        "avatarVersion": 0,
    }

    assert (
        client.post(
            f"/v1/friends/requests/{request_id}/accept",
            headers=bob,
        ).status_code
        == 204
    )
    assert client.get("/v1/friends", headers=alice).json()["items"][0]["id"] == bob_user["id"]

    challenge = client.post(
        "/v1/challenges",
        json={"opponentId": bob_user["id"]},
        headers=alice,
    )
    assert challenge.status_code == 201
    challenge_document = challenge.json()
    assert challenge_document["challenger"]["id"] == alice_user["id"]
    assert challenge_document["opponent"]["id"] == bob_user["id"]
    assert challenge_document["expiresAt"] > challenge_document["createdAt"]
    # A pending friend challenge is not a joinable/waiting-room match.
    assert client.get("/v1/matches", headers=alice).json()["items"] == []

    accepted = client.post(
        f"/v1/challenges/{challenge_document['id']}/accept",
        headers=bob,
    )
    assert accepted.status_code == 200
    repeated = client.post(
        f"/v1/challenges/{challenge_document['id']}/accept",
        headers=bob,
    )
    assert repeated.status_code == 200
    assert repeated.json() == accepted.json()
    match_id = accepted.json()["matchId"]

    match = client.get(f"/v1/matches/{match_id}", headers=alice)
    assert match.status_code == 200
    assert match.json()["origin"] == "friendChallenge"
    assert match.json()["rated"] is True
    assert match.json()["joinCode"] is None

    # A third party cannot use the internal join code, and neither participant
    # can route the active direct match through ordinary room joining.
    _, eve = _account(client, "eve", "Eve Observer")
    unavailable = client.post(
        "/v1/matches/join",
        json={"joinCode": "AAAAAA"},
        headers=eve,
    )
    assert unavailable.status_code == 404

    loser_headers = alice if match.json()["yourColor"] == "white" else bob
    resigned = client.post(
        f"/v1/matches/{match_id}/resign",
        json={"expectedRevision": 0, "idempotencyKey": "friend-resign-0001"},
        headers=loser_headers,
    )
    assert resigned.status_code == 200
    repeated_resign = client.post(
        f"/v1/matches/{match_id}/resign",
        json={"expectedRevision": 0, "idempotencyKey": "friend-resign-0001"},
        headers=loser_headers,
    )
    assert repeated_resign.status_code == 200

    alice_stats = client.get("/v1/stats/me", headers=alice).json()
    bob_stats = client.get("/v1/stats/me", headers=bob).json()
    assert alice_stats["games"] == bob_stats["games"] == 1
    assert alice_stats["wins"] + bob_stats["wins"] == 1
    assert alice_stats["losses"] + bob_stats["losses"] == 1
    assert alice_stats["rating"] + bob_stats["rating"] == 2400
    assert alice_stats["kills"] == bob_stats["kills"] == 0
    assert alice_stats["spawns"] == bob_stats["spawns"] == 0


def test_search_indexes_one_two_and_three_character_name_prefixes(client: TestClient) -> None:
    _, seeker = _account(client, "seeker", "Search Player")
    players = [
        _account(client, "shortone", "Q")[0],
        _account(client, "shorttwo", "Li")[0],
        _account(client, "shortthree", "Zed")[0],
    ]

    for query, expected in zip(("q", "li", "zed"), players, strict=True):
        response = client.get(
            "/v1/players/search",
            params={"q": query},
            headers=seeker,
        )
        assert response.status_code == 200
        assert [item["id"] for item in response.json()["items"]] == [expected["id"]]
