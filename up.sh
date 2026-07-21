#!/bin/bash

set -e  # Exit on error

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Starting GitHub Runner Infrastructure${NC}"
echo -e "${GREEN}========================================${NC}"

# Check if .env file exists
if [[ ! -f .env ]]; then
    echo -e "${RED}ERROR: .env file not found!${NC}"
    echo -e "${YELLOW}Please create one from the template:${NC}"
    echo "  cp .env.example .env"
    echo "  # Edit .env and fill in your values"
    exit 1
fi

# Source environment variables
source .env

# Check required variables
if [[ -z "${ACCESS_TOKEN}" ]] || [[ "${ACCESS_TOKEN}" == "ghp_your_token_here" ]]; then
    echo -e "${RED}ERROR: ACCESS_TOKEN not configured in .env${NC}"
    echo "Please set your GitHub Personal Access Token in .env"
    exit 1
fi

if [[ -z "${DOCKER_GID}" ]]; then
    echo -e "${YELLOW}WARNING: DOCKER_GID not set in .env${NC}"
    echo "Get your Docker GID with: getent group docker | cut -d: -f3"
fi

# Set default replica count if not specified
RUNNER_REPLICAS=${RUNNER_REPLICAS:-1}

echo -e "\n${GREEN}Configuration:${NC}"
echo "  Runner replicas: ${RUNNER_REPLICAS}"
echo "  Runner name prefix: ${RUNNER_NAME_PREFIX:-docker-runner}"
echo ""

# Step 1: Start database and storage services first
echo -e "${GREEN}Starting database and storage services...${NC}"
docker compose up postgres minio -d

echo -e "\n${GREEN}Waiting for PostgreSQL and MinIO to be healthy...${NC}"
sleep 3

# Step 2: Create nx-cache bucket if it doesn't exist
echo -e "${GREEN}Ensuring nx-cache bucket exists...${NC}"
docker compose exec -T minio mc alias set local http://localhost:9000 "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}" >/dev/null 2>&1
if docker compose exec -T minio mc ls local/nx-cache &>/dev/null; then
    echo -e "${YELLOW}Bucket 'nx-cache' already exists${NC}"
else
    echo -e "${GREEN}Creating bucket 'nx-cache'...${NC}"
    docker compose exec -T minio mc mb local/nx-cache
    echo -e "${GREEN}Bucket created successfully!${NC}"
fi

# Step 2 bis: Create gh-actions-cache bucket if it doesn't exist
echo -e "${GREEN}Ensuring gh-actions-cache bucket exists...${NC}"
docker compose exec -T minio mc alias set local http://localhost:9000 "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}" >/dev/null 2>&1
if docker compose exec -T minio mc ls local/gh-actions-cache &>/dev/null; then
    echo -e "${YELLOW}Bucket 'gh-actions-cache' already exists${NC}"
else
    echo -e "${GREEN}Creating bucket 'gh-actions-cache'...${NC}"
    docker compose exec -T minio mc mb local/gh-actions-cache
    echo -e "${GREEN}Bucket created successfully!${NC}"
fi

# Step 3: Build and start all services with scaling
echo -e "\n${GREEN}Building and starting all services...${NC}"
docker compose up --build --scale github-runner=${RUNNER_REPLICAS} -d

echo -e "\n${GREEN}Waiting for all services to be healthy...${NC}"
sleep 5

echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}✓ All services started successfully!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${GREEN}Running services:${NC}"
docker compose ps
echo ""
echo -e "${GREEN}Access points:${NC}"
echo "  - MinIO Console: http://localhost:9001"
echo "    Username: ${MINIO_ROOT_USER}"
echo "    Password: ${MINIO_ROOT_PASSWORD}"
echo ""
echo -e "${YELLOW}Useful commands:${NC}"
echo "  - View logs: ./logs.sh"
echo "  - Stop services: ./down.sh"
echo "  - Check status: docker compose ps"
echo ""
