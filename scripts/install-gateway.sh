#!/usr/bin/env bash
set -euo pipefail
# Run ON the DGX as its normal login user. It does not modify the existing dsh process.
ROOT="${POCKET_ROOT:-$HOME/.local/share/harness-pocket}"
NODE="${POCKET_NODE:-$(command -v node || true)}"
if [[ -z "$NODE" ]]; then echo 'Set POCKET_NODE to the Node.js 22+ executable.' >&2; exit 1; fi
mkdir -p "$ROOT/data" "$HOME/.config/systemd/user"
chmod 700 "$ROOT/data"
if [[ ! -f "$ROOT/gateway/.env" ]]; then echo 'Create the private gateway/.env from .env.example first.' >&2; exit 1; fi
chmod 600 "$ROOT/gateway/.env"
cat > "$HOME/.config/systemd/user/harness-pocket.service" <<EOF
[Unit]
Description=Harness Pocket iPhone gateway and completion notifications
After=network-online.target

[Service]
Type=simple
WorkingDirectory=$ROOT/gateway
ExecStart=$NODE --env-file=$ROOT/gateway/.env src/main.mjs
Restart=on-failure
RestartSec=5
UMask=0077
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now harness-pocket.service
systemctl --user --no-pager status harness-pocket.service
echo 'Next: tailscale serve --bg --https=8443 http://127.0.0.1:8787'
