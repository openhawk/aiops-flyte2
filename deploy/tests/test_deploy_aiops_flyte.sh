#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/deploy-aiops-flyte.sh"
LEGACY_CLEANUP="$ROOT_DIR/scripts/cleanup-legacy-app-ksvc.sh"

if [[ ! -f "$SCRIPT" ]]; then
  printf 'deploy script is missing: %s\n' "$SCRIPT" >&2
  exit 1
fi

short_head="$(git -C "$ROOT_DIR" rev-parse --short HEAD)"
full_head="$(git -C "$ROOT_DIR" rev-parse HEAD)"
output="$(
  env -u PUBLIC_REGISTRY -u REGISTRY_BACKEND -u IMAGE_REPOSITORY -u DOWNLOADER_IMAGE_REPOSITORY \
    -u POSTGRES_IMAGE_REPOSITORY -u CONSOLE_IMAGE_REPOSITORY -u RUSTFS_IMAGE_REPOSITORY \
    -u BUSYBOX_IMAGE_REPOSITORY -u IMAGE_TAG -u DOWNLOADER_IMAGE_TAG -u IMAGE_TAG_PREFIX \
    -u IMAGE_TAG_KEEP -u REMOTE_DIR -u REMOTE_BRANCH \
    DRY_RUN=1 REMOTE_HOST=aione-flyte2 PROXY_URL=http://172.19.210.24:7890 \
    KUBECONFIG_PATH=/root/.kube/flyte-cluster.yaml \
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

assert_contains "REMOTE_DIR='/opt/aiops-flyte2'"
assert_contains "REMOTE_BRANCH='main'"
assert_contains "EXPECTED_COMMIT='$full_head'"
assert_contains 'aione-flyte2'
assert_contains 'cd "$REMOTE_DIR"'
assert_contains 'git pull --ff-only origin "$REMOTE_BRANCH"'
assert_contains 'actual_commit="$(git rev-parse HEAD)"'
assert_contains 'Expected remote checkout at'
assert_contains "PROXY_URL='http://172.19.210.24:7890'"
assert_contains "KUBECONFIG_PATH='/root/.kube/flyte-cluster.yaml'"
assert_contains 'export HTTP_PROXY="$PROXY_URL"'
assert_contains 'pypi.fzyun.io,registry.npmmirror.com'
assert_contains '--build-arg HTTP_PROXY="$PROXY_URL"'
assert_contains 'This deployment requires an existing k3s cluster client and node agent runtime.'
assert_contains 'systemctl is-active --quiet "${K3S_SYSTEMD_UNIT}.service"'
assert_contains 'K3S_SYSTEMD_UNIT="k3s-agent"'
assert_not_contains 'K3S_SYSTEMD_UNIT="k3s"'
assert_contains 'export KUBECONFIG="$KUBECONFIG_PATH"'
assert_contains 'kubectl get --raw=/readyz'
assert_contains 'wait_for_cluster'
assert_not_contains 'curl -sfL https://get.k3s.io'
assert_contains 'ensure_k3s_registries'
assert_contains 'https://docker.ops.fzyun.io'
assert_contains 'registry.k8s.io:'
assert_contains 'quay.io:'
assert_contains 'nvcr.io:'
assert_contains 'docker.ops.fzyun.io:5000'
assert_contains 'http://docker.ops.fzyun.io:5000'
assert_contains 'insecure_skip_verify: true'
assert_contains 'sudo systemctl restart "${K3S_SYSTEMD_UNIT}.service"'
assert_contains 'get_helm.sh'
assert_contains 'ensure_buildkit_k3s'
assert_contains 'After=${K3S_SYSTEMD_UNIT}.service'
assert_contains 'Requires=${K3S_SYSTEMD_UNIT}.service'
assert_contains 'wait_for_buildkit'
assert_contains 'install_if_changed /tmp/buildkit-k3s.service.expected /etc/systemd/system/buildkit-k3s.service'
assert_contains 'restart_buildkit=1'
assert_contains 'if ! wait_for_buildkit; then'
assert_contains 'sudo systemctl restart buildkit-k3s.service'
assert_not_contains 'sudo systemctl restart buildkit-k3s.service'$'\n''  wait_for_buildkit'
assert_contains 'NERDCTL=(sudo env HTTP_PROXY="${HTTP_PROXY:-}"'
assert_contains '/usr/local/bin/nerdctl --address /run/k3s/containerd/containerd.sock --namespace k8s.io'
assert_contains '--hosts-dir /var/lib/rancher/k3s/agent/etc/containerd/certs.d'
assert_contains '"${NERDCTL[@]}" build "${build_proxy_args[@]}" -t "${IMAGE_REPOSITORY}:${IMAGE_TAG}" -f Dockerfile .'
assert_contains '--build-arg HTTP_PROXY='
assert_contains '--build-arg HTTPS_PROXY='
assert_contains '-t "${DOWNLOADER_IMAGE_REPOSITORY}:${DOWNLOADER_IMAGE_TAG}"'
assert_contains '-t "${DOWNLOADER_IMAGE_REPOSITORY}:latest"'
assert_contains 'bash scripts/registry/push-local-images.sh'
assert_contains '"${IMAGE_REPOSITORY}:${IMAGE_TAG}"'
assert_contains '"${DOWNLOADER_IMAGE_REPOSITORY}:${DOWNLOADER_IMAGE_TAG}"'
assert_contains "IMAGE_REPOSITORY='docker.ops.fzyun.io/flyte-binary-v2'"
assert_contains "DOWNLOADER_IMAGE_REPOSITORY='docker.ops.fzyun.io/aione-downloader'"
assert_contains "POSTGRES_IMAGE_REPOSITORY='docker.ops.fzyun.io/library/postgres'"
assert_contains "CONSOLE_IMAGE_REPOSITORY='docker.ops.fzyun.io/unionai-oss/flyteconsole-v2'"
assert_contains "IMAGE_TAG='main-${short_head}'"
assert_contains "IMAGE_TAG_PREFIX='main-'"
assert_contains "IMAGE_TAG_KEEP='3'"
assert_contains 'pull_containerd_image rancher/mirrored-coredns-coredns:1.14.3'
assert_contains 'prune_old_release_images'
assert_contains 'sudo k3s ctr images rm'
assert_not_contains 'docker save'
assert_not_contains 'k3s ctr images import'
assert_not_contains 'sudo env DOCKER_BUILDKIT=1 docker build'
assert_not_contains 'docker-buildx'
assert_contains 'pull_containerd_image rancher/mirrored-library-busybox:1.37.0'
assert_contains 'pull_containerd_image rancher/mirrored-library-traefik:3.6.13'
assert_contains 'kubectl -n kube-system rollout status deploy/traefik'
assert_not_contains 'delete pod -l k8s-app=kube-dns'
assert_not_contains 'delete pod -l app=local-path-provisioner'
assert_not_contains 'rollout restart deploy/traefik'
assert_contains 'chown -R 10001:10001 /var/lib/flyte/storage/rustfs'
assert_contains 'pull_containerd_image "${POSTGRES_IMAGE_REPOSITORY}:17"'
assert_contains 'CREATE DATABASE runs'
assert_contains 'kubectl -n "$NAMESPACE" rollout status deploy/postgresql'
assert_contains 'if ! helm dependency update charts/flyte-devbox; then'
assert_contains 'Helm dependency update failed; using existing packaged dependencies.'
assert_contains 'Helm dependency update failed and no packaged dependencies exist.'
assert_contains 'helm upgrade --install "$RELEASE" charts/flyte-devbox'
assert_contains '--set docker-registry.enabled=false'
assert_contains '--set flyte-binary.configuration.co-pilot.image.repository="$IMAGE_REPOSITORY"'
assert_contains '--set flyte-binary.configuration.co-pilot.image.tag="$IMAGE_TAG"'
assert_contains '--set flyte-binary.deployment.extraEnvVars[0].name=AIONE_DOWNLOADER_IMAGE'
assert_contains '--set flyte-binary.deployment.image.pullPolicy=IfNotPresent'
assert_contains '--set flyte-binary.deployment.extraEnvVars[0].value="${DOWNLOADER_IMAGE_REPOSITORY}:${DOWNLOADER_IMAGE_TAG}"'
assert_contains '--set flyte-binary.deployment.waitForDB.image.pullPolicy=IfNotPresent'
assert_contains '--set flyte-binary.console.image.repository="$CONSOLE_IMAGE_REPOSITORY"'
assert_contains '--set flyte-binary.console.image.pullPolicy=IfNotPresent'
assert_contains '--set rustfs.image.rustfs.repository="$RUSTFS_IMAGE_REPOSITORY"'
assert_not_contains 'knative-serving.enabled'
assert_contains 'kubectl -n "$NAMESPACE" rollout status deploy/flyte-binary-console'
assert_contains 'kubectl -n "$NAMESPACE" rollout status deploy/rustfs'
assert_contains 'kubectl -n "$NAMESPACE" rollout status deploy/flyte-binary'
assert_contains 'Ingress access:'
assert_contains 'Web UI: http://%s:%s/v2'
assert_contains 'API endpoint: http://%s:%s'
assert_not_contains 'git archive --format=tar HEAD -o'
assert_not_contains 'scp'
assert_not_contains 'REMOTE_ARCHIVE='
assert_not_contains 'tar -xf "$REMOTE_ARCHIVE"'
assert_not_contains 'rm -rf "$REMOTE_DIR"'

if [[ ! -x "$LEGACY_CLEANUP" ]]; then
  printf 'expected executable legacy App cleanup script\n' >&2
  exit 1
fi
if ! grep -q 'services.serving.knative.dev' "$LEGACY_CLEANUP"; then
  printf 'expected cleanup script to target legacy KServices\n' >&2
  exit 1
fi
if ! grep -Fq "services(\\.serving\\.knative\\.dev)?" "$LEGACY_CLEANUP"; then
  printf 'expected cleanup script to recognize fully-qualified KService resources\n' >&2
  exit 1
fi

dockerfile="$(cat "$ROOT_DIR/Dockerfile")"
if [[ "$dockerfile" != *'FROM --platform=${BUILDPLATFORM} docker.fzyun.io/library/golang:1.26.5-bookworm AS flytebuilder'* ]]; then
  printf 'expected backend Dockerfile to use the docker.fzyun.io golang base image\n' >&2
  exit 1
fi
if [[ "$dockerfile" != *'COPY go.mod go.sum ./'* ]]; then
  printf 'expected backend Dockerfile to copy go.mod/go.sum before source directories\n' >&2
  exit 1
fi
if [[ "$dockerfile" != *'RUN --mount=type=cache,id=flyte-go-mod,target=/root/go/pkg/mod go mod download'* ]]; then
  printf 'expected backend Dockerfile go mod download to use the module cache mount\n' >&2
  exit 1
fi
if [[ "$dockerfile" != *'FROM docker.fzyun.io/library/debian:bookworm-slim'* ]]; then
  printf 'expected backend Dockerfile to use the docker.fzyun.io debian base image\n' >&2
  exit 1
fi

dockerignore="$(cat "$ROOT_DIR/.dockerignore")"
if [[ "$dockerignore" != *'flyte_console/'* ]]; then
  printf 'expected root .dockerignore to exclude flyte_console/ from backend context\n' >&2
  exit 1
fi

printf 'PASS tests/test_deploy_aiops_flyte.sh\n'
