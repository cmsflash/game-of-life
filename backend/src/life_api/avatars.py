from __future__ import annotations

import hashlib
import io
import json
import logging
import warnings
from dataclasses import dataclass
from typing import Protocol
from urllib.parse import quote
from uuid import uuid4

import boto3
from botocore.exceptions import ClientError
from fastapi import UploadFile
from PIL import Image, ImageOps

from .errors import ApiError
from .models import AvatarDocument, StoredPublicPlayer, User
from .repository import Repository
from .settings import Settings

LOGGER = logging.getLogger("life_api.avatars")

MAX_UPLOAD_BYTES = 3 * 1024 * 1024
MAX_SOURCE_EDGE = 4096
MAX_SOURCE_PIXELS = 16_000_000
AVATAR_EDGE = 512
_OUTPUT_CONTENT_TYPE = "image/webp"
_ALLOWED_FORMATS = {
    "JPEG": "image/jpeg",
    "PNG": "image/png",
    "WEBP": "image/webp",
}


class AvatarObjectStore(Protocol):
    def put(self, key: str, body: bytes) -> None: ...

    def get(self, key: str) -> bytes | None: ...

    def activate(self, key: str) -> None: ...

    def mark_for_deletion(self, key: str) -> None: ...

    def schedule_cleanup(self, user_id: str, key: str, *, delay_seconds: int) -> None: ...

    def delete(self, key: str) -> None: ...

    def delete_user_objects(self, user_id: str) -> None: ...


class InMemoryAvatarObjectStore:
    def __init__(self) -> None:
        self.objects: dict[str, bytes] = {}
        self.scheduled_cleanups: list[tuple[str, str, int]] = []

    def put(self, key: str, body: bytes) -> None:
        self.objects[key] = body

    def get(self, key: str) -> bytes | None:
        return self.objects.get(key)

    def activate(self, key: str) -> None:
        if key not in self.objects:
            raise RuntimeError("avatar object is missing")

    def mark_for_deletion(self, key: str) -> None:
        del key

    def schedule_cleanup(self, user_id: str, key: str, *, delay_seconds: int) -> None:
        self.scheduled_cleanups.append((user_id, key, delay_seconds))

    def delete(self, key: str) -> None:
        self.objects.pop(key, None)

    def delete_user_objects(self, user_id: str) -> None:
        prefix = _user_prefix(user_id)
        for key in [value for value in self.objects if value.startswith(prefix)]:
            self.objects.pop(key, None)


class S3AvatarObjectStore:
    def __init__(self, settings: Settings) -> None:
        if not settings.avatar_bucket_name:
            raise RuntimeError("AVATAR_BUCKET_NAME is required for S3 avatar storage")
        if not settings.avatar_cleanup_queue_url:
            raise RuntimeError("AVATAR_CLEANUP_QUEUE_URL is required for S3 avatar storage")
        self._bucket = settings.avatar_bucket_name
        self._cleanup_queue_url = settings.avatar_cleanup_queue_url
        self._client = boto3.client("s3", region_name=settings.aws_region)
        self._sqs = boto3.client("sqs", region_name=settings.aws_region)

    def put(self, key: str, body: bytes) -> None:
        self._client.put_object(
            Bucket=self._bucket,
            Key=key,
            Body=body,
            ContentType=_OUTPUT_CONTENT_TYPE,
            CacheControl="private, no-store",
            ContentDisposition="inline",
            ServerSideEncryption="AES256",
            Tagging="state=pending",
        )

    def get(self, key: str) -> bytes | None:
        try:
            response = self._client.get_object(Bucket=self._bucket, Key=key)
        except ClientError as error:
            if error.response["Error"]["Code"] in {"NoSuchKey", "404", "NotFound"}:
                return None
            raise
        return bytes(response["Body"].read())

    def activate(self, key: str) -> None:
        self._tag(key, "active")

    def mark_for_deletion(self, key: str) -> None:
        try:
            self._tag(key, "orphan")
        except ClientError as error:
            if error.response["Error"]["Code"] in {"NoSuchKey", "404", "NotFound"}:
                return
            raise

    def schedule_cleanup(self, user_id: str, key: str, *, delay_seconds: int) -> None:
        owner_digest = hashlib.sha256(user_id.encode()).hexdigest()
        self._sqs.send_message(
            QueueUrl=self._cleanup_queue_url,
            DelaySeconds=delay_seconds,
            MessageBody=json.dumps(
                {"ownerDigest": owner_digest, "key": key},
                separators=(",", ":"),
                sort_keys=True,
            ),
        )

    def delete(self, key: str) -> None:
        self._client.delete_object(Bucket=self._bucket, Key=key)

    def delete_user_objects(self, user_id: str) -> None:
        prefix = _user_prefix(user_id)
        paginator = self._client.get_paginator("list_objects_v2")
        empty_passes = 0
        for _ in range(8):
            keys = [
                str(value["Key"])
                for page in paginator.paginate(Bucket=self._bucket, Prefix=prefix)
                for value in page.get("Contents", [])
            ]
            if not keys:
                empty_passes += 1
                if empty_passes == 2:
                    return
                continue
            empty_passes = 0
            for offset in range(0, len(keys), 1000):
                response = self._client.delete_objects(
                    Bucket=self._bucket,
                    Delete={
                        "Objects": [{"Key": key} for key in keys[offset : offset + 1000]],
                        "Quiet": True,
                    },
                )
                errors = response.get("Errors", [])
                if errors:
                    raise RuntimeError("S3 did not delete every profile-picture object")
        raise RuntimeError("Profile-picture cleanup did not reach an empty prefix")

    def _tag(self, key: str, state: str) -> None:
        self._client.put_object_tagging(
            Bucket=self._bucket,
            Key=key,
            Tagging={"TagSet": [{"Key": "state", "Value": state}]},
        )


@dataclass(slots=True)
class AvatarService:
    repository: Repository
    store: AvatarObjectStore
    public_api_base_url: str

    def user_document(self, user: User) -> User:
        profile = self.repository.get_public_player(user.id)
        if profile is None:
            return user.model_copy(update={"avatar_url": None, "avatar_version": 0})
        return user.model_copy(
            update={
                "avatar_url": self.url(profile),
                "avatar_version": profile.avatar_version,
            }
        )

    def document(self, profile: StoredPublicPlayer) -> AvatarDocument:
        return AvatarDocument(
            avatar_url=self.url(profile),
            avatar_version=profile.avatar_version,
        )

    def url(self, profile: StoredPublicPlayer) -> str | None:
        if profile.avatar_key is None:
            return None
        player_id = quote(profile.id, safe="")
        return (
            f"{self.public_api_base_url.rstrip('/')}/v1/players/{player_id}/avatar"
            f"?v={profile.avatar_version}"
        )

    def upload(self, user: User, upload: UploadFile) -> AvatarDocument:
        profile = self._profile(user.id)
        self.repository.check_avatar_upload_rate(user.id)
        body = upload.file.read(MAX_UPLOAD_BYTES + 1)
        if len(body) > MAX_UPLOAD_BYTES:
            raise ApiError(
                "avatarTooLarge",
                "Profile pictures must be 3 MiB or smaller.",
                status_code=413,
            )
        if not body:
            raise ApiError("invalidAvatar", "Choose a non-empty image.", status_code=422)
        encoded = _validated_avatar(body, upload.content_type)
        key = f"{_user_prefix(user.id)}{uuid4()}.webp"
        self.store.put(key, encoded)
        try:
            # The delayed check is durable before the object can become active:
            # it removes the object unless the authoritative profile points to
            # this exact random key when the message is delivered.
            self.store.schedule_cleanup(user.id, key, delay_seconds=900)
        except Exception as storage_error:
            self._retire(user.id, key)
            raise ApiError(
                "avatarStorageUnavailable",
                "The profile picture could not be saved safely. Retry later.",
                status_code=503,
            ) from storage_error
        if profile.avatar_key is not None:
            try:
                self.store.schedule_cleanup(
                    user.id,
                    profile.avatar_key,
                    delay_seconds=60,
                )
                # Make the lifecycle fallback durable before the pointer CAS.
                # If the CAS loses, the queued worker sees the old pointer and
                # promotes this object back to active.
                self.store.mark_for_deletion(profile.avatar_key)
            except Exception as cleanup_schedule_error:
                self._activate_best_effort(profile.avatar_key)
                self._retire(user.id, key)
                raise ApiError(
                    "avatarStorageUnavailable",
                    "The previous profile picture could not be retired safely.",
                    status_code=503,
                ) from cleanup_schedule_error
        try:
            updated = self.repository.set_player_avatar(
                user.id,
                avatar_key=key,
                expected_profile_version=profile.version,
            )
        except Exception:
            if profile.avatar_key is not None:
                self._activate_best_effort(profile.avatar_key)
            self._retire(user.id, key)
            raise
        if profile.avatar_key is not None and profile.avatar_key != key:
            self._retire(user.id, profile.avatar_key)
        return self.document(updated)

    def remove(self, user: User) -> AvatarDocument:
        profile = self._profile(user.id)
        if profile.avatar_key is None:
            return self.document(profile)
        try:
            self.store.schedule_cleanup(user.id, profile.avatar_key, delay_seconds=60)
            self.store.mark_for_deletion(profile.avatar_key)
        except Exception as cleanup_schedule_error:
            self._activate_best_effort(profile.avatar_key)
            raise ApiError(
                "avatarStorageUnavailable",
                "The profile picture could not be retired safely.",
                status_code=503,
            ) from cleanup_schedule_error
        try:
            updated = self.repository.set_player_avatar(
                user.id,
                avatar_key=None,
                expected_profile_version=profile.version,
            )
        except Exception:
            self._activate_best_effort(profile.avatar_key)
            raise
        self._retire(user.id, profile.avatar_key)
        return self.document(updated)

    def image(self, player_id: str, version: int) -> bytes:
        profile = self.repository.get_public_player(player_id)
        if profile is None or profile.avatar_key is None or profile.avatar_version != version:
            raise ApiError("avatarNotFound", "That profile picture was not found.", status_code=404)
        image = self.store.get(profile.avatar_key)
        if image is None:
            raise ApiError("avatarNotFound", "That profile picture was not found.", status_code=404)
        return image

    def delete_user_objects(self, user_id: str) -> None:
        self.store.delete_user_objects(user_id)

    def prepare_account_deletion(self, user_id: str) -> str | None:
        profile = self.repository.get_public_player(user_id)
        if profile is None or profile.avatar_key is None:
            return None
        try:
            self.store.schedule_cleanup(user_id, profile.avatar_key, delay_seconds=60)
            self.store.mark_for_deletion(profile.avatar_key)
        except Exception as cleanup_schedule_error:
            self._activate_best_effort(profile.avatar_key)
            raise ApiError(
                "avatarStorageUnavailable",
                "The profile picture could not be prepared for account deletion.",
                status_code=503,
            ) from cleanup_schedule_error
        return profile.avatar_key

    def restore_prepared_avatar(self, key: str | None) -> None:
        if key is not None:
            self._activate_best_effort(key)

    def _retire(self, user_id: str, key: str) -> None:
        tagged = False
        try:
            self.store.mark_for_deletion(key)
            tagged = True
        except Exception:
            LOGGER.exception("Could not tag a superseded avatar for expiry")
        try:
            self.store.delete(key)
            return
        except Exception:
            LOGGER.exception("Could not immediately delete a superseded avatar")
        try:
            self.store.schedule_cleanup(user_id, key, delay_seconds=0)
        except Exception:
            if tagged:
                LOGGER.exception("Could not enqueue cleanup; S3 lifecycle will expire the object")
            else:
                # New objects are created with a pending tag; old objects reach
                # this method only after an orphan tag succeeded. If both this
                # retry and a redundant tag fail, the earlier durable delayed
                # check remains the primary cleanup path.
                LOGGER.exception("Could not enqueue immediate avatar cleanup")

    def _activate_best_effort(self, key: str) -> None:
        try:
            self.store.activate(key)
        except Exception:
            # The delayed worker promotes an exact current pointer. Keeping an
            # object pending/orphan is privacy-safe even if availability later
            # degrades under the one-day lifecycle fallback.
            LOGGER.exception("Could not mark the authoritative avatar active")

    def _profile(self, user_id: str) -> StoredPublicPlayer:
        profile = self.repository.get_public_player(user_id)
        if profile is None:
            raise ApiError("playerUnavailable", "That player is unavailable.", status_code=404)
        return profile


def build_avatar_service(settings: Settings, repository: Repository) -> AvatarService:
    store: AvatarObjectStore
    if settings.avatar_bucket_name:
        store = S3AvatarObjectStore(settings)
    else:
        store = InMemoryAvatarObjectStore()
    return AvatarService(
        repository=repository,
        store=store,
        public_api_base_url=settings.public_api_base_url or "http://testserver",
    )


def _validated_avatar(body: bytes, declared_content_type: str | None) -> bytes:
    if declared_content_type not in set(_ALLOWED_FORMATS.values()):
        raise ApiError(
            "unsupportedAvatarType",
            "Use a JPEG, PNG, or WebP profile picture.",
            status_code=415,
        )
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("error", Image.DecompressionBombWarning)
            with Image.open(io.BytesIO(body)) as probe:
                image_format = probe.format
                if image_format not in _ALLOWED_FORMATS:
                    raise ApiError(
                        "unsupportedAvatarType",
                        "Use a JPEG, PNG, or WebP profile picture.",
                        status_code=415,
                    )
                if _ALLOWED_FORMATS[image_format] != declared_content_type:
                    raise ApiError(
                        "avatarTypeMismatch",
                        "The uploaded file does not match its image type.",
                        status_code=422,
                    )
                if getattr(probe, "n_frames", 1) != 1:
                    raise ApiError(
                        "animatedAvatarUnsupported",
                        "Animated or multi-page profile pictures are not supported.",
                        status_code=422,
                    )
                width, height = probe.size
                if (
                    width < 1
                    or height < 1
                    or width > MAX_SOURCE_EDGE
                    or height > MAX_SOURCE_EDGE
                    or width * height > MAX_SOURCE_PIXELS
                ):
                    raise ApiError(
                        "invalidAvatarDimensions",
                        "Profile pictures may be at most 4096 pixels per side and 16 megapixels.",
                        status_code=422,
                    )
                probe.verify()

            with Image.open(io.BytesIO(body)) as source:
                source.load()
                oriented = ImageOps.exif_transpose(source)
                has_alpha = oriented.mode in {"RGBA", "LA"} or (
                    oriented.mode == "P" and "transparency" in oriented.info
                )
                converted = oriented.convert("RGBA" if has_alpha else "RGB")
                fitted = ImageOps.fit(
                    converted,
                    (AVATAR_EDGE, AVATAR_EDGE),
                    method=Image.Resampling.LANCZOS,
                )
                output = io.BytesIO()
                fitted.save(output, format="WEBP", quality=86, method=6, exact=True)
    except ApiError:
        raise
    except (Image.DecompressionBombError, Image.DecompressionBombWarning):
        raise ApiError(
            "invalidAvatarDimensions",
            "That image is too large to process safely.",
            status_code=422,
        ) from None
    except (OSError, SyntaxError, ValueError):
        raise ApiError(
            "invalidAvatar", "That file is not a valid image.", status_code=422
        ) from None
    encoded = output.getvalue()
    if not encoded or len(encoded) > MAX_UPLOAD_BYTES:
        raise ApiError(
            "invalidAvatar", "That image could not be processed safely.", status_code=422
        )
    return encoded


def _user_prefix(user_id: str) -> str:
    digest = hashlib.sha256(user_id.encode()).hexdigest()
    return f"avatars/{digest}/"
