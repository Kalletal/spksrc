#!/bin/sh
# CGI proxy for Pelican Panel - forwards all requests to container on port 8080
# Rewrites URLs in HTML and JSON responses for subfolder compatibility

PANEL_URL="http://127.0.0.1:8080"
CGI_BASE="/webman/3rdparty/pelican_panel/panel.cgi"
DEBUG_LOG="/var/packages/pelican_panel/var/cgi-debug.log"

# Debug logging (comment out in production)
log_debug() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$DEBUG_LOG" 2>/dev/null
}

# Build the target path
if [ -n "$PATH_INFO" ]; then
    TARGET_PATH="$PATH_INFO"
else
    TARGET_PATH="/"
fi

# Add query string if present
if [ -n "$QUERY_STRING" ]; then
    TARGET_URL="${PANEL_URL}${TARGET_PATH}?${QUERY_STRING}"
else
    TARGET_URL="${PANEL_URL}${TARGET_PATH}"
fi

log_debug "=== New request ==="
log_debug "METHOD=$REQUEST_METHOD PATH=$TARGET_PATH"
log_debug "CONTENT_TYPE=$CONTENT_TYPE CONTENT_LENGTH=$CONTENT_LENGTH"

# Create temp files
RESPONSE_FILE=$(mktemp)
HEADER_FILE=$(mktemp)
MODIFIED_FILE=$(mktemp)
BODY_FILE=$(mktemp)
trap 'rm -f "$RESPONSE_FILE" "$HEADER_FILE" "$MODIFIED_FILE" "$BODY_FILE"' EXIT

# Read POST body if present
# Use head -c for better performance than dd bs=1
if [ -n "$CONTENT_LENGTH" ] && [ "$CONTENT_LENGTH" -gt 0 ] 2>/dev/null; then
    head -c "$CONTENT_LENGTH" > "$BODY_FILE"
    BODY_SIZE=$(wc -c < "$BODY_FILE" | tr -d ' ')
    log_debug "Body read: expected=$CONTENT_LENGTH actual=$BODY_SIZE"
    if echo "$TARGET_PATH" | grep -qi "livewire"; then
        log_debug "Body preview: $(head -c 200 "$BODY_FILE")"
    fi
fi

# Build curl command
do_curl() {
    curl -s --connect-timeout 10 --max-time 60 \
        -X "$REQUEST_METHOD" \
        ${CONTENT_TYPE:+-H "Content-Type: $CONTENT_TYPE"} \
        ${HTTP_ACCEPT:+-H "Accept: $HTTP_ACCEPT"} \
        ${HTTP_ACCEPT_LANGUAGE:+-H "Accept-Language: $HTTP_ACCEPT_LANGUAGE"} \
        ${HTTP_COOKIE:+-H "Cookie: $HTTP_COOKIE"} \
        ${HTTP_X_LIVEWIRE:+-H "X-Livewire: $HTTP_X_LIVEWIRE"} \
        ${HTTP_X_CSRF_TOKEN:+-H "X-CSRF-TOKEN: $HTTP_X_CSRF_TOKEN"} \
        ${HTTP_X_REQUESTED_WITH:+-H "X-Requested-With: $HTTP_X_REQUESTED_WITH"} \
        ${HTTP_X_XSRF_TOKEN:+-H "X-XSRF-TOKEN: $HTTP_X_XSRF_TOKEN"} \
        ${HTTP_REFERER:+-H "Referer: $HTTP_REFERER"} \
        ${HTTP_ORIGIN:+-H "Origin: $HTTP_ORIGIN"} \
        -D "$HEADER_FILE" \
        -o "$RESPONSE_FILE" \
        "$@"
}

# Execute request
case "$REQUEST_METHOD" in
    POST|PUT|PATCH)
        if [ -s "$BODY_FILE" ]; then
            do_curl --data-binary "@$BODY_FILE" "$TARGET_URL" 2>/dev/null
        else
            do_curl "$TARGET_URL" 2>/dev/null
        fi
        ;;
    *)
        REQUEST_METHOD="${REQUEST_METHOD:-GET}"
        do_curl "$TARGET_URL" 2>/dev/null
        ;;
esac

# Check if curl succeeded
if [ ! -s "$HEADER_FILE" ]; then
    log_debug "ERROR: No response from upstream (header file empty)"
    echo "Content-Type: text/html; charset=utf-8"
    echo ""
    echo "<html><body><h1>502 Bad Gateway</h1><p>Cannot connect to Panel</p></body></html>"
    exit 0
fi

# Extract status code
STATUS_CODE=$(head -1 "$HEADER_FILE" | grep -oE '[0-9]{3}' | head -1)
[ -z "$STATUS_CODE" ] && STATUS_CODE="200"

RESPONSE_SIZE=$(wc -c < "$RESPONSE_FILE" | tr -d ' ')
log_debug "Response: status=$STATUS_CODE size=$RESPONSE_SIZE"
if [ "$STATUS_CODE" -ge 400 ] && echo "$TARGET_PATH" | grep -qi "livewire"; then
    log_debug "Error response body: $(head -c 500 "$RESPONSE_FILE")"
fi

echo "Status: $STATUS_CODE"

# Get content type
CONTENT_TYPE_HEADER=$(grep -i "^Content-Type:" "$HEADER_FILE" | head -1 | tr -d '\r')

# Output headers (rewrite Location and Set-Cookie paths, skip problematic ones)
tail -n +2 "$HEADER_FILE" | while IFS= read -r line; do
    line=$(echo "$line" | tr -d '\r')
    [ -z "$line" ] && continue
    case "$line" in
        Transfer-Encoding:*|Connection:*|X-Frame-Options:*|Content-Length:*)
            continue
            ;;
        Location:*)
            location_value=$(echo "$line" | sed 's/^Location: *//')
            if echo "$location_value" | grep -qE '^https?://'; then
                path=$(echo "$location_value" | sed -E 's|^https?://[^/]+||')
                [ -z "$path" ] && path="/"
                echo "Location: ${CGI_BASE}${path}"
            elif echo "$location_value" | grep -q '^/'; then
                echo "Location: ${CGI_BASE}${location_value}"
            else
                echo "$line"
            fi
            ;;
        Set-Cookie:*)
            # Rewrite cookie path from "/" to CGI base path
            # This ensures cookies are sent back on subsequent CGI requests
            modified_cookie=$(echo "$line" | sed "s|path=/;|path=${CGI_BASE}/;|g" | sed "s|path=/\$|path=${CGI_BASE}/|g")
            # Also remove SameSite=Lax as it can cause issues with proxied requests
            modified_cookie=$(echo "$modified_cookie" | sed 's|; samesite=lax||gi')
            echo "$modified_cookie"
            ;;
        *)
            echo "$line"
            ;;
    esac
done

echo ""

# Process response based on content type
case "$CONTENT_TYPE_HEADER" in
    *text/html*)
        # Comprehensive URL rewriting for HTML
        sed -e 's|href="/|href="'"${CGI_BASE}"'/|g' \
            -e 's|src="/|src="'"${CGI_BASE}"'/|g' \
            -e 's|action="/|action="'"${CGI_BASE}"'/|g' \
            -e 's|data-update-uri="/|data-update-uri="'"${CGI_BASE}"'/|g' \
            -e 's|data-uri="/|data-uri="'"${CGI_BASE}"'/|g' \
            -e 's|url("/|url("'"${CGI_BASE}"'/|g' \
            -e "s|url('/|url('${CGI_BASE}/|g" \
            -e 's|http://127\.0\.0\.1:8080/|'"${CGI_BASE}"'/|g' \
            -e 's|http://127\.0\.0\.1:8090/|'"${CGI_BASE}"'/|g' \
            -e 's|"\\/livewire|"'"${CGI_BASE}"'\\/livewire|g' \
            -e 's|"/livewire|"'"${CGI_BASE}"'/livewire|g' \
            -e "s|'/livewire|'${CGI_BASE}/livewire|g" \
            "$RESPONSE_FILE" > "$MODIFIED_FILE"

        cat "$MODIFIED_FILE"
        ;;
    *application/json*)
        # Rewrite URLs in JSON responses (for Livewire)
        # Be careful to only rewrite actual path URLs, not arbitrary escaped slashes
        # Pattern: match URLs that look like paths (starting with /) in JSON context
        sed -e 's|"redirect":"\\/|"redirect":"'"${CGI_BASE}"'\\/|g' \
            -e 's|"redirect":"\/|"redirect":"'"${CGI_BASE}"'\/|g' \
            -e 's|"url":"\\/|"url":"'"${CGI_BASE}"'\\/|g' \
            -e 's|"url":"\/|"url":"'"${CGI_BASE}"'\/|g' \
            -e 's|"path":"\\/|"path":"'"${CGI_BASE}"'\\/|g' \
            -e 's|"path":"\/|"path":"'"${CGI_BASE}"'\/|g' \
            -e 's|http:\\\/\\\/127\.0\.0\.1:8080\\\/|'"${CGI_BASE}"'\\\/|g' \
            -e 's|http:\\\/\\\/127\.0\.0\.1:8090\\\/|'"${CGI_BASE}"'\\\/|g' \
            "$RESPONSE_FILE"
        ;;
    *)
        cat "$RESPONSE_FILE"
        ;;
esac
