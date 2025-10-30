# Quick Start Guide

## Prerequisites
- Docker (version 20.10+)
- Docker Compose (version 2.0+)
- Slack workspace and webhook URL (for alerts)

## 1. Clone and Setup

```bash
git clone https://github.com/codelikesuraj/hng13-stage2-devops.git
cd hng13-stage2-devops
```

## 2. Configure Environment

Copy the example environment file and configure:

```bash
cp .env.example .env
```

Edit `.env` and set your Slack webhook URL:

```bash
SLACK_WEBHOOK_URL=https://hooks.slack.com/services/YOUR/WEBHOOK/URL
```

Default configuration:
- Active pool: **blue**
- Blue image: `ghcr.io/codelikesuraj/docker-nodejs-blue-green-service:blue`
- Green image: `ghcr.io/codelikesuraj/docker-nodejs-blue-green-service:green`
- Ports: 8080 (Nginx), 8081 (Blue), 8082 (Green)
- Error rate threshold: **2%**
- Alert cooldown: **300 seconds**

## 3. Start Services

```bash
docker compose up -d
```

Wait for services to be healthy:

```bash
docker compose ps
```

Expected output:
```
NAME            IMAGE                                                         STATUS
app_blue        ghcr.io/codelikesuraj/docker-nodejs-blue-green-service:blue   Up (healthy)
app_green       ghcr.io/codelikesuraj/docker-nodejs-blue-green-service:green  Up (healthy)
nginx_proxy     nginx:alpine                                                  Up (healthy)
alert_watcher   python:3.11-slim                                              Up
```

You should also receive a startup alert in Slack confirming the alert watcher is running.

## 4. Test Baseline

```bash
curl -i http://localhost:8080/version
```

Expected response:
```
HTTP/1.1 200 OK
X-App-Pool: blue
X-Release-Id: blue-v1.0.0
...
```

## 5. Test Failover

### Induce failure on Blue:

```bash
curl -X POST http://localhost:8081/chaos/start?mode=error
```

### Verify automatic failover:

```bash
curl -i http://localhost:8080/version
```

Expected response:
```
HTTP/1.1 200 OK
X-App-Pool: green
X-Release-Id: green-v1.0.0
...
```

### Stop chaos:

```bash
curl -X POST http://localhost:8081/chaos/stop
```

## 6. Run Comprehensive Tests

Run the full test suite to verify all monitoring features:

```bash
chmod +x test.sh
./test.sh
```

This script will:
1. **Test 1: Baseline** - Verify Blue pool is active
2. **Test 2: Failover** - Blue fails → Green takes over (zero failures)
3. **Intermediate: Recovery** - Blue recovers → Traffic returns to Blue
4. **Test 3: High Error Rate** - Both pools fail → Error rate alert
5. **Test 4: System Recovery** - Both pools recover → Recovery alert
6. **Cleanup** - Clear logs and reset watcher state

**Expected Slack Alerts:**
1. `:information_source:` Log Watcher Started
2. `:warning:` Failover Detected (blue → green)
3. `:white_check_mark:` Pool Recovery Detected (green → blue)
4. `:rotating_light:` High Error Rate Detected
5. `:white_check_mark:` Pool Recovery Detected (system recovered)

## 7. Monitor Alerts

Check your Slack channel for real-time alerts:
- **Startup Alert** - Confirms monitoring is active
- **Failover Alert** - Pool switch detected
- **High Error Rate Alert** - Error threshold exceeded
- **Recovery Alert** - System back to normal

View alert watcher logs:

```bash
docker compose logs -f alert_watcher
```

## 8. View Logs

```bash
# All services
docker compose logs -f

# Specific service
docker compose logs -f nginx
docker compose logs -f app_blue
docker compose logs -f app_green
```

## 9. Stop Services

```bash
docker compose down
```

## Troubleshooting

### Alerts not appearing in Slack?

1. Verify Slack webhook URL is correct:
```bash
docker compose exec alert_watcher env | grep SLACK_WEBHOOK_URL
```

2. Test webhook manually:
```bash
curl -X POST -H 'Content-type: application/json' \
  --data '{"text":"Test alert from Blue/Green deployment"}' \
  YOUR_SLACK_WEBHOOK_URL
```

3. Check alert watcher logs:
```bash
docker compose logs alert_watcher | grep ERROR
```

4. Verify maintenance mode is disabled:
```bash
docker compose exec alert_watcher env | grep MAINTENANCE_MODE
```

### Too many alerts?

Adjust alert thresholds in `.env`:
```bash
# Increase error rate threshold (default: 2%)
ERROR_RATE_THRESHOLD=5

# Increase cooldown period (default: 300s)
ALERT_COOLDOWN_SEC=600

# Restart watcher to apply changes
docker compose restart alert_watcher
```

### Alert watcher not detecting events?

1. Verify logs are being generated:
```bash
docker compose exec nginx tail -10 /var/log/nginx/access.log | jq .
```

2. Check watcher is processing logs:
```bash
docker compose logs --tail=50 alert_watcher
```

3. Restart watcher:
```bash
docker compose restart alert_watcher
```

### Services not starting?

```bash
# Check logs
docker compose logs

# Restart services
docker compose restart

# Force rebuild
docker compose down -v
docker compose up -d --force-recreate
```

### Ports already in use?

Edit `.env` and change PORT variable, or stop conflicting services:

```bash
# Check what's using port 8080
lsof -i :8080

# Kill the process
kill -9 <PID>
```

### Failover not working?

1. Check Nginx configuration:
```bash
docker compose exec nginx cat /etc/nginx/conf.d/default.conf
```

2. Test Nginx configuration syntax:
```bash
docker compose exec nginx nginx -t
```

3. Verify both services are accessible directly:
```bash
curl http://localhost:8081/version  # Blue
curl http://localhost:8082/version  # Green
```

## Common Commands

```bash
# Start services
docker compose up -d

# Stop services
docker compose down

# View status
docker compose ps

# View logs
docker compose logs -f

# View alert watcher logs
docker compose logs -f alert_watcher

# View Nginx access logs (JSON format)
docker compose exec nginx tail -f /var/log/nginx/access.log | jq .

# Restart specific service
docker compose restart nginx

# Restart alert watcher (clears state)
docker compose restart alert_watcher

# Run comprehensive test suite
./test.sh

# Test baseline
curl -i http://localhost:8080/version

# Induce chaos on Blue (errors)
curl -X POST http://localhost:8081/chaos/start?mode=error

# Induce chaos on Blue (timeouts)
curl -X POST http://localhost:8081/chaos/start?mode=timeout

# Stop chaos on Blue
curl -X POST http://localhost:8081/chaos/stop

# Test direct access to Blue
curl -i http://localhost:8081/version

# Test direct access to Green
curl -i http://localhost:8082/version

# Clear Nginx logs
docker compose exec nginx sh -c "echo '' > /var/log/nginx/access.log"
```

## Next Steps

- Read [README.md](README.md) for detailed documentation
- Read [ARCHITECTURE.md](ARCHITECTURE.md) for architecture overview
- Read [runbook.md](runbook.md) for operational procedures and alert response
- Check alert watcher configuration in [docker-compose.yml](docker-compose.yml)
