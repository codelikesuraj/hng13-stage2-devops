#!/bin/bash

# Color codes for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=========================================="
echo "Blue/Green Deployment Failover Test"
echo "=========================================="
echo ""

# Test 1: Baseline - Blue active
echo -e "${YELLOW}Test 1: Baseline State (Blue Active)${NC}"
echo "Testing http://localhost:8080/version"
echo ""

response=$(curl -s -i http://localhost:8080/version)
status_code=$(echo "$response" | grep HTTP | awk '{print $2}')
app_pool=$(echo "$response" | grep -i "X-App-Pool:" | awk '{print $2}' | tr -d '\r')
release_id=$(echo "$response" | grep -i "X-Release-Id:" | awk '{print $2}' | tr -d '\r')

echo "Status Code: $status_code"
echo "X-App-Pool: $app_pool"
echo "X-Release-Id: $release_id"

if [ "$status_code" = "200" ] && [ "$app_pool" = "blue" ]; then
    echo -e "${GREEN}✓ Test 1 PASSED${NC}"
else
    echo -e "${RED}✗ Test 1 FAILED${NC}"
    exit 1
fi

echo ""
echo "=========================================="
echo ""

# Test 2: Induce chaos on Blue
echo -e "${YELLOW}Test 2: Inducing Chaos on Blue${NC}"
echo "POST http://localhost:8081/chaos/start?mode=error"
echo ""

chaos_response=$(curl -s -X POST http://localhost:8081/chaos/start?mode=error)
echo "Response: $chaos_response"
echo -e "${GREEN}✓ Chaos induced on Blue${NC}"

echo ""
echo "Waiting 2 seconds for Nginx to detect failure..."
sleep 2
echo ""

# Test 3: Verify automatic failover to Green
echo -e "${YELLOW}Test 3: Automatic Failover to Green${NC}"
echo "Testing http://localhost:8080/version"
echo ""

response=$(curl -s -i http://localhost:8080/version)
status_code=$(echo "$response" | grep HTTP | awk '{print $2}')
app_pool=$(echo "$response" | grep -i "X-App-Pool:" | awk '{print $2}' | tr -d '\r')
release_id=$(echo "$response" | grep -i "X-Release-Id:" | awk '{print $2}' | tr -d '\r')

echo "Status Code: $status_code"
echo "X-App-Pool: $app_pool"
echo "X-Release-Id: $release_id"

if [ "$status_code" = "200" ] && [ "$app_pool" = "green" ]; then
    echo -e "${GREEN}✓ Test 3 PASSED - Automatic failover successful${NC}"
else
    echo -e "${RED}✗ Test 3 FAILED - No failover detected${NC}"
    exit 1
fi

echo ""
echo "=========================================="
echo ""

# Test 4: Verify zero failed requests under load
echo -e "${YELLOW}Test 4: Load Test (20 requests) - Verify Zero Failures${NC}"
echo ""

failed_count=0
green_count=0
blue_count=0
total_requests=20

for i in $(seq 1 $total_requests); do
    response=$(curl -s -i http://localhost:8080/version)
    status_code=$(echo "$response" | grep HTTP | awk '{print $2}')
    app_pool=$(echo "$response" | grep -i "X-App-Pool:" | awk '{print $2}' | tr -d '\r')

    if [ "$status_code" != "200" ]; then
        ((failed_count++))
        echo -e "${RED}Request $i: FAILED (Status: $status_code)${NC}"
    else
        if [ "$app_pool" = "green" ]; then
            ((green_count++))
        elif [ "$app_pool" = "blue" ]; then
            ((blue_count++))
        fi
        echo -e "${GREEN}Request $i: SUCCESS (Pool: $app_pool)${NC}"
    fi

    sleep 0.3
done

echo ""
echo "Results:"
echo "  Total requests: $total_requests"
echo "  Green responses: $green_count"
echo "  Blue responses: $blue_count"
echo "  Failed requests: $failed_count"

success_rate=$((($total_requests - $failed_count) * 100 / $total_requests))
green_percentage=$(($green_count * 100 / $total_requests))

echo "  Success rate: $success_rate%"
echo "  Green percentage: $green_percentage%"

if [ $failed_count -eq 0 ] && [ $green_percentage -ge 95 ]; then
    echo -e "${GREEN}✓ Test 4 PASSED - Zero failures, ≥95% from Green${NC}"
else
    echo -e "${RED}✗ Test 4 FAILED${NC}"
    exit 1
fi

echo ""
echo "=========================================="
echo ""

# Test 5: Stop chaos and verify
echo -e "${YELLOW}Test 5: Stopping Chaos${NC}"
echo "POST http://localhost:8081/chaos/stop"
echo ""

stop_response=$(curl -s -X POST http://localhost:8081/chaos/stop)
echo "Response: $stop_response"
echo -e "${GREEN}✓ Chaos stopped on Blue${NC}"

echo ""
echo "=========================================="
echo ""
echo -e "${GREEN}ALL TESTS PASSED!${NC}"
echo ""
echo "Summary:"
echo "  ✓ Baseline state verified (Blue active)"
echo "  ✓ Chaos induced on Blue"
echo "  ✓ Automatic failover to Green"
echo "  ✓ Zero failed requests"
echo "  ✓ ≥95% responses from Green after failover"
echo ""
