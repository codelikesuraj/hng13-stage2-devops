# Architecture Overview

## Blue/Green Deployment with Nginx Auto-Failover

### System Components

```                            
+-----------------------------------------------------------+
|                           Client                          |
+-----------------------------|-----------------------------+
                              |
                        HTTP Requests
                          Port 8080
                              |
                             \|/
+-----------------------------------------------------------+
|                    Nginx Reverse Proxy                    |
|  +-----------------------------------------------------+  |
|  |  Upstream: active_pool                              |  |
|  |  - Primary: app_blue:3000 (max_fails=1, timeout=5s) |  |
|  |  - Backup:  app_green:3000                          |  |
|  |                                                     |  |
|  |  Retry Policy:                                      |  |
|  |  - error, timeout, http_5XX                         |  |
|  |  - max_tries: 2                                     |  |
|  |  - timeout: 5s                                      |  |
|  |                                                     |  |
|  |  Timeouts:                                          |  |
|  |  - connect: 2s, send: 2s, read: 2s                  |  |
|  +-----------------------------------------------------+  |
+--------------|---------------------------|----------------+
               |                           |
            Primary                      Backup
               |                   (only on failure)
               |                           | 
              \|/                         \|/
  +-------------------------+   +-------------------------+
  |    Blue Service         |   |    Green Service        |
  |  Port: 8081 (external)  |   |  Port: 8082 (external)  |
  |  Port: 3000 (internal)  |   |  Port: 3000 (internal)  |
  |                         |   |                         |
  |  Endpoints:             |   |  Endpoints:             |
  |  - GET /version         |   |  - GET /version         |
  |  - GET /healthz         |   |  - GET /healthz         |
  |  - POST /chaos/start    |   |  - POST /chaos/start    |
  |  - POST /chaos/stop     |   |  - POST /chaos/stop     |
  |                         |   |                         |
  |  Headers:               |   |  Headers:               |
  |  - X-App-Pool: blue     |   |  - X-App-Pool: green    |
  |  - X-Release-Id: <id>   |   |  - X-Release-Id: <id>   |
  +-------------------------+   +-------------------------+
```

## Failover Mechanism

### Normal State (Blue Active)

1. All client requests to `http://localhost:8080` route through Nginx
2. Nginx forwards requests to Blue service (primary upstream)
3. Blue responds with:
   - HTTP 200 OK
   - X-App-Pool: blue
   - X-Release-Id: blue-v1.0.0

### Failure Detection

When Blue fails (500 errors, timeouts, or connection errors):

1. **Immediate Detection** (within 2 seconds):
   - Nginx's tight timeouts (2s) trigger quickly
   - Connection errors, timeouts, or 5xx responses are detected

2. **Retry to Backup**:
   - Within the same client request, Nginx retries to Green (backup)
   - Client never sees the failure from Blue
   - `proxy_next_upstream` ensures seamless retry

3. **Mark Primary as Failed**:
   - After 1 failure (`max_fails=1`), Blue is marked as down
   - For the next 5 seconds (`fail_timeout=5s`), all traffic goes to Green

### Automatic Failover (Blue Failed, Green Active)

1. All subsequent requests route to Green (backup becomes primary)
2. Green responds with:
   - HTTP 200 OK
   - X-App-Pool: green
   - X-Release-Id: green-v1.0.0

3. **Zero Failed Requests**:
   - Clients receive HTTP 200 even during failover
   - Retry happens within the same request
   - No client-visible failures

### Recovery

1. After 5 seconds (`fail_timeout`), Nginx tries Blue again
2. If Blue is healthy, traffic gradually returns to Blue
3. Green remains as backup

## Configuration Flow

### Environment Variables (.env)

```
BLUE_IMAGE → Docker image for Blue service
GREEN_IMAGE → Docker image for Green service
ACTIVE_POOL → Which pool is primary (blue/green)
RELEASE_ID_BLUE → Release identifier for Blue
RELEASE_ID_GREEN → Release identifier for Green
APP_PORT → Application port (default: 3000)
```

### Docker Compose (docker-compose.yml)

1. **app_blue service**:
   - Uses ${BLUE_IMAGE}
   - Exposes port 8081 (external) → 3000 (internal)
   - Sets environment: APP_POOL=blue, RELEASE_ID=${RELEASE_ID_BLUE}
   - Health checks every 5 seconds

2. **app_green service**:
   - Uses ${GREEN_IMAGE}
   - Exposes port 8082 (external) → 3000 (internal)
   - Sets environment: APP_POOL=green, RELEASE_ID=${RELEASE_ID_GREEN}
   - Health checks every 5 seconds

3. **nginx service**:
   - Uses nginx:alpine image
   - Exposes port 8080 → 80
   - Mounts nginx.conf.template and entrypoint.sh
   - Waits for both Blue and Green to be healthy before starting

### Nginx Configuration Template (nginx.conf.template)

Uses envsubst to replace variables:
- `${ACTIVE_POOL}` → primary server (blue or green)
- `${BACKUP_POOL}` → backup server (automatically computed)
- `${PORT}` → application port

### Entrypoint Script (entrypoint.sh)

1. Computes BACKUP_POOL based on ACTIVE_POOL:
   - If ACTIVE_POOL=blue → BACKUP_POOL=green
   - If ACTIVE_POOL=green → BACKUP_POOL=blue

2. Runs envsubst on nginx.conf.template → /etc/nginx/conf.d/default.conf

3. Tests Nginx configuration

4. Starts Nginx in foreground

## Request Flow

### Successful Request (Normal State)

```
Client → Nginx (port 8080)
         |
         ├-> proxy_pass to upstream "active_pool"
         |
         +-> app_blue:3000
             |
             +-> HTTP 200
                 X-App-Pool: blue
                 X-Release-Id: blue-v1.0.0
                 |
                 +-> Response to Client
```

### Failed Request with Automatic Retry

```
Client → Nginx (port 8080)
         |
         ├-> proxy_pass to upstream "active_pool"
         |
         ├-> app_blue:3000
         |   |
         |   +-> 500 Internal Server Error / Timeout
         |       |
         |       +-> proxy_next_upstream triggered
         |
         +-> Retry to app_green:3000 (backup)
             |
             +-> HTTP 200
                 X-App-Pool: green
                 X-Release-Id: green-v1.0.0
                 |
                 +-> Response to Client (client sees 200, not the 500!)
```

## Key Features

### 1. Zero Downtime
- Retry mechanism happens within the same client request
- Client never sees failures from the primary
- Seamless transition from Blue to Green

### 2. Quick Failure Detection
- 2-second timeouts for connect, send, and read
- Failures detected almost immediately
- Fast failover (typically < 2 seconds)

### 3. Header Preservation
- X-App-Pool header identifies which pool served the request
- X-Release-Id header identifies the release version
- All application headers are forwarded to clients

### 4. Health Monitoring
- Docker health checks every 5 seconds
- Nginx upstream health checking via max_fails/fail_timeout
- Both active and passive health monitoring

### 5. Parameterized Configuration
- All settings controlled via .env
- No hardcoded values
- Easy to switch between Blue and Green as primary

### 6. Testability
- Direct access to both pools (8081, 8082) for chaos testing
- Chaos endpoints for simulating failures
- Automated test scripts and CI/CD workflow

## Performance Characteristics

- **Failure Detection Time**: < 2 seconds
- **Failover Time**: < 2 seconds
- **Recovery Time**: 5 seconds (configurable via fail_timeout)
- **Maximum Request Duration**: < 5 seconds (connect + retry timeout)
- **Zero Failed Requests**: Guaranteed (via retry mechanism)
- **Success Rate During Failover**: 100% (all retried requests succeed)
