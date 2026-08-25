#!/usr/bin/env bash
set -euo pipefail

REMOTE_HOST="${REMOTE_HOST:-aione-flyte2}"
REMOTE_DIR="${REMOTE_DIR:-/opt/aiops-flyte2}"
NAMESPACE="${NAMESPACE:-flyte}"
CONSOLE_URL="${CONSOLE_URL:-http://172.19.66.218:30081/v2/projects}"
PUBLIC_REGISTRY="${PUBLIC_REGISTRY:-docker.ops.fzyun.io}"
REGISTRY_BACKEND="${REGISTRY_BACKEND:-172.19.66.224:30000}"
IMAGE_REPOSITORY="${IMAGE_REPOSITORY:-${PUBLIC_REGISTRY}/flyte-console-extracted}"
IMAGE_TAG="${IMAGE_TAG:-}"
NERDCTL_VERSION="${NERDCTL_VERSION:-2.3.3}"
PROXY_URL="${PROXY_URL:-}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-/root/.kube/config}"
EXPECTED_COMMIT="${EXPECTED_COMMIT:-$(git rev-parse HEAD)}"
DRY_RUN="${DRY_RUN:-0}"

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

remote_env() {
  printf "REMOTE_DIR=%s NAMESPACE=%s CONSOLE_URL=%s PUBLIC_REGISTRY=%s REGISTRY_BACKEND=%s IMAGE_REPOSITORY=%s IMAGE_TAG=%s NERDCTL_VERSION=%s PROXY_URL=%s KUBECONFIG_PATH=%s EXPECTED_COMMIT=%s" \
    "$(shell_quote "$REMOTE_DIR")" \
    "$(shell_quote "$NAMESPACE")" \
    "$(shell_quote "$CONSOLE_URL")" \
    "$(shell_quote "$PUBLIC_REGISTRY")" \
    "$(shell_quote "$REGISTRY_BACKEND")" \
    "$(shell_quote "$IMAGE_REPOSITORY")" \
    "$(shell_quote "$IMAGE_TAG")" \
    "$(shell_quote "$NERDCTL_VERSION")" \
    "$(shell_quote "$PROXY_URL")" \
    "$(shell_quote "$KUBECONFIG_PATH")" \
    "$(shell_quote "$EXPECTED_COMMIT")"
}

SSH_BIN="${SSH_BIN:-ssh}"
if ! command -v "$SSH_BIN" >/dev/null 2>&1; then
  printf 'SSH client is unavailable: %s\n' "$SSH_BIN" >&2
  exit 1
fi

remote_script="$(cat <<'REMOTE_SCRIPT'
set -euo pipefail

if [[ -n "${PROXY_URL:-}" ]]; then
  export HTTP_PROXY="$PROXY_URL"
  export HTTPS_PROXY="$PROXY_URL"
  export http_proxy="$PROXY_URL"
  export https_proxy="$PROXY_URL"
  export NO_PROXY="${NO_PROXY:-127.0.0.1,localhost,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.svc,.cluster.local,docker.fzyun.io,docker.ops.fzyun.io,mirrors.fzyun.io,pypi.fzyun.io,registry.npmmirror.com}"
  export no_proxy="$NO_PROXY"
fi

K3S_SYSTEMD_UNIT="k3s-agent"
if ! systemctl is-active --quiet "${K3S_SYSTEMD_UNIT}.service"; then
  printf 'The existing k3s cluster node agent is not active: %s.service\n' "$K3S_SYSTEMD_UNIT" >&2
  exit 1
fi

if [[ ! -r "$KUBECONFIG_PATH" ]]; then
  printf 'Kubernetes kubeconfig is not readable: %s\n' "$KUBECONFIG_PATH" >&2
  exit 1
fi
export KUBECONFIG="$KUBECONFIG_PATH"
kubectl get --raw=/readyz >/dev/null
kubectl get namespace "$NAMESPACE" >/dev/null

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

curl_with_retries() {
  local url="$1"
  local attempt
  for attempt in {1..10}; do
    if curl -I "$url"; then
      return 0
    fi
    sleep 2
  done
  curl -I "$url"
}

cd "$REMOTE_DIR"
if [[ "$(git rev-parse HEAD)" != "$EXPECTED_COMMIT" ]]; then
  git pull --ff-only origin main
fi
if [[ "$(git rev-parse HEAD)" != "$EXPECTED_COMMIT" ]]; then
  printf 'remote checkout is not at expected commit %s\n' "$EXPECTED_COMMIT" >&2
  exit 1
fi
COMMIT="$(git rev-parse --short HEAD)"
IMAGE_TAG="${IMAGE_TAG:-main-${COMMIT}}"
ensure_buildkit_k3s

export BUILDKIT_HOST="${BUILDKIT_HOST:-unix:///run/buildkit/buildkitd.sock}"
NERDCTL=(sudo env HTTP_PROXY="${HTTP_PROXY:-}" HTTPS_PROXY="${HTTPS_PROXY:-}" http_proxy="${http_proxy:-}" https_proxy="${https_proxy:-}" NO_PROXY="${NO_PROXY:-}" no_proxy="${no_proxy:-}" /usr/local/bin/nerdctl --address /run/k3s/containerd/containerd.sock --namespace k8s.io)
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

"${NERDCTL[@]}" build "${build_proxy_args[@]}" -f flyte_console/Dockerfile \
  -t "${IMAGE_REPOSITORY}:${IMAGE_TAG}" \
  -t "${IMAGE_REPOSITORY}:latest" \
  flyte_console
sudo k3s ctr -n k8s.io images ls | grep -E "${IMAGE_REPOSITORY}:(${IMAGE_TAG}|latest)"

PUBLIC_REGISTRY="$PUBLIC_REGISTRY" REGISTRY_BACKEND="$REGISTRY_BACKEND" \
  bash scripts/registry/push-local-images.sh \
    "${IMAGE_REPOSITORY}:${IMAGE_TAG}" \
    "${IMAGE_REPOSITORY}:latest"

sed "s|image: docker.ops.fzyun.io/flyte-console-extracted:latest|image: ${IMAGE_REPOSITORY}:${IMAGE_TAG}|" \
  deploy/ui/flyte-console-extracted.yaml | kubectl apply -f -
kubectl -n "$NAMESPACE" rollout status deploy/flyte-console-extracted --timeout=180s
kubectl -n "$NAMESPACE" get pod -l app=flyte-console-extracted -o wide
kubectl -n "$NAMESPACE" logs deploy/flyte-console-extracted --tail=80
curl_with_retries "$CONSOLE_URL"
REMOTE_SCRIPT
)"

ssh_env="$(remote_env)"

if [[ "$DRY_RUN" == "1" ]]; then
  printf '%s %s %s bash -s\n' "$SSH_BIN" "$REMOTE_HOST" "$ssh_env"
  printf '%s\n' "$remote_script"
  exit 0
fi

"$SSH_BIN" "$REMOTE_HOST" "$ssh_env bash -s" <<<"$remote_script"
