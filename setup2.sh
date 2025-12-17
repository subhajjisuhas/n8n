
#!/usr/bin/env bash
set -euo pipefail

# --- Configuration (override via environment variables) ---
N8N_DIR="${N8N_DIR:-/opt/n8n}"
N8N_PORT="${N8N_PORT:-5678}"
N8N_IMAGE="${N8N_IMAGE:-n8nio/n8n:latest}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:16-alpine}"
TIMEZONE="${TIMEZONE:-Asia/Kolkata}"
START_AFTER_CREATE="${START_AFTER_CREATE:-false}"   # set to "true" to run `docker compose up -d`
# ---------------------------------------------------------

log() { echo -e "\033[1;32m[+] $*\033[0m"; }
warn() { echo -e "\033[1;33m[!] $*\033[0m"; }
err() { echo -e "\033[1;31m[!] $*\033[0m"; }

check_deps() {
  command -v docker >/dev/null || err "Docker not found. Install Docker first." 
  command -v openssl >/dev/null || err "OpenSSL not found (needed to generate secrets)."
  # Compose v2 is part of `docker`, so no separate check for `docker-compose`.
}

prepare_dirs() {
  log "Creating directories: ${N8N_DIR}, data, postgres ..."
  sudo mkdir -p "${N8N_DIR}/data" "${N8N_DIR}/postgres"
  sudo chown -R 1000:1000 "${N8N_DIR}/data"      # n8n uses UID 1000
  sudo chown -R 999:999 "${N8N_DIR}/postgres"    # Postgres commonly uses UID 999
}

create_env() {
  if [ -f "${N8N_DIR}/.env" ]; then
    warn ".env already exists at ${N8N_DIR}/.env. Will not overwrite."
    return
  fi

  log "Generating secrets and creating .env ..."
  local enc_key db_pass
  enc_key="$(openssl rand -hex 32)"
  db_pass="$(openssl rand -hex 16)"

  cat > "${N8N_DIR}/.env" <<EOF
# -----------------------
# n8n environment
# -----------------------
N8N_HOST=localhost
N8N_PORT=${N8N_PORT}
N8N_PROTOCOL=http
WEBHOOK_URL=http://localhost:${N8N_PORT}/
GENERIC_TIMEZONE=${TIMEZONE}
N8N_ENCRYPTION_KEY=${enc_key}
N8N_METRICS=true

# -----------------------
# Database (PostgreSQL)
# -----------------------
DB_TYPE=postgresdb
DB_POSTGRESDB_HOST=postgres
DB_POSTGRESDB_PORT=5432
DB_POSTGRESDB_DATABASE=n8n
DB_POSTGRESDB_USER=n8n
DB_POSTGRESDB_PASSWORD=${db_pass}
EOF
}

create_compose_yml() {
  local compose_path="${N8N_DIR}/docker-compose.yml"
  if [ -f "${compose_path}" ]; then
    warn "docker-compose.yml already exists at ${compose_path}. Will not overwrite."
    return
  fi

  log "Creating docker-compose.yml ..."
  cat > "${compose_path}" <<'YAML'
services:
  postgres:
    image: ${POSTGRES_IMAGE}
    restart: unless-stopped
    environment:
      POSTGRES_USER: n8n
      POSTGRES_PASSWORD: ${DB_POSTGRESDB_PASSWORD}
      POSTGRES_DB: n8n
    volumes:
      - ./postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U n8n -d n8n"]
      interval: 5s
      timeout: 5s
      retries: 20

  n8n:
    image: ${N8N_IMAGE}
    restart: unless-stopped
    env_file:
      - .env
    ports:
      - "${N8N_PORT}:5678"
    depends_on:
      postgres:
        condition: service_healthy
    volumes:
      - ./data:/home/node/.n8n
YAML
}

start_stack() {
  if [ "${START_AFTER_CREATE}" = "true" ]; then
    log "Starting n8n stack with Docker Compose ..."
    pushd "${N8N_DIR}" >/dev/null
    export N8N_IMAGE POSTGRES_IMAGE N8N_PORT
    docker compose pull
    docker compose up -d
    popd >/dev/null
    log "Stack started. It may take ~30–60s on first run."
  else
    warn "START_AFTER_CREATE=false. Skipping auto-start."
  fi
}

print_summary() {
  cat <<EOF

------------------------------------------------------------
✅ Files created

Compose file: ${N8N_DIR}/docker-compose.yml
Env file:     ${N8N_DIR}/.env
Data dir:     ${N8N_DIR}/data  (owned by UID 1000)
DB dir:       ${N8N_DIR}/postgres (owned by UID 999)

To start the stack manually:
  cd ${N8N_DIR}
  docker compose up -d
  docker compose logs -f n8n

n8n will be available at:
  http://localhost:${N8N_PORT}/

Tips:
- If you edit .env, re-run: cd ${N8N_DIR} && docker compose up -d
- Keep N8N_ENCRYPTION_KEY stable once data exists.
- Backup ${N8N_DIR}/data and ${N8N_DIR}/postgres regularly.
------------------------------------------------------------
EOF
}

main() {
  check_deps
  prepare_dirs
  create_env
  create_compose_yml
  start_stack
  print_summary
}

main "$@"
``

