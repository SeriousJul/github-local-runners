#!/bin/bash

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}Stopping GitHub Runner Infrastructure${NC}"
echo -e "${YELLOW}========================================${NC}"

# Stop all services
echo -e "\n${YELLOW}Stopping all services...${NC}"
docker compose down

echo -e "\n${GREEN}✓ All services stopped${NC}"
echo ""
echo -e "${YELLOW}Note:${NC} Data volumes are preserved (postgres-data, minio-data)"
echo "To completely remove all data, run: docker compose down -v"
echo ""
