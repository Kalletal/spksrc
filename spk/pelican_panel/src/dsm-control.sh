#!/bin/sh

# Pelican Panel - DSM Start/Stop/Status Script

PACKAGE="pelican_panel"
DNAME="Pelican Panel"
INSTALL_DIR="/var/packages/${PACKAGE}/target"
VAR_DIR="/var/packages/${PACKAGE}/var"
LOG_FILE="${VAR_DIR}/${PACKAGE}.log"

# Docker compose paths
COMPOSE_FILE="${INSTALL_DIR}/share/docker/compose.yaml"
ENV_FILE="${VAR_DIR}/panel.env"

# Wings config path (container managed via Docker Compose)
WINGS_CONFIG="${VAR_DIR}/data/wings/config.yml"
DATA_DIR="${VAR_DIR}/data"

# Loading proxy
LOADING_PROXY="${INSTALL_DIR}/bin/loading-proxy.py"
LOADING_HTML="${INSTALL_DIR}/share/loading.html"
PROXY_PID_FILE="${VAR_DIR}/loading-proxy.pid"

# Wings config watcher
WATCHER_SCRIPT="${INSTALL_DIR}/bin/wings-config-watcher.sh"
WATCHER_PID_FILE="${VAR_DIR}/wings-watcher.pid"

# Nginx reverse proxy for DSM iframe embedding
# www.*.conf files are included in server context (for location blocks)
NGINX_CONF_SRC="${INSTALL_DIR}/conf/nginx.pelican.conf"
NGINX_CONF_DST="/etc/nginx/conf.d/www.${PACKAGE}.conf"

# Ports
PANEL_PORT="8080"           # Public port (served by proxy)
PANEL_INTERNAL_PORT="8090"  # Internal Docker port

# Get port from env file if available
get_panel_port() {
    if [ -f "${ENV_FILE}" ]; then
        PORT=$(grep -E "^PANEL_PORT=" "${ENV_FILE}" | cut -d'=' -f2 | tr -d '"')
        [ -n "$PORT" ] && PANEL_PORT="$PORT"
    fi
}

get_panel_port

PATH="${INSTALL_DIR}/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

# Detect docker compose command
if docker compose version >/dev/null 2>&1; then
    DOCKER_COMPOSE="docker compose"
else
    DOCKER_COMPOSE="docker-compose"
fi

log() {
    printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" >> "${LOG_FILE}" 2>/dev/null
}

# Start the loading proxy on the public port
start_loading_proxy()
{
    if [ ! -f "${LOADING_PROXY}" ]; then
        log "Loading proxy not found at ${LOADING_PROXY}"
        return 1
    fi

    # Stop any existing proxy
    stop_loading_proxy

    log "Starting loading proxy on port ${PANEL_PORT} (forwarding to ${PANEL_INTERNAL_PORT})..."

    # Start proxy in background
    python3 "${LOADING_PROXY}" "${PANEL_PORT}" "${PANEL_INTERNAL_PORT}" "${LOADING_HTML}" >> "${LOG_FILE}" 2>&1 &
    PROXY_PID=$!
    echo "${PROXY_PID}" > "${PROXY_PID_FILE}"

    sleep 1
    if kill -0 "${PROXY_PID}" 2>/dev/null; then
        log "Loading proxy started (PID: ${PROXY_PID})"
        return 0
    else
        log "Failed to start loading proxy"
        return 1
    fi
}

# Stop the loading proxy
stop_loading_proxy()
{
    if [ -f "${PROXY_PID_FILE}" ]; then
        PID=$(cat "${PROXY_PID_FILE}" 2>/dev/null)
        if [ -n "${PID}" ] && kill -0 "${PID}" 2>/dev/null; then
            log "Stopping loading proxy (PID: ${PID})"
            kill "${PID}" 2>/dev/null
            sleep 1
            kill -9 "${PID}" 2>/dev/null
        fi
        rm -f "${PROXY_PID_FILE}"
    fi

    # Kill any remaining python proxy processes
    pkill -f "loading-proxy.py.*${PANEL_PORT}" 2>/dev/null || true
}

# Check if proxy is running
proxy_running()
{
    [ -f "${PROXY_PID_FILE}" ] && kill -0 "$(cat "${PROXY_PID_FILE}" 2>/dev/null)" 2>/dev/null
}

# Start the Wings config watcher daemon
start_watcher()
{
    if [ ! -f "${WATCHER_SCRIPT}" ]; then
        log "Wings config watcher script not found at ${WATCHER_SCRIPT}"
        return 1
    fi

    # Stop any existing watcher
    stop_watcher

    log "Starting Wings config watcher daemon..."
    sh "${WATCHER_SCRIPT}" &

    sleep 1
    if [ -f "${WATCHER_PID_FILE}" ]; then
        WATCHER_PID=$(cat "${WATCHER_PID_FILE}" 2>/dev/null)
        if kill -0 "${WATCHER_PID}" 2>/dev/null; then
            log "Wings config watcher started (PID: ${WATCHER_PID})"
            return 0
        fi
    fi
    log "Warning: Wings config watcher may not have started correctly"
    return 1
}

# Stop the Wings config watcher daemon
stop_watcher()
{
    if [ -f "${WATCHER_PID_FILE}" ]; then
        PID=$(cat "${WATCHER_PID_FILE}" 2>/dev/null)
        if [ -n "${PID}" ] && kill -0 "${PID}" 2>/dev/null; then
            log "Stopping Wings config watcher (PID: ${PID})"
            kill "${PID}" 2>/dev/null
            sleep 1
            kill -9 "${PID}" 2>/dev/null
        fi
        rm -f "${WATCHER_PID_FILE}"
    fi

    # Kill any remaining watcher processes
    pkill -f "wings-config-watcher.sh" 2>/dev/null || true
}

# Check if watcher is running
watcher_running()
{
    [ -f "${WATCHER_PID_FILE}" ] && kill -0 "$(cat "${WATCHER_PID_FILE}" 2>/dev/null)" 2>/dev/null
}

# Install nginx reverse proxy config for DSM iframe embedding
# This allows accessing Pelican via /webman/3rdparty/pelican_panel/panel/
# which works within DSM's iframe without cross-origin issues
install_nginx_proxy()
{
    if [ ! -f "${NGINX_CONF_SRC}" ]; then
        log "Nginx config not found at ${NGINX_CONF_SRC}"
        return 1
    fi

    log "Installing nginx reverse proxy configuration..."

    # Copy config to nginx conf.d
    cp "${NGINX_CONF_SRC}" "${NGINX_CONF_DST}" 2>/dev/null
    if [ $? -ne 0 ]; then
        log "Failed to copy nginx config"
        return 1
    fi

    # Test nginx configuration before reload
    if nginx -t 2>/dev/null; then
        # Reload nginx to apply changes
        if nginx -s reload 2>/dev/null; then
            log "Nginx reverse proxy installed and reloaded"
            return 0
        else
            # Try alternative reload method
            synoservicectl --reload nginx 2>/dev/null || true
            log "Nginx reverse proxy installed (reload via synoservicectl)"
            return 0
        fi
    else
        log "ERROR: Invalid nginx configuration - removing"
        rm -f "${NGINX_CONF_DST}"
        return 1
    fi
}

# Remove nginx reverse proxy config
remove_nginx_proxy()
{
    if [ -f "${NGINX_CONF_DST}" ]; then
        log "Removing nginx reverse proxy configuration..."
        rm -f "${NGINX_CONF_DST}"

        # Reload nginx
        nginx -s reload 2>/dev/null || synoservicectl --reload nginx 2>/dev/null || true
        log "Nginx reverse proxy removed"
    fi
}

# Apply X-Frame-Options fix for DSM iframe embedding
apply_iframe_fix()
{
    CONTAINER_NAME="${PACKAGE}-panel-1"

    if ! docker ps --filter "name=${CONTAINER_NAME}" --format '{{.Names}}' 2>/dev/null | grep -q "${CONTAINER_NAME}"; then
        log "Container ${CONTAINER_NAME} not running, skipping iframe fix"
        return 1
    fi

    log "Applying X-Frame-Options fix for DSM iframe embedding..."

    # Change X-Frame-Options from DENY to SAMEORIGIN in nginx config
    docker exec "${CONTAINER_NAME}" sh -c "sed -i 's/X-Frame-Options \"DENY\"/X-Frame-Options \"SAMEORIGIN\"/' /etc/nginx/nginx.conf" 2>/dev/null

    # Also handle case where it might be set differently
    docker exec "${CONTAINER_NAME}" sh -c "sed -i 's/X-Frame-Options \"deny\"/X-Frame-Options \"SAMEORIGIN\"/' /etc/nginx/nginx.conf" 2>/dev/null

    # Reload nginx to apply changes
    docker exec "${CONTAINER_NAME}" nginx -s reload 2>/dev/null

    if [ $? -eq 0 ]; then
        log "X-Frame-Options fix applied successfully"
        return 0
    else
        log "Warning: Could not reload nginx after iframe fix"
        return 1
    fi
}

ensure_port_free()
{
    local port="$1"
    log "Ensuring port ${port} is free..."

    if command -v fuser >/dev/null 2>&1; then
        fuser -k ${port}/tcp 2>/dev/null
        sleep 1
    fi

    PID_ON_PORT=$(lsof -t -i:${port} 2>/dev/null)
    if [ -n "${PID_ON_PORT}" ]; then
        log "Killing process ${PID_ON_PORT} on port ${port}"
        kill -9 ${PID_ON_PORT} 2>/dev/null
        sleep 1
    fi

    if netstat -tlnp 2>/dev/null | grep -q ":${port} "; then
        log "WARNING: Port ${port} still in use"
        return 1
    fi

    log "Port ${port} is free"
    return 0
}

# Fix Wings config for Docker-in-Docker on Synology
# Applied at every start to ensure config is always correct
fix_wings_config()
{
    if [ -f "${WINGS_CONFIG}" ]; then
        log "Applying Docker-in-Docker fixes to Wings config..."

        # FIX 1: API Port - Panel génère 8445 (externe) mais le conteneur écoute sur 8080 (interne)
        sed -i 's/port: 8445$/port: 8080/' "${WINGS_CONFIG}"

        # FIX 2: System paths - Use host paths instead of container paths
        # These patterns match any occurrence, regardless of indentation
        sed -i "s|/var/lib/pelican/volumes|${DATA_DIR}/servers|g" "${WINGS_CONFIG}"
        sed -i "s|/var/lib/pelican/backups|${DATA_DIR}/backups|g" "${WINGS_CONFIG}"
        sed -i "s|/var/lib/pelican/archives|${DATA_DIR}/archives|g" "${WINGS_CONFIG}"
        sed -i "s|/var/log/pelican|${DATA_DIR}/wings-logs|g" "${WINGS_CONFIG}"

        # Fix root_directory - match with or without trailing content
        sed -i "s|root_directory: /var/lib/pelican$|root_directory: ${DATA_DIR}|" "${WINGS_CONFIG}"

        # FIX 3: Disable mount_passwd - the passwd_file path doesn't exist on host
        sed -i 's/mount_passwd: true/mount_passwd: false/g' "${WINGS_CONFIG}"

        # FIX 4: tmp_directory - Must be a host path for install scripts
        sed -i "s|tmp_directory: /tmp/pelican$|tmp_directory: ${DATA_DIR}/tmp|" "${WINGS_CONFIG}"

        # FIX 5: Fix allowed_origins for WebSocket
        # Replace empty array with wildcard
        sed -i 's/allowed_origins: \[\]/allowed_origins:\n  - "*"/' "${WINGS_CONFIG}"

        # FIX 6: Prevent Panel from overwriting our config fixes
        sed -i 's/ignore_panel_config_updates: false/ignore_panel_config_updates: true/' "${WINGS_CONFIG}"

        # Create required directories
        mkdir -p "${DATA_DIR}/servers" "${DATA_DIR}/backups" "${DATA_DIR}/archives" "${DATA_DIR}/wings-logs" "${DATA_DIR}/tmp" 2>/dev/null || true
        chmod 777 "${DATA_DIR}/tmp" 2>/dev/null || true

        log "Wings config fixes applied"
    fi
}

fix_permissions()
{
    log "Fixing permissions for container volumes..."

    # Panel directories
    mkdir -p "${DATA_DIR}/pelican-data"
    mkdir -p "${DATA_DIR}/pelican-logs"
    mkdir -p "${DATA_DIR}/pelican-logs/supervisord"

    # MariaDB data directory
    mkdir -p "${DATA_DIR}/mariadb"

    # Wings directories (must exist for Docker-in-Docker)
    mkdir -p "${DATA_DIR}/servers"
    mkdir -p "${DATA_DIR}/backups"
    mkdir -p "${DATA_DIR}/archives"
    mkdir -p "${DATA_DIR}/wings-logs"
    mkdir -p "${DATA_DIR}/tmp"

    chmod -R 777 "${DATA_DIR}/pelican-data" 2>/dev/null || true
    chmod -R 777 "${DATA_DIR}/pelican-logs" 2>/dev/null || true
    chmod 777 "${DATA_DIR}/tmp" 2>/dev/null || true

    # Fix MariaDB data directory permissions (mysql user = UID 999 in mariadb:10.11)
    chown -R 999:999 "${DATA_DIR}/mariadb" 2>/dev/null || true
    chmod 755 "${DATA_DIR}/mariadb" 2>/dev/null || true
    log "MariaDB data directory permissions fixed (owner: UID 999)"

    log "Permissions fixed"
}

# Check if container is healthy
check_container_health()
{
    CONTAINER_NAME="${PACKAGE}-panel-1"

    if ! docker ps --filter "name=${CONTAINER_NAME}" --format '{{.Names}}' 2>/dev/null | grep -q "${CONTAINER_NAME}"; then
        return 1
    fi

    docker exec "${CONTAINER_NAME}" curl -sf http://localhost:8080/api/health >/dev/null 2>&1
    return $?
}

containers_running()
{
    docker ps --filter "name=${PACKAGE}" --format '{{.Names}}' 2>/dev/null | grep -q "${PACKAGE}"
}

wait_for_migrations()
{
    CONTAINER_NAME="${PACKAGE}-panel-1"
    log "Waiting for migrations to complete..."

    # Wait for migrations by checking if database has users table
    for i in $(seq 1 60); do
        # Check if migrations are done by looking for a key table
        TABLES=$(docker exec "${CONTAINER_NAME}" php artisan tinker --execute="echo Schema::hasTable('users') ? 'ready' : 'waiting';" 2>/dev/null | tr -d '\n' | grep -o 'ready\|waiting')
        if [ "${TABLES}" = "ready" ]; then
            log "Database migrations completed"
            return 0
        fi
        sleep 5
    done
    log "Timeout waiting for migrations"
    return 1
}

start_containers()
{
    if [ ! -f "${COMPOSE_FILE}" ]; then
        log "ERROR: compose.yaml not found at ${COMPOSE_FILE}"
        return 1
    fi
    if [ ! -f "${ENV_FILE}" ]; then
        log "ERROR: panel.env not found at ${ENV_FILE}"
        return 1
    fi

    fix_permissions

    # Check if already running and healthy
    if containers_running && check_container_health; then
        log "Docker containers already running and healthy"
        # Apply iframe fix immediately (container already running)
        apply_iframe_fix
        # Make sure proxy is running
        if ! proxy_running; then
            start_loading_proxy
        fi
        return 0
    fi

    # STEP 1: Ensure ports are free
    ensure_port_free "${PANEL_PORT}"
    ensure_port_free "${PANEL_INTERNAL_PORT}"

    # STEP 2: Start the loading proxy on public port FIRST
    # This gives immediate feedback to users
    log "Starting loading proxy..."
    start_loading_proxy

    # STEP 3: Pull latest Docker images (ensures fixes like installer redirect are included)
    log "Pulling latest Docker images..."
    ${DOCKER_COMPOSE} --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" -p "${PACKAGE}" pull >> "${LOG_FILE}" 2>&1

    # STEP 4: Start Docker containers with force-recreate to apply new images
    log "Starting Docker containers..."
    ${DOCKER_COMPOSE} --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" -p "${PACKAGE}" up -d --force-recreate >> "${LOG_FILE}" 2>&1

    log "Docker containers started. Panel initializing..."
    log "Users can access http://<IP>:${PANEL_PORT} - loading page shown until Panel is ready"

    # STEP 5: Wait for panel to be ready in background
    # Note: Admin user is created via Pelican web installer at /installer
    (
        log "Waiting for Panel to be ready..."

        # First wait for container health check
        for i in $(seq 1 120); do
            if check_container_health; then
                log "Panel health check passed!"
                break
            fi
            sleep 5
        done

        if ! check_container_health; then
            log "Panel initialization timeout after 10 minutes"
            exit 1
        fi

        # Apply X-Frame-Options fix for DSM iframe embedding
        apply_iframe_fix

        # Wait additional time for migrations to complete
        log "Waiting for migrations to finish..."
        wait_for_migrations

        # Patch is now applied via Docker volume mounts in compose.yaml
        # No runtime patching needed

        log "Panel fully initialized - user should complete setup at /installer"
    ) >> "${LOG_FILE}" 2>&1 &

    return 0
}

# Patch the default Wings port in Panel source code
# Copies pre-patched files from the package to the container
fix_default_wings_port()
{
    CONTAINER_NAME="${PACKAGE}-panel-1"
    PATCHES_DIR="${INSTALL_DIR}/share/patches"

    log "Patching default Wings port (8080 -> 8445)..."

    # Files to patch
    NODE_MODEL="/var/www/html/app/Models/Node.php"
    CREATE_NODE="/var/www/html/app/Filament/Admin/Resources/Nodes/Pages/CreateNode.php"
    EDIT_NODE="/var/www/html/app/Filament/Admin/Resources/Nodes/Pages/EditNode.php"

    # Check if patches exist
    if [ ! -d "${PATCHES_DIR}" ]; then
        log "Patches directory not found: ${PATCHES_DIR}"
        return 1
    fi

    # Copy pre-patched Node.php
    if [ -f "${PATCHES_DIR}/Node.php" ]; then
        docker cp "${PATCHES_DIR}/Node.php" "${CONTAINER_NAME}:${NODE_MODEL}" 2>/dev/null
        docker exec "${CONTAINER_NAME}" chown root:www-data "${NODE_MODEL}" 2>/dev/null
        docker exec "${CONTAINER_NAME}" chmod 640 "${NODE_MODEL}" 2>/dev/null
        log "Node.php patched"
    fi

    # Copy pre-patched CreateNode.php
    if [ -f "${PATCHES_DIR}/CreateNode.php" ]; then
        docker cp "${PATCHES_DIR}/CreateNode.php" "${CONTAINER_NAME}:${CREATE_NODE}" 2>/dev/null
        docker exec "${CONTAINER_NAME}" chown root:www-data "${CREATE_NODE}" 2>/dev/null
        docker exec "${CONTAINER_NAME}" chmod 640 "${CREATE_NODE}" 2>/dev/null
        log "CreateNode.php patched"
    fi

    # Copy pre-patched EditNode.php
    if [ -f "${PATCHES_DIR}/EditNode.php" ]; then
        docker cp "${PATCHES_DIR}/EditNode.php" "${CONTAINER_NAME}:${EDIT_NODE}" 2>/dev/null
        docker exec "${CONTAINER_NAME}" chown root:www-data "${EDIT_NODE}" 2>/dev/null
        docker exec "${CONTAINER_NAME}" chmod 640 "${EDIT_NODE}" 2>/dev/null
        log "EditNode.php patched"
    fi

    # Clear cache
    docker exec "${CONTAINER_NAME}" php /var/www/html/artisan cache:clear 2>/dev/null
    docker exec "${CONTAINER_NAME}" php /var/www/html/artisan view:clear 2>/dev/null

    log "Wings port patch complete"
}

stop_containers()
{
    log "Stopping Docker containers..."

    if [ -f "${COMPOSE_FILE}" ] && [ -f "${ENV_FILE}" ]; then
        ${DOCKER_COMPOSE} --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" -p "${PACKAGE}" down >> "${LOG_FILE}" 2>&1
    fi

    CONTAINERS=$(docker ps -q --filter "name=${PACKAGE}" 2>/dev/null)
    if [ -n "${CONTAINERS}" ]; then
        log "Force stopping remaining containers..."
        docker stop ${CONTAINERS} >> "${LOG_FILE}" 2>&1
        docker rm -f ${CONTAINERS} >> "${LOG_FILE}" 2>&1
    fi

    if containers_running; then
        log "WARNING: Some containers may still be running"
    else
        log "Docker containers stopped"
    fi
}

start_wings()
{
    # Wings is now managed as a Docker container in compose.yaml
    # It starts automatically with docker compose up
    log "Wings container is managed via Docker Compose"
}

stop_wings()
{
    # Wings is now managed as a Docker container in compose.yaml
    # It stops automatically with docker compose down
    log "Wings container is managed via Docker Compose"
}

start_migration_watcher()
{
    local WATCHER_SCRIPT="${SYNOPKG_PKGDEST}/bin/migration-watcher.sh"
    local WATCHER_PID_FILE="${SYNOPKG_PKGVAR}/migration_watcher.pid"

    if [ -f "${WATCHER_SCRIPT}" ]; then
        # ALWAYS kill any existing watcher first (ensures new version runs after upgrade)
        stop_migration_watcher

        log "Starting migration watcher daemon..."
        # Remove old status file to start fresh
        rm -f "${SYNOPKG_PKGVAR}/init_status.json"
        # Start watcher in background and save PID
        "${WATCHER_SCRIPT}" &
        local pid=$!
        echo "$pid" > "${WATCHER_PID_FILE}"
        log "Migration watcher started (PID: $pid)"
    else
        log "Migration watcher script not found: ${WATCHER_SCRIPT}"
    fi
}

stop_migration_watcher()
{
    local WATCHER_PID_FILE="${SYNOPKG_PKGVAR}/migration_watcher.pid"

    # Kill by PID file if exists
    if [ -f "${WATCHER_PID_FILE}" ]; then
        local pid=$(cat "${WATCHER_PID_FILE}")
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            log "Stopping migration watcher (PID: $pid)..."
            kill "$pid" 2>/dev/null
            sleep 1
            kill -9 "$pid" 2>/dev/null
        fi
        rm -f "${WATCHER_PID_FILE}"
    fi

    # Also kill by process name (catch any orphaned processes)
    pkill -f "migration-watcher.sh" 2>/dev/null || true

    # Remove status file on stop
    rm -f "${SYNOPKG_PKGVAR}/init_status.json"
}

case "$1" in
    start)
        echo "Démarrage de ${DNAME}"
        log "Starting ${DNAME}"
        fix_wings_config  # Apply Docker-in-Docker fixes before starting
        start_containers
        start_wings

        # Start the Wings config watcher daemon
        # This monitors config.yml and automatically applies fixes when Panel modifies it
        start_watcher

        # Start migration watcher to track database initialization
        start_migration_watcher

        # Install nginx reverse proxy for DSM iframe embedding
        install_nginx_proxy

        exit 0
        ;;
    stop)
        echo "Arrêt de ${DNAME}"
        log "Stopping ${DNAME}"
        stop_watcher
        stop_migration_watcher
        stop_wings
        stop_loading_proxy
        stop_containers

        # Remove nginx reverse proxy config
        remove_nginx_proxy

        exit 0
        ;;
    status)
        if containers_running || proxy_running; then
            echo "${DNAME} est en cours d'exécution"
            exit 0
        else
            echo "${DNAME} n'est pas en cours d'exécution"
            exit 1
        fi
        ;;
    restart)
        $0 stop
        sleep 2
        $0 start
        ;;
    log)
        tail -n 200 -f "${LOG_FILE}"
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|log}"
        exit 1
        ;;
esac
