
#!/bin/bash
set -euo pipefail

# ====== Configurable defaults ======
N8N_USER="${N8N_USER:-admin}"
N8N_PASS="${N8N_PASS:-admin123}"
N8N_PORT="${N8N_PORT:-5678}"       # Host port to expose
N8N_DIR="${N8N_DIR:-$HOME/n8n}"    # Install directory

echo "== Minimal install: Docker + n8n (MCP) for low-end servers =="

# ====== Prereqs (keep it light) ======
sudo apt update -y

# Install Docker Engine from Ubuntu packages (lightweight & fast)
if ! command -v docker >/dev/null 2>&1; then
  sudo apt install -y docker.io
  sudo systemctl enable --now docker
else
  echo "Docker already installed."
  sudo systemctl enable docker || true
  sudo systemctl start docker || true
fi

# Install Compose V2 plugin (preferred) if 'docker compose' not available
if ! docker compose version >/dev/null 2>&1; then
  echo "Installing docker-compose-plugin..."
  sudo apt install -y docker-compose-plugin
else
  echo "docker compose plugin already installed."
fi

# Add current user to docker group (optional)
if ! groups "$USER" | grep -qw docker; then
  echo "Adding '$USER' to 'docker' group..."
  sudo usermod -aG docker "$USER" || true
  echo "Log out/in for group changes to take effect."
fi

# ====== Prepare n8n directory ======
mkdir -p "$N8N_DIR"
cd "$N8N_DIR"

# ====== Create docker-compose.yml (tuned for low memory/CPU) ======
cat <<EOF > docker-compose.yml
version: "3.8"

services:
  n8n:
    image: mcp/n8n:latest
    container_name: n8n
    restart: unless-stopped
    ports:
      - "${N8N_PORT:-5678}:5678"
    # NOTE: deploy.resources.limits are only enforced in Swarm.
    # For low-end tuning we use Node heap limit + n8n settings.
    environment:
      # ---- Security / Access ----
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=${N8N_USER:-admin}
      - N8N_BASIC_AUTH_PASSWORD=${N8N_PASS:-admin123}
      - N8N_PROTOCOL=http
      - N8N_HOST=0.0.0.0
      - N8N_PORT=5678

      # ---- Low-end performance tuning ----
      # Limit Node.js heap to 256 MB to prevent OOM on 1–2GB machines
      - NODE_OPTIONS=--max-old-space-size=256
      # Reduce noisy logs
      - N8N_LOG_LEVEL=warn
      # Run executions in main process (lower overhead than separate)
      - EXECUTIONS_PROCESS=main
      # Limit parallelism
      - N8N_CONCURRENCY=1
      # Keep webhook deregistration from blocking startup (helps restarts)
      - N8N_SKIP_WEBHOOK_DEREGISTRATION=true
      # Disable metrics/diagnostics/notifications to save CPU/mem
      - N8N_DIAGNOSTICS_ENABLED=false
      - N8N_METRICS_ENABLED=false
      - N8N_VERSION_NOTIFICATIONS_ENABLED=false
      # Avoid crash loops if something fails
      - N8N_HIRING_BANNER_ENABLED=false

      # ---- URLs for external callbacks (optional, plain HTTP) ----
      # Uncomment and set your public IP/domain if you use webhooks externally:
      #- WEBHOOK_URL=http://YOUR_PUBLIC_IP_OR_DOMAIN:${N8N_PORT:-5678}
      #- N8N_EDITOR_BASE_URL=http://YOUR_PUBLIC_IP_OR_DOMAIN:${N8N_PORT:-5678}

    # Persist minimal data on disk
    volumes:
      - ./n8n_data:/home/node/.n8n

    # Healthcheck: simple curl to editor endpoint (lightweight)
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:5678/ || exit 1"]
      interval: 20s
      timeout: 5s
      retries: 10
      start_period: 20s
EOF

# Export variables for compose interpolation
export N8N_USER N8N_PASS N8N_PORT

# ====== Open firewall (UFW) only if present ======
if command -v ufw >/dev/null 2>&1; then
  echo "Allowing TCP port ${N8N_PORT} via UFW..."
  sudo ufw allow "${N8N_PORT}/tcp" || true
  sudo ufw status || true
else
  echo "UFW not found; skipping firewall step."
fi

# ====== Pull & start (Compose V2) ======
echo "Pulling and starting n8n (MCP build)..."
docker compose pull
docker compose up -d

# ====== Diagnostics ======
echo "== Containers =="
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

echo "== Initial logs (tail 50) =="
docker compose logs --tail=50 n8n || true

# Resolve public IP quickly without heavy deps
PUB_IP="$(curl -s --max-time 3 http://checkip.amazonaws.com || curl -s --max-time 3 ifconfig.me || hostname -I | awk '{print $1}')"
echo
echo "✅ n8n (MCP) should be reachable at:  http://${PUB_IP}:${N8N_PORT}"
echo "🔐 Basic auth credentials:           ${N8N_USER} / ${N8N_PASS}"
echo
echo "Tips:"
echo "- If you get 'connection refused', check DigitalOcean Cloud Firewall and UFW for port ${N8N_PORT}/tcp."
echo "- For tiny droplets, keep workflows simple and avoid high parallelism."
echo "- Change port: N8N_PORT=8080 ./install_n8n_low_end.sh"
echo
