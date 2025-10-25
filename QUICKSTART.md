# Quick Start Guide

## Prerequisites
- Docker (version 20.10+)
- Docker Compose (version 2.0+)

## 1. Clone and Setup

```bash
git clone https://github.com/yourusername/hng13-stage2-devops.git
cd hng13-stage2-devops
```

## 2. Review Configuration

The `.env` file contains all configuration:

```bash
cat .env
```

Default values:
- Active pool: **blue**
- Blue image: `ghcr.io/codelikesuraj/docker-nodejs-blue-green-service:blue`
- Green image: `ghcr.io/codelikesuraj/docker-nodejs-blue-green-service:green`
- Ports: 8080 (Nginx), 8081 (Blue), 8082 (Green)

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
NAME          IMAGE                                                         STATUS
app_blue      ghcr.io/codelikesuraj/docker-nodejs-blue-green-service:blue   Up (healthy)
app_green     ghcr.io/codelikesuraj/docker-nodejs-blue-green-service:green  Up (healthy)
nginx_proxy   nginx:alpine                                                  Up (healthy)
```

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

## 6. Run Automated Tests

```bash
./test-failover.sh
```

This script will:
1. Test baseline state (Blue active)
2. Induce chaos on Blue
3. Verify automatic failover to Green
4. Run 20 consecutive requests to verify zero failures
5. Stop chaos mode

## 7. View Logs

```bash
# All services
docker compose logs -f

# Specific service
docker compose logs -f nginx
docker compose logs -f app_blue
docker compose logs -f app_green
```

## 8. Stop Services

```bash
docker compose down
```

## Troubleshooting

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

# Restart specific service
docker compose restart nginx

# Test failover
./test-failover.sh

# Test baseline
curl -i http://localhost:8080/version

# Induce chaos on Blue
curl -X POST http://localhost:8081/chaos/start?mode=error

# Stop chaos on Blue
curl -X POST http://localhost:8081/chaos/stop

# Test direct access to Blue
curl -i http://localhost:8081/version

# Test direct access to Green
curl -i http://localhost:8082/version
```

## Next Steps

- Read [README.md](README.md) for detailed documentation
- Read [ARCHITECTURE.md](ARCHITECTURE.md) for architecture overview
- Check [.github/workflows/test-deployment.yml](.github/workflows/test-deployment.yml) for CI/CD setup
