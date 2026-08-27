#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_dir="$(mktemp -d)"
trap 'rm -rf "$temporary_dir"' EXIT

mock_bin="$temporary_dir/bin"
mock_log="$temporary_dir/commands.log"
mock_build="$temporary_dir/web-build"
mkdir -p "$mock_bin" "$mock_build"

cat >"$mock_bin/npx" <<'MOCK_NPX'
#!/usr/bin/env bash
set -euo pipefail
printf 'npx' >>"$MOCK_COMMAND_LOG"
printf ' %s' "$@" >>"$MOCK_COMMAND_LOG"
printf '\n' >>"$MOCK_COMMAND_LOG"

config_file=""
while (($# > 0)); do
  if [[ "$1" == "--local-config" ]]; then
    config_file="$2"
    break
  fi
  shift
done

[[ -n "$config_file" ]]
cp "$config_file" "$MOCK_VERCEL_CONFIG"
printf '%s\n' 'https://game-of-life-game-example.vercel.app'
MOCK_NPX
chmod +x "$mock_bin/npx"

for relative_path in \
  index.html \
  flutter_bootstrap.js \
  main.dart.js \
  push-service-worker.js \
  version.json; do
  printf '%s\n' "$relative_path https://api.example.com/prod" >"$mock_build/$relative_path"
done

generated_config="$temporary_dir/generated-vercel.json"
MOCK_COMMAND_LOG="$mock_log" \
MOCK_VERCEL_CONFIG="$generated_config" \
LIFE_WEB_BUILD_DIR="$mock_build" \
PATH="$mock_bin:$PATH" \
  "$repo_dir/infra/deploy-vercel-web.sh" \
    --api-base-url https://api.example.com/prod \
    --project game-of-life-game \
    --team team_example \
    --use-existing-build >/dev/null

grep -F -- "npx --yes vercel@59.9.1 deploy $mock_build --prod --yes --archive=tgz --project game-of-life-game --scope team_example" "$mock_log" >/dev/null
grep -F -- "img-src 'self' data: blob: https://api.example.com;" "$generated_config" >/dev/null
grep -F -- '"source": "/font-fallback/:path*"' "$generated_config" >/dev/null
grep -F -- '"destination": "https://fonts.gstatic.com/s/:path*"' "$generated_config" >/dev/null
grep -F -- '"destination": "/index.html"' "$generated_config" >/dev/null

if grep -F -- "__API_ORIGIN__" "$generated_config" >/dev/null; then
  echo "Expected the API origin placeholder to be replaced." >&2
  exit 1
fi

if LIFE_WEB_BUILD_DIR="$mock_build" \
  PATH="$mock_bin:$PATH" \
  "$repo_dir/infra/deploy-vercel-web.sh" \
    --api-base-url https://other.example.com/prod \
    --use-existing-build >/dev/null 2>&1; then
  echo "Expected a mismatched existing build to be rejected." >&2
  exit 1
fi

if LIFE_WEB_BUILD_DIR="$repo_dir" \
  PATH="$mock_bin:$PATH" \
  "$repo_dir/infra/deploy-vercel-web.sh" \
    --api-base-url https://api.example.com/prod \
    --use-existing-build >/dev/null 2>&1; then
  echo "Expected an unsafe build directory to be rejected." >&2
  exit 1
fi

echo "deploy-vercel-web.sh tests passed"
