#!/usr/bin/env bash
set -euo pipefail

readonly vercel_cli_version="59.9.1"
readonly default_project="game-of-life-game"
readonly default_team="team_OaeRIiVwKocsx8aDSXm4mnsz"

usage() {
  cat <<'USAGE'
Usage:
  infra/deploy-vercel-web.sh \
    --api-base-url HTTPS_API_BASE_URL \
    [--google-sign-in-enabled true|false] \
    [--project VERCEL_PROJECT] \
    [--team VERCEL_TEAM_ID_OR_SLUG] \
    [--use-existing-build]

Builds the production Flutter web application and deploys it to Vercel. The
existing-build option is intended for a locally verified bundle produced from
the current source revision.
USAGE
}

api_base_url=""
google_sign_in_enabled="false"
project="$default_project"
team="$default_team"
use_existing_build="false"

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
    --project)
      [[ $# -ge 2 ]] || { echo "Missing value for --project" >&2; exit 2; }
      project="$2"
      shift 2
      ;;
    --team)
      [[ $# -ge 2 ]] || { echo "Missing value for --team" >&2; exit 2; }
      team="$2"
      shift 2
      ;;
    --use-existing-build)
      use_existing_build="true"
      shift
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
api_origin="${BASH_REMATCH[1]}"

if [[ "$api_base_url" == */ ]]; then
  echo "--api-base-url must not have a trailing slash." >&2
  exit 2
fi

if [[ "$google_sign_in_enabled" != "true" && "$google_sign_in_enabled" != "false" ]]; then
  echo "--google-sign-in-enabled must be true or false." >&2
  exit 2
fi

if [[ ! "$project" =~ ^[a-z0-9][a-z0-9._-]{0,99}$ ]]; then
  echo "--project must be a valid Vercel project name or ID." >&2
  exit 2
fi

if [[ ! "$team" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "--team must be a valid Vercel team ID or slug." >&2
  exit 2
fi

for required_command in grep npx sed; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    echo "Required command is not installed: $required_command" >&2
    exit 1
  fi
done

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="$repo_dir/apps/game_app/build/web"

if [[ -n "${LIFE_WEB_BUILD_DIR:-}" ]]; then
  build_dir="$LIFE_WEB_BUILD_DIR"
  case "$build_dir" in
    /tmp/?*|/private/tmp/?*|/var/folders/?*) ;;
    *)
      echo "LIFE_WEB_BUILD_DIR must be a dedicated OS temporary directory." >&2
      exit 2
      ;;
  esac
  if [[ "$build_dir" == *"/../"* || "$build_dir" == */.. ]]; then
    echo "LIFE_WEB_BUILD_DIR must not contain parent-directory segments." >&2
    exit 2
  fi
fi

if [[ "$use_existing_build" == "false" ]]; then
  "$repo_dir/infra/build-web.sh" \
    --api-base-url "$api_base_url" \
    --google-sign-in-enabled "$google_sign_in_enabled" \
    --output "$build_dir"
fi

required_build_files=(
  index.html
  flutter_bootstrap.js
  main.dart.js
  push-service-worker.js
  version.json
)
for relative_path in "${required_build_files[@]}"; do
  if [[ ! -f "$build_dir/$relative_path" ]]; then
    echo "The web bundle is missing $build_dir/$relative_path." >&2
    exit 1
  fi
done

if ! grep -F -- "$api_base_url" "$build_dir/main.dart.js" >/dev/null; then
  echo "The web bundle was not built for API $api_base_url." >&2
  exit 1
fi

temporary_dir="$(mktemp -d)"
trap 'rm -rf "$temporary_dir"' EXIT
vercel_config="$temporary_dir/vercel.json"
sed "s|__API_ORIGIN__|$api_origin|g" "$repo_dir/infra/vercel.json" >"$vercel_config"

if grep -F -- "__API_ORIGIN__" "$vercel_config" >/dev/null; then
  echo "The generated Vercel configuration still contains an API placeholder." >&2
  exit 1
fi

echo "Deploying Flutter web bundle to Vercel project $project"
npx --yes "vercel@$vercel_cli_version" deploy "$build_dir" \
  --prod \
  --yes \
  --archive=tgz \
  --project "$project" \
  --scope "$team" \
  --local-config "$vercel_config" \
  --no-color
