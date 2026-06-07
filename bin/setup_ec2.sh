#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# setup_ec2.sh
#
# One-time setup for a fresh Ubuntu 22.04 EC2 instance.
# Run as a user with sudo access (e.g. the default `ubuntu` user).
#
# Usage:
#   ssh ubuntu@YOUR_EC2_IP
#   curl -fsSL https://raw.githubusercontent.com/.../bin/setup_ec2.sh | bash
#   OR copy and run directly.
# ---------------------------------------------------------------------------
set -euo pipefail

APP_USER="pod"
APP_DIR="/opt/pod"
DB_NAME="pod_prod"
DB_USER="pod"

echo "==> Updating system packages"
sudo apt-get update -qq
sudo apt-get upgrade -y -qq

echo "==> Installing system dependencies"
sudo apt-get install -y -qq \
  build-essential \
  curl \
  git \
  nginx \
  ffmpeg \
  libssl-dev \
  inotify-tools

# ---------------------------------------------------------------------------
# Erlang + Elixir via erlang-solutions
# ---------------------------------------------------------------------------
echo "==> Installing Erlang and Elixir"
wget -q https://packages.erlang-solutions.com/erlang-solutions_2.0_all.deb
sudo dpkg -i erlang-solutions_2.0_all.deb
rm erlang-solutions_2.0_all.deb
sudo apt-get update -qq
sudo apt-get install -y -qq esl-erlang elixir

# Install hex and rebar (non-interactive)
mix local.hex --force
mix local.rebar --force

# ---------------------------------------------------------------------------
# PostgreSQL 16
# ---------------------------------------------------------------------------
echo "==> Installing PostgreSQL 16"
sudo apt-get install -y -qq \
  postgresql \
  postgresql-contrib

sudo systemctl enable postgresql
sudo systemctl start postgresql

echo "==> Creating database user and database"
sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1 || \
  sudo -u postgres psql -c "CREATE USER ${DB_USER} WITH CREATEDB PASSWORD 'changeme_set_in_env';"

sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1 || \
  sudo -u postgres createdb -O "${DB_USER}" "${DB_NAME}"

echo ""
echo "  !! IMPORTANT: Change the DB password to match DATABASE_URL in /opt/pod/.env"
echo "  Run: sudo -u postgres psql -c \"ALTER USER pod PASSWORD 'your_real_password';\""
echo ""

# ---------------------------------------------------------------------------
# App user and directory
# ---------------------------------------------------------------------------
echo "==> Creating app user and directory"
id "${APP_USER}" &>/dev/null || sudo useradd --system --shell /bin/bash --create-home "${APP_USER}"
sudo mkdir -p "${APP_DIR}"
sudo chown "${APP_USER}:${APP_USER}" "${APP_DIR}"

# ---------------------------------------------------------------------------
# systemd service
# ---------------------------------------------------------------------------
echo "==> Installing systemd service"
sudo tee /etc/systemd/system/pod.service > /dev/null <<'SERVICE'
[Unit]
Description=Pod Phoenix Application
After=network.target postgresql.service
Requires=postgresql.service

[Service]
Type=exec
User=pod
WorkingDirectory=/opt/pod
EnvironmentFile=/opt/pod/.env
ExecStart=/opt/pod/_build/prod/rel/pod/bin/pod start
ExecStop=/opt/pod/_build/prod/rel/pod/bin/pod stop
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=pod

# Allow binding to port 1935 (RTMP) as non-root
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
SERVICE

sudo systemctl daemon-reload
sudo systemctl enable pod

# ---------------------------------------------------------------------------
# Nginx — proxy port 80 → Phoenix on 4000
# ---------------------------------------------------------------------------
echo "==> Configuring Nginx"
sudo tee /etc/nginx/sites-available/pod > /dev/null <<'NGINX'
upstream phoenix {
    server 127.0.0.1:4000;
}

server {
    listen 80;
    server_name _;          # Accepts any hostname / IP

    # WebSocket upgrade support (Phoenix Channels)
    location /socket/ {
        proxy_pass         http://phoenix;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade $http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_set_header   Host $host;
        proxy_set_header   X-Real-IP $remote_addr;
        proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_read_timeout 300s;
    }

    location / {
        proxy_pass         http://phoenix;
        proxy_http_version 1.1;
        proxy_set_header   Host $host;
        proxy_set_header   X-Real-IP $remote_addr;
        proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_read_timeout 60s;
        client_max_body_size 10m;
    }
}
NGINX

sudo ln -sf /etc/nginx/sites-available/pod /etc/nginx/sites-enabled/pod
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl enable nginx
sudo systemctl restart nginx

# ---------------------------------------------------------------------------
# Allow pod user to restart the service without a password
# ---------------------------------------------------------------------------
echo "pod ALL=(root) NOPASSWD: /bin/systemctl restart pod, /bin/systemctl start pod, /bin/systemctl stop pod" \
  | sudo tee /etc/sudoers.d/pod-service > /dev/null
sudo chmod 440 /etc/sudoers.d/pod-service

echo ""
echo "==> Setup complete!"
echo ""
echo "Next steps:"
echo "  1. Copy your code to ${APP_DIR}:"
echo "       rsync -avz --exclude '_build' --exclude 'deps' --exclude '.git' ./ ubuntu@YOUR_IP:${APP_DIR}/"
echo ""
echo "  2. Create the env file:"
echo "       sudo cp ${APP_DIR}/.env.production.example ${APP_DIR}/.env"
echo "       sudo nano ${APP_DIR}/.env        # fill in all values"
echo "       sudo chown pod:pod ${APP_DIR}/.env"
echo "       sudo chmod 600 ${APP_DIR}/.env"
echo ""
echo "  3. Build and start the app:"
echo "       sudo -u pod bash ${APP_DIR}/bin/remote_build.sh"
echo ""
echo "  EC2 Security Group must have these ports open:"
echo "    22   (SSH)"
echo "    80   (HTTP / API)"
echo "    1935 (RTMP — for broadcasters)"
