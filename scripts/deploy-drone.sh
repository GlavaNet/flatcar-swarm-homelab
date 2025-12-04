#!/bin/bash
# Deploy Drone CI on Docker Swarm

set -e

DRONE_RPC_SECRET=$(openssl rand -hex 16)
GITHUB_CLIENT_ID="${GITHUB_CLIENT_ID:-}"
GITHUB_CLIENT_SECRET="${GITHUB_CLIENT_SECRET:-}"

if [ -z "$GITHUB_CLIENT_ID" ] || [ -z "$GITHUB_CLIENT_SECRET" ]; then
    echo "Setup GitHub OAuth App first:"
    echo "1. Go to: https://github.com/settings/developers"
    echo "2. New OAuth App"
    echo "3. Homepage URL: http://192.168.99.101:8080"
    echo "4. Callback URL: http://192.168.99.101:8080/login"
    echo ""
    echo "Then run:"
    echo "  export GITHUB_CLIENT_ID='your_client_id'"
    echo "  export GITHUB_CLIENT_SECRET='your_client_secret'"
    echo "  ./deploy-drone.sh"
    exit 1
fi

echo "Creating Drone CI stack..."

cat > drone-stack.yml << EOF
version: '3.8'

services:
  drone-server:
    image: drone/drone:2
    ports:
      - "8080:80"
    volumes:
      - drone-data:/data
    environment:
      DRONE_GITHUB_CLIENT_ID: ${GITHUB_CLIENT_ID}
      DRONE_GITHUB_CLIENT_SECRET: ${GITHUB_CLIENT_SECRET}
      DRONE_RPC_SECRET: ${DRONE_RPC_SECRET}
      DRONE_SERVER_HOST: 192.168.99.101:8080
      DRONE_SERVER_PROTO: http
      DRONE_USER_CREATE: username:GlavaNet,admin:true
    deploy:
      placement:
        constraints:
          - node.role == manager
      restart_policy:
        condition: on-failure

  drone-runner:
    image: drone/drone-runner-docker:1
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      DRONE_RPC_PROTO: http
      DRONE_RPC_HOST: drone-server
      DRONE_RPC_SECRET: ${DRONE_RPC_SECRET}
      DRONE_RUNNER_CAPACITY: 2
      DRONE_RUNNER_NAME: swarm-runner
    depends_on:
      - drone-server
    deploy:
      mode: global
      restart_policy:
        condition: on-failure

volumes:
  drone-data:
    driver: local

networks:
  default:
    driver: overlay
EOF

echo ""
echo "Replace YOUR_GITHUB_USERNAME in drone-stack.yml with your GitHub username"
read -p "Press Enter when ready..."

docker stack deploy -c drone-stack.yml drone

echo ""
echo "✓ Drone CI deployed"
echo ""
echo "Access Drone at: http://192.168.99.101:8080"
echo "RPC Secret: $DRONE_RPC_SECRET"
echo ""
echo "Activate your repo in Drone UI, then add .drone.yml to your repo:"
echo ""
cat << 'DRONEYML'
---
kind: pipeline
type: docker
name: deploy

steps:
  - name: deploy-stack
    image: docker:latest
    volumes:
      - name: docker-sock
        path: /var/run/docker.sock
    commands:
      - docker stack deploy -c docker-compose.yml myapp
    when:
      branch:
        - main
      event:
        - push

volumes:
  - name: docker-sock
    host:
      path: /var/run/docker.sock
DRONEYML
