#!/bin/bash

# Colors for output
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Tailing GitHub Runner Logs${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Press Ctrl+C to exit"
echo ""

# Follow logs for all runner containers
docker compose logs -f github-runner
