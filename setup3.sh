#!/bin/bash
set -euo pipefail

# ====== Configurable defaults ======
N8N_USER="${N8N_USER:-admin}"
N8N_PASS="${N8N_PASS:-CHANGE_ME}"
N8N_PORT="${N8N_PORT:-5678}"     # Host port
N8N_DIR="${N8N_DIR:-$HOME/n8n}"

echo "== n8n Docker installer =="

# ====== OS check ======
if ! grep -qiE "ubuntu|debian" /etc/os-release; then
  echo "This script supports Ubuntu/Debian only."
  exit 1
fi

# ====== System update ======
sudo apt update -y
sudo apt upgrade -y

# ====== Install Docker ======
if ! command -v docker >/dev/null 2>&1; then
  sudo apt install -y docker.io
  sudo systemctl enable docker
  sudo systemctl start docker
else
  sudo systemctl start docker || true
fi

# ====== Install Docker Compose v2 ======
if ! docker compose version >/dev/null 2>&1; then
  sudo apt install -y docker-compose-plugin
fi

# ====== Docker group ======
if ! groups "$USER" | grep -qw docker; then
  sudo usermod -aG docker "$USER"
  echo "User added to docker group. Log out/in after script finishes."
fi

# ====== Prepare directories ======
mkdir -p "$N8N_DIR/n8n_data"
cd "$N8N_DIR"

# ====== docker-compose.yml ======
cat <<EOF > docker-compose.yml
version: "3.8"
services:
  n8n:
    image: n8nio/n8n:latest
    container_name: n8n
    restart: unless-stopped
    ports:
      - "${N8N_PORT}:5678"
    environment:
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=${N8N_USER}
      - N8N_BASIC_AUTH_PASSWORD=${N8N_PASS}

      - N8N_PORT=5678
      - N8N_PROTOCOL=http

      - N8N_DIAGNOSTICS_ENABLED=false
      - N8N_VERSION_NOTIFICATIONS_ENABLED=false

    volumes:
      - ./n8n_data:/home/node/.n8n
EOF

# ====== Firewall ======
if command -v ufw >/dev/null 2>&1; then
  sudo ufw allow "${N8N_PORT}/tcp" || true
  sudo ufw enable || true
fi

# ====== Start n8n ======
echo "Starting n8n..."
docker compose pull
docker compose up -d

# ====== Status ======
docker ps --filter name=n8n

PUB_IP="$(curl -s ifconfig.me || hostname -I | awk '{print $1}')"

echo
echo "n8n URL : http://${PUB_IP}:${N8N_PORT}"
echo "User    : ${N8N_USER}"
echo "Pass    : ${N8N_PASS}"
echo
echo "IMPORTANT:"
echo "- Change the default password immediately"
echo "- For production, use a domain + HTTPS (Traefik / Nginx)"
