#!/usr/bin/env python3
"""
Nginx Log Watcher for Blue/Green Deployment Monitoring
Monitors Nginx access logs for failover events and error rate spikes.
"""

import json
import os
import sys
import time
from datetime import datetime
import requests

def log(level: str, message: str) -> None:
    """Log message with timestamp and level."""
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{timestamp}] [{level}] {message}")

class AlertWatcher:
    def __init__(self):
        # Environment configuration
        self.slack_webhook_url = os.getenv("SLACK_WEBHOOK_URL")
        self.initial_pool = os.getenv("ACTIVE_POOL", "blue")
        self.error_rate_threshold = float(os.getenv("ERROR_RATE_THRESHOLD", "2"))
        self.window_size = int(os.getenv("WINDOW_SIZE", "200"))
        self.alert_cooldown_sec = int(os.getenv("ALERT_COOLDOWN_SEC", "300"))
        self.maintenance_mode = os.getenv("MAINTENANCE_MODE", "False").lower() == "true"

        # State tracking
        self.last_pool = self.initial_pool
        self.request_window = []  # Simple list to store request statuses
        self.last_failover_alert = 0
        self.last_error_rate_alert = 0
        self.last_recovery_alert = 0
        self.system_degraded = False  # Track if system is in degraded state

        # Counters
        self.total_requests = 0
        self.failover_count = 0

        log("INFO", "Alert Watcher initialized")
        log("INFO", f"Initial pool: {self.initial_pool}")
        log("INFO", f"Error rate threshold: {self.error_rate_threshold}%")
        log("INFO", f"Window size: {self.window_size} requests")
        log("INFO", f"Alert cooldown: {self.alert_cooldown_sec}s")
        log("INFO", f"Maintenance mode: {self.maintenance_mode}")

        if not self.slack_webhook_url:
            log("WARNING", "SLACK_WEBHOOK_URL not set - alerts will be printed to console only")
        else:
            # Send startup alert
            self.send_startup_alert()

    def send_startup_alert(self) -> bool:
        """Send startup notification to Slack."""
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        message = (f"• Monitoring: Docker logs from devops-nginx\n"
                   f"• Error Threshold: {self.error_rate_threshold}%\n"
                   f"• Window Size: {self.window_size} requests\n"
                   f"• Alert Cooldown: {self.alert_cooldown_sec}s")

        payload = {
            "attachments": [{
                "color": "information",
                "title": ":information_source: - Log Watcher Started",
                "text": message,
                "footer": f"Time: {timestamp}"
            }]
        }

        try:
            response = requests.post(
                self.slack_webhook_url,
                json=payload,
                timeout=10
            )
            response.raise_for_status()
            log("INFO", "Startup alert sent to Slack")
            return True
        except Exception as e:
            log("ERROR", f"Failed to send startup alert: {e}")
            return False

    def send_slack_alert(self, title: str, message: str, color: str = "#ff0000") -> bool:
        """Send alert to Slack webhook."""
        if self.maintenance_mode:
            log("MAINTENANCE", f"Alert suppressed: {title}")
            return True

        if not self.slack_webhook_url:
            log("ALERT", f"{title}: {message}")
            return True

        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

        payload = {
            "attachments": [{
                "color": color,
                "title": title,
                "text": message,
                "footer": f"Time: {timestamp}"
            }]
        }

        try:
            response = requests.post(
                self.slack_webhook_url,
                json=payload,
                timeout=10
            )
            response.raise_for_status()
            log("INFO", f"Slack alert sent: {title}")
            return True
        except Exception as e:
            log("ERROR", f"Failed to send Slack alert: {e}")
            return False

    def check_cooldown(self, last_alert_time):
        """Check if enough time has passed since last alert."""
        current_time = time.time()
        time_since_last_alert = current_time - last_alert_time

        if time_since_last_alert >= self.alert_cooldown_sec:
            return True
        else:
            return False

    def detect_failover(self, pool: str) -> bool:
        """Detect if a failover event occurred."""
        if not pool:
            return False

        # Always prioritize the initial pool when detected
        # If we see traffic from the initial pool, update last_pool immediately
        if pool == self.initial_pool and self.last_pool != self.initial_pool:
            # Recovery to initial pool detected
            previous_pool = self.last_pool
            self.last_pool = pool
            self.failover_count += 1

            # Recovery uses its own cooldown
            if not self.check_cooldown(self.last_recovery_alert):
                log("INFO", f"Recovery detected ({previous_pool} → {pool}) but cooldown active")
                return False

            # Auto-disable maintenance mode on recovery
            if self.maintenance_mode:
                log("INFO", "Recovery detected - automatically disabling maintenance mode")
                self.maintenance_mode = False

            self.send_slack_alert(
                title=":white_check_mark: - Pool Recovery Detected",
                message=f"Traffic has recovered back to the primary pool.\n\n"
                        f"- Previous Pool: *{previous_pool}*\n"
                        f"- Current Pool: *{pool}*\n"
                        f"- Total Requests: {self.total_requests}\n"
                        f"- Failover Count: {self.failover_count}",
                color="good"
            )
            self.last_recovery_alert = time.time()
            return True

        # If pool hasn't changed, no failover
        if pool == self.last_pool:
            return False

        # Failover detected (from initial pool to backup pool)
        previous_pool = self.last_pool
        self.last_pool = pool
        self.failover_count += 1

        # Failover uses its own cooldown
        if not self.check_cooldown(self.last_failover_alert):
            log("INFO", f"Failover detected ({previous_pool} → {pool}) but cooldown active")
            return False

        self.send_slack_alert(
            title=":warning: - Failover Detected",
            message=f"Pool switch detected - traffic is now being served by the backup pool.\n\n"
                    f"- Previous Pool: *{previous_pool}*\n"
                    f"- New Pool: *{pool}*\n"
                    f"- Total Requests: {self.total_requests}\n"
                    f"- Failover Count: {self.failover_count}\n\n"
                    f"*Action Required:* Check the health of the *{previous_pool}* pool.",
            color="warning"
        )
        self.last_failover_alert = time.time()

        return True

    def calculate_error_rate(self):
        """Calculate error rate from request window."""
        if len(self.request_window) == 0:
            return 0.0

        # Count how many requests had 5xx errors
        error_count = 0
        for status in self.request_window:
            if status >= 500:
                error_count += 1

        # Calculate percentage
        total_requests = len(self.request_window)
        error_rate = (error_count / total_requests) * 100
        return error_rate

    def check_error_rate(self):
        """Check if error rate exceeds threshold."""
        # Need at least 50 requests before checking error rate
        minimum_requests = 50
        if self.window_size < minimum_requests:
            minimum_requests = self.window_size

        if len(self.request_window) < minimum_requests:
            return False

        error_rate = self.calculate_error_rate()

        if error_rate > self.error_rate_threshold:
            # Check if we're still in cooldown
            if not self.check_cooldown(self.last_error_rate_alert):
                return False

            self.last_error_rate_alert = time.time()
            self.system_degraded = True  # Mark system as degraded

            # Count errors again for the alert message
            error_count = 0
            for status in self.request_window:
                if status >= 500:
                    error_count += 1

            self.send_slack_alert(
                title=":rotating_light: - High Error Rate Detected",
                message=f"Upstream error rate has exceeded the threshold.\n\n"
                        f"- Current Error Rate: *{error_rate:.2f}%*\n"
                        f"- Threshold: {self.error_rate_threshold}%\n"
                        f"- Errors in Window: {error_count}/{len(self.request_window)}\n"
                        f"- Current Pool: *{self.last_pool}*\n"
                        f"- Total Requests: {self.total_requests}\n\n"
                        f"*Action Required:* Investigate upstream logs and consider toggling pools.",
                color="danger"
            )
            return True
        else:
            # Check if we're recovering from degraded state
            if self.system_degraded:
                # System has recovered - error rate is now below threshold
                if not self.check_cooldown(self.last_recovery_alert):
                    log("INFO", f"System recovery detected but cooldown active")
                    return False

                self.system_degraded = False  # Clear degraded flag

                # Auto-disable maintenance mode on recovery
                if self.maintenance_mode:
                    log("INFO", "Recovery detected - automatically disabling maintenance mode")
                    self.maintenance_mode = False

                self.send_slack_alert(
                    title=":white_check_mark: - Pool Recovery Detected",
                    message=f"System has recovered from high error rate.\n\n"
                            f"- Current Pool: *{self.last_pool}*\n"
                            f"- Current Error Rate: *{error_rate:.2f}%*\n"
                            f"- Threshold: {self.error_rate_threshold}%\n"
                            f"- Total Requests: {self.total_requests}\n"
                            f"- Failover Count: {self.failover_count}",
                    color="good"
                )
                self.last_recovery_alert = time.time()
                return True

        return False

    def process_log_line(self, line: str) -> None:
        """Process a single log line."""
        try:
            log_entry = json.loads(line)

            # Extract fields
            status = log_entry.get("status", 0)
            pool = log_entry.get("pool", "")
            upstream_status_str = log_entry.get("upstream_status", "")

            # Track request - use final status code
            self.total_requests += 1

            # Check if we have upstream failures (even if final status is 200)
            # upstream_status can be like "502, 200" for retry scenarios
            has_upstream_error = False
            if upstream_status_str:
                # Check if any upstream returned 5xx
                upstream_statuses = upstream_status_str.split(", ")
                for us in upstream_statuses:
                    try:
                        us_code = int(us.strip())
                        if us_code >= 500:
                            has_upstream_error = True
                            break
                    except ValueError:
                        pass

            # Track the effective status (upstream error or final status)
            if has_upstream_error:
                self.request_window.append(502)  # Track as error
            else:
                self.request_window.append(status)

            # Keep only the last N requests (sliding window)
            if len(self.request_window) > self.window_size:
                self.request_window = self.request_window[-self.window_size:]

            # Detect failover
            if pool:
                self.detect_failover(pool)

            # Check error rate
            self.check_error_rate()

        except json.JSONDecodeError:
            # Skip non-JSON lines
            pass
        except Exception as e:
            log("ERROR", f"Failed to process log line: {e}")

    def tail_log_file(self, log_path: str) -> None:
        """Tail nginx log file and process new lines."""
        log("INFO", f"Starting to tail log file: {log_path}")

        # Wait for log file to exist
        while not os.path.exists(log_path):
            log("INFO", f"Waiting for log file to be created: {log_path}")
            time.sleep(2)

        with open(log_path, 'r') as f:
            # Try to move to end of file (skip existing logs)
            try:
                f.seek(0, 2)
            except OSError:
                # If file is not seekable, read all existing lines to skip them
                log("INFO", "File not seekable, reading existing logs...")
                for _ in f:
                    pass

            log("INFO", "Log watcher ready - monitoring for events")

            while True:
                line = f.readline()
                if line:
                    self.process_log_line(line.strip())
                else:
                    time.sleep(0.1)

    def run(self) -> None:
        """Main run loop."""
        log_path = "/var/log/nginx/access.log"

        try:
            self.tail_log_file(log_path)
        except KeyboardInterrupt:
            log("INFO", "Shutting down watcher...")
        except Exception as e:
            log("ERROR", f"Fatal error: {e}")
            sys.exit(1)


if __name__ == "__main__":
    watcher = AlertWatcher()
    watcher.run()