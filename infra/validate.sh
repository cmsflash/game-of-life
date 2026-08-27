#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

SAM_CLI_TELEMETRY=0 sam validate --template-file infra/template.yaml --lint
SAM_CLI_TELEMETRY=0 sam validate \
  --template-file infra/web-template.yaml \
  --region us-east-1 \
  --lint
bash -n \
  infra/build-web.sh \
  infra/deploy-web.sh \
  infra/deploy-vercel-web.sh \
  infra/test-deploy-web.sh \
  infra/test-deploy-vercel-web.sh
infra/test-deploy-web.sh
infra/test-deploy-vercel-web.sh

python3 -m json.tool infra/vercel.json >/dev/null

grep -F 'id="life-startup"' apps/game_app/web/index.html >/dev/null
grep -F 'id="life-startup-retry"' apps/game_app/web/index.html >/dev/null
grep -F 'onEntrypointLoaded: async' apps/game_app/web/flutter_bootstrap.js >/dev/null
grep -F 'initializeEngine(engineConfig)' apps/game_app/web/flutter_bootstrap.js >/dev/null
grep -F '.catch(failStartup)' apps/game_app/web/flutter_bootstrap.js >/dev/null

if [[ "${1:-}" == "--build" ]]; then
  docker_endpoint="${DOCKER_HOST:-}"
  if [[ -z "$docker_endpoint" ]] && command -v docker >/dev/null 2>&1; then
    docker_endpoint="$(docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null || true)"
  fi

  if [[ -n "$docker_endpoint" ]]; then
    DOCKER_HOST="$docker_endpoint" SAM_CLI_TELEMETRY=0 sam build \
      --template-file infra/template.yaml \
      --parallel
  else
    SAM_CLI_TELEMETRY=0 sam build \
      --template-file infra/template.yaml \
      --parallel
  fi
fi
