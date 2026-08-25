#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/deploy-flyte-console-source.sh"

if [[ ! -f "$SCRIPT" ]]; then
  printf 'frontend deploy script is missing: %s\n' "$SCRIPT" >&2
  exit 1
fi

output="$(
  DRY_RUN=1 REMOTE_HOST=aione-flyte2 REMOTE_DIR=/opt/aiops-flyte2 PROXY_URL=http://172.19.210.24:7890 \
    KUBECONFIG_PATH=/etc/rancher/k3s/flyte-admin.yaml EXPECTED_COMMIT=0123456789abcdef \
    bash "$SCRIPT"
)"

assert_contains() {
  local needle="$1"
  if [[ "$output" != *"$needle"* ]]; then
    printf 'expected dry-run output to contain: %s\n' "$needle" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
}

assert_not_contains() {
  local needle="$1"
  if [[ "$output" == *"$needle"* ]]; then
    printf 'expected dry-run output not to contain: %s\n' "$needle" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
}

assert_contains 'aione-flyte2'
assert_contains "REMOTE_DIR='/opt/aiops-flyte2'"
assert_contains "CONSOLE_URL='http://172.19.66.218:30081/v2/projects'"
assert_contains "KUBECONFIG_PATH='/etc/rancher/k3s/flyte-admin.yaml'"
assert_contains "EXPECTED_COMMIT='0123456789abcdef'"
assert_contains "PUBLIC_REGISTRY='docker.ops.fzyun.io'"
assert_contains "REGISTRY_BACKEND='172.19.66.224:30000'"
assert_contains "IMAGE_REPOSITORY='docker.ops.fzyun.io/flyte-console-extracted'"
assert_contains 'export KUBECONFIG="$KUBECONFIG_PATH"'
assert_contains 'pypi.fzyun.io,registry.npmmirror.com'
assert_contains 'kubectl get --raw=/readyz'
assert_contains 'kubectl get namespace "$NAMESPACE"'
assert_contains 'if [[ "$(git rev-parse HEAD)" != "$EXPECTED_COMMIT" ]]; then'
assert_contains 'git pull --ff-only origin main'
assert_contains 'K3S_SYSTEMD_UNIT="k3s-agent"'
assert_contains 'systemctl is-active --quiet "${K3S_SYSTEMD_UNIT}.service"'
assert_not_contains 'K3S_SYSTEMD_UNIT="k3s"'
assert_contains 'After=${K3S_SYSTEMD_UNIT}.service'
assert_contains 'Requires=${K3S_SYSTEMD_UNIT}.service'
assert_contains 'ensure_buildkit_k3s'
assert_contains 'wait_for_buildkit'
assert_contains 'install_if_changed /tmp/buildkit-k3s.service.expected /etc/systemd/system/buildkit-k3s.service'
assert_contains 'restart_buildkit=1'
assert_contains 'if ! wait_for_buildkit; then'
assert_contains 'sudo systemctl restart buildkit-k3s.service'
assert_not_contains 'sudo systemctl restart buildkit-k3s.service'$'\n''  wait_for_buildkit'
assert_contains 'NERDCTL=(sudo env HTTP_PROXY="${HTTP_PROXY:-}"'
assert_contains '/usr/local/bin/nerdctl --address /run/k3s/containerd/containerd.sock --namespace k8s.io)'
assert_contains 'IMAGE_TAG="${IMAGE_TAG:-main-${COMMIT}}"'
assert_contains '-t "${IMAGE_REPOSITORY}:${IMAGE_TAG}"'
assert_contains '-t "${IMAGE_REPOSITORY}:latest"'
assert_contains 'k3s ctr -n k8s.io images ls | grep -E'
assert_contains 'bash scripts/registry/push-local-images.sh'
assert_contains '"${IMAGE_REPOSITORY}:${IMAGE_TAG}"'
assert_contains '"${IMAGE_REPOSITORY}:latest"'
assert_contains 'sed "s|image: docker.ops.fzyun.io/flyte-console-extracted:latest|image: ${IMAGE_REPOSITORY}:${IMAGE_TAG}|"'
assert_contains 'deploy/ui/flyte-console-extracted.yaml | kubectl apply -f -'
assert_not_contains 'rollout restart deploy/flyte-console-extracted'
assert_contains 'kubectl -n "$NAMESPACE" rollout status deploy/flyte-console-extracted --timeout=180s'
assert_contains 'curl_with_retries "$CONSOLE_URL"'
assert_contains 'for attempt in {1..10}; do'
assert_contains 'curl -I "$url"'
assert_not_contains 'docker build'
assert_not_contains 'docker save'
assert_not_contains 'k3s ctr images import'

dockerfile="$(cat "$ROOT_DIR/flyte_console/Dockerfile")"
if [[ "$dockerfile" != *'--mount=type=cache,id=flyte-console-pnpm-store,target=/pnpm/store'* ]]; then
  printf 'expected frontend Dockerfile to cache the pnpm store\n' >&2
  exit 1
fi
if [[ "$dockerfile" != *'COREPACK_NPM_REGISTRY=https://registry.npmmirror.com'* ]]; then
  printf 'expected frontend Dockerfile to make corepack use the npm mirror\n' >&2
  exit 1
fi
if [[ "$dockerfile" != *'pnpm config set store-dir /pnpm/store'* ]]; then
  printf 'expected frontend Dockerfile to set the pnpm store cache path\n' >&2
  exit 1
fi
if [[ "$dockerfile" != *'--mount=type=cache,id=flyte-console-next-cache,target=/app/.next/cache'* ]]; then
  printf 'expected frontend Dockerfile to cache the Next build cache\n' >&2
  exit 1
fi

dockerignore="$(cat "$ROOT_DIR/flyte_console/.dockerignore")"
if [[ "$dockerignore" != *'public/monaco/'* ]]; then
  printf 'expected frontend .dockerignore to exclude generated Monaco assets\n' >&2
  exit 1
fi

printf 'PASS tests/test_deploy_flyte_console_source.sh\n'
