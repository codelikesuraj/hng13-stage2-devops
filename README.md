# Blue/Green Deployment with Nginx Auto-Failover & Monitoring

## Documentation

- **[QUICKSTART.md](QUICKSTART.md)** - Quick start guide with common commands
- **[ARCHITECTURE.md](ARCHITECTURE.md)** - Detailed architecture and design documentation
- **[runbook.md](runbook.md)** - Operations runbook for alert response
- **[README.md](README.md)** (this file) - Complete project documentation

## Overview

This project implements a Blue/Green deployment strategy for a Node.js application using Nginx as a reverse proxy with automatic failover capabilities and real-time monitoring. When the active pool (Blue) fails, Nginx automatically routes traffic to the backup pool (Green) with zero downtime and no failed client requests. The system includes a Python-based log watcher that monitors Nginx logs and sends alerts to Slack when failovers occur or error rates exceed thresholds.

## Architecture

```
Client -> Nginx (localhost:8080) -> [Blue (8081) | Green (8082)]
                |
                | logs
               \|/
         Alert Watcher -> Slack Webhook
```

- **Nginx**: Reverse proxy with upstream health checking, automatic failover, and detailed JSON logging
- **Blue Service**: Primary application instance (active by default)
- **Green Service**: Backup application instance (activated on Blue failure)
- **Alert Watcher**: Python service that monitors Nginx logs and sends alerts to Slack

## Features

### Stage 2: Deployment & Failover
- **Zero-downtime failover**: Automatic switch from Blue to Green on failure
- **Request retry logic**: Failed requests are retried on backup pool within the same client request
- **Health monitoring**: Continuous health checks on both pools
- **Header preservation**: Application headers (X-App-Pool, X-Release-Id) are forwarded to clients
- **Quick failure detection**: Tight timeouts (2s) for fast failover
- **Parameterized configuration**: All settings controlled via .env file

### Monitoring & Alerts
- **Structured logging**: Nginx logs capture pool, release ID, upstream status, latency, and upstream address
- **Real-time monitoring**: Python log watcher tails Nginx logs in real time
- **Failover detection**: Automatically detects and alerts when traffic switches between pools
- **Error rate monitoring**: Tracks 5xx errors over a sliding window and alerts on threshold breaches
- **Slack integration**: Sends actionable alerts to Slack with detailed context
- **Alert cooldowns**: Prevents alert spam with configurable cooldown periods
- **Maintenance mode**: Suppresses alerts during planned toggles and testing

## Prerequisites

- Docker (version 20.10+)
- Docker Compose (version 2.0+)
- Slack workspace and webhook URL (for alerts)

## Configuration

All deployment and monitoring settings are configured in the `.env` file:

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

# Slack webhook for alerts
SLACK_WEBHOOK_URL=https://hooks.slack.com/services/YOUR/WEBHOOK/URL

# Alert configuration
ERROR_RATE_THRESHOLD=2          # Error rate threshold percentage
WINDOW_SIZE=200                 # Sliding window size for error calculation
ALERT_COOLDOWN_SEC=300          # Alert cooldown in seconds
MAINTENANCE_MODE=false          # Suppress alerts during maintenance
```

## Quick Start

For complete setup instructions, see [QUICKSTART.md](QUICKSTART.md).

### 1. Configure Environment

```bash
cp .env.example .env
# Edit .env and set your SLACK_WEBHOOK_URL
```

### 2. Start the Services

```bash
docker compose up -d
```

This will start:
- Blue service on port 8081
- Green service on port 8082
- Nginx proxy on port 8080
- Alert watcher (monitoring Nginx logs)

### 3. Verify Deployment

Check that all services are running:

```bash
docker compose ps
```

You should see all four services (app_blue, app_green, nginx_proxy, alert_watcher) running.

You'll also receive a startup alert in Slack confirming monitoring is active.

### 4. Run Comprehensive Tests

Run the complete test suite to verify all features:

```bash
chmod +x test.sh
./test.sh
```

This will test:
- Baseline state (Blue active)
- Failover to Green (zero failures)
- Recovery back to Blue
- High error rate detection
- System recovery

You'll receive 5 Slack alerts confirming all monitoring features work correctly.

For more details, see [QUICKSTART.md](QUICKSTART.md).

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

### Log Format

Nginx uses a custom JSON log format that captures:

```json
{
  "timestamp": "2025-10-30T12:34:56+00:00",
  "remote_addr": "172.18.0.5",
  "request": "GET /version HTTP/1.1",
  "status": 200,
  "body_bytes_sent": 45,
  "request_time": 0.002,
  "upstream_addr": "172.18.0.2:3000",
  "upstream_status": "200",
  "upstream_response_time": "0.001",
  "pool": "blue",
  "release": "v1-0-0-blue"
}
```

## Monitoring & Alerts

### Setup Slack Webhook

1. Create a Slack incoming webhook:
   - Go to https://api.slack.com/apps
   - Create a new app or select existing
   - Navigate to "Incoming Webhooks"
   - Create a new webhook URL

2. Configure the webhook in `.env`:
   ```bash
   SLACK_WEBHOOK_URL=https://hooks.slack.com/services/YOUR/WEBHOOK/URL
   ```

3. Restart services:
   ```bash
   docker compose down
   docker compose up -d
   ```

### Alert Types

The alert watcher monitors Nginx logs and sends three types of alerts:

#### 1. Failover Detected (⚠️)
Triggered when traffic switches from one pool to another.

**Example:**
```
⚠️ Failover Detected
Pool switch detected - traffic is now being served by the backup pool.

• Previous Pool: blue
• New Pool: green
• Total Requests: 1234
• Failover Count: 1

Action Required: Check the health of the blue pool.
```

#### 2. High Error Rate Detected (🚨)
Triggered when 5xx error rate exceeds threshold over the sliding window.

**Example:**
```
🚨 High Error Rate Detected
Upstream error rate has exceeded the threshold.

• Current Error Rate: 5.50%
• Threshold: 2%
• Errors in Window: 11/200
• Current Pool: blue
• Total Requests: 2500

Action Required: Investigate upstream logs and consider toggling pools.
```

#### 3. Pool Recovery Detected (🟢)
Triggered when traffic returns to the primary pool after failover.

**Example:**
```
🟢 Pool Recovery Detected
Traffic has recovered back to the primary pool.

• Previous Pool: green
• Current Pool: blue
• Total Requests: 3456
• Failover Count: 2
```

### Alert Configuration

Configure alert behavior in `.env`:

```bash
# Error rate threshold percentage (default: 2%)
ERROR_RATE_THRESHOLD=2

# Sliding window size for error calculation (default: 200 requests)
WINDOW_SIZE=200

# Alert cooldown in seconds (default: 300s / 5min)
ALERT_COOLDOWN_SEC=300

# Suppress alerts during maintenance (default: false)
MAINTENANCE_MODE=false
```

### View Logs

```bash
# Watch alert watcher logs
docker compose logs -f alert_watcher

# View Nginx access logs (JSON format)
docker compose exec nginx tail -f /var/log/nginx/access.log

# Pretty-print logs with jq
docker compose exec nginx tail -f /var/log/nginx/access.log | jq .
```

### Testing Alerts

```bash
# 1. Trigger chaos on blue pool
curl -X POST http://localhost:8081/chaos/start?mode=error

# 2. Generate traffic to trigger failover
for i in {1..10}; do
  curl -s http://localhost:8080/version
  sleep 0.5
done

# 3. Check alert watcher logs for Slack notification
docker compose logs alert_watcher

# 4. Stop chaos
curl -X POST http://localhost:8081/chaos/stop
```

### Maintenance Mode

Suppress alerts during planned maintenance or testing:

```bash
# Enable maintenance mode
echo "MAINTENANCE_MODE=true" >> .env
docker compose restart alert_watcher

# Disable maintenance mode
# Edit .env and set MAINTENANCE_MODE=false
docker compose restart alert_watcher
```

For detailed operator instructions, see [runbook.md](runbook.md).

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

### Stage 2: Deployment & Failover
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

### Monitoring & Alerts
- ✅ Custom Nginx log format capturing pool, release, upstream status, and latency
- ✅ Python log-watcher service tailing logs in real time
- ✅ Failover detection and alerting (Blue->Green, Green->Blue)
- ✅ Error rate monitoring over sliding window
- ✅ Slack webhook integration for alerts
- ✅ Alert cooldown to prevent spam
- ✅ Maintenance mode for suppressing alerts during planned activities
- ✅ Shared log volume between Nginx and watcher
- ✅ Environment-based configuration (no secrets in code)
- ✅ Operator runbook with response procedures

## Project Structure

```
blue-green-deployment/
├── .env                        # Environment configuration (not in repo)
├── .env.example                # Environment template with all variables
├── .github/
│   └── workflows/
│       └── test-deployment.yml # CI/CD workflow
├── .gitignore                  # Git ignore rules
├── ARCHITECTURE.md             # Architecture documentation
├── QUICKSTART.md               # Quick start guide
├── README.md                   # This file (complete documentation)
├── docker-compose.yml          # Service orchestration (4 services)
├── entrypoint.sh               # Nginx startup script with envsubst
├── nginx.conf.template         # Nginx config with custom log format
├── requirements.txt            # Python dependencies for watcher (requests)
├── runbook.md                  # Operations runbook for alert response
├── test.sh                     # Comprehensive test suite (all alerts)
└── watcher.py                  # Python log watcher service (no Dockerfile)
```

**Key Files:**
- **watcher.py**: Real-time log monitoring with Slack integration
- **test.sh**: Complete test suite covering failover, recovery, and error rate alerts
- **runbook.md**: Operator guide for responding to Slack alerts
- **nginx.conf.template**: Nginx configuration with custom JSON logging
- **docker-compose.yml**: Orchestrates 4 services (blue, green, nginx, alert_watcher)

## License

MIT License
