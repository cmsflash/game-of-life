#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  infra/deploy-web.sh \
    --stack-name STACK_NAME \
    --api-base-url HTTPS_API_BASE_URL \
    [--google-sign-in-enabled true|false] \
    [--profile AWS_PROFILE] \
    [--region us-east-1]

Builds the production Flutter web application, reads WebBucketName and
CloudFrontDistributionId from the web CloudFormation stack, synchronizes the
build with explicit cache metadata, and waits for a CloudFront invalidation.
USAGE
}

stack_name=""
api_base_url=""
google_sign_in_enabled="false"
aws_profile=""
aws_region="us-east-1"

while (($# > 0)); do
  case "$1" in
    --stack-name)
      [[ $# -ge 2 ]] || { echo "Missing value for --stack-name" >&2; exit 2; }
      stack_name="$2"
      shift 2
      ;;
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
    --profile)
      [[ $# -ge 2 ]] || { echo "Missing value for --profile" >&2; exit 2; }
      aws_profile="$2"
      shift 2
      ;;
    --region)
      [[ $# -ge 2 ]] || { echo "Missing value for --region" >&2; exit 2; }
      aws_region="$2"
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

if [[ -z "$stack_name" || -z "$api_base_url" ]]; then
  echo "--stack-name and --api-base-url are required." >&2
  usage >&2
  exit 2
fi

if [[ "$aws_region" != "us-east-1" ]]; then
  echo "The CloudFront web stack must be deployed in us-east-1." >&2
  exit 2
fi

if [[ ! "$api_base_url" =~ ^https://[^[:space:]]+$ ]]; then
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

for required_command in aws flutter; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    echo "Required command is not installed: $required_command" >&2
    exit 1
  fi
done

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_dir="$repo_dir/apps/game_app"
build_dir="$app_dir/build/web"

# The override exists for isolated CI testing only. Constrain it to a new or
# empty OS temporary directory so a mistaken environment variable can never
# make the recursive S3 sync upload a home directory or workspace.
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
  if [[ -d "$build_dir" ]] && [[ -n "$(find "$build_dir" -mindepth 1 -print -quit)" ]]; then
    echo "LIFE_WEB_BUILD_DIR must not contain pre-existing files." >&2
    exit 2
  fi
fi

aws_cli=(aws --no-cli-pager --region "$aws_region")
if [[ -n "$aws_profile" ]]; then
  aws_cli+=(--profile "$aws_profile")
fi

stack_output() {
  local output_key="$1"
  "${aws_cli[@]}" cloudformation describe-stacks \
    --stack-name "$stack_name" \
    --query "Stacks[0].Outputs[?OutputKey=='${output_key}'].OutputValue | [0]" \
    --output text
}

bucket_name="$(stack_output WebBucketName)"
distribution_id="$(stack_output CloudFrontDistributionId)"
web_base_url="$(stack_output WebBaseUrl)"

if [[ -z "$bucket_name" || "$bucket_name" == "None" ]]; then
  echo "Stack output WebBucketName is missing." >&2
  exit 1
fi

if [[ -z "$distribution_id" || "$distribution_id" == "None" ]]; then
  echo "Stack output CloudFrontDistributionId is missing." >&2
  exit 1
fi

if [[ ! "$bucket_name" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]]; then
  echo "Stack returned an invalid S3 bucket name." >&2
  exit 1
fi

if [[ ! "$distribution_id" =~ ^[A-Z0-9]+$ ]]; then
  echo "Stack returned an invalid CloudFront distribution ID." >&2
  exit 1
fi

echo "Building Flutter web application for API $api_base_url"
(
  cd "$app_dir"
  flutter clean
  flutter pub get
  flutter build web \
    --release \
    --no-web-resources-cdn \
    --output "$build_dir" \
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
  if [[ ! -f "$build_dir/$relative_path" ]]; then
    echo "Flutter build did not produce $build_dir/$relative_path." >&2
    exit 1
  fi
done

if ! grep -Eq '"useLocalCanvasKit"[[:space:]]*:[[:space:]]*true' \
  "$build_dir/flutter_bootstrap.js"; then
  echo "Flutter build is not configured to serve CanvasKit locally." >&2
  exit 1
fi

if ! grep -Eq \
  '"?fontFallbackBaseUrl"?[[:space:]]*:[[:space:]]*"/font-fallback/"' \
  "$build_dir/flutter_bootstrap.js"; then
  echo "Flutter build is not configured to use the same-origin font proxy." >&2
  exit 1
fi

echo "Synchronizing web build to s3://$bucket_name"
no_cache_files=(
  "index.html|text/html; charset=utf-8"
  "flutter_bootstrap.js|application/javascript"
  "flutter_service_worker.js|application/javascript"
  "push-service-worker.js|application/javascript"
  "manifest.json|application/manifest+json"
  "version.json|application/json"
)
revalidate_files=(
  "flutter.js|application/javascript"
  "main.dart.js|application/javascript"
  "assets/AssetManifest.bin|application/octet-stream"
  "assets/AssetManifest.bin.json|application/json"
  "assets/FontManifest.json|application/json"
)
sync_exclusions=()
for file_specification in "${no_cache_files[@]}" "${revalidate_files[@]}"; do
  sync_exclusions+=(--exclude "${file_specification%%|*}")
done

# Upload immutable and ordinary assets first while the prior startup shell
# remains intact. Stable startup files and JavaScript bundles are replaced only
# after their dependencies are present, so an interrupted release remains
# bootable from the previous shell.
"${aws_cli[@]}" s3 sync \
  "$build_dir/" \
  "s3://$bucket_name/" \
  --delete \
  --cache-control "public,max-age=3600,must-revalidate" \
  --no-progress \
  --only-show-errors \
  "${sync_exclusions[@]}"

# These stable filenames coordinate application startup and releases. Always
# re-upload them so their cache metadata is correct even when their bytes did
# not change between builds.
for file_specification in "${no_cache_files[@]}"; do
  relative_path="${file_specification%%|*}"
  content_type="${file_specification#*|}"
  if [[ -f "$build_dir/$relative_path" ]]; then
    "${aws_cli[@]}" s3 cp \
      "$build_dir/$relative_path" \
      "s3://$bucket_name/$relative_path" \
      --cache-control "no-cache,no-store,max-age=0,must-revalidate" \
      --content-type "$content_type" \
      --only-show-errors
  fi
done

for file_specification in "${revalidate_files[@]}"; do
  relative_path="${file_specification%%|*}"
  content_type="${file_specification#*|}"
  if [[ -f "$build_dir/$relative_path" ]]; then
    "${aws_cli[@]}" s3 cp \
      "$build_dir/$relative_path" \
      "s3://$bucket_name/$relative_path" \
      --cache-control "public,max-age=0,must-revalidate,s-maxage=3600" \
      --content-type "$content_type" \
      --only-show-errors
  fi
done

# CanvasKit filenames stay stable across Flutter releases. Require browser
# revalidation so a previously visited phone never combines a new bootstrap
# with an old JavaScript renderer after a deployment.
while IFS= read -r -d '' canvaskit_js_path; do
  relative_path="${canvaskit_js_path#"$build_dir/"}"
  "${aws_cli[@]}" s3 cp \
    "$canvaskit_js_path" \
    "s3://$bucket_name/$relative_path" \
    --cache-control "public,max-age=0,must-revalidate,s-maxage=3600" \
    --content-type "application/javascript" \
    --only-show-errors
done < <(find "$build_dir/canvaskit" -type f -name "*.js" -print0)

# WebAssembly streaming compilation requires the application/wasm media type.
# Set it explicitly instead of depending on the deployer's host MIME database.
while IFS= read -r -d '' wasm_path; do
  relative_path="${wasm_path#"$build_dir/"}"
  "${aws_cli[@]}" s3 cp \
    "$wasm_path" \
    "s3://$bucket_name/$relative_path" \
    --cache-control "public,max-age=0,must-revalidate,s-maxage=3600" \
    --content-type "application/wasm" \
    --only-show-errors
done < <(find "$build_dir" -type f -name "*.wasm" -print0)

echo "Invalidating CloudFront distribution $distribution_id"
invalidation_id="$(
  "${aws_cli[@]}" cloudfront create-invalidation \
    --distribution-id "$distribution_id" \
    --paths "/*" \
    --query "Invalidation.Id" \
    --output text
)"

if [[ -z "$invalidation_id" || "$invalidation_id" == "None" ]]; then
  echo "CloudFront did not return an invalidation ID." >&2
  exit 1
fi

"${aws_cli[@]}" cloudfront wait invalidation-completed \
  --distribution-id "$distribution_id" \
  --id "$invalidation_id"

echo "Web release complete: $web_base_url"
