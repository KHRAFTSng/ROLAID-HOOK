#!/bin/bash
# Script to run offchain components via Docker Compose

set -e

echo "Building and starting ROLAID offchain services..."

# Check if .env exists
if [ ! -f .env ]; then
  echo "Warning: .env file not found. Services may fail without proper configuration."
fi

# Build and start services
docker-compose up --build -d

echo ""
echo "Services started:"
echo "  - Auctioneer: http://localhost:8001"
echo "  - Insurance: http://localhost:8002"
echo ""
echo "Check logs with: docker-compose logs -f"
echo "Stop services with: docker-compose down"

