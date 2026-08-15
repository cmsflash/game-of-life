#!/usr/bin/env python3
"""Generate every platform icon from the canonical two-player 2x2 mark."""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import string
from pathlib import Path

import PIL
from PIL import Image, ImageDraw

APP_ROOT = Path(__file__).resolve().parents[1]
CANVAS = 1024
RENDER_SCALE = 4
EXPECTED_PILLOW_VERSION = "12.3.0"

INK = "#111318"
SPROUT = "#B7F36B"
PAPER = "#F7F3EA"
OUTLINE = "#85847F"

# The canonical mark mirrors LifeLogo: a centered 2x2 block whose diagonal
# cells belong to the same player. Platform masks use optical variants of this
# same normalized geometry so the mark stays legible and safely cropped.
TILE_BOX = (150, 150, 874, 874)
TILE_RADIUS = 221
TILE_STROKE = 20
CELL_SIZE = 160
CELL_RADIUS = 40
CELL_GAP = 54
CELL_ORIGIN = 325

FULL_CELL_SIZE = 225
FULL_CELL_RADIUS = 57
FULL_CELL_GAP = 77
FULL_CELL_ORIGIN = 249

ADAPTIVE_CELL_SIZE = 196
ADAPTIVE_CELL_RADIUS = 49
ADAPTIVE_CELL_GAP = 64
ADAPTIVE_CELL_ORIGIN = 284

IOS_ICON_SIZES = {
    "Icon-App-20x20@1x.png": 20,
    "Icon-App-20x20@2x.png": 40,
    "Icon-App-20x20@3x.png": 60,
    "Icon-App-29x29@1x.png": 29,
    "Icon-App-29x29@2x.png": 58,
    "Icon-App-29x29@3x.png": 87,
    "Icon-App-40x40@1x.png": 40,
    "Icon-App-40x40@2x.png": 80,
    "Icon-App-40x40@3x.png": 120,
    "Icon-App-60x60@2x.png": 120,
    "Icon-App-60x60@3x.png": 180,
    "Icon-App-76x76@1x.png": 76,
    "Icon-App-76x76@2x.png": 152,
    "Icon-App-83.5x83.5@2x.png": 167,
    "Icon-App-1024x1024@1x.png": 1024,
}

MACOS_ICON_SIZES = (16, 32, 64, 128, 256, 512, 1024)
ANDROID_ICON_SIZES = {
    "mipmap-mdpi/ic_launcher.png": 48,
    "mipmap-hdpi/ic_launcher.png": 72,
    "mipmap-xhdpi/ic_launcher.png": 96,
    "mipmap-xxhdpi/ic_launcher.png": 144,
    "mipmap-xxxhdpi/ic_launcher.png": 192,
}


def _scaled(value: int, output_size: int) -> int:
    numerator = value * output_size * RENDER_SCALE
    return (numerator + CANVAS // 2) // CANVAS


def _draw_cells(
    draw: ImageDraw.ImageDraw,
    *,
    origin: int,
    cell_size: int,
    gap: int,
    radius: int,
    output_size: int,
    monochrome: bool = False,
) -> None:
    colors = (PAPER,) * 4 if monochrome else (SPROUT, PAPER, PAPER, SPROUT)
    positions = (
        (origin, origin),
        (origin + cell_size + gap, origin),
        (origin, origin + cell_size + gap),
        (origin + cell_size + gap, origin + cell_size + gap),
    )
    for (x, y), color in zip(positions, colors, strict=True):
        draw.rounded_rectangle(
            (
                _scaled(x, output_size),
                _scaled(y, output_size),
                _scaled(x + cell_size, output_size),
                _scaled(y + cell_size, output_size),
            ),
            radius=_scaled(radius, output_size),
            fill=color,
        )


def _render_master(*, opaque: bool, output_size: int) -> Image.Image:
    side = output_size * RENDER_SCALE
    background = INK if opaque else (0, 0, 0, 0)
    image = Image.new("RGBA", (side, side), background)
    draw = ImageDraw.Draw(image)

    if opaque:
        _draw_cells(
            draw,
            origin=FULL_CELL_ORIGIN,
            cell_size=FULL_CELL_SIZE,
            gap=FULL_CELL_GAP,
            radius=FULL_CELL_RADIUS,
            output_size=output_size,
        )
    else:
        draw.rounded_rectangle(
            tuple(_scaled(value, output_size) for value in TILE_BOX),
            radius=_scaled(TILE_RADIUS, output_size),
            fill=INK,
            outline=OUTLINE,
            width=max(1, _scaled(TILE_STROKE, output_size)),
        )
        _draw_cells(
            draw,
            origin=CELL_ORIGIN,
            cell_size=CELL_SIZE,
            gap=CELL_GAP,
            radius=CELL_RADIUS,
            output_size=output_size,
        )
    return image


def _raster_image(size: int, *, opaque: bool) -> Image.Image:
    return _render_master(opaque=opaque, output_size=size).resize(
        (size, size),
        Image.Resampling.BOX,
    )


def _badge_png_bytes(size: int) -> bytes:
    side = size * RENDER_SCALE
    image = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    _draw_cells(
        ImageDraw.Draw(image),
        origin=FULL_CELL_ORIGIN,
        cell_size=FULL_CELL_SIZE,
        gap=FULL_CELL_GAP,
        radius=FULL_CELL_RADIUS,
        output_size=size,
        monochrome=True,
    )
    image = image.resize((size, size), Image.Resampling.BOX)
    output = io.BytesIO()
    image.save(output, format="PNG", compress_level=9, optimize=False)
    return output.getvalue()


def _png_bytes(size: int, *, opaque: bool, preserve_alpha: bool = False) -> bytes:
    image = _raster_image(size, opaque=opaque)
    if opaque and not preserve_alpha:
        image = image.convert("RGB")
    output = io.BytesIO()
    image.save(output, format="PNG", compress_level=9, optimize=False)
    return output.getvalue()


def _ico_bytes() -> bytes:
    sizes = (16, 24, 32, 48, 64, 128, 256)
    frames = [_raster_image(size, opaque=False) for size in reversed(sizes)]
    output = io.BytesIO()
    frames[0].save(
        output,
        format="ICO",
        sizes=[(size, size) for size in sizes],
        append_images=frames[1:],
    )
    return output.getvalue()


def _svg_bytes() -> bytes:
    return f'''<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <rect x="150" y="150" width="724" height="724" rx="221" fill="{INK}" stroke="{OUTLINE}" stroke-width="20"/>
  <rect x="325" y="325" width="160" height="160" rx="40" fill="{SPROUT}"/>
  <rect x="539" y="325" width="160" height="160" rx="40" fill="{PAPER}"/>
  <rect x="325" y="539" width="160" height="160" rx="40" fill="{PAPER}"/>
  <rect x="539" y="539" width="160" height="160" rx="40" fill="{SPROUT}"/>
</svg>
'''.encode()


def _android_foreground_bytes() -> bytes:
    return _android_cell_vector((SPROUT, PAPER, PAPER, SPROUT))


def _android_cell_path(x: int, y: int) -> str:
    radius = ADAPTIVE_CELL_RADIUS
    far_x = x + ADAPTIVE_CELL_SIZE
    far_y = y + ADAPTIVE_CELL_SIZE
    return (
        f"M{x + radius},{y} H{far_x - radius} "
        f"A{radius},{radius} 0,0 1,{far_x} {y + radius} "
        f"V{far_y - radius} A{radius},{radius} 0,0 1,{far_x - radius} {far_y} "
        f"H{x + radius} A{radius},{radius} 0,0 1,{x} {far_y - radius} "
        f"V{y + radius} A{radius},{radius} 0,0 1,{x + radius} {y} Z"
    )


def _android_cell_vector(colors: tuple[str, str, str, str]) -> bytes:
    offset = ADAPTIVE_CELL_SIZE + ADAPTIVE_CELL_GAP
    positions = (
        (ADAPTIVE_CELL_ORIGIN, ADAPTIVE_CELL_ORIGIN),
        (ADAPTIVE_CELL_ORIGIN + offset, ADAPTIVE_CELL_ORIGIN),
        (ADAPTIVE_CELL_ORIGIN, ADAPTIVE_CELL_ORIGIN + offset),
        (ADAPTIVE_CELL_ORIGIN + offset, ADAPTIVE_CELL_ORIGIN + offset),
    )
    paths = "\n".join(
        f'    <path android:fillColor="{color}" '
        f'android:pathData="{_android_cell_path(x, y)}" />'
        for (x, y), color in zip(positions, colors, strict=True)
    )
    return f"""<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="1024"
    android:viewportHeight="1024">
{paths}
</vector>
""".encode()


def _android_monochrome_bytes() -> bytes:
    return _android_cell_vector(("#FF000000",) * 4)


def _android_notification_bytes() -> bytes:
    return b"""<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="24"
    android:viewportHeight="24">
    <path android:fillColor="#FFFFFFFF" android:pathData="M6,4 H9 A2,2 0,0 1,11 6 V9 A2,2 0,0 1,9 11 H6 A2,2 0,0 1,4 9 V6 A2,2 0,0 1,6 4 Z" />
    <path android:fillColor="#FFFFFFFF" android:pathData="M15,4 H18 A2,2 0,0 1,20 6 V9 A2,2 0,0 1,18 11 H15 A2,2 0,0 1,13 9 V6 A2,2 0,0 1,15 4 Z" />
    <path android:fillColor="#FFFFFFFF" android:pathData="M6,13 H9 A2,2 0,0 1,11 15 V18 A2,2 0,0 1,9 20 H6 A2,2 0,0 1,4 18 V15 A2,2 0,0 1,6 13 Z" />
    <path android:fillColor="#FFFFFFFF" android:pathData="M15,13 H18 A2,2 0,0 1,20 15 V18 A2,2 0,0 1,18 20 H15 A2,2 0,0 1,13 18 V15 A2,2 0,0 1,15 13 Z" />
</vector>
"""


def _android_adaptive_bytes() -> bytes:
    return b"""<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background" />
    <foreground android:drawable="@drawable/ic_launcher_foreground" />
    <monochrome android:drawable="@drawable/ic_launcher_monochrome" />
</adaptive-icon>
"""


def build_assets() -> dict[Path, bytes]:
    assets: dict[Path, bytes] = {
        Path("assets/brand/app_icon.svg"): _svg_bytes(),
        Path("assets/brand/app_icon_1024.png"): _png_bytes(1024, opaque=False),
        Path("assets/brand/app_icon_ios_1024.png"): _png_bytes(1024, opaque=True),
        Path("assets/brand/play_store_icon_512.png"): _png_bytes(
            512,
            opaque=True,
            preserve_alpha=True,
        ),
        Path(
            "android/app/src/main/res/drawable/ic_launcher_foreground.xml"
        ): _android_foreground_bytes(),
        Path(
            "android/app/src/main/res/drawable/ic_launcher_monochrome.xml"
        ): _android_monochrome_bytes(),
        Path(
            "android/app/src/main/res/drawable/ic_stat_life.xml"
        ): _android_notification_bytes(),
        Path(
            "android/app/src/main/res/mipmap-anydpi-v33/ic_launcher.xml"
        ): _android_adaptive_bytes(),
        Path(
            "android/app/src/main/res/mipmap-anydpi-v33/ic_launcher_round.xml"
        ): _android_adaptive_bytes(),
        Path("web/favicon.png"): _png_bytes(32, opaque=False),
        Path("web/icons/Apple-touch-icon-180.png"): _png_bytes(180, opaque=True),
        Path("web/icons/Badge-96.png"): _badge_png_bytes(96),
        Path("web/icons/Icon-192.png"): _png_bytes(192, opaque=False),
        Path("web/icons/Icon-512.png"): _png_bytes(512, opaque=False),
        Path("web/icons/Icon-maskable-192.png"): _png_bytes(192, opaque=True),
        Path("web/icons/Icon-maskable-512.png"): _png_bytes(512, opaque=True),
        Path("windows/runner/resources/app_icon.ico"): _ico_bytes(),
    }

    for relative, size in ANDROID_ICON_SIZES.items():
        assets[Path("android/app/src/main/res") / relative] = _png_bytes(
            size,
            opaque=False,
        )
    for filename, size in IOS_ICON_SIZES.items():
        assets[Path("ios/Runner/Assets.xcassets/AppIcon.appiconset") / filename] = (
            _png_bytes(size, opaque=True)
        )
    for size in MACOS_ICON_SIZES:
        assets[
            Path("macos/Runner/Assets.xcassets/AppIcon.appiconset")
            / f"app_icon_{size}.png"
        ] = _png_bytes(size, opaque=False)
    return assets


def _validate_generated_assets(assets: dict[Path, bytes]) -> None:
    png_expectations: dict[Path, tuple[int, str]] = {
        Path("assets/brand/app_icon_1024.png"): (1024, "RGBA"),
        Path("assets/brand/app_icon_ios_1024.png"): (1024, "RGB"),
        Path("assets/brand/play_store_icon_512.png"): (512, "RGBA"),
        Path("web/favicon.png"): (32, "RGBA"),
        Path("web/icons/Apple-touch-icon-180.png"): (180, "RGB"),
        Path("web/icons/Badge-96.png"): (96, "RGBA"),
        Path("web/icons/Icon-192.png"): (192, "RGBA"),
        Path("web/icons/Icon-512.png"): (512, "RGBA"),
        Path("web/icons/Icon-maskable-192.png"): (192, "RGB"),
        Path("web/icons/Icon-maskable-512.png"): (512, "RGB"),
    }
    for relative, size in ANDROID_ICON_SIZES.items():
        png_expectations[Path("android/app/src/main/res") / relative] = (size, "RGBA")
    for filename, size in IOS_ICON_SIZES.items():
        png_expectations[
            Path("ios/Runner/Assets.xcassets/AppIcon.appiconset") / filename
        ] = (size, "RGB")
    for size in MACOS_ICON_SIZES:
        png_expectations[
            Path("macos/Runner/Assets.xcassets/AppIcon.appiconset")
            / f"app_icon_{size}.png"
        ] = (size, "RGBA")

    for path, (size, mode) in png_expectations.items():
        with Image.open(io.BytesIO(assets[path])) as image:
            if (
                image.format != "PNG"
                or image.size != (size, size)
                or image.mode != mode
            ):
                raise ValueError(
                    f"invalid generated PNG {path}: "
                    f"format={image.format} size={image.size} mode={image.mode}"
                )
            if (
                mode == "RGBA"
                and path != Path("assets/brand/play_store_icon_512.png")
                and (
                    image.getchannel("A").getextrema() != (0, 255)
                    or image.getpixel((0, 0))[3] != 0
                )
            ):
                raise ValueError(
                    f"transparent icon must have a clear corner and opaque art: {path}"
                )

    with Image.open(
        io.BytesIO(assets[Path("assets/brand/play_store_icon_512.png")])
    ) as play_icon:
        if play_icon.getchannel("A").getextrema() != (255, 255):
            raise ValueError("Google Play icon must be 32-bit and fully opaque")

    with Image.open(
        io.BytesIO(assets[Path("assets/brand/app_icon_ios_1024.png")])
    ) as canonical_icon:
        expected_cells = (
            ((361, 361), SPROUT),
            ((663, 361), PAPER),
            ((361, 663), PAPER),
            ((663, 663), SPROUT),
        )
        for position, expected_hex in expected_cells:
            expected_rgb = tuple(bytes.fromhex(expected_hex.removeprefix("#")))
            if canonical_icon.getpixel(position) != expected_rgb:
                raise ValueError(
                    "canonical icon must use the two-player diagonal 2x2 layout"
                )
        expected_background = tuple(bytes.fromhex(INK.removeprefix("#")))
        if canonical_icon.getpixel((0, 0)) != expected_background:
            raise ValueError("canonical opaque icon must use the ink background")

    with Image.open(
        io.BytesIO(assets[Path("assets/brand/app_icon_1024.png")])
    ) as transparent_icon:
        expected_cells = (
            ((405, 405), SPROUT),
            ((619, 405), PAPER),
            ((405, 619), PAPER),
            ((619, 619), SPROUT),
        )
        for position, expected_hex in expected_cells:
            expected_rgba = (*bytes.fromhex(expected_hex.removeprefix("#")), 255)
            if transparent_icon.getpixel(position) != expected_rgba:
                raise ValueError(
                    "transparent icon must use the two-player diagonal 2x2 layout"
                )
        expected_ink = (*bytes.fromhex(INK.removeprefix("#")), 255)
        if transparent_icon.getpixel((512, 512)) != expected_ink:
            raise ValueError("transparent icon tile must use the ink background")

    with Image.open(io.BytesIO(assets[Path("web/icons/Badge-96.png")])) as badge:
        expected_paper = (*bytes.fromhex(PAPER.removeprefix("#")), 255)
        for position in ((34, 34), (62, 34), (34, 62), (62, 62)):
            if badge.getpixel(position) != expected_paper:
                raise ValueError("notification badge must contain four paper cells")

    for path in (
        Path("assets/brand/app_icon.svg"),
        Path("android/app/src/main/res/drawable/ic_launcher_foreground.xml"),
    ):
        artwork = assets[path].decode()
        if artwork.count(SPROUT) != 2 or artwork.count(PAPER) != 2:
            raise ValueError(f"invalid two-player cell colors in {path}")
        if "#FF765E" in artwork or "#7FC8FF" in artwork:
            raise ValueError(f"legacy accent color remains in {path}")

    with Image.open(
        io.BytesIO(assets[Path("windows/runner/resources/app_icon.ico")])
    ) as icon:
        expected_sizes = {16, 24, 32, 48, 64, 128, 256}
        actual_sizes = {size[0] for size in icon.ico.sizes()}
        if actual_sizes != expected_sizes:
            raise ValueError(f"invalid Windows ICO frames: {sorted(actual_sizes)}")

    adaptive_block = 2 * ADAPTIVE_CELL_SIZE + ADAPTIVE_CELL_GAP
    adaptive_dp = adaptive_block * 108 / CANVAS
    if not 48 <= adaptive_dp <= 66:
        raise ValueError(
            f"adaptive foreground is outside the safe optical range: {adaptive_dp}"
        )


def _manifest_bytes(assets: dict[Path, bytes]) -> bytes:
    hashes = {
        path.as_posix(): hashlib.sha256(content).hexdigest()
        for path, content in sorted(assets.items(), key=lambda item: item[0].as_posix())
    }
    return (json.dumps(hashes, indent=2, sort_keys=True) + "\n").encode()


def _read_committed_assets(expected_paths: set[Path]) -> dict[Path, bytes]:
    manifest_path = APP_ROOT / "assets/brand/app_icon_assets.sha256.json"
    manifest_value = json.loads(manifest_path.read_text())
    if not isinstance(manifest_value, dict) or not all(
        isinstance(path, str) and isinstance(digest, str)
        for path, digest in manifest_value.items()
    ):
        raise ValueError("brand icon hash manifest must map paths to SHA-256 strings")

    expected_names = {path.as_posix() for path in expected_paths}
    actual_names = set(manifest_value)
    if actual_names != expected_names:
        missing = sorted(expected_names - actual_names)
        extra = sorted(actual_names - expected_names)
        raise ValueError(
            f"brand icon hash manifest inventory differs: missing={missing}, extra={extra}"
        )

    committed: dict[Path, bytes] = {}
    for relative in sorted(expected_paths, key=lambda path: path.as_posix()):
        expected_digest = manifest_value[relative.as_posix()]
        if (
            len(expected_digest) != 64
            or expected_digest != expected_digest.lower()
            or any(character not in string.hexdigits for character in expected_digest)
        ):
            raise ValueError(f"invalid SHA-256 digest for {relative}")
        content = (APP_ROOT / relative).read_bytes()
        actual_digest = hashlib.sha256(content).hexdigest()
        if actual_digest != expected_digest:
            raise ValueError(
                f"committed brand icon does not match its hash: {relative}"
            )
        committed[relative] = content
    return committed


def _validate_generated_matches_committed(
    generated: dict[Path, bytes],
    committed: dict[Path, bytes],
) -> None:
    for path in sorted(generated, key=lambda item: item.as_posix()):
        if path.suffix == ".png":
            with (
                Image.open(io.BytesIO(generated[path])) as generated_image,
                Image.open(io.BytesIO(committed[path])) as committed_image,
            ):
                if (
                    generated_image.mode != committed_image.mode
                    or generated_image.size != committed_image.size
                    or generated_image.tobytes() != committed_image.tobytes()
                ):
                    raise ValueError(
                        f"generated raster artwork differs from committed {path}"
                    )
        elif path.suffix == ".ico":
            with (
                Image.open(io.BytesIO(generated[path])) as generated_icon,
                Image.open(io.BytesIO(committed[path])) as committed_icon,
            ):
                generated_sizes = generated_icon.ico.sizes()
                committed_sizes = committed_icon.ico.sizes()
                if generated_sizes != committed_sizes:
                    raise ValueError(
                        f"generated ICO frames differ from committed {path}"
                    )
                for size in generated_sizes:
                    generated_frame = generated_icon.ico.getimage(size).convert("RGBA")
                    committed_frame = committed_icon.ico.getimage(size).convert("RGBA")
                    if generated_frame.tobytes() != committed_frame.tobytes():
                        raise ValueError(
                            f"generated ICO artwork differs from committed {path} at {size}"
                        )
        elif generated[path] != committed[path]:
            raise ValueError(f"generated source artwork differs from committed {path}")


def write_assets() -> None:
    assets = build_assets()
    _validate_generated_assets(assets)
    assets[Path("assets/brand/app_icon_assets.sha256.json")] = _manifest_bytes(assets)
    for relative, content in assets.items():
        destination = APP_ROOT / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        if not destination.exists() or destination.read_bytes() != content:
            destination.write_bytes(content)
            print(f"updated {relative}")


def check_assets() -> int:
    try:
        generated = build_assets()
        _validate_generated_assets(generated)
        committed = _read_committed_assets(set(generated))
        _validate_generated_assets(committed)
        _validate_generated_matches_committed(generated, committed)
    except (OSError, ValueError) as error:
        print(f"brand icon verification failed: {error}")
        return 1
    print(
        "brand icons verified "
        f"({len(committed)} committed hashes; generated semantics valid)"
    )
    return 0


def main() -> int:
    if PIL.__version__ != EXPECTED_PILLOW_VERSION:
        raise SystemExit(
            "brand icon generation requires Pillow "
            f"{EXPECTED_PILLOW_VERSION}; found {PIL.__version__}"
        )
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="verify committed assets without changing them",
    )
    args = parser.parse_args()
    if args.check:
        return check_assets()
    write_assets()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
