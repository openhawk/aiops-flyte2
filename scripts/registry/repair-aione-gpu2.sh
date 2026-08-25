#!/usr/bin/env bash
set -euo pipefail

DROP_IN_DIR=/etc/systemd/system/k3s-agent.service.d
DROP_IN="$DROP_IN_DIR/10-aiops-node.conf"

sudo systemctl stop k3s-agent.service || true
if [[ -x /usr/local/bin/k3s-killall.sh ]]; then
  sudo /usr/local/bin/k3s-killall.sh
fi
sudo mkdir -p "$DROP_IN_DIR"
cat <<'EOF' | sudo tee "$DROP_IN" >/dev/null
[Service]
ExecStart=
ExecStart=/usr/local/bin/k3s agent --node-name aione-gpu2 --node-ip 172.19.66.222
EOF
sudo chmod 0644 "$DROP_IN"
sudo systemctl daemon-reload
sudo systemctl enable --now k3s-agent.service

for attempt in {1..60}; do
  if sudo systemctl is-active --quiet k3s-agent.service; then
    exec_start="$(sudo systemctl show k3s-agent.service -p ExecStart --value)"
    if [[ "$exec_start" != *node-role.kubernetes.io/worker* ]]; then
      printf 'aione-gpu2 k3s agent is active with corrected arguments.\n'
      exit 0
    fi
  fi
  sleep 2
done

sudo systemctl status k3s-agent.service --no-pager -l
exit 1
