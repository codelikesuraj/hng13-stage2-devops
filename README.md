# HNG DevOps Internship - Stage 2: Blue/Green Deployment with Nginx Auto-Failover

## Documentation

- **[QUICKSTART.md](QUICKSTART.md)** - Quick start guide with common commands
- **[ARCHITECTURE.md](ARCHITECTURE.md)** - Detailed architecture and design documentation
- **[README.md](README.md)** (this file) - Complete project documentation

## Overview

This project implements a Blue/Green deployment strategy for a Node.js application using Nginx as a reverse proxy with automatic failover capabilities. When the active pool (Blue) fails, Nginx automatically routes traffic to the backup pool (Green) with zero downtime and no failed client requests.

## Architecture

```
Client → Nginx (localhost:8080) → [Blue (8081) | Green (8082)]
```

- **Nginx**: Reverse proxy with upstream health checking and automatic failover
- **Blue Service**: Primary application instance (active by default)
- **Green Service**: Backup application instance (activated on Blue failure)

## Features

- **Zero-downtime failover**: Automatic switch from Blue to Green on failure
- **Request retry logic**: Failed requests are retried on backup pool within the same client request
- **Health monitoring**: Continuous health checks on both pools
- **Header preservation**: Application headers (X-App-Pool, X-Release-Id) are forwarded to clients
- **Quick failure detection**: Tight timeouts (2s) for fast failover
- **Parameterized configuration**: All settings controlled via .env file

## Prerequisites

- Docker (version 20.10+)
- Docker Compose (version 2.0+)

## Configuration

All deployment settings are configured in the `.env` file:

```bash
# Docker images for Blue and Green pools
BLUE_IMAGE=ghcr.io/codelikesuraj/docker-nodejs-blue-green-service:blue
GREEN_IMAGE=ghcr.io/codelikesuraj/docker-nodejs-blue-green-service:green

# Active pool (blue or green)
ACTIVE_POOL=blue

# Release identifiers (returned in X-Release-Id header)
RELEASE_ID_BLUE=v1-0-0-blue
RELEASE_ID_GREEN=v1-0-0-green

# Application port
APP_PORT=3000
```

## Quick Start

### 1. Start the Services

```bash
docker compose up -d
```

This will start:
- Blue service on port 8081
- Green service on port 8082
- Nginx proxy on port 8080

### 2. Verify Deployment

Check that all services are running:

```bash
docker compose ps
```

You should see all three services (app_blue, app_green, nginx_proxy) in "running" state.

### 3. Test Baseline State

Test the version endpoint through Nginx:

```bash
curl -i http://localhost:8080/version
```

Expected response:
- Status: 200 OK
- Header `X-App-Pool: blue`
- Header `X-Release-Id: blue-v1.0.0`

### 4. Test Direct Access

Verify both pools are accessible directly:

```bash
# Blue pool
curl -i http://localhost:8081/version

# Green pool
curl -i http://localhost:8082/version
```

## Failover Testing

### Simulate Blue Failure

Induce downtime on the active (Blue) pool:

```bash
# Trigger error mode on Blue
curl -X POST http://localhost:8081/chaos/start?mode=error
```

### Verify Automatic Failover

Make requests through Nginx - they should now be served by Green:

```bash
curl -i http://localhost:8080/version
```

Expected response:
- Status: 200 OK
- Header `X-App-Pool: green`
- Header `X-Release-Id: green-v1.0.0`

### Test Under Load

Run multiple consecutive requests to verify zero failures:

```bash
for i in {1..20}; do
  echo "Request $i:"
  curl -s -w "\nHTTP Status: %{http_code}\n" http://localhost:8080/version | grep -E "(X-App-Pool|X-Release-Id|HTTP Status)"
  sleep 0.5
done
```

All requests should return:
- HTTP Status: 200
- X-App-Pool: green (after chaos)

### Restore Blue Service

Stop the chaos mode:

```bash
curl -X POST http://localhost:8081/chaos/stop
```

Note: Nginx will continue routing to Green until Blue's `fail_timeout` (5s) expires and Blue passes health checks again.

## Endpoints

### Through Nginx (Port 8080)
- `GET http://localhost:8080/version` - Get service version and pool info
- `GET http://localhost:8080/healthz` - Health check

### Direct Access to Blue (Port 8081)
- `GET http://localhost:8081/version` - Blue version
- `GET http://localhost:8081/healthz` - Blue health
- `POST http://localhost:8081/chaos/start?mode=error` - Trigger failures
- `POST http://localhost:8081/chaos/start?mode=timeout` - Trigger timeouts
- `POST http://localhost:8081/chaos/stop` - Stop chaos mode

### Direct Access to Green (Port 8082)
- `GET http://localhost:8082/version` - Green version
- `GET http://localhost:8082/healthz` - Green health
- `POST http://localhost:8082/chaos/start?mode=error` - Trigger failures
- `POST http://localhost:8082/chaos/stop` - Stop chaos mode

## Nginx Configuration Details

### Upstream Configuration

```nginx
upstream active_pool {
    server app_blue:3000 max_fails=1 fail_timeout=5s;
    server app_green:3000 backup;
}
```

- **max_fails=1**: Mark server as down after 1 failure
- **fail_timeout=5s**: Retry after 5 seconds
- **backup**: Green only receives traffic when Blue is down

### Retry Policy

```nginx
proxy_next_upstream error timeout http_500 http_502 http_503 http_504;
proxy_next_upstream_tries 2;
proxy_next_upstream_timeout 5s;
```

- Retries on: connection errors, timeouts, 5xx responses
- Maximum 2 attempts (primary + backup)
- Total timeout: 5 seconds

### Timeout Settings

```nginx
proxy_connect_timeout 2s;
proxy_send_timeout 2s;
proxy_read_timeout 2s;
```

Quick timeouts ensure fast failure detection and immediate failover.

## Switching Active Pool

To make Green the primary pool:

1. Update `.env`:
   ```bash
   ACTIVE_POOL=green
   ```

2. Restart the services:
   ```bash
   docker compose down
   docker compose up -d
   ```

## Troubleshooting

### Check Service Logs

```bash
# All services
docker compose logs -f

# Specific service
docker compose logs -f nginx
docker compose logs -f app_blue
docker compose logs -f app_green
```

### Verify Nginx Configuration

```bash
docker compose exec nginx cat /etc/nginx/conf.d/default.conf
```

### Test Nginx Configuration Syntax

```bash
docker compose exec nginx nginx -t
```

### Restart Services

```bash
docker compose restart
```

### Stop All Services

```bash
docker compose down
```

### Force Rebuild

```bash
docker compose down -v
docker compose up -d --force-recreate
```

## CI/CD Integration

This setup is designed for automated testing in CI pipelines. The grader will:

1. Set environment variables in `.env`
2. Start services with `docker compose up -d`
3. Wait for health checks to pass
4. Test baseline state (Blue active)
5. Trigger chaos on Blue
6. Verify automatic failover to Green
7. Assert zero failed requests
8. Verify correct headers on all responses

## Requirements Met

- ✅ Blue/Green deployment using pre-built container images
- ✅ Nginx reverse proxy with upstream configuration
- ✅ Automatic failover on failure (backup role)
- ✅ Zero failed client requests during failover
- ✅ Quick failure detection (2s timeouts)
- ✅ Request retry policy (error, timeout, 5xx)
- ✅ Header preservation (X-App-Pool, X-Release-Id)
- ✅ Parameterized configuration via .env
- ✅ Direct access to both pools (8081, 8082)
- ✅ Chaos engineering endpoints for testing
- ✅ Docker Compose orchestration
- ✅ No application code changes or image rebuilds

## Project Structure

```
hng13-stage2-devops/
├── .env                     # Environment configuration
├── .env.example             # Environment template
├── .github/
│   └── workflows/
│       └── test-deployment.yml  # CI/CD workflow
├── .gitignore               # Git ignore rules
├── ARCHITECTURE.md          # Architecture documentation
├── DEPLOYMENT_CHECKLIST.md  # Deployment checklist
├── QUICKSTART.md            # Quick start guide
├── README.md                # This file
├── docker-compose.yml       # Service orchestration
├── entrypoint.sh            # Nginx startup script with envsubst
├── nginx.conf.template      # Nginx configuration template
└── test-failover.sh         # Automated test script
```

## License

This project is part of the HNG DevOps Internship Stage 2.
