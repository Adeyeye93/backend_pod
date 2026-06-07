#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# deploy.sh
#
# Run this from your LOCAL machine to push code to the EC2 server and
# trigger a rebuild + restart.
#
# Usage:
#   ./bin/deploy.sh ubuntu@YOUR_EC2_IP [path/to/ssh_key.pem]
#
# Examples:
#   ./bin/deploy.sh ubuntu@3.92.45.10
#   ./bin/deploy.sh ubuntu@3.92.45.10 ~/.ssh/my-key.pem
# ---------------------------------------------------------------------------
set -euo pipefail

TARGET="${1:-}"
SSH_KEY="${2:-}"

if [[ -z "${TARGET}" ]]; then
  echo "Usage: $0 user@ec2-ip [path/to/key.pem]"
  exit 1
fi

SSH_OPTS="-o StrictHostKeyChecking=no"
if [[ -n "${SSH_KEY}" ]]; then
  SSH_OPTS="${SSH_OPTS} -i ${SSH_KEY}"
fi

APP_DIR="/opt/pod"

echo "==> Syncing code to ${TARGET}:${APP_DIR}"
rsync -avz \
  --exclude '_build' \
  --exclude 'deps' \
  --exclude '.git' \
  --exclude 'priv/segments' \
  --exclude '.env' \
  --exclude '*.log' \
  -e "ssh ${SSH_OPTS}" \
  ./ "${TARGET}:${APP_DIR}/"

echo "==> Fixing ownership"
ssh ${SSH_OPTS} "${TARGET}" "sudo chown -R pod:pod ${APP_DIR}"

echo "==> Building and restarting"
ssh ${SSH_OPTS} "${TARGET}" "sudo -u pod bash ${APP_DIR}/bin/remote_build.sh"
