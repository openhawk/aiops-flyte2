#!/usr/bin/env bash
set -euo pipefail

REMOTE_HOST="${REMOTE_HOST:-aione-flyte2}"
REMOTE_DIR="${REMOTE_DIR:-/opt/aiops-flyte2}"
REMOTE_BRANCH="${REMOTE_BRANCH:-main}"
NAMESPACE="${NAMESPACE:-flyte}"
RELEASE="${RELEASE:-flyte-devbox}"
CONTROL_PLANE_NODE="${CONTROL_PLANE_NODE:-aione-flyte2}"
PUBLIC_REGISTRY="${PUBLIC_REGISTRY:-docker.ops.fzyun.io}"
REGISTRY_BACKEND="${REGISTRY_BACKEND:-172.19.66.224:30000}"
IMAGE_REPOSITORY="${IMAGE_REPOSITORY:-${PUBLIC_REGISTRY}/flyte-binary-v2}"
DOWNLOADER_IMAGE_REPOSITORY="${DOWNLOADER_IMAGE_REPOSITORY:-${PUBLIC_REGISTRY}/aione-downloader}"
POSTGRES_IMAGE_REPOSITORY="${POSTGRES_IMAGE_REPOSITORY:-${PUBLIC_REGISTRY}/library/postgres}"
CONSOLE_IMAGE_REPOSITORY="${CONSOLE_IMAGE_REPOSITORY:-${PUBLIC_REGISTRY}/unionai-oss/flyteconsole-v2}"
RUSTFS_IMAGE_REPOSITORY="${RUSTFS_IMAGE_REPOSITORY:-${PUBLIC_REGISTRY}/rustfs/rustfs}"
BUSYBOX_IMAGE_REPOSITORY="${BUSYBOX_IMAGE_REPOSITORY:-${PUBLIC_REGISTRY}/library/busybox}"
IMAGE_TAG_PREFIX="${IMAGE_TAG_PREFIX:-main-}"
IMAGE_TAG_KEEP="${IMAGE_TAG_KEEP:-3}"
IMAGE_TAG="${IMAGE_TAG:-${IMAGE_TAG_PREFIX}$(git rev-parse --short HEAD)}"
DOWNLOADER_IMAGE_TAG="${DOWNLOADER_IMAGE_TAG:-$IMAGE_TAG}"
EXPECTED_COMMIT="${EXPECTED_COMMIT:-$(git rev-parse HEAD)}"
NERDCTL_VERSION="${NERDCTL_VERSION:-2.3.3}"
PROXY_URL="${PROXY_URL:-}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-/root/.kube/config}"
DRY_RUN="${DRY_RUN:-0}"

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

remote_env() {
  printf "REMOTE_HOST=%s REMOTE_DIR=%s REMOTE_BRANCH=%s NAMESPACE=%s RELEASE=%s CONTROL_PLANE_NODE=%s PUBLIC_REGISTRY=%s REGISTRY_BACKEND=%s IMAGE_REPOSITORY=%s DOWNLOADER_IMAGE_REPOSITORY=%s POSTGRES_IMAGE_REPOSITORY=%s CONSOLE_IMAGE_REPOSITORY=%s RUSTFS_IMAGE_REPOSITORY=%s BUSYBOX_IMAGE_REPOSITORY=%s IMAGE_TAG=%s DOWNLOADER_IMAGE_TAG=%s IMAGE_TAG_PREFIX=%s IMAGE_TAG_KEEP=%s EXPECTED_COMMIT=%s NERDCTL_VERSION=%s PROXY_URL=%s KUBECONFIG_PATH=%s" \
    "$(shell_quote "$REMOTE_HOST")" \
    "$(shell_quote "$REMOTE_DIR")" \
    "$(shell_quote "$REMOTE_BRANCH")" \
    "$(shell_quote "$NAMESPACE")" \
    "$(shell_quote "$RELEASE")" \
    "$(shell_quote "$CONTROL_PLANE_NODE")" \
    "$(shell_quote "$PUBLIC_REGISTRY")" \
    "$(shell_quote "$REGISTRY_BACKEND")" \
    "$(shell_quote "$IMAGE_REPOSITORY")" \
    "$(shell_quote "$DOWNLOADER_IMAGE_REPOSITORY")" \
    "$(shell_quote "$POSTGRES_IMAGE_REPOSITORY")" \
    "$(shell_quote "$CONSOLE_IMAGE_REPOSITORY")" \
    "$(shell_quote "$RUSTFS_IMAGE_REPOSITORY")" \
    "$(shell_quote "$BUSYBOX_IMAGE_REPOSITORY")" \
    "$(shell_quote "$IMAGE_TAG")" \
    "$(shell_quote "$DOWNLOADER_IMAGE_TAG")" \
    "$(shell_quote "$IMAGE_TAG_PREFIX")" \
    "$(shell_quote "$IMAGE_TAG_KEEP")" \
    "$(shell_quote "$EXPECTED_COMMIT")" \
    "$(shell_quote "$NERDCTL_VERSION")" \
    "$(shell_quote "$PROXY_URL")" \
    "$(shell_quote "$KUBECONFIG_PATH")"
}

SSH_BIN="${SSH_BIN:-ssh}"
if ! command -v "$SSH_BIN" >/dev/null 2>&1; then
  printf 'SSH client is unavailable: %s\n' "$SSH_BIN" >&2
  exit 1
fi

remote_script="$(cat <<'REMOTE_SCRIPT'
set -euo pipefail

if [[ -z "${REMOTE_DIR:-}" ]]; then
  REMOTE_DIR="flyte-work"
fi
if [[ "$REMOTE_DIR" != /* ]]; then
  REMOTE_DIR="$HOME/$REMOTE_DIR"
fi
REMOTE_BRANCH="${REMOTE_BRANCH:-main}"

if [[ -n "${PROXY_URL:-}" ]]; then
  export HTTP_PROXY="$PROXY_URL"
  export HTTPS_PROXY="$PROXY_URL"
  export http_proxy="$PROXY_URL"
  export https_proxy="$PROXY_URL"
  export NO_PROXY="${NO_PROXY:-127.0.0.1,localhost,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.svc,.cluster.local,docker.fzyun.io,docker.ops.fzyun.io,mirrors.fzyun.io,pypi.fzyun.io,registry.npmmirror.com}"
  export no_proxy="$NO_PROXY"
fi

cd "$REMOTE_DIR"
if [[ ! -d .git ]]; then
  printf 'Remote directory is not a git checkout: %s\n' "$REMOTE_DIR" >&2
  exit 1
fi
git pull --ff-only origin "$REMOTE_BRANCH"
actual_commit="$(git rev-parse HEAD)"
if [[ -n "${EXPECTED_COMMIT:-}" && "$actual_commit" != "$EXPECTED_COMMIT" ]]; then
  printf 'Expected remote checkout at %s after git pull, got %s\n' "$EXPECTED_COMMIT" "$actual_commit" >&2
  exit 1
fi

if ! command -v k3s >/dev/null 2>&1 || ! command -v kubectl >/dev/null 2>&1; then
  printf 'This deployment requires an existing k3s cluster client and node agent runtime.\n' >&2
  exit 1
fi

K3S_SYSTEMD_UNIT="k3s-agent"
if ! systemctl is-active --quiet "${K3S_SYSTEMD_UNIT}.service"; then
  printf 'The existing k3s cluster node agent is not active: %s.service\n' "$K3S_SYSTEMD_UNIT" >&2
  exit 1
fi

if [[ ! -r "$KUBECONFIG_PATH" ]]; then
  printf 'Kubernetes cluster kubeconfig is not readable: %s\n' "$KUBECONFIG_PATH" >&2
  exit 1
fi
export KUBECONFIG="$KUBECONFIG_PATH"

wait_for_cluster() {
  local attempt
  for attempt in {1..60}; do
    if systemctl is-active --quiet "${K3S_SYSTEMD_UNIT}.service" \
      && [[ -S /run/k3s/containerd/containerd.sock ]] \
      && kubectl get --raw=/readyz >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  systemctl is-active "${K3S_SYSTEMD_UNIT}.service"
  test -S /run/k3s/containerd/containerd.sock
  kubectl get --raw=/readyz >/dev/null
}

wait_for_cluster

ensure_k3s_registries() {
  cat >/tmp/k3s-registries.yaml.expected <<'EOF'
mirrors:
  docker.io:
    endpoint:
      - "https://docker.ops.fzyun.io"
      - "https://docker.fzyun.io"
  registry.k8s.io:
    endpoint:
      - "https://docker.ops.fzyun.io"
  quay.io:
    endpoint:
      - "https://docker.ops.fzyun.io"
  nvcr.io:
    endpoint:
      - "https://docker.ops.fzyun.io"
  "docker.ops.fzyun.io:5000":
    endpoint:
      - "http://docker.ops.fzyun.io:5000"
configs:
  "docker.ops.fzyun.io:5000":
    tls:
      insecure_skip_verify: true
EOF

  if ! sudo test -f /etc/rancher/k3s/registries.yaml \
    || ! sudo cmp -s /tmp/k3s-registries.yaml.expected /etc/rancher/k3s/registries.yaml; then
    sudo install -D -m 0644 /tmp/k3s-registries.yaml.expected /etc/rancher/k3s/registries.yaml
    sudo systemctl restart "${K3S_SYSTEMD_UNIT}.service"
    wait_for_cluster
  fi
}

ensure_k3s_registries

kubectl get nodes

if ! command -v helm >/dev/null 2>&1; then
  curl -fsSL -o /tmp/get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
  chmod 700 /tmp/get_helm.sh
  /tmp/get_helm.sh
fi

install_nerdctl_full() {
  local version="${NERDCTL_VERSION:-2.3.3}"
  local arch
  case "$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *)
      printf 'unsupported architecture for nerdctl-full install: %s\n' "$(uname -m)" >&2
      return 1
      ;;
  esac

  local archive="/tmp/nerdctl-full-${version}-linux-${arch}.tar.gz"
  local url="https://github.com/containerd/nerdctl/releases/download/v${version}/nerdctl-full-${version}-linux-${arch}.tar.gz"
  curl -fL --retry 3 --retry-delay 2 -o "$archive" "$url"
  sudo tar -xzf "$archive" -C /usr/local \
    bin/nerdctl \
    bin/buildctl \
    bin/buildkitd \
    bin/buildkit-cni-bridge \
    bin/buildkit-cni-firewall \
    bin/buildkit-cni-host-local \
    bin/buildkit-cni-loopback \
    bin/buildkit-cni-portmap \
    libexec/cni/bridge \
    libexec/cni/firewall \
    libexec/cni/host-local \
    libexec/cni/loopback \
    libexec/cni/portmap
  sudo chmod +x /usr/local/bin/nerdctl /usr/local/bin/buildctl /usr/local/bin/buildkitd
  sudo chmod +x /usr/local/libexec/cni/bridge /usr/local/libexec/cni/firewall /usr/local/libexec/cni/host-local /usr/local/libexec/cni/loopback /usr/local/libexec/cni/portmap
  rm -f "$archive"
}

wait_for_buildkit() {
  local attempt
  for attempt in {1..30}; do
    if sudo /usr/local/bin/buildctl --addr unix:///run/buildkit/buildkitd.sock debug workers >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  sudo /usr/local/bin/buildctl --addr unix:///run/buildkit/buildkitd.sock debug workers >/dev/null
}

restart_buildkit=0

install_if_changed() {
  local source="$1"
  local target="$2"
  local target_dir
  target_dir="$(dirname "$target")"
  if [[ ! -f "$target" ]] || ! sudo cmp -s "$source" "$target"; then
    sudo mkdir -p "$target_dir"
    sudo install -m 0644 "$source" "$target"
    restart_buildkit=1
  fi
}

ensure_buildkit_k3s() {
  if [[ ! -x /usr/local/bin/nerdctl || ! -x /usr/local/bin/buildctl || ! -x /usr/local/bin/buildkitd ]]; then
    sudo apt-get update
    sudo apt-get install -y ca-certificates curl
    install_nerdctl_full
  fi

  restart_buildkit=0
  cat >/tmp/buildkit-k3s.service.expected <<EOF
[Unit]
Description=BuildKit daemon for k3s containerd
After=${K3S_SYSTEMD_UNIT}.service
Requires=${K3S_SYSTEMD_UNIT}.service

[Service]
Type=simple
ExecStartPre=/bin/mkdir -p /run/buildkit
ExecStart=/usr/local/bin/buildkitd --addr unix:///run/buildkit/buildkitd.sock --oci-worker=false --containerd-worker=true --containerd-worker-addr=/run/k3s/containerd/containerd.sock --containerd-worker-snapshotter=overlayfs --containerd-worker-net=host
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
  install_if_changed /tmp/buildkit-k3s.service.expected /etc/systemd/system/buildkit-k3s.service

  if [[ -n "${PROXY_URL:-}" ]]; then
    sudo mkdir -p /etc/systemd/system/buildkit-k3s.service.d
    cat >/tmp/buildkit-k3s-proxy.conf.expected <<EOF
[Service]
Environment="HTTP_PROXY=$PROXY_URL"
Environment="HTTPS_PROXY=$PROXY_URL"
Environment="NO_PROXY=$NO_PROXY"
EOF
    install_if_changed /tmp/buildkit-k3s-proxy.conf.expected /etc/systemd/system/buildkit-k3s.service.d/proxy.conf
  else
    if sudo test -e /etc/systemd/system/buildkit-k3s.service.d; then
      sudo rm -rf /etc/systemd/system/buildkit-k3s.service.d
      restart_buildkit=1
    fi
  fi

  if (( restart_buildkit )); then
    sudo systemctl daemon-reload
  fi
  sudo systemctl enable --now buildkit-k3s.service
  if (( restart_buildkit )); then
    sudo systemctl restart buildkit-k3s.service
  fi
  if ! wait_for_buildkit; then
    sudo systemctl restart buildkit-k3s.service
  fi
  wait_for_buildkit
}

ensure_buildkit_k3s

export BUILDKIT_HOST="${BUILDKIT_HOST:-unix:///run/buildkit/buildkitd.sock}"
NERDCTL=(sudo env HTTP_PROXY="${HTTP_PROXY:-}" HTTPS_PROXY="${HTTPS_PROXY:-}" http_proxy="${http_proxy:-}" https_proxy="${https_proxy:-}" NO_PROXY="${NO_PROXY:-}" no_proxy="${no_proxy:-}" /usr/local/bin/nerdctl --address /run/k3s/containerd/containerd.sock --namespace k8s.io --hosts-dir /var/lib/rancher/k3s/agent/etc/containerd/certs.d)
build_proxy_args=()
if [[ -n "${PROXY_URL:-}" ]]; then
  build_proxy_args+=(
    --build-arg HTTP_PROXY="$PROXY_URL"
    --build-arg HTTPS_PROXY="$PROXY_URL"
    --build-arg http_proxy="$PROXY_URL"
    --build-arg https_proxy="$PROXY_URL"
    --build-arg NO_PROXY="$NO_PROXY"
    --build-arg no_proxy="$NO_PROXY"
  )
fi
"${NERDCTL[@]}" build "${build_proxy_args[@]}" -t "${IMAGE_REPOSITORY}:${IMAGE_TAG}" -f Dockerfile .
# The downloader image uses only internal mirrors. Explicitly clear build-time
# proxy variables so pip does not try to use a SOCKS proxy without PySocks.
downloader_build_args=(
  --build-arg HTTP_PROXY=
  --build-arg HTTPS_PROXY=
  --build-arg http_proxy=
  --build-arg https_proxy=
  --build-arg NO_PROXY="$NO_PROXY"
  --build-arg no_proxy="$NO_PROXY"
)
"${NERDCTL[@]}" build "${downloader_build_args[@]}" \
  -t "${DOWNLOADER_IMAGE_REPOSITORY}:${DOWNLOADER_IMAGE_TAG}" \
  -t "${DOWNLOADER_IMAGE_REPOSITORY}:latest" \
  -f flyteplugins/aione/downloader/Dockerfile flyteplugins/aione/downloader

PUBLIC_REGISTRY="$PUBLIC_REGISTRY" REGISTRY_BACKEND="$REGISTRY_BACKEND" \
  bash scripts/registry/push-local-images.sh \
    "${IMAGE_REPOSITORY}:${IMAGE_TAG}" \
    "${DOWNLOADER_IMAGE_REPOSITORY}:${DOWNLOADER_IMAGE_TAG}" \
    "${DOWNLOADER_IMAGE_REPOSITORY}:latest"

prune_old_release_images() {
  if [[ "$IMAGE_TAG" != "$IMAGE_TAG_PREFIX"* ]]; then
    printf 'Skipping release image pruning for non-release tag: %s\n' "$IMAGE_TAG"
    return 0
  fi
  if ! [[ "$IMAGE_TAG_KEEP" =~ ^[0-9]+$ ]] || (( IMAGE_TAG_KEEP < 1 )); then
    printf 'IMAGE_TAG_KEEP must be a positive integer, got: %s\n' "$IMAGE_TAG_KEEP" >&2
    return 1
  fi

  local keep_file
  keep_file="$(mktemp)"
  {
    "${NERDCTL[@]}" images --format '{{.Repository}}:{{.Tag}}|{{.CreatedAt}}' \
      | awk -F '|' -v repository="${IMAGE_REPOSITORY}" -v tag_prefix="${IMAGE_TAG_PREFIX}" '
        {
          repo_tag = $1
          tag = substr(repo_tag, length(repository) + 2)
          if (repo_tag == repository ":" tag && index(tag, tag_prefix) == 1 && $2 != "") {
            printf "%s\t%s\n", $2, tag
          }
        }'
    printf '9999-12-31T23:59:59Z|%s\n' "$IMAGE_TAG"
  } | sort -t '|' -k1,1 \
    | awk -F '|' '{rows[$2] = $0} END {for (tag in rows) print rows[tag]}' \
    | sort -t '|' -k1,1 \
    | tail -n "$IMAGE_TAG_KEEP" \
    | awk -F '|' '{print $2}' > "$keep_file"

  sudo k3s ctr images ls -q \
    | while IFS= read -r image; do
        case "$image" in
          "${IMAGE_REPOSITORY}:${IMAGE_TAG_PREFIX}"*|*/"${IMAGE_REPOSITORY}:${IMAGE_TAG_PREFIX}"*)
            tag="${image##*:}"
            if ! grep -Fxq "$tag" "$keep_file"; then
              sudo k3s ctr images rm "$image" || true
            fi
            ;;
        esac
      done

  rm -f "$keep_file"
}

pull_containerd_image() {
  local image="$1"
  local image_refs
  image_refs="$(sudo k3s ctr -n k8s.io images ls -q || true)"
  if printf '%s\n' "$image_refs" | grep -Fxq "$image"; then
    printf 'Image already present: %s\n' "$image"
    return
  fi
  if [[ "$image" != */* ]] && printf '%s\n' "$image_refs" | grep -Fxq "docker.io/library/$image"; then
    printf 'Image already present: %s\n' "$image"
    return
  fi
  if [[ "$image" != */* ]] && printf '%s\n' "$image_refs" | grep -Fxq "docker.fzyun.io/library/$image"; then
    printf 'Image already present: %s\n' "$image"
    return
  fi
  if [[ "$image" == */* && "$image" != *.*/* && "$image" != localhost/* ]] && printf '%s\n' "$image_refs" | grep -Fxq "docker.io/$image"; then
    printf 'Image already present: %s\n' "$image"
    return
  fi
  if [[ "$image" == */* && "$image" != *.*/* && "$image" != localhost/* ]] && printf '%s\n' "$image_refs" | grep -Fxq "docker.fzyun.io/$image"; then
    printf 'Image already present: %s\n' "$image"
    return
  fi
  "${NERDCTL[@]}" pull "$image"
}

pull_containerd_image rancher/mirrored-pause:3.6
pull_containerd_image rancher/mirrored-coredns-coredns:1.14.3
pull_containerd_image rancher/local-path-provisioner:v0.0.36
pull_containerd_image rancher/mirrored-library-busybox:1.37.0 || printf 'Optional image unavailable: %s\n' 'rancher/mirrored-library-busybox:1.37.0'
pull_containerd_image rancher/mirrored-library-traefik:3.6.13
pull_containerd_image "${POSTGRES_IMAGE_REPOSITORY}:17"
pull_containerd_image "${CONSOLE_IMAGE_REPOSITORY}:latest"
pull_containerd_image "${RUSTFS_IMAGE_REPOSITORY}:1.0.0-alpha.94"
pull_containerd_image "${BUSYBOX_IMAGE_REPOSITORY}:stable"

kubectl -n kube-system rollout status deploy/coredns --timeout=5m
kubectl -n kube-system rollout status deploy/local-path-provisioner --timeout=5m
if kubectl -n kube-system get deploy/traefik >/dev/null 2>&1; then
  kubectl -n kube-system rollout status deploy/traefik --timeout=5m
fi

sudo mkdir -p /var/lib/flyte/storage/rustfs
sudo chown -R 10001:10001 /var/lib/flyte/storage/rustfs

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$NAMESPACE" apply -f - <<POSTGRES_MANIFEST
apiVersion: v1
kind: ConfigMap
metadata:
  name: postgresql-init
data:
  init.sql: |
    CREATE DATABASE runs;
---
apiVersion: v1
kind: Service
metadata:
  name: postgresql
spec:
  selector:
    app: postgresql
  ports:
    - name: postgresql
      port: 5432
      targetPort: 5432
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgresql
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postgresql
  template:
    metadata:
      labels:
        app: postgresql
    spec:
      nodeSelector:
        kubernetes.io/hostname: ${CONTROL_PLANE_NODE}
      containers:
        - name: postgresql
          image: ${POSTGRES_IMAGE_REPOSITORY}:17
          imagePullPolicy: IfNotPresent
          env:
            - name: POSTGRES_USER
              value: postgres
            - name: POSTGRES_PASSWORD
              value: postgres
            - name: POSTGRES_DB
              value: flyte
          ports:
            - containerPort: 5432
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
            - name: init
              mountPath: /docker-entrypoint-initdb.d
      volumes:
        - name: data
          emptyDir: {}
        - name: init
          configMap:
            name: postgresql-init
POSTGRES_MANIFEST
kubectl -n "$NAMESPACE" rollout status deploy/postgresql --timeout=5m
if ! helm dependency update charts/flyte-devbox; then
  if compgen -G "charts/flyte-devbox/charts/*.tgz" >/dev/null; then
    printf 'Helm dependency update failed; using existing packaged dependencies.\n'
  else
    printf 'Helm dependency update failed and no packaged dependencies exist.\n' >&2
    exit 1
  fi
fi
helm upgrade --install "$RELEASE" charts/flyte-devbox \
  --namespace "$NAMESPACE" \
  --set docker-registry.enabled=false \
  --set flyte-binary.configuration.co-pilot.image.repository="$IMAGE_REPOSITORY" \
  --set flyte-binary.configuration.co-pilot.image.tag="$IMAGE_TAG" \
  --set flyte-binary.deployment.image.repository="$IMAGE_REPOSITORY" \
  --set flyte-binary.deployment.image.tag="$IMAGE_TAG" \
  --set flyte-binary.deployment.image.pullPolicy=IfNotPresent \
  --set "flyte-binary.deployment.extraPodSpec.nodeSelector.kubernetes\\.io/hostname=$CONTROL_PLANE_NODE" \
  --set flyte-binary.deployment.extraEnvVars[0].name=AIONE_DOWNLOADER_IMAGE \
  --set flyte-binary.deployment.extraEnvVars[0].value="${DOWNLOADER_IMAGE_REPOSITORY}:${DOWNLOADER_IMAGE_TAG}" \
  --set flyte-binary.deployment.waitForDB.image.repository="$POSTGRES_IMAGE_REPOSITORY" \
  --set-string flyte-binary.deployment.waitForDB.image.tag=17 \
  --set flyte-binary.deployment.waitForDB.image.pullPolicy=IfNotPresent \
  --set flyte-binary.console.image.repository="$CONSOLE_IMAGE_REPOSITORY" \
  --set flyte-binary.console.image.tag=latest \
  --set flyte-binary.console.image.pullPolicy=IfNotPresent \
  --set "flyte-binary.console.nodeSelector.kubernetes\\.io/hostname=$CONTROL_PLANE_NODE" \
  --set "rustfs.nodeSelector.kubernetes\\.io/hostname=$CONTROL_PLANE_NODE" \
  --set rustfs.image.repository="$RUSTFS_IMAGE_REPOSITORY" \
  --set rustfs.image.tag=1.0.0-alpha.94 \
  --set rustfs.image.rustfs.repository="$RUSTFS_IMAGE_REPOSITORY" \
  --set rustfs.image.rustfs.tag=1.0.0-alpha.94 \
  --set rustfs.image.rustfs.pullPolicy=IfNotPresent \
  --set rustfs.image.initImage.repository="$BUSYBOX_IMAGE_REPOSITORY" \
  --set rustfs.image.initImage.tag=stable \
  --set rustfs.image.initImage.pullPolicy=IfNotPresent

kubectl -n "$NAMESPACE" rollout status deploy/flyte-binary-console --timeout=5m
kubectl -n "$NAMESPACE" rollout status deploy/rustfs --timeout=5m
kubectl -n "$NAMESPACE" rollout status deploy/flyte-binary --timeout=10m
prune_old_release_images
kubectl -n "$NAMESPACE" get svc,pod
node_ip="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
ingress_port="$(kubectl -n kube-system get svc traefik -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}')"
printf '\nIngress access:\n'
printf 'Web UI: http://%s:%s/v2\n' "$node_ip" "$ingress_port"
printf 'API endpoint: http://%s:%s\n' "$node_ip" "$ingress_port"
REMOTE_SCRIPT
)"

ssh_env="$(remote_env)"

if [[ "$DRY_RUN" == "1" ]]; then
  printf '%s %s %s bash -s\n' "$SSH_BIN" "$REMOTE_HOST" "$ssh_env"
  printf '%s\n' "$remote_script"
  exit 0
fi

"$SSH_BIN" "$REMOTE_HOST" "$ssh_env bash -s" <<<"$remote_script"
