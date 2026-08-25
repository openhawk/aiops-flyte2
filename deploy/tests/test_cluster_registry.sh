#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MANIFEST="$ROOT_DIR/deploy/registry/registry.yaml"
UI_MANIFEST="$ROOT_DIR/deploy/registry/registry-ui.yaml"
IMAGE_LIST="$ROOT_DIR/deploy/registry/images.txt"
DEPLOY_SCRIPT="$ROOT_DIR/scripts/deploy-cluster-registry.sh"
SYNC_SCRIPT="$ROOT_DIR/scripts/registry/sync-images.sh"
CLUSTER_SCRIPT="$ROOT_DIR/scripts/registry/deploy-on-cluster.sh"
GATEWAY_SCRIPT="$ROOT_DIR/scripts/registry/configure-gateway.sh"
NODE_SCRIPT="$ROOT_DIR/scripts/registry/configure-node.sh"
REPAIR_SCRIPT="$ROOT_DIR/scripts/registry/repair-aione-gpu2.sh"

for file in "$MANIFEST" "$UI_MANIFEST" "$IMAGE_LIST" "$DEPLOY_SCRIPT" "$SYNC_SCRIPT" \
  "$CLUSTER_SCRIPT" "$GATEWAY_SCRIPT" "$NODE_SCRIPT" "$REPAIR_SCRIPT"; do
  if [[ ! -f "$file" ]]; then
    printf 'required cluster Registry file is missing: %s\n' "$file" >&2
    exit 1
  fi
done

assert_file_contains() {
  local file="$1"
  local needle="$2"
  if ! grep -Fq -- "$needle" "$file"; then
    printf 'expected %s to contain: %s\n' "$file" "$needle" >&2
    exit 1
  fi
}

assert_file_not_contains() {
  local file="$1"
  local needle="$2"
  if grep -Fq -- "$needle" "$file"; then
    printf 'expected %s not to contain: %s\n' "$file" "$needle" >&2
    exit 1
  fi
}

assert_file_contains "$MANIFEST" 'name: registry-system'
assert_file_contains "$MANIFEST" 'name: registry-config-ro'
assert_file_contains "$MANIFEST" 'name: registry-config-rw'
assert_file_contains "$MANIFEST" 'enabled: true'
assert_file_contains "$MANIFEST" 'storage: 200Gi'
assert_file_contains "$MANIFEST" 'storageClassName: bj1-ebs'
assert_file_contains "$MANIFEST" 'nodePort: 30000'
assert_file_contains "$MANIFEST" 'aiops.fzyun.io/registry-host'
assert_file_contains "$MANIFEST" 'docker.ops.fzyun.io/library/registry:3.1.1@sha256:1be55279f18a2fe1a74edf2664cac61c1bea305b7b4642dab412e7affdcb3e33'
assert_file_not_contains "$MANIFEST" 'namespace: flyte'

assert_file_contains "$UI_MANIFEST" 'name: registry-ui'
assert_file_contains "$UI_MANIFEST" 'namespace: registry-system'
assert_file_contains "$UI_MANIFEST" 'replicas: 2'
assert_file_contains "$UI_MANIFEST" 'nodePort: 30001'
assert_file_contains "$UI_MANIFEST" 'docker.ops.fzyun.io/joxit/docker-registry-ui:2.6.0@sha256:db27f52b9a1b2ac295b507cafe6953a6d5b244b8cf8edfbbd9a998f02bffa9ca'
assert_file_contains "$UI_MANIFEST" 'name: DELETE_IMAGES'
assert_file_contains "$UI_MANIFEST" 'name: SHOW_CONTENT_DIGEST'
assert_file_contains "$UI_MANIFEST" 'name: ENABLE_VERSION_NOTIFICATION'
assert_file_not_contains "$UI_MANIFEST" 'namespace: flyte'

assert_file_contains "$IMAGE_LIST" 'docker.io/rancher/mirrored-pause:3.6'
assert_file_contains "$IMAGE_LIST" 'docker.io/joxit/docker-registry-ui:2.6.0'
assert_file_contains "$IMAGE_LIST" 'registry.k8s.io/nfd/node-feature-discovery:v0.18.3'
assert_file_contains "$IMAGE_LIST" 'quay.io/cephcsi/cephcsi:v3.15.0'
assert_file_contains "$IMAGE_LIST" 'nvcr.io/nvidia/gpu-operator:v26.3.2'

output="$(DRY_RUN=1 bash "$DEPLOY_SCRIPT")"
for needle in \
  'git pull --ff-only origin' \
  'repair-aione-gpu2.sh' \
  'STAGE=bootstrap' \
  'STAGE=apply' \
  'aiops-haproxy' \
  'configure registries.yaml' \
  'https://docker.ops.fzyun.io/v2/' \
  'http://docker.ops.fzyun.io:5000/v2/'; do
  if [[ "$output" != *"$needle"* ]]; then
    printf 'expected Registry dry-run output to contain: %s\n' "$needle" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
done

assert_file_contains "$SYNC_SCRIPT" 'registry-config-rw'
assert_file_contains "$SYNC_SCRIPT" 'registry-config-ro'
assert_file_contains "$SYNC_SCRIPT" 'trap restore_read_only EXIT'
assert_file_contains "$SYNC_SCRIPT" 'skopeo copy --retry-times 3'
assert_file_not_contains "$SYNC_SCRIPT" 'skopeo copy --all'
assert_file_contains "$SYNC_SCRIPT" '--dest-tls-verify=false'
assert_file_contains "$CLUSTER_SCRIPT" 'kubectl label node aiops-hawk1'
assert_file_contains "$CLUSTER_SCRIPT" 'kubectl apply -f deploy/registry/registry.yaml'
assert_file_contains "$CLUSTER_SCRIPT" 'kubectl apply -f deploy/registry/registry-ui.yaml'
assert_file_contains "$CLUSTER_SCRIPT" 'docker.fzyun.io/library/registry:3.1.1'
assert_file_contains "$DEPLOY_SCRIPT" "images tag --force"
assert_file_contains "$DEPLOY_SCRIPT" 'docker.ops.fzyun.io/library/registry@sha256:'
assert_file_contains "$GATEWAY_SCRIPT" 'acl host_docker_ops hdr(host) -i docker.ops.fzyun.io'
assert_file_contains "$GATEWAY_SCRIPT" 'acl path_docker_registry_api path_beg -i /v2'
assert_file_contains "$GATEWAY_SCRIPT" 'server k3s_registry 172.19.66.224:30000 check'
assert_file_contains "$GATEWAY_SCRIPT" 'server k3s_registry_ui 172.19.66.224:30001 check'
assert_file_contains "$GATEWAY_SCRIPT" 'http://docker.ops.fzyun.io:5000/v2/'
assert_file_contains "$NODE_SCRIPT" 'https://docker.ops.fzyun.io'
assert_file_contains "$NODE_SCRIPT" 'https://docker.fzyun.io'
assert_file_contains "$NODE_SCRIPT" 'http://docker.ops.fzyun.io:5000'
assert_file_contains "$REPAIR_SCRIPT" 'ExecStart=/usr/local/bin/k3s agent --node-name aione-gpu2 --node-ip 172.19.66.222'
assert_file_not_contains "$REPAIR_SCRIPT" 'ExecStart=/usr/local/bin/k3s agent --node-name aione-gpu2 --node-ip 172.19.66.222 --node-label'

printf 'PASS deploy/tests/test_cluster_registry.sh\n'
