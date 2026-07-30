#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_dir="$(mktemp -d)"
trap 'rm -rf "$temporary_dir"' EXIT

mock_bin="$temporary_dir/bin"
mock_log="$temporary_dir/commands.log"
mock_build="$temporary_dir/web-build"
mkdir -p "$mock_bin"

cat >"$mock_bin/aws" <<'MOCK_AWS'
#!/usr/bin/env bash
set -euo pipefail
printf 'aws' >>"$MOCK_COMMAND_LOG"
printf ' %q' "$@" >>"$MOCK_COMMAND_LOG"
printf '\n' >>"$MOCK_COMMAND_LOG"

arguments="$*"
case "$arguments" in
  *"OutputKey=='WebBucketName'"*)
    printf '%s\n' "life-production-web-123456789012"
    ;;
  *"OutputKey=='CloudFrontDistributionId'"*)
    printf '%s\n' "E123EXAMPLE"
    ;;
  *"OutputKey=='WebBaseUrl'"*)
    printf '%s\n' "https://play.example.com"
    ;;
  *"cloudfront create-invalidation"*)
    printf '%s\n' "I123EXAMPLE"
    ;;
esac
MOCK_AWS

cat >"$mock_bin/flutter" <<'MOCK_FLUTTER'
#!/usr/bin/env bash
set -euo pipefail
printf 'flutter' >>"$MOCK_COMMAND_LOG"
printf ' %q' "$@" >>"$MOCK_COMMAND_LOG"
printf '\n' >>"$MOCK_COMMAND_LOG"

if [[ "${1:-}" != "build" || "${2:-}" != "web" ]]; then
  exit 0
fi

output_dir=""
while (($# > 0)); do
  if [[ "$1" == "--output" ]]; then
    output_dir="$2"
    break
  fi
  shift
done

[[ -n "$output_dir" ]]
mkdir -p "$output_dir/assets" "$output_dir/canvaskit"
for file in \
  index.html \
  flutter_bootstrap.js \
  flutter_service_worker.js \
  flutter.js \
  main.dart.js \
  manifest.json \
  version.json \
  assets/AssetManifest.bin \
  assets/AssetManifest.bin.json \
  assets/FontManifest.json \
  canvaskit/canvaskit.js \
  canvaskit/canvaskit.wasm; do
  printf '%s\n' "$file" >"$output_dir/$file"
done
printf '%s\n' \
  '{"useLocalCanvasKit":true,"fontFallbackBaseUrl":"/font-fallback/"}' \
  >"$output_dir/flutter_bootstrap.js"
MOCK_FLUTTER

chmod +x "$mock_bin/aws" "$mock_bin/flutter"

MOCK_COMMAND_LOG="$mock_log" \
LIFE_WEB_BUILD_DIR="$mock_build" \
PATH="$mock_bin:$PATH" \
  "$repo_dir/infra/deploy-web.sh" \
    --stack-name life-web-test \
    --api-base-url https://api.example.com \
    --google-sign-in-enabled true \
    --profile test-profile

grep -F -- "flutter build web --release --no-web-resources-cdn --output $mock_build --dart-define=API_BASE_URL=https://api.example.com --dart-define=GOOGLE_SIGN_IN_ENABLED=true" "$mock_log" >/dev/null
grep -F -- "s3 sync $mock_build/ s3://life-production-web-123456789012/ --delete" "$mock_log" >/dev/null
grep -F -- "--exclude index.html" "$mock_log" >/dev/null
grep -F -- "--exclude main.dart.js" "$mock_log" >/dev/null
grep -F -- "main.dart.js s3://life-production-web-123456789012/main.dart.js --cache-control public,max-age=0,must-revalidate,s-maxage=3600" "$mock_log" >/dev/null
grep -F -- "assets/AssetManifest.bin s3://life-production-web-123456789012/assets/AssetManifest.bin --cache-control public,max-age=0,must-revalidate,s-maxage=3600" "$mock_log" >/dev/null
grep -F -- "canvaskit/canvaskit.js s3://life-production-web-123456789012/canvaskit/canvaskit.js --cache-control public,max-age=0,must-revalidate,s-maxage=3600 --content-type application/javascript" "$mock_log" >/dev/null
grep -F -- "canvaskit/canvaskit.wasm s3://life-production-web-123456789012/canvaskit/canvaskit.wasm" "$mock_log" >/dev/null
grep -F -- "--cache-control public,max-age=0,must-revalidate,s-maxage=3600 --content-type application/wasm" "$mock_log" >/dev/null
grep -F -- "--content-type application/wasm" "$mock_log" >/dev/null
grep -F -- "cloudfront create-invalidation --distribution-id E123EXAMPLE --paths /\\*" "$mock_log" >/dev/null
grep -F -- "cloudfront wait invalidation-completed --distribution-id E123EXAMPLE --id I123EXAMPLE" "$mock_log" >/dev/null

if "$repo_dir/infra/deploy-web.sh" \
  --stack-name life-web-test \
  --api-base-url https://api.example.com/ >/dev/null 2>&1; then
  echo "Expected a trailing API slash to be rejected." >&2
  exit 1
fi

if "$repo_dir/infra/deploy-web.sh" \
  --stack-name life-web-test \
  --api-base-url https://api.example.com \
  --region ap-east-1 >/dev/null 2>&1; then
  echo "Expected a non-us-east-1 web stack region to be rejected." >&2
  exit 1
fi

if "$repo_dir/infra/deploy-web.sh" \
  --stack-name life-web-test \
  --api-base-url https://api.example.com \
  --google-sign-in-enabled maybe >/dev/null 2>&1; then
  echo "Expected an invalid Google sign-in flag to be rejected." >&2
  exit 1
fi

if LIFE_WEB_BUILD_DIR="$repo_dir" \
  "$repo_dir/infra/deploy-web.sh" \
  --stack-name life-web-test \
  --api-base-url https://api.example.com >/dev/null 2>&1; then
  echo "Expected an unsafe build-output override to be rejected." >&2
  exit 1
fi

echo "deploy-web.sh tests passed"
