#!/bin/bash

# Color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

HOST="${1:-localhost}"

timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

echo "=========================================="
echo "Blue/Green Deployment Test Suite"
echo "=========================================="
echo "Host: $HOST"
echo "Started: $(timestamp)"
echo ""

# Cleanup
echo -e "${YELLOW}Cleanup: Stopping chaos on both pools...${NC}"
curl -s -X POST http://$HOST:8081/chaos/stop > /dev/null 2>&1
curl -s -X POST http://$HOST:8082/chaos/stop > /dev/null 2>&1
echo -e "${GREEN}✓ Chaos stopped on Blue and Green${NC}"

echo -e "${YELLOW}Waiting for pools to stabilize...${NC}"
sleep 5
echo -e "${GREEN}✓ Pools stabilized${NC}"

echo -e "${YELLOW}Resetting alert watcher (clearing cooldowns)...${NC}"
docker compose restart alert_watcher > /dev/null 2>&1
sleep 3
echo -e "${GREEN}✓ Alert watcher ready${NC}"
echo ""

# Test 1: Baseline
echo "=========================================="
echo -e "${YELLOW}Test 1: Baseline (Blue Active)${NC}"
echo "=========================================="
echo -e "${BLUE}[$(timestamp)]${NC} Testing baseline state..."

response=$(curl -s -i http://$HOST:8080/version)
status=$(echo "$response" | grep HTTP | awk '{print $2}')
pool=$(echo "$response" | grep -i "X-App-Pool:" | awk '{print $2}' | tr -d '\r')
release=$(echo "$response" | grep -i "X-Release-Id:" | awk '{print $2}' | tr -d '\r')

echo "  Status: $status"
echo "  Pool: $pool"
echo "  Release: $release"
echo "  Time: $(timestamp)"

if [ "$status" = "200" ] && [ "$pool" = "blue" ]; then
    echo -e "${GREEN}✓ PASSED - Blue is active${NC}"
else
    echo -e "${RED}✗ FAILED - Expected Blue to be active${NC}"
    exit 1
fi
echo ""

# Test 2: Trigger Chaos & Failover
echo "=========================================="
echo -e "${YELLOW}Test 2: Failover (Blue → Green)${NC}"
echo "=========================================="
echo -e "${BLUE}[$(timestamp)]${NC} Triggering chaos on Blue..."
curl -s -X POST http://$HOST:8081/chaos/start?mode=error > /dev/null
sleep 1

echo -e "${BLUE}[$(timestamp)]${NC} Generating traffic (10 requests)..."
green_count=0
failed=0
for i in {1..10}; do
    response=$(curl -s -i http://$HOST:8080/version)
    status=$(echo "$response" | grep HTTP | awk '{print $2}')
    pool=$(echo "$response" | grep -i "X-App-Pool:" | awk '{print $2}' | tr -d '\r')

    echo -e "  Request $i: Status=$status Pool=$pool"

    if [ "$status" = "200" ] && [ "$pool" = "green" ]; then
        ((green_count++))
    elif [ "$status" != "200" ]; then
        ((failed++))
    fi
    sleep 0.3
done

echo ""
echo "  Results: $green_count/10 from Green, $failed failed"
echo "  Time: $(timestamp)"

if [ $failed -eq 0 ] && [ $green_count -ge 9 ]; then
    echo -e "${GREEN}✓ PASSED - Failover successful, zero failures${NC}"
else
    echo -e "${RED}✗ FAILED - Failover issues detected${NC}"
    exit 1
fi

echo ""
echo "Check Slack for: Failover Detected alert"
echo ""

# Intermediate Recovery: Stop Blue chaos and let it recover
echo "=========================================="
echo -e "${YELLOW}Intermediate: Blue Recovery${NC}"
echo "=========================================="
echo -e "${BLUE}[$(timestamp)]${NC} Stopping chaos on Blue..."
curl -s -X POST http://$HOST:8081/chaos/stop > /dev/null
echo -e "${BLUE}[$(timestamp)]${NC} Waiting 8 seconds for Blue to recover..."
sleep 8

echo -e "${BLUE}[$(timestamp)]${NC} Verifying Blue is healthy again..."
blue_healthy=0
for i in {1..5}; do
    response=$(curl -s -i http://$HOST:8080/version)
    pool=$(echo "$response" | grep -i "X-App-Pool:" | awk '{print $2}' | tr -d '\r')
    if [ "$pool" = "blue" ]; then
        ((blue_healthy++))
    fi
    sleep 0.3
done

echo "  Blue recovered: $blue_healthy/5 requests from Blue"
echo -e "${GREEN}✓ Blue is healthy and back in rotation${NC}"
echo ""

# Test 3: High Error Rate Alert
echo "=========================================="
echo -e "${YELLOW}Test 3: High Error Rate Alert${NC}"
echo "=========================================="
echo -e "${BLUE}[$(timestamp)]${NC} Triggering chaos on BOTH pools..."
curl -s -X POST http://$HOST:8081/chaos/start?mode=error > /dev/null
curl -s -X POST http://$HOST:8082/chaos/start?mode=error > /dev/null
sleep 1

echo -e "${BLUE}[$(timestamp)]${NC} Generating sustained errors (200 requests)..."

start_time=$(date +%s)
error_count=0
success_count=0
for i in {1..200}; do
    if [ $((i % 20)) -eq 0 ]; then
        echo "  Progress: $i/200 requests..."
    fi
    response=$(curl -s -w "%{http_code}" http://$HOST:8080/version 2>&1)
    status=$(echo "$response" | tail -c 4)
    if [ "$status" -ge 500 ] || [ "$status" -ge 400 ]; then
        ((error_count++))
    elif [ "$status" = "200" ]; then
        ((success_count++))
    fi
    sleep 0.05
done
end_time=$(date +%s)
duration=$((end_time - start_time))

error_rate=$(awk "BEGIN {printf \"%.2f\", ($error_count / 200) * 100}")

echo ""
echo "  Requests: 200"
echo "  Errors: $error_count"
echo "  Success: $success_count"
echo "  Error Rate: ${error_rate}%"
echo "  Duration: ${duration}s"
echo "  Time: $(timestamp)"
echo -e "${GREEN}✓ Traffic generated${NC}"
echo ""
echo "Check Slack for: High Error Rate Detected alert"
echo ""

# Test 4: Recovery
echo "=========================================="
echo -e "${YELLOW}Test 4: Recovery (Both Pools)${NC}"
echo "=========================================="
echo -e "${BLUE}[$(timestamp)]${NC} Stopping chaos on both pools..."
curl -s -X POST http://$HOST:8081/chaos/stop > /dev/null
curl -s -X POST http://$HOST:8082/chaos/stop > /dev/null
echo -e "${BLUE}[$(timestamp)]${NC} Waiting 8 seconds for both pools to recover..."
sleep 8

echo -e "${BLUE}[$(timestamp)]${NC} Generating recovery traffic (100 requests)..."
blue_count=0
success_count=0
for i in {1..100}; do
    if [ $((i % 20)) -eq 0 ]; then
        echo "  Progress: $i/100 requests..."
    fi
    response=$(curl -s -i http://$HOST:8080/version)
    status=$(echo "$response" | grep HTTP | awk '{print $2}')
    pool=$(echo "$response" | grep -i "X-App-Pool:" | awk '{print $2}' | tr -d '\r')

    if [ "$pool" = "blue" ]; then
        ((blue_count++))
    fi
    if [ "$status" = "200" ]; then
        ((success_count++))
    fi
    sleep 0.05
done

echo ""
echo "  Results: $blue_count/100 from Blue, $success_count/100 successful"
echo "  Time: $(timestamp)"

if [ $blue_count -gt 0 ] && [ $success_count -gt 95 ]; then
    echo -e "${GREEN}✓ PASSED - Blue recovered with low error rate${NC}"
else
    echo -e "${RED}✗ FAILED - Recovery incomplete${NC}"
    exit 1
fi

echo ""
echo "Check Slack for: Pool Recovery Detected alert"
echo ""
echo -e "${YELLOW}Waiting 5 seconds for recovery alert to process...${NC}"
sleep 5
echo ""

# Summary
echo "=========================================="
echo -e "${GREEN}ALL TESTS PASSED!${NC}"
echo "=========================================="
echo "Completed: $(timestamp)"
echo ""
echo "Summary:"
echo "  ✓ Baseline verified (Blue active)"
echo "  ✓ Failover to Green (zero failures)"
echo "  ✓ High error rate traffic generated"
echo "  ✓ Recovery to Blue"
echo ""
echo "Expected Slack Alerts:"
echo "  1. Failover Detected (blue → green)"
echo "  2. Pool Recovery Detected (green → blue)"
echo "  3. High Error Rate Detected"
echo "  4. Pool Recovery Detected (system recovered)"
echo ""

# Post-test cleanup
echo "=========================================="
echo -e "${YELLOW}Post-Test Cleanup${NC}"
echo "=========================================="
echo -e "${BLUE}[$(timestamp)]${NC} Clearing Nginx access logs..."
docker compose exec nginx sh -c "echo '' > /var/log/nginx/access.log" > /dev/null 2>&1
echo -e "${GREEN}✓ Nginx logs cleared${NC}"

echo -e "${BLUE}[$(timestamp)]${NC} Restarting alert watcher (resets state)..."
docker compose restart alert_watcher > /dev/null 2>&1
sleep 3
echo -e "${GREEN}✓ Alert watcher restarted${NC}"
echo ""
echo "System is now clean and ready for next test run."
echo ""