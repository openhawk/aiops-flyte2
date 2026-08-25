#!/usr/bin/env bash
set -euo pipefail

REGISTRY_NAMESPACE="${REGISTRY_NAMESPACE:-registry-system}"
DEPLOYMENT="${DEPLOYMENT:-registry}"
PUBLIC_REGISTRY="${PUBLIC_REGISTRY:-docker.ops.fzyun.io}"
REGISTRY_BACKEND="${REGISTRY_BACKEND:-172.19.66.224:30000}"
CONTAINERD_ADDRESS="${CONTAINERD_ADDRESS:-/run/k3s/containerd/containerd.sock}"
CONTAINERD_NAMESPACE="${CONTAINERD_NAMESPACE:-k8s.io}"
LOCK_FILE="${LOCK_FILE:-/tmp/aiops-registry-write.lock}"

if (( $# == 0 )); then
  printf 'usage: %s %s/repository:tag [...]\n' "$0" "$PUBLIC_REGISTRY" >&2
  exit 1
fi

for command_name in flock kubectl skopeo sudo; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'required command is unavailable: %s\n' "$command_name" >&2
    exit 1
  fi
done
if [[ ! -x /usr/local/bin/nerdctl ]]; then
  printf 'required command is unavailable: /usr/local/bin/nerdctl\n' >&2
  exit 1
fi

exec 9>"$LOCK_FILE"
flock 9

switch_config() {
  local config_map="$1"
  kubectl -n "$REGISTRY_NAMESPACE" patch deployment "$DEPLOYMENT" --type=strategic \
    -p "{\"spec\":{\"template\":{\"spec\":{\"volumes\":[{\"name\":\"config\",\"configMap\":{\"name\":\"$config_map\"}}]}}}}"
  kubectl -n "$REGISTRY_NAMESPACE" rollout status "deployment/$DEPLOYMENT" --timeout=180s
}

restore_read_only() {
  local status=$?
  trap - EXIT
  if ! switch_config registry-config-ro; then
    printf 'failed to restore the registry to read-only mode\n' >&2
    exit 1
  fi
  exit "$status"
}

verify_public_image() {
  local public_ref="$1"
  local attempt
  for attempt in {1..30}; do
    if skopeo inspect "docker://$public_ref" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  skopeo inspect "docker://$public_ref" >/dev/null
}

NERDCTL=(
  sudo /usr/local/bin/nerdctl
  --address "$CONTAINERD_ADDRESS"
  --namespace "$CONTAINERD_NAMESPACE"
  --insecure-registry
)

for public_ref in "$@"; do
  if [[ "$public_ref" != "$PUBLIC_REGISTRY/"*:* ]]; then
    printf 'image must use %s and include a tag: %s\n' "$PUBLIC_REGISTRY" "$public_ref" >&2
    exit 1
  fi
  "${NERDCTL[@]}" image inspect "$public_ref" >/dev/null
done

switch_config registry-config-rw
trap restore_read_only EXIT

for public_ref in "$@"; do
  destination_ref="${public_ref#"$PUBLIC_REGISTRY/"}"
  internal_ref="$REGISTRY_BACKEND/$destination_ref"
  printf 'Pushing %s through %s\n' "$public_ref" "$REGISTRY_BACKEND"
  "${NERDCTL[@]}" tag "$public_ref" "$internal_ref"
  "${NERDCTL[@]}" push --quiet "$internal_ref"
  skopeo inspect --tls-verify=false "docker://$internal_ref" >/dev/null
done

switch_config registry-config-ro
trap - EXIT

for public_ref in "$@"; do
  verify_public_image "$public_ref"
done
printf 'Pushed %d images and restored read-only mode.\n' "$#"
