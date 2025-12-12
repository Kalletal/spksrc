#!/bin/bash
#
# Migration Watcher Daemon
# Monitors Pelican Panel database migrations and writes status to JSON file
#

PACKAGE_NAME="pelican_panel"
CONTAINER_NAME="${PACKAGE_NAME}-panel-1"
STATUS_FILE="/var/packages/${PACKAGE_NAME}/var/init_status.json"
LOG_FILE="/var/packages/${PACKAGE_NAME}/var/migration_watcher.log"
PID_FILE="/var/packages/${PACKAGE_NAME}/var/migration_watcher.pid"
MIGRATE_PID_FILE="/var/packages/${PACKAGE_NAME}/var/migrate.pid"

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Track completed migrations
COMPLETED_MIGRATIONS=""

# Write status to JSON file
write_status() {
    local progress="$1"
    local message="$2"
    local migrations_done="$3"
    local migrations_total="$4"
    local current_migration="$5"
    local panel_ready="$6"

    # Build JSON array of completed migrations
    local migrations_json="[]"
    if [ -n "$COMPLETED_MIGRATIONS" ]; then
        migrations_json=$(echo "$COMPLETED_MIGRATIONS" | awk '{
            printf "["
            for(i=1; i<=NF; i++) {
                if(i>1) printf ","
                printf "\"%s\"", $i
            }
            printf "]"
        }')
    fi

    cat > "$STATUS_FILE" << EOF
{
    "progress": ${progress},
    "message": "${message}",
    "migrations_done": ${migrations_done},
    "migrations_total": ${migrations_total},
    "current_migration": "${current_migration}",
    "panel_ready": ${panel_ready},
    "completed_migrations": ${migrations_json},
    "timestamp": $(date +%s)
}
EOF
}

# Check if container is running
container_running() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"
}

# Get migration status from container
get_migration_status() {
    docker exec "$CONTAINER_NAME" php /var/www/html/artisan migrate:status 2>&1
}

# Fix database directory permissions on host
fix_db_permissions() {
    local db_dir="/var/packages/${PACKAGE_NAME}/var/data/pelican-data/database"
    if [ -d "$db_dir" ]; then
        chown -R 82:82 "$db_dir" 2>/dev/null || true
        chmod 777 "$db_dir" 2>/dev/null || true
        [ -f "$db_dir/database.sqlite" ] && chmod 666 "$db_dir/database.sqlite" 2>/dev/null || true
        log "Fixed database permissions"
    fi
}

# Start migrations in background
start_migrations_background() {
    if [ -f "$MIGRATE_PID_FILE" ]; then
        local old_pid=$(cat "$MIGRATE_PID_FILE")
        if kill -0 "$old_pid" 2>/dev/null; then
            log "Migrations already running (PID: $old_pid)"
            return 0
        fi
    fi

    log "Starting migrations in background..."
    fix_db_permissions

    # Run migrations in background, redirect output to log
    (
        docker exec "$CONTAINER_NAME" php /var/www/html/artisan migrate --force >> "$LOG_FILE" 2>&1
        log "Migration process completed"
        rm -f "$MIGRATE_PID_FILE"
    ) &
    echo $! > "$MIGRATE_PID_FILE"
    log "Migration started with PID: $!"
}

# Check if migrations are currently running
migrations_running() {
    if [ -f "$MIGRATE_PID_FILE" ]; then
        local pid=$(cat "$MIGRATE_PID_FILE")
        kill -0 "$pid" 2>/dev/null && return 0
    fi
    return 1
}

# Check if panel responds correctly
panel_responds() {
    local http_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:8090/login" 2>/dev/null)
    [ "$http_code" = "200" ]
}

# Main monitoring loop
monitor() {
    log "Migration watcher started"
    write_status 5 "Démarrage du service..." 0 0 "" "false"

    local attempt=0
    local max_attempts=300  # 10 minutes max (2 second intervals)
    local migrations_started=false

    while [ $attempt -lt $max_attempts ]; do
        attempt=$((attempt + 1))

        # Phase 1: Wait for container to start
        if ! container_running; then
            write_status 10 "Attente du démarrage du conteneur..." 0 0 "" "false"
            log "Waiting for container to start (attempt $attempt)"
            sleep 2
            continue
        fi

        # Phase 2: Get migration status
        local migration_output=$(get_migration_status)

        # Check if database needs initialization
        if echo "$migration_output" | grep -q "Migration table not found"; then
            if [ "$migrations_started" = false ]; then
                write_status 25 "Initialisation de la base de données..." 0 0 "" "false"
                log "Database needs initialization"
                start_migrations_background
                migrations_started=true
            else
                # Migrations started - monitor via our own log file (migrations output goes there)
                local done=$(grep -c "DONE" "$LOG_FILE" 2>/dev/null || echo "0")
                if [ "$done" -gt 0 ]; then
                    # Extract migration names from our log file
                    COMPLETED_MIGRATIONS=$(grep "DONE" "$LOG_FILE" | awk '{print $1}' | sed 's/^[0-9_]*_//' | tr '\n' ' ')
                    # Get current migration (last line that doesn't have DONE)
                    local current=$(tail -5 "$LOG_FILE" | grep -v "DONE" | grep "^  [0-9]" | tail -1 | awk '{print $1}' | sed 's/^[0-9_]*_//')
                    local progress=$((25 + (done * 60 / 222)))  # 222 total migrations
                    write_status "$progress" "Création des tables ($done/222)..." "$done" 222 "$current" "false"
                    log "Progress: $done/222 tables created"
                else
                    write_status 30 "Création de la base de données..." 0 0 "" "false"
                fi
            fi
            sleep 2
            continue
        fi

        # Check if database file doesn't exist yet
        if echo "$migration_output" | grep -q "does not exist"; then
            if [ "$migrations_started" = false ]; then
                write_status 20 "Préparation de la base de données..." 0 0 "" "false"
                log "Database file not ready, fixing permissions"
                fix_db_permissions
                sleep 2
                # Try starting migrations
                start_migrations_background
                migrations_started=true
            fi
            sleep 2
            continue
        fi

        # Check for readonly error - need to fix permissions
        if echo "$migration_output" | grep -q "readonly database"; then
            log "Database readonly error, fixing permissions"
            fix_db_permissions
            sleep 2
            continue
        fi

        # Parse migration status if we have valid output
        if echo "$migration_output" | grep -q "Migration name"; then
            # Count completed and pending migrations
            local done=$(echo "$migration_output" | grep -c 'Ran' || echo "0")
            local pending=$(echo "$migration_output" | grep -c 'Pending' || echo "0")
            local total=$((done + pending))

            # Get first pending migration name
            local current=$(echo "$migration_output" | grep 'Pending' | head -1 | awk '{print $1}')

            # Collect completed migration names (extract short name from full migration name)
            COMPLETED_MIGRATIONS=$(echo "$migration_output" | grep 'Ran' | awk '{print $1}' | sed 's/^[0-9_]*_//' | tr '\n' ' ')

            # Ensure we have valid numbers
            [ -z "$done" ] && done=0
            [ -z "$pending" ] && pending=0
            [ -z "$total" ] || [ "$total" -eq 0 ] && total=1

            log "Migration status: done=$done pending=$pending total=$total current=$current"

            # If there are pending migrations and we haven't started them
            if [ "$pending" -gt 0 ] && [ "$migrations_started" = false ]; then
                log "Found $pending pending migrations, starting..."
                start_migrations_background
                migrations_started=true
            fi

            # Calculate progress (20-90% for migrations)
            local progress=20
            if [ "$total" -gt 0 ] && [ "$done" -gt 0 ]; then
                progress=$((20 + (done * 70 / total)))
            fi

            if [ "$pending" -eq 0 ] && [ "$done" -gt 0 ]; then
                # All migrations done!
                write_status 95 "Migrations terminées ($done tables)" "$done" "$total" "" "false"
                log "All migrations complete: $done/$total"

                # Check if panel responds
                if panel_responds; then
                    write_status 100 "Panel prêt !" "$done" "$total" "" "true"
                    log "Panel is ready!"
                    # Keep status for a bit so page can redirect
                    for i in 1 2 3 4 5; do
                        write_status 100 "Panel prêt !" "$done" "$total" "" "true"
                        sleep 2
                    done
                    break
                fi
            else
                # Migrations in progress
                local msg="Installation des tables ($done/$total)..."
                if [ -n "$current" ]; then
                    # Shorten migration name for display
                    local short_name=$(echo "$current" | sed 's/^[0-9_]*_//')
                    msg="$short_name ($done/$total)"
                fi
                write_status "$progress" "$msg" "$done" "$total" "$current" "false"
            fi
        else
            # Can't get migration status yet
            local http_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:8090/" 2>/dev/null)

            if [ "$http_code" = "302" ] || [ "$http_code" = "200" ]; then
                write_status 25 "Base de données en préparation..." 0 0 "" "false"
                log "Backend responds ($http_code) but artisan not ready (attempt $attempt)"
            elif [ "$http_code" != "000" ] && [ "$http_code" != "0" ]; then
                write_status 20 "Service en démarrage..." 0 0 "" "false"
                log "Backend HTTP code: $http_code (attempt $attempt)"
            else
                write_status 15 "Attente du service..." 0 0 "" "false"
                log "Cannot connect to backend (attempt $attempt)"
            fi
        fi

        sleep 2
    done

    # Final check
    if panel_responds; then
        write_status 100 "Panel prêt !" 0 0 "" "true"
        log "Migration watcher completed successfully"
    else
        write_status 95 "Vérification finale..." 0 0 "" "false"
        log "Migration watcher timeout, panel may still be initializing"
    fi

    rm -f "$PID_FILE"
    rm -f "$MIGRATE_PID_FILE"
}

# Handle signals
cleanup() {
    log "Migration watcher stopped"
    rm -f "$PID_FILE"
    # Don't kill migration process - let it complete
    exit 0
}

trap cleanup SIGTERM SIGINT

# Check if already running
if [ -f "$PID_FILE" ]; then
    old_pid=$(cat "$PID_FILE")
    if kill -0 "$old_pid" 2>/dev/null; then
        log "Migration watcher already running (PID: $old_pid)"
        exit 0
    fi
fi

# Create directories if needed
mkdir -p "$(dirname "$STATUS_FILE")"
mkdir -p "$(dirname "$LOG_FILE")"

# Save PID
echo $$ > "$PID_FILE"

# Run in background or foreground
if [ "$1" = "-f" ] || [ "$1" = "--foreground" ]; then
    monitor
else
    monitor &
    disown
fi
