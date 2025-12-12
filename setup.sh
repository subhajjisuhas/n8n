
#!/bin/bash
set -euo pipefail

# Update system
sudo apt update
sudo apt -y upgrade

# Install Docker
echo "Installing Docker..."
sudo apt -y install docker.io
sudo systemctl enable docker
sudo systemctl start docker

# Install Docker Compose
echo "Installing Docker Compose..."
sudo apt -y install docker-compose

# Create n8n directory
mkdir -p "$HOME/n8n"
cd "$HOME/n8n"

# Create docker-compose.yml (quoted heredoc to avoid interpolation)
cat <<'EOF' > docker-compose.yml
version: "3"
services:
  n8n:
    image: n8nio/n8n
    restart: always
    ports:
      - "5678:5678"
    environment:
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=admin
      - N8N_BASIC_AUTH_PASSWORD=admin123
    volumes:
      - ./n8n_data:/home/node/.n8n
EOF

# Start n8n
echo "Starting n8n..."
docker-compose up -d

IP_ADDR=$(hostname -I | awk '{print $1}')
echo "✅ n8n is running at: http://$IP_ADDR:5678"
echo "🔐 Basic auth: admin / admin123 (change in docker-compose.yml)"
``


