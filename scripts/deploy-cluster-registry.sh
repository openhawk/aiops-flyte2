#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REMOTE_HOST="${REMOTE_HOST:-aione-flyte2}"
REMOTE_DIR="${REMOTE_DIR:-/opt/aiops-flyte2}"
REMOTE_BRANCH="${REMOTE_BRANCH:-main}"
GATEWAY_HOST="${GATEWAY_HOST:-aiops-haproxy}"
CONTROL_PLANE_HOST="${CONTROL_PLANE_HOST:-aiops-master}"
EXPECTED_COMMIT="${EXPECTED_COMMIT:-$(git -C "$ROOT_DIR" rev-parse HEAD)}"
PROXY_URL="${PROXY_URL:-http://172.19.210.24:7897}"
DRY_RUN="${DRY_RUN:-0}"
REGISTRY_IMAGE="docker.ops.fzyun.io/library/registry:3.1.1@sha256:1be55279f18a2fe1a74edf2664cac61c1bea305b7b4642dab412e7affdcb3e33"
REGISTRY_SOURCE="docker.fzyun.io/library/registry:3.1.1"
REGISTRY_CANONICAL="docker.ops.fzyun.io/library/registry@sha256:1be55279f18a2fe1a74edf2664cac61c1bea305b7b4642dab412e7affdcb3e33"

SSH_BIN="${SSH_BIN:-ssh}"
for required in "$SSH_BIN" git; do
  if ! command -v "$required" >/dev/null 2>&1; then
    printf 'required command is unavailable: %s\n' "$required" >&2
    exit 1
  fi
done

if [[ "$DRY_RUN" == "1" ]]; then
  cat <<EOF
$SSH_BIN $REMOTE_HOST "cd '$REMOTE_DIR' && git pull --ff-only origin '$REMOTE_BRANCH'"
$SSH_BIN aione-gpu2 "bash -s" < scripts/registry/repair-aione-gpu2.sh
$SSH_BIN $REMOTE_HOST "STAGE=bootstrap EXPECTED_COMMIT='$EXPECTED_COMMIT' PROXY_URL='$PROXY_URL' bash scripts/registry/deploy-on-cluster.sh"
preload $REGISTRY_IMAGE on aiops-hawk1 aiops-hawk2 aiops-hawk3
$SSH_BIN $REMOTE_HOST "STAGE=apply EXPECTED_COMMIT='$EXPECTED_COMMIT' PROXY_URL='$PROXY_URL' bash scripts/registry/deploy-on-cluster.sh"
$SSH_BIN $GATEWAY_HOST "bash -s" < scripts/registry/configure-gateway.sh
configure registries.yaml on aiops-hawk1 aiops-hawk2 aiops-hawk3 aione-gpu2 aione-flyte2 aiops-master
verify https://docker.ops.fzyun.io/v2/ and http://docker.ops.fzyun.io:5000/v2/
EOF
  exit 0
fi

remote_update="cd '$REMOTE_DIR' && git pull --ff-only origin '$REMOTE_BRANCH' && test \"\$(git rev-parse HEAD)\" = '$EXPECTED_COMMIT'"
"$SSH_BIN" "$REMOTE_HOST" "$remote_update"

"$SSH_BIN" aione-gpu2 'bash -s' <"$ROOT_DIR/scripts/registry/repair-aione-gpu2.sh"
"$SSH_BIN" "$CONTROL_PLANE_HOST" \
  "sudo k3s kubectl wait node/aione-gpu2 --for=condition=Ready --timeout=180s && sudo k3s kubectl label node aione-gpu2 node-role.kubernetes.io/worker=worker --overwrite"

"$SSH_BIN" "$REMOTE_HOST" \
  "cd '$REMOTE_DIR' && STAGE=bootstrap EXPECTED_COMMIT='$EXPECTED_COMMIT' PROXY_URL='$PROXY_URL' bash scripts/registry/deploy-on-cluster.sh"

for host in aiops-hawk1 aiops-hawk2 aiops-hawk3; do
  printf 'Preloading the pinned registry image on %s.\n' "$host"
  "$SSH_BIN" "$host" \
    "sudo k3s ctr -n k8s.io images pull '$REGISTRY_SOURCE' >/dev/null && sudo k3s ctr -n k8s.io images tag --force '$REGISTRY_SOURCE' '${REGISTRY_IMAGE%@*}' '$REGISTRY_IMAGE' '$REGISTRY_CANONICAL' && sudo k3s ctr -n k8s.io images ls | grep 'docker.ops.fzyun.io/library/registry'"
done

"$SSH_BIN" "$REMOTE_HOST" \
  "cd '$REMOTE_DIR' && STAGE=apply EXPECTED_COMMIT='$EXPECTED_COMMIT' PROXY_URL='$PROXY_URL' bash scripts/registry/deploy-on-cluster.sh"

"$SSH_BIN" "$GATEWAY_HOST" 'bash -s' <"$ROOT_DIR/scripts/registry/configure-gateway.sh"

configure_node() {
  local host="$1"
  local node_name="$2"
  local service_unit="$3"
  printf 'Configuring registry mirrors on %s.\n' "$host"
  "$SSH_BIN" "$host" "SERVICE_UNIT='$service_unit' bash -s" <"$ROOT_DIR/scripts/registry/configure-node.sh"
  "$SSH_BIN" "$CONTROL_PLANE_HOST" \
    "sudo k3s kubectl wait node/'$node_name' --for=condition=Ready --timeout=180s"
}

configure_node aiops-hawk1 aiops-hawk1 k3s-agent
configure_node aiops-hawk2 aiops-hawk2 k3s-agent
configure_node aiops-hawk3 aiops-hawk3 k3s-agent
configure_node aione-gpu2 aione-gpu2 k3s-agent
configure_node aione-flyte2 aione-flyte2 k3s-agent
configure_node aiops-master aiops-master k3s

"$SSH_BIN" aione-gpu2 \
  "sudo k3s crictl pull registry.k8s.io/nfd/node-feature-discovery:v0.18.3"
"$SSH_BIN" "$CONTROL_PLANE_HOST" \
  "sudo k3s kubectl get nodes -o wide; sudo k3s kubectl -n registry-system get deployment,pod,service,pvc -o wide; sudo k3s kubectl get pods -A -o wide --field-selector spec.nodeName=aione-gpu2"

curl -fsS --connect-timeout 5 https://docker.ops.fzyun.io/v2/ >/dev/null
curl -fsS --connect-timeout 5 http://docker.ops.fzyun.io:5000/v2/ >/dev/null
printf 'Cluster registry deployment and node rollout completed successfully.\n'
