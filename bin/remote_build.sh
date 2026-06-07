#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# remote_build.sh
#
# Run this ON the EC2 server (as the pod user or with sudo -u pod) after
# pushing code to /opt/pod. Compiles a prod release and restarts the service.
#
# Usage (from the server):
#   sudo -u pod bash /opt/pod/bin/remote_build.sh
# ---------------------------------------------------------------------------
set -euo pipefail

APP_DIR="/opt/pod"
cd "${APP_DIR}"

echo "==> Fetching dependencies"
mix local.hex --force --quiet
mix local.rebar --force --quiet
MIX_ENV=prod mix deps.get --only prod

echo "==> Compiling"
MIX_ENV=prod mix compile --warnings-as-errors

echo "==> Building release"
MIX_ENV=prod mix release --overwrite

echo "==> Running migrations"
source "${APP_DIR}/.env"
"${APP_DIR}/_build/prod/rel/pod/bin/pod" eval "Pod.Release.migrate()"

echo "==> Restarting service"
sudo systemctl restart pod

echo ""
echo "==> Done! Check status with: sudo systemctl status pod"
echo "    Logs: sudo journalctl -u pod -f"
