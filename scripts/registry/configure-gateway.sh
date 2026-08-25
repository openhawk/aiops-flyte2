#!/usr/bin/env bash
set -euo pipefail

CONFIG=/opt/haproxy/haproxy.cfg
BACKUP_DIR=/opt/haproxy/backups
REGISTRY_BACKEND_URL="${REGISTRY_BACKEND_URL:-http://172.19.66.224:30000/v2/}"
UI_BACKEND_URL="${UI_BACKEND_URL:-http://172.19.66.224:30001/}"
CANDIDATE="$(mktemp)"
BACKUP=""
switched=0

cleanup() {
  local status=$?
  rm -f "$CANDIDATE"
  if (( status != 0 && switched == 1 )) && [[ -n "$BACKUP" ]]; then
    printf 'Gateway validation failed; restoring %s\n' "$BACKUP" >&2
    sudo cp -a "$BACKUP" "$CONFIG"
    sudo systemctl restart haproxy-docker.service || true
  fi
  exit "$status"
}
trap cleanup EXIT

curl -fsS --connect-timeout 5 "$REGISTRY_BACKEND_URL" >/dev/null
curl -fsS --connect-timeout 5 "$UI_BACKEND_URL" | grep -qi '<html'
sudo test -r "$CONFIG"
sudo mkdir -p "$BACKUP_DIR"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="$BACKUP_DIR/haproxy.cfg.$timestamp"
sudo cp -a "$CONFIG" "$BACKUP"

sudo awk '
  /# BEGIN AIOPS CLUSTER REGISTRY ACL/ { skip_acl=1; next }
  /# END AIOPS CLUSTER REGISTRY ACL/ { skip_acl=0; next }
  /# BEGIN AIOPS CLUSTER REGISTRY BACKEND/ { skip_backend=1; next }
  /# END AIOPS CLUSTER REGISTRY BACKEND/ { skip_backend=0; next }
  skip_acl || skip_backend { next }
  /^[[:space:]]*default_backend[[:space:]]+aione_flyte2_ingress/ && !acl_added {
    print "    # BEGIN AIOPS CLUSTER REGISTRY ACL"
    print "    acl host_docker_ops hdr(host) -i docker.ops.fzyun.io"
    print "    acl path_docker_registry_api path_beg -i /v2"
    print "    use_backend cluster_registry_api if host_docker_ops path_docker_registry_api"
    print "    use_backend cluster_registry_ui if host_docker_ops"
    print "    # END AIOPS CLUSTER REGISTRY ACL"
    print ""
    acl_added=1
  }
  { print }
  END {
    if (!acl_added) exit 42
    print ""
    print "# BEGIN AIOPS CLUSTER REGISTRY BACKEND"
    print "backend cluster_registry_api"
    print "    mode http"
    print "    option httpchk GET /v2/"
    print "    http-check expect status 200"
    print "    timeout connect 5s"
    print "    timeout server 1h"
    print "    server k3s_registry 172.19.66.224:30000 check"
    print ""
    print "backend cluster_registry_ui"
    print "    mode http"
    print "    option httpchk GET /"
    print "    http-check expect status 200"
    print "    timeout connect 5s"
    print "    timeout server 60s"
    print "    server k3s_registry_ui 172.19.66.224:30001 check"
    print "# END AIOPS CLUSTER REGISTRY BACKEND"
  }
' "$CONFIG" >"$CANDIDATE"

sudo docker run --rm --user root --network host \
  -v "$CANDIDATE:/usr/local/etc/haproxy/haproxy.cfg:ro" \
  -v /opt/haproxy/certs:/usr/local/etc/haproxy/certs:ro \
  haproxy:lts-alpine haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg
sudo install -m 0644 "$CANDIDATE" "$CONFIG"
switched=1
sudo systemctl restart haproxy-docker.service
sudo systemctl is-active --quiet haproxy-docker.service

for attempt in {1..30}; do
  if curl -fsS --connect-timeout 5 https://docker.ops.fzyun.io/v2/ >/dev/null; then
    break
  fi
  sleep 2
done
curl -fsS --connect-timeout 5 https://docker.ops.fzyun.io/v2/ >/dev/null
curl -fsS --connect-timeout 5 https://docker.ops.fzyun.io/ | grep -qi '<html'
curl -fsS --connect-timeout 5 http://docker.ops.fzyun.io:5000/v2/ >/dev/null
printf 'HAProxy routes /v2 to the Registry API and all other paths to Joxit UI. Backup: %s\n' "$BACKUP"
switched=0
