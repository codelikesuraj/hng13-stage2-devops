#!/bin/sh

# Determine backup pool based on active pool
if [ "$ACTIVE_POOL" = "blue" ]; then
    export BACKUP_POOL="green"
else
    export BACKUP_POOL="blue"
fi

# Substitute environment variables in the Nginx config template
envsubst '${ACTIVE_POOL} ${BACKUP_POOL} ${APP_PORT}' < /etc/nginx/templates/nginx.conf.template > /etc/nginx/conf.d/default.conf

# Verify the generated configuration
echo "Generated Nginx configuration:"
cat /etc/nginx/conf.d/default.conf

# Test Nginx configuration
nginx -t

# Start Nginx in the foreground
exec nginx -g 'daemon off;'
