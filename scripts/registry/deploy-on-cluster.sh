#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
EXPECTED_COMMIT="${EXPECTED_COMMIT:-}"
STAGE="${STAGE:-all}"
NAMESPACE="${NAMESPACE:-registry-system}"
REGISTRY_BACKEND="${REGISTRY_BACKEND:-172.19.66.224:30000}"
PROXY_URL="${PROXY_URL:-}"
REGISTRY_SOURCE="docker.io/library/registry:3.1.1"
REGISTRY_PUBLIC="docker.ops.fzyun.io/library/registry:3.1.1"
REGISTRY_DIGEST="sha256:1be55279f18a2fe1a74edf2664cac61c1bea305b7b4642dab412e7affdcb3e33"

cd "$ROOT_DIR"
if [[ -n "$EXPECTED_COMMIT" && "$(git rev-parse HEAD)" != "$EXPECTED_COMMIT" ]]; then
  printf 'remote checkout is not at expected commit %s\n' "$EXPECTED_COMMIT" >&2
  exit 1
fi
for command_name in kubectl curl skopeo; do
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

bootstrap_registry_image() {
  local current_digest=""
  current_digest="$(skopeo inspect "docker://$REGISTRY_PUBLIC" 2>/dev/null | sed -n 's/.*"Digest": "\([^"]*\)".*/\1/p' || true)"
  if [[ "$current_digest" == "$REGISTRY_DIGEST" ]]; then
    printf 'Bootstrap registry image already exists at %s@%s\n' "$REGISTRY_PUBLIC" "$REGISTRY_DIGEST"
    return 0
  fi
  printf 'Copying bootstrap registry image to the existing HTTPS registry.\n'
  skopeo copy --all --retry-times 3 \
    "docker://$REGISTRY_SOURCE" "docker://$REGISTRY_PUBLIC"
  current_digest="$(skopeo inspect "docker://$REGISTRY_PUBLIC" | sed -n 's/.*"Digest": "\([^"]*\)".*/\1/p')"
  if [[ "$current_digest" != "$REGISTRY_DIGEST" ]]; then
    printf 'unexpected bootstrap registry digest: %s\n' "$current_digest" >&2
    exit 1
  fi
}

apply_registry() {
  kubectl label node aiops-hawk1 aiops.fzyun.io/registry-host=true --overwrite
  kubectl label node aiops-hawk2 aiops.fzyun.io/registry-host=true --overwrite
  kubectl label node aiops-hawk3 aiops.fzyun.io/registry-host=true --overwrite
  kubectl apply -f deploy/registry/registry.yaml
  kubectl -n "$NAMESPACE" wait pvc/registry-data \
    --for=jsonpath='{.status.phase}'=Bound --timeout=180s
  kubectl -n "$NAMESPACE" rollout status deployment/registry --timeout=300s

  local attempt
  for attempt in {1..30}; do
    if curl -fsS --connect-timeout 3 "http://$REGISTRY_BACKEND/v2/" >/dev/null; then
      break
    fi
    sleep 2
  done
  curl -fsS --connect-timeout 5 "http://$REGISTRY_BACKEND/v2/" >/dev/null

  NAMESPACE="$NAMESPACE" REGISTRY_BACKEND="$REGISTRY_BACKEND" PROXY_URL="$PROXY_URL" \
    bash scripts/registry/sync-images.sh

  curl -fsS --connect-timeout 5 "http://$REGISTRY_BACKEND/v2/" >/dev/null
  kubectl -n "$NAMESPACE" get deployment,pod,service,pvc -o wide
}

case "$STAGE" in
  bootstrap)
    bootstrap_registry_image
    ;;
  apply)
    apply_registry
    ;;
  all)
    bootstrap_registry_image
    apply_registry
    ;;
  *)
    printf 'unsupported deployment stage: %s\n' "$STAGE" >&2
    exit 1
    ;;
esac
