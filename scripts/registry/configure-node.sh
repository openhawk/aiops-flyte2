#!/usr/bin/env bash
set -euo pipefail

SERVICE_UNIT="${SERVICE_UNIT:?SERVICE_UNIT is required}"
TARGET=/etc/rancher/k3s/registries.yaml
BACKUP_DIR=/etc/rancher/k3s/registry-backups
EXPECTED="$(mktemp)"
trap 'rm -f "$EXPECTED"' EXIT

cat >"$EXPECTED" <<'EOF'
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

curl -fsS --connect-timeout 5 https://docker.ops.fzyun.io/v2/ >/dev/null
if sudo test -f "$TARGET" && sudo cmp -s "$EXPECTED" "$TARGET"; then
  printf '%s already uses the cluster registry configuration.\n' "$(hostname)"
  exit 0
fi

sudo mkdir -p "$BACKUP_DIR"
if sudo test -f "$TARGET"; then
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  sudo cp -a "$TARGET" "$BACKUP_DIR/registries.yaml.$timestamp"
fi
sudo install -D -m 0644 "$EXPECTED" "$TARGET"
sudo systemctl restart "$SERVICE_UNIT.service"

for attempt in {1..90}; do
  if sudo systemctl is-active --quiet "$SERVICE_UNIT.service"; then
    printf '%s restarted successfully with the cluster registry configuration.\n' "$(hostname)"
    exit 0
  fi
  sleep 2
done

sudo systemctl status "$SERVICE_UNIT.service" --no-pager -l
exit 1
