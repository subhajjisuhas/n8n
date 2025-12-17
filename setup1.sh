
#!/usr/bin/env bash
set -euo pipefail

# --- Configuration (edit if needed) ---
N8N_DIR="/opt/n8n"
N8N_PORT="${N8N_PORT:-5678}"
N8N_IMAGE="${N8N_IMAGE:-n8nio/n8n:latest}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:16-alpine}"
TIMEZONE="${TIMEZONE:-Asia/Kolkata}"   # Bangalore default
ENABLE_UFW="${ENABLE_UFW:-false}"      # set to "true" to open port using UFW
CREATE_SWAP="${CREATE_SWAP:-false}"    # set to "true" to create a 2G swapfile if RAM < 2G
# --------------------------------------

log() { echo -e "\033[1;32m[+] $*\033[0m"; }
warn() { echo -e "\033[1;33m[!] $*\033[0m"; }
err() { echo -e "\033[1;31m[!] $*\033[0m"; }

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    err "Please run as root (e.g., sudo bash $0)"
    exit 1
  fi
}

detect_ubuntu() {
  if ! command -v lsb_release >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y lsb-release
  fi
  UBUNTU_CODENAME=$(lsb_release -cs || echo "jammy")
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    log "Docker already installed. Skipping installation."
    systemctl enable --now docker || true
    return
  fi
  log "Installing Docker Engine + Compose v2..."

  apt-get update -y
  apt-get install -y ca-certificates curl gnupg apt-transport-https software-properties-common

  install -m 0755 -d /etc/apt/keyrings
  if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
  fi

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list

  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  systemctl enable --now docker
  log "Docker installed and running."
}

add_user_to_docker_group() {
  local user_name="${SUDO_USER:-$USER}"
  if id -nG "$user_name" | grep -qw docker; then
    log "User '$user_name' is already in the docker group."
  else
    log "Adding user '$user_name' to docker group..."
    usermod -aG docker "$user_name"
    warn "You may need to log out and back in (or run 'newgrp docker') for group changes to take effect."
  fi
}

create_swap_if_needed() {
  if [ "$CREATE_SWAP" = "true" ]; then
    local mem_kb
    mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local mem_mb=$((mem_kb/1024))
    if [ "$mem_mb" -lt 2048 ] && ! swapon --show | grep -q "^"; then
      warn "Low RAM detected (${mem_mb} MB). Creating 2G swapfile..."
      fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
      chmod 600 /swapfile
      mkswap /swapfile
      swapon /swapfile
      if ! grep -q "/swapfile" /etc/fstab; then
        echo "/swapfile none swap sw 0 0" >> /etc/fstab
      fi
      log "Swapfile created and activated."
    fi
  fi
}

prepare_n8n_directory() {
  log "Preparing n8n directory at $N8N_DIR ..."
  mkdir -p "$N8N_DIR"
  mkdir -p "$N8N_DIR/data"
  mkdir -p "$N8N_DIR/postgres"

  # Create .env file
  if [ ! -f "$N8N_DIR/.env" ]; then
    log "Creating .env file..."
    # Generate encryption key
    ENC_KEY=$(openssl rand -hex 32)
    POSTGRES_PASSWORD=$(openssl rand -hex 16)

    cat > "$N8N_DIR/.env" <<EOF
# -----------------------
# n8n environment
# -----------------------
N8N_HOST=localhost
N8N_PORT=${N8N_PORT}
N8N_PROTOCOL=http
WEBHOOK_URL=http://localhost:${N8N_PORT}/
GENERIC_TIMEZONE=${TIMEZONE}
N8N_ENCRYPTION_KEY=${ENC_KEY}
# Important: set a secure cookie/domain if behind reverse proxy
N8N_METRICS=true

# -----------------------
# Database (PostgreSQL)
# -----------------------
DB_TYPE=postgresdb
DB_POSTGRESDB_HOST=postgres
DB_POSTGRESDB_PORT=5432
DB_POSTGRESDB_DATABASE=n8n
DB_POSTGRESDB_USER=n8n
DB_POSTGRESDB_PASSWORD=${POSTGRES_PASSWORD}

# Optional: enable basic auth (uncomment to use)
# N8N_BASIC_AUTH_ACTIVE=true
# N8N_BASIC_AUTH_USER=admin
# N8N_BASIC_AUTH_PASSWORD=change_me

# If behind reverse proxy, set these appropriately:
# N8N_HOST=n8n.example.com
# N8N_PROTOCOL=https
# WEBHOOK_URL=https://n8n.example.com/
EOF
  else
    warn ".env already exists. Not overwriting."
  fi

  # docker-compose.yml
  if [ ! -f "$N8N_DIR/docker-compose.yml" ]; then
    log "Creating docker-compose.yml..."
    cat > "$N8N_DIR/docker-compose.yml" <<'YAML'
services:
  n8n:
    image: ${N8N_IMAGE}
    restart: unless-stopped
    env_file:
      - .env
    ports:
      - "${N8N_PORT}:5678"
    depends_on:
      - postgres
    volumes:
      - ./data:/home/node/.n8n
    # Uncomment if behind a reverse proxy that sets correct headers
    # labels:
    #   - "traefik.enable=true"
    #   - "traefik.http.routers.n8n.rule=Host(`${N8N_HOST}`)"
    #   - "traefik.http.services.n8n.loadbalancer.server.port=5678"

  postgres:
    image: ${POSTGRES_IMAGE}
    restart: unless-stopped
    environment:
      POSTGRES_USER: n8n
      POSTGRES_PASSWORD: ${DB_POSTGRESDB_PASSWORD}
      POSTGRES_DB: n8n
    volumes:
      - ./postgres:/var/lib/postgresql/data

# Compose v2 automatically creates an isolated network for this project
YAML
  else
    warn "docker-compose.yml already exists. Not overwriting."
  fi
}

start_stack() {
  log "Starting n8n stack with Docker Compose..."
  pushd "$N8N_DIR" >/dev/null
  # Ensure the env substitutions work for Compose v2
  export N8N_IMAGE POSTGRES_IMAGE N8N_PORT
  # Pull latest images
  docker compose pull
  # Launch
  docker compose up -d
  popd >/dev/null
  log "n8n is starting. This may take ~30–60 seconds on first run."
}

configure_firewall() {
  if [ "$ENABLE_UFW" = "true" ]; then
    if command -v ufw >/dev/null 2>&1; then
      log "Configuring UFW to allow port ${N8N_PORT} ..."
      ufw allow "${N8N_PORT}/tcp" || warn "Could not configure UFW."
    else
      warn "UFW not installed. Skipping firewall configuration."
    fi
  fi
}

print_summary() {
  local host="localhost"
  local protocol="http"
  if [ -f "$N8N_DIR/.env" ]; then
    # shellcheck disable=SC2046
    export $(grep -E '^(N8N_HOST|N8N_PROTOCOL|N8N_PORT|WEBHOOK_URL)=' "$N8N_DIR/.env" | xargs)
    host="${N8N_HOST:-localhost}"
    protocol="${N8N_PROTOCOL:-http}"
  fi
  cat <<EOF

------------------------------------------------------------
✅ Installation complete

n8n URL:    ${protocol}://${host}:${N8N_PORT}/
Data dir:   ${N8N_DIR}/data
DB dir:     ${N8N_DIR}/postgres
Compose:    ${N8N_DIR}/docker-compose.yml

Common commands:
  cd ${N8N_DIR}
  docker compose ps
  docker compose logs -f n8n
  docker compose restart n8n
  docker compose pull && docker compose up -d

Tips:
- If you just added your user to the docker group, run: newgrp docker
- To run behind a reverse proxy & HTTPS, set N8N_HOST/N8N_PROTOCOL/WEBHOOK_URL in .env accordingly.
- To enable basic auth: uncomment N8N_BASIC_AUTH_* in .env.

Enjoy automating! 🚀
------------------------------------------------------------
EOF
}

main() {
  require_root
  detect_ubuntu
  install_docker
  add_user_to_docker_group
  create_swap_if_needed
  prepare_n8n_directory
  start_stack
  configure_firewall
  print_summary
}

main
