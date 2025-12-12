
#!/bin/bash
set -euo pipefail

# ====== Configurable defaults ======
N8N_USER="${N8N_USER:-admin}"
N8N_PASS="${N8N_PASS:-admin123}"
N8N_PORT="${N8N_PORT:-5678}"     # Host port to expose
N8N_DIR="${N8N_DIR:-$HOME/n8n}"  # Install directory

echo "== Installing prerequisites and Docker =="

# Update system
sudo apt update
sudo apt -y upgrade

# Install Docker
if ! command -v docker >/dev/null 2>&1; then
  sudo apt -y install docker.io
  sudo systemctl enable docker
  sudo systemctl start docker
else
  echo "Docker already installed."
  sudo systemctl enable docker || true
  sudo systemctl start docker || true
fi

# Install Docker Compose
if ! command -v docker-compose >/dev/null 2>&1; then
  sudo apt -y install docker-compose
else
  echo "docker-compose already installed."
fi

# Add current user to docker group (optional, for non-sudo docker usage)
if groups "$USER" | grep -qw docker; then
  echo "User '$USER' already in 'docker' group."
else
  echo "Adding '$USER' to 'docker' group..."
  sudo usermod -aG docker "$USER" || true
  echo "You may need to log out/in for group changes to take effect."
fi

# ====== Prepare n8n directory ======
mkdir -p "$N8N_DIR"
cd "$N8N_DIR"

# ====== Create docker-compose.yml ======
cat <<EOF > docker-compose.yml
version: "3.8"
services:
  n8n:
    image: mcp/n8n:latest
    container_name: n8n
    restart: always
    ports:
      - "${N8N_PORT}:5678"
    environment:
      # Basic auth for local/public access - CHANGE THESE
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=${N8N_USER}
      - N8N_BASIC_AUTH_PASSWORD=${N8N_PASS}

      # Bind & protocol to ensure public IP access over HTTP
      - N8N_HOST=0.0.0.0
      - N8N_PORT=5678
      - N8N_PROTOCOL=http

      # Recommended to avoid telemetry externally (optional)
      - N8N_DIAGNOSTICS_ENABLED=false
      - N8N_VERSION_NOTIFICATIONS_ENABLED=false

    volumes:
      - ./n8n_data:/home/node/.n8n
EOF

# Export variables for docker-compose variable interpolation
export N8N_USER N8N_PASS N8N_PORT

# ====== Open firewall (UFW) for chosen port ======
if command -v ufw >/dev/null 2>&1; then
  echo "Configuring UFW to allow TCP port ${N8N_PORT}..."
  sudo ufw allow "${N8N_PORT}/tcp" || true
  sudo ufw status || true
else
  echo "UFW not found; skipping firewall step."
fi

# ====== Start n8n ======
echo "Pulling and starting n8n..."
docker-compose pull
docker-compose up -d

# ====== Diagnostics ======
echo "== Docker containers =="
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

echo "== n8n logs (initial tail, may take ~10s to be ready) =="
docker-compose logs --tail=50 n8n || true

# Get public IP (fallbacks included)
PUB_IP="$(curl -s http://checkip.amazonaws.com || curl -s ifconfig.me || hostname -I | awk '{print $1}')"
echo
echo "✅ n8n should be reachable at:  http://${PUB_IP}:${N8N_PORT}"
echo "🔐 Basic auth credentials:     ${N8N_USER} / ${N8N_PASS}"
echo
echo "Tips:"
echo "- If you still see 'refused to connect', verify cloud security groups allow port ${N8N_PORT}/tcp."
echo "- You can change port by re-running with: N8N_PORT=8080 ./install_n8n_public.sh"
echo "- Change credentials: N8N_USER=you N8N_PASS=strongpass ./install_n8n_public.sh"
``


