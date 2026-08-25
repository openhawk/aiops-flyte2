#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
NAMESPACE="${NAMESPACE:-registry-system}"
DEPLOYMENT="${DEPLOYMENT:-registry}"
REGISTRY_BACKEND="${REGISTRY_BACKEND:-172.19.66.224:30000}"
IMAGE_LIST="${IMAGE_LIST:-$ROOT_DIR/deploy/registry/images.txt}"
PROXY_URL="${PROXY_URL:-}"

if [[ ! -r "$IMAGE_LIST" ]]; then
  printf 'registry image list is not readable: %s\n' "$IMAGE_LIST" >&2
  exit 1
fi
for command_name in kubectl skopeo; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'required command is unavailable: %s\n' "$command_name" >&2
    exit 1
  fi
done

if [[ -n "$PROXY_URL" ]]; then
  export HTTP_PROXY="$PROXY_URL"
  export HTTPS_PROXY="$PROXY_URL"
  export http_proxy="$PROXY_URL"
  export https_proxy="$PROXY_URL"
fi
export NO_PROXY="${NO_PROXY:-127.0.0.1,localhost,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.svc,.cluster.local,docker.ops.fzyun.io}"
export no_proxy="$NO_PROXY"

switch_config() {
  local config_map="$1"
  kubectl -n "$NAMESPACE" patch deployment "$DEPLOYMENT" --type=strategic \
    -p "{\"spec\":{\"template\":{\"spec\":{\"volumes\":[{\"name\":\"config\",\"configMap\":{\"name\":\"$config_map\"}}]}}}}"
  kubectl -n "$NAMESPACE" rollout status "deployment/$DEPLOYMENT" --timeout=180s
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

declare -A destination_sources=()
images=()
while IFS= read -r source_ref; do
  source_ref="${source_ref%%#*}"
  source_ref="${source_ref//[[:space:]]/}"
  [[ -z "$source_ref" ]] && continue
  if [[ "$source_ref" != */*:* ]]; then
    printf 'image references must include an explicit registry and tag: %s\n' "$source_ref" >&2
    exit 1
  fi
  source_registry="${source_ref%%/*}"
  destination_ref="${source_ref#*/}"
  destination_repository="${destination_ref%:*}"
  if [[ -n "${destination_sources[$destination_repository]:-}" \
    && "${destination_sources[$destination_repository]}" != "$source_registry" ]]; then
    printf 'repository collision for %s between %s and %s\n' \
      "$destination_repository" "${destination_sources[$destination_repository]}" "$source_registry" >&2
    exit 1
  fi
  destination_sources[$destination_repository]="$source_registry"
  images+=("$source_ref")
done <"$IMAGE_LIST"

if (( ${#images[@]} == 0 )); then
  printf 'registry image list is empty: %s\n' "$IMAGE_LIST" >&2
  exit 1
fi

kubectl -n "$NAMESPACE" get deployment "$DEPLOYMENT" >/dev/null
switch_config registry-config-rw
trap restore_read_only EXIT

for source_ref in "${images[@]}"; do
  destination_ref="${source_ref#*/}"
  destination="docker://$REGISTRY_BACKEND/$destination_ref"
  printf 'Syncing %s -> %s/%s\n' "$source_ref" "$REGISTRY_BACKEND" "$destination_ref"
  skopeo copy --all --retry-times 3 --dest-tls-verify=false \
    "docker://$source_ref" "$destination"
  skopeo inspect --tls-verify=false "$destination" >/dev/null
done

switch_config registry-config-ro
trap - EXIT
printf 'Synced %d images and restored read-only mode.\n' "${#images[@]}"
