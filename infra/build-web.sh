#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  infra/build-web.sh \
    --api-base-url HTTPS_API_BASE_URL \
    [--google-sign-in-enabled true|false] \
    [--output BUILD_DIRECTORY]

Builds and validates the production Flutter web bundle shared by the
CloudFront and Vercel release paths.
USAGE
}

api_base_url=""
google_sign_in_enabled="false"
output_dir=""

while (($# > 0)); do
  case "$1" in
    --api-base-url)
      [[ $# -ge 2 ]] || { echo "Missing value for --api-base-url" >&2; exit 2; }
      api_base_url="$2"
      shift 2
      ;;
    --google-sign-in-enabled)
      [[ $# -ge 2 ]] || {
        echo "Missing value for --google-sign-in-enabled" >&2
        exit 2
      }
      google_sign_in_enabled="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || { echo "Missing value for --output" >&2; exit 2; }
      output_dir="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$api_base_url" ]]; then
  echo "--api-base-url is required." >&2
  usage >&2
  exit 2
fi

if [[ ! "$api_base_url" =~ ^(https://([A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?)(:[0-9]{1,5})?)(/[^?#[:space:]]*)?$ ]]; then
  echo "--api-base-url must be an HTTPS URL." >&2
  exit 2
fi

if [[ "$api_base_url" == */ ]]; then
  echo "--api-base-url must not have a trailing slash." >&2
  exit 2
fi

if [[ "$google_sign_in_enabled" != "true" && "$google_sign_in_enabled" != "false" ]]; then
  echo "--google-sign-in-enabled must be true or false." >&2
  exit 2
fi

if ! command -v flutter >/dev/null 2>&1; then
  echo "Required command is not installed: flutter" >&2
  exit 1
fi

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_dir="$repo_dir/apps/game_app"
canonical_output_dir="$app_dir/build/web"

if [[ -z "$output_dir" ]]; then
  output_dir="$canonical_output_dir"
fi

if [[ "$output_dir" != "$canonical_output_dir" ]]; then
  case "$output_dir" in
    /tmp/?*|/private/tmp/?*|/var/folders/?*) ;;
    *)
      echo "A custom --output must be a dedicated OS temporary directory." >&2
      exit 2
      ;;
  esac
  if [[ "$output_dir" == *"/../"* || "$output_dir" == */.. ]]; then
    echo "A custom --output must not contain parent-directory segments." >&2
    exit 2
  fi
  if [[ -d "$output_dir" ]] && [[ -n "$(find "$output_dir" -mindepth 1 -print -quit)" ]]; then
    echo "A custom --output must not contain pre-existing files." >&2
    exit 2
  fi
fi

echo "Building Flutter web application for API $api_base_url"
(
  cd "$app_dir"
  flutter clean
  flutter pub get
  flutter build web \
    --release \
    --no-web-resources-cdn \
    --output "$output_dir" \
    --dart-define="API_BASE_URL=$api_base_url" \
    --dart-define="GOOGLE_SIGN_IN_ENABLED=$google_sign_in_enabled"
)

required_build_files=(
  index.html
  flutter_bootstrap.js
  main.dart.js
  push-service-worker.js
  version.json
)
for relative_path in "${required_build_files[@]}"; do
  if [[ ! -f "$output_dir/$relative_path" ]]; then
    echo "Flutter build did not produce $output_dir/$relative_path." >&2
    exit 1
  fi
done

if ! grep -Eq '"useLocalCanvasKit"[[:space:]]*:[[:space:]]*true' \
  "$output_dir/flutter_bootstrap.js"; then
  echo "Flutter build is not configured to serve CanvasKit locally." >&2
  exit 1
fi

if ! grep -Eq \
  '"?fontFallbackBaseUrl"?[[:space:]]*:[[:space:]]*"/font-fallback/"' \
  "$output_dir/flutter_bootstrap.js"; then
  echo "Flutter build is not configured to use the same-origin font proxy." >&2
  exit 1
fi

echo "Flutter web build complete: $output_dir"
