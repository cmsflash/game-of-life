from __future__ import annotations

import io
import threading
from collections.abc import Callable
from typing import Any

from botocore.exceptions import ClientError
from conftest import register_and_login
from fastapi import UploadFile
from fastapi.testclient import TestClient
from PIL import Image
from starlette.datastructures import Headers

from life_api.avatars import AvatarService, InMemoryAvatarObjectStore, S3AvatarObjectStore
from life_api.errors import ApiError
from life_api.models import StoredPublicPlayer, User
from life_api.repository import InMemoryRepository


def _image_bytes(
    image_format: str = "PNG",
    *,
    size: tuple[int, int] = (80, 40),
    animated: bool = False,
) -> bytes:
    output = io.BytesIO()
    first = Image.new("RGB", size, (220, 30, 60))
    if animated:
        second = Image.new("RGB", size, (30, 60, 220))
        first.save(output, format=image_format, save_all=True, append_images=[second], duration=50)
    else:
        exif = Image.Exif()
        exif[274] = 6
        first.save(output, format=image_format, exif=exif, icc_profile=b"test-color-profile")
    return output.getvalue()


def _auth(client: TestClient, username: str) -> tuple[dict[str, Any], dict[str, str]]:
    tokens, authorization = register_and_login(
        client,
        username,
        display_name=f"{username.title()} Avatar",
    )
    return tokens["user"], {"Authorization": authorization}


def test_avatar_upload_reencodes_and_propagates_current_version(client: TestClient) -> None:
    alice, alice_headers = _auth(client, "alice")
    _, bob_headers = _auth(client, "bob")

    uploaded = client.post(
        "/v1/me/avatar",
        headers=alice_headers,
        files={"file": ("alice.png", _image_bytes(), "image/png")},
    )
    assert uploaded.status_code == 200
    first = uploaded.json()
    assert first["avatarVersion"] == 1
    assert first["avatarUrl"].endswith(f"/v1/players/{alice['id']}/avatar?v=1")

    delivered = client.get(first["avatarUrl"])
    assert delivered.status_code == 200
    assert delivered.headers["content-type"] == "image/webp"
    assert delivered.headers["cache-control"] == "public, max-age=60, must-revalidate"
    with Image.open(io.BytesIO(delivered.content)) as processed:
        assert processed.format == "WEBP"
        assert processed.size == (512, 512)
        assert getattr(processed, "n_frames", 1) == 1
        assert "exif" not in processed.info
        assert "icc_profile" not in processed.info

    found = client.get(
        "/v1/players/search",
        params={"q": "alice"},
        headers=bob_headers,
    )
    assert found.status_code == 200
    public = found.json()["items"][0]
    assert public["avatarUrl"] == first["avatarUrl"]
    assert public["avatarVersion"] == 1
    assert "avatarKey" not in found.text

    replaced = client.post(
        "/v1/me/avatar",
        headers=alice_headers,
        files={"file": ("alice.jpg", _image_bytes("JPEG"), "image/jpeg")},
    )
    assert replaced.status_code == 200
    assert replaced.json()["avatarVersion"] == 2
    assert client.get(first["avatarUrl"]).status_code == 404

    removed = client.delete("/v1/me/avatar", headers=alice_headers)
    assert removed.status_code == 200
    assert removed.json() == {"avatarUrl": None, "avatarVersion": 3}
    assert client.get(replaced.json()["avatarUrl"]).status_code == 404


def test_avatar_rejects_type_mismatch_animation_and_oversized_transport(
    client: TestClient,
) -> None:
    _, headers = _auth(client, "alice")

    mismatch = client.post(
        "/v1/me/avatar",
        headers=headers,
        files={"file": ("wrong.jpg", _image_bytes(), "image/jpeg")},
    )
    assert mismatch.status_code == 422
    assert mismatch.json()["error"]["code"] == "avatarTypeMismatch"

    animated = client.post(
        "/v1/me/avatar",
        headers=headers,
        files={"file": ("animated.webp", _image_bytes("WEBP", animated=True), "image/webp")},
    )
    assert animated.status_code == 422
    assert animated.json()["error"]["code"] == "animatedAvatarUnsupported"

    too_large = client.post(
        "/v1/me/avatar",
        headers=headers,
        files={"file": ("large.png", b"x" * (3 * 1024 * 1024 + 1), "image/png")},
    )
    assert too_large.status_code == 413
    assert too_large.json()["error"]["code"] == "avatarTooLarge"


def test_match_player_avatar_is_hydrated_after_replacement(client: TestClient) -> None:
    alice, alice_headers = _auth(client, "alice")
    _, bob_headers = _auth(client, "bob")
    waiting = client.post("/v1/matches", json={}, headers=alice_headers).json()
    joined = client.post(
        "/v1/matches/join",
        json={"joinCode": waiting["joinCode"]},
        headers=bob_headers,
    )
    assert joined.status_code == 200

    first = client.post(
        "/v1/me/avatar",
        headers=alice_headers,
        files={"file": ("first.png", _image_bytes(), "image/png")},
    ).json()
    initial_response = client.get(f"/v1/matches/{waiting['id']}", headers=alice_headers)
    initial_etag = initial_response.headers["etag"]
    initial_match = initial_response.json()
    alice_view = next(
        value
        for value in (initial_match["blackPlayer"], initial_match["whitePlayer"])
        if value["id"] == alice["id"]
    )
    assert alice_view["avatarUrl"] == first["avatarUrl"]
    unchanged = client.get(
        f"/v1/matches/{waiting['id']}",
        headers={**alice_headers, "If-None-Match": initial_etag},
    )
    assert unchanged.status_code == 304

    second = client.post(
        "/v1/me/avatar",
        headers=alice_headers,
        files={"file": ("second.jpg", _image_bytes("JPEG"), "image/jpeg")},
    ).json()
    refreshed_response = client.get(
        f"/v1/matches/{waiting['id']}",
        headers={**bob_headers, "If-None-Match": initial_etag},
    )
    assert refreshed_response.status_code == 200
    assert refreshed_response.headers["etag"] != initial_etag
    refreshed_match = refreshed_response.json()
    alice_view = next(
        value
        for value in (refreshed_match["blackPlayer"], refreshed_match["whitePlayer"])
        if value["id"] == alice["id"]
    )
    assert alice_view["avatarUrl"] == second["avatarUrl"]
    assert alice_view["avatarVersion"] == 2
    assert client.get(first["avatarUrl"]).status_code == 404


class BlockingStore(InMemoryAvatarObjectStore):
    def __init__(self, barrier: threading.Barrier | None = None) -> None:
        super().__init__()
        self.barrier = barrier
        self.put_started = threading.Event()
        self.release_put = threading.Event()

    def put(self, key: str, body: bytes) -> None:
        super().put(key, body)
        if self.barrier is not None:
            self.barrier.wait(timeout=5)
        else:
            self.put_started.set()
            assert self.release_put.wait(timeout=5)


class PostFencePutStore(InMemoryAvatarObjectStore):
    def __init__(self) -> None:
        super().__init__()
        self.put_started = threading.Event()
        self.release_put = threading.Event()

    def put(self, key: str, body: bytes) -> None:
        self.put_started.set()
        assert self.release_put.wait(timeout=5)
        super().put(key, body)

    def mark_for_deletion(self, key: str) -> None:
        del key
        raise RuntimeError("tagging unavailable")

    def delete(self, key: str) -> None:
        del key
        raise RuntimeError("deletion unavailable")


class LifecycleStore(InMemoryAvatarObjectStore):
    def __init__(self, events: list[str]) -> None:
        super().__init__()
        self.events = events
        self.states: dict[str, str] = {}

    def put(self, key: str, body: bytes) -> None:
        super().put(key, body)
        self.states[key] = "pending"
        self.events.append(f"put:{key}")

    def activate(self, key: str) -> None:
        super().activate(key)
        self.states[key] = "active"
        self.events.append(f"active:{key}")

    def mark_for_deletion(self, key: str) -> None:
        if key not in self.objects:
            raise RuntimeError("avatar object is missing")
        self.states[key] = "orphan"
        self.events.append(f"orphan:{key}")

    def schedule_cleanup(self, user_id: str, key: str, *, delay_seconds: int) -> None:
        super().schedule_cleanup(user_id, key, delay_seconds=delay_seconds)
        self.events.append(f"schedule:{delay_seconds}:{key}")

    def delete(self, key: str) -> None:
        super().delete(key)
        self.states.pop(key, None)
        self.events.append(f"delete:{key}")


class LifecycleRepository(InMemoryRepository):
    def __init__(self, events: list[str]) -> None:
        super().__init__()
        self.events = events
        self.crash_before_cas = False

    def set_player_avatar(
        self,
        user_id: str,
        *,
        avatar_key: str | None,
        expected_profile_version: int,
    ) -> StoredPublicPlayer:
        if self.crash_before_cas:
            raise SystemExit("simulated process death before avatar CAS")
        updated = super().set_player_avatar(
            user_id,
            avatar_key=avatar_key,
            expected_profile_version=expected_profile_version,
        )
        self.events.append(f"cas:{avatar_key}")
        return updated


def _upload() -> UploadFile:
    return UploadFile(
        file=io.BytesIO(_image_bytes()),
        filename="avatar.png",
        headers=Headers({"content-type": "image/png"}),
    )


def _avatar_service(
    store: InMemoryAvatarObjectStore,
) -> tuple[AvatarService, InMemoryRepository, User]:
    repository = InMemoryRepository()
    user = User(
        id="user-1",
        username="alice",
        email="alice@example.com",
        display_name="Alice Avatar",
    )
    repository.upsert_public_player(
        StoredPublicPlayer(
            id=user.id,
            display_name=user.display_name,
            normalized_display_name="alice avatar",
        )
    )
    return AvatarService(repository, store, "https://api.example.test"), repository, user


def _lifecycle_service() -> tuple[
    AvatarService,
    LifecycleRepository,
    LifecycleStore,
    User,
    list[str],
]:
    events: list[str] = []
    store = LifecycleStore(events)
    repository = LifecycleRepository(events)
    user = User(
        id="user-1",
        username="alice",
        email="alice@example.com",
        display_name="Alice Avatar",
    )
    repository.upsert_public_player(
        StoredPublicPlayer(
            id=user.id,
            display_name=user.display_name,
            normalized_display_name="alice avatar",
        )
    )
    return (
        AvatarService(repository, store, "https://api.example.test"),
        repository,
        store,
        user,
        events,
    )


def _service_with_missing_current() -> tuple[
    AvatarService,
    InMemoryRepository,
    InMemoryAvatarObjectStore,
    User,
]:
    store = InMemoryAvatarObjectStore()
    service, repository, user = _avatar_service(store)
    current = repository.get_public_player(user.id)
    assert current is not None
    repository.set_player_avatar(
        user.id,
        avatar_key=f"avatars/missing/{user.id}.webp",
        expected_profile_version=current.version,
    )
    return service, repository, store, user


def _run(call: Callable[[], object], errors: list[Exception]) -> None:
    try:
        call()
    except Exception as error:
        errors.append(error)


def test_concurrent_uploads_leave_only_the_winning_object() -> None:
    store = BlockingStore(threading.Barrier(2))
    service, repository, user = _avatar_service(store)
    errors: list[Exception] = []
    threads = [
        threading.Thread(target=_run, args=(lambda: service.upload(user, _upload()), errors))
        for _ in range(2)
    ]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(timeout=5)

    assert len(errors) == 1
    assert isinstance(errors[0], ApiError)
    profile = repository.get_public_player(user.id)
    assert profile is not None and profile.avatar_key is not None
    assert set(store.objects) == {profile.avatar_key}


def test_replacement_and_removal_make_lifecycle_safe_before_pointer_cas() -> None:
    service, repository, store, user, events = _lifecycle_service()
    first = service.upload(user, _upload())
    old_profile = repository.get_public_player(user.id)
    assert old_profile is not None and old_profile.avatar_key is not None
    old_key = old_profile.avatar_key
    assert store.states[old_key] == "pending"
    assert first.avatar_version == 1

    events.clear()
    second = service.upload(user, _upload())
    current = repository.get_public_player(user.id)
    assert current is not None and current.avatar_key is not None
    new_key = current.avatar_key
    assert second.avatar_version == 2
    assert events.index(f"schedule:60:{old_key}") < events.index(f"orphan:{old_key}")
    assert events.index(f"orphan:{old_key}") < events.index(f"cas:{new_key}")
    assert f"active:{new_key}" not in events
    assert store.states[new_key] == "pending"
    assert old_key not in store.objects

    events.clear()
    removed = service.remove(user)
    assert removed.avatar_version == 3
    assert events.index(f"schedule:60:{new_key}") < events.index(f"orphan:{new_key}")
    assert events.index(f"orphan:{new_key}") < events.index("cas:None")
    assert events.index("cas:None") < events.index(f"delete:{new_key}")


def test_crash_before_pointer_cas_leaves_only_pending_or_orphan_objects() -> None:
    service, repository, store, user, _ = _lifecycle_service()
    service.upload(user, _upload())
    old_profile = repository.get_public_player(user.id)
    assert old_profile is not None and old_profile.avatar_key is not None
    old_key = old_profile.avatar_key
    repository.crash_before_cas = True

    try:
        service.upload(user, _upload())
    except SystemExit:
        pass
    else:
        raise AssertionError("expected the simulated process death")

    current = repository.get_public_player(user.id)
    assert current is not None and current.avatar_key == old_key
    assert store.states[old_key] == "orphan"
    uncommitted = next(key for key in store.objects if key != old_key)
    assert store.states[uncommitted] == "pending"
    assert (user.id, old_key, 60) in store.scheduled_cleanups
    assert (user.id, uncommitted, 900) in store.scheduled_cleanups


def test_missing_current_object_does_not_block_replace_remove_or_account_delete() -> None:
    replace_service, _, _, replace_user = _service_with_missing_current()
    assert replace_service.upload(replace_user, _upload()).avatar_version == 2

    remove_service, _, _, remove_user = _service_with_missing_current()
    removed = remove_service.remove(remove_user)
    assert removed.avatar_url is None and removed.avatar_version == 2

    delete_service, delete_repository, _, delete_user = _service_with_missing_current()
    prepared = delete_service.prepare_account_deletion(delete_user.id)
    assert prepared is not None
    delete_repository.begin_user_deletion(delete_user.id)
    delete_service.delete_user_objects(delete_user.id)


class MissingTagClient:
    def put_object_tagging(self, **kwargs: Any) -> dict[str, Any]:
        del kwargs
        raise ClientError(
            {"Error": {"Code": "NoSuchKey", "Message": "missing"}},
            "PutObjectTagging",
        )


def test_s3_orphan_tagging_treats_a_missing_object_as_already_retired() -> None:
    store = object.__new__(S3AvatarObjectStore)
    store._bucket = "private-avatars"
    store._client = MissingTagClient()

    store.mark_for_deletion("avatars/owner/missing.webp")
    try:
        store.activate("avatars/owner/missing.webp")
    except ClientError as error:
        assert error.response["Error"]["Code"] == "NoSuchKey"
    else:
        raise AssertionError("activation of a missing current object must fail")


def test_unchanged_profile_refresh_does_not_conflict_with_avatar_upload() -> None:
    store = BlockingStore()
    service, repository, user = _avatar_service(store)
    errors: list[Exception] = []
    thread = threading.Thread(
        target=_run,
        args=(lambda: service.upload(user, _upload()), errors),
    )
    thread.start()
    assert store.put_started.wait(timeout=5)

    before = repository.get_public_player(user.id)
    assert before is not None
    repository.upsert_public_player(
        StoredPublicPlayer(
            id=user.id,
            display_name=user.display_name,
            normalized_display_name="alice avatar",
        )
    )
    refreshed = repository.get_public_player(user.id)
    assert refreshed is not None and refreshed.version == before.version

    store.release_put.set()
    thread.join(timeout=5)
    assert errors == []


def test_upload_racing_remove_or_account_delete_leaves_no_orphan() -> None:
    for delete_account in (False, True):
        store = BlockingStore()
        service, repository, user = _avatar_service(store)
        initial = service.upload
        store.release_put.set()
        initial(user, _upload())
        store.release_put.clear()
        store.put_started.clear()
        errors: list[Exception] = []
        thread = threading.Thread(
            target=_run,
            args=(
                lambda current_service=service, current_user=user: current_service.upload(
                    current_user, _upload()
                ),
                errors,
            ),
        )
        thread.start()
        assert store.put_started.wait(timeout=5)
        if delete_account:
            repository.begin_user_deletion(user.id)
            repository.delete_user_data(user.id)
            service.delete_user_objects(user.id)
        else:
            service.remove(user)
        store.release_put.set()
        thread.join(timeout=5)

        assert len(errors) == 1
        assert isinstance(errors[0], ApiError)
        assert store.objects == {}


def test_post_fence_put_is_private_and_has_durable_bounded_cleanup() -> None:
    store = PostFencePutStore()
    service, repository, user = _avatar_service(store)
    errors: list[Exception] = []
    thread = threading.Thread(
        target=_run,
        args=(lambda: service.upload(user, _upload()), errors),
    )
    thread.start()
    assert store.put_started.wait(timeout=5)

    repository.begin_user_deletion(user.id)
    service.delete_user_objects(user.id)
    assert store.objects == {}
    store.release_put.set()
    thread.join(timeout=5)

    assert len(errors) == 1
    assert isinstance(errors[0], ApiError)
    assert errors[0].code == "accountDeleting"
    assert len(store.objects) == 1
    remaining_key = next(iter(store.objects))
    assert (user.id, remaining_key, 900) in store.scheduled_cleanups
    assert (user.id, remaining_key, 0) in store.scheduled_cleanups
    try:
        service.image(user.id, 1)
    except ApiError as error:
        assert error.code == "avatarNotFound"
    else:
        raise AssertionError("a fenced account must never expose a racing object")


class ReadSpy(io.BytesIO):
    def __init__(self) -> None:
        super().__init__(b"not-an-image")
        self.was_read = False

    def read(self, size: int = -1) -> bytes:
        self.was_read = True
        return super().read(size)


def test_upload_rate_limit_fires_before_read_or_decode() -> None:
    store = InMemoryAvatarObjectStore()
    service, repository, user = _avatar_service(store)
    for _ in range(10):
        repository.check_avatar_upload_rate(user.id)
    source = ReadSpy()
    upload = UploadFile(
        file=source,
        filename="avatar.png",
        headers=Headers({"content-type": "image/png"}),
    )

    try:
        service.upload(user, upload)
    except ApiError as error:
        assert error.code == "avatarUploadRateLimited"
    else:
        raise AssertionError("expected the avatar rate limit")
    assert source.was_read is False
