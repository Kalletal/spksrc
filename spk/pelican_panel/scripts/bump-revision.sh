#!/bin/bash
#
# Auto-increment SPK_REV in Makefile and update CHANGELOG
# Usage: ./scripts/bump-revision.sh [changelog_message]
#
# If no message provided, uses a default placeholder
#

MAKEFILE="$(dirname "$0")/../Makefile"

if [ ! -f "$MAKEFILE" ]; then
    echo "ERROR: Makefile not found at $MAKEFILE"
    exit 1
fi

# Get current revision
CURRENT_REV=$(grep -E "^SPK_REV\s*=" "$MAKEFILE" | sed 's/SPK_REV\s*=\s*//')

if [ -z "$CURRENT_REV" ]; then
    echo "ERROR: Could not find SPK_REV in Makefile"
    exit 1
fi

# Increment revision
NEW_REV=$((CURRENT_REV + 1))

# Get changelog message from argument or use default
CHANGELOG_MSG="${1:-Mise à jour}"

# Update SPK_REV in Makefile
sed -i "s/^SPK_REV\s*=\s*[0-9]*/SPK_REV = ${NEW_REV}/" "$MAKEFILE"

# Update CHANGELOG - prepend new version entry
# Format: "1.0.0-XX: Message. 1.0.0-YY: Old message..."
CURRENT_CHANGELOG=$(grep -E "^CHANGELOG\s*=" "$MAKEFILE" | sed 's/CHANGELOG\s*=\s*"//' | sed 's/"$//')
NEW_CHANGELOG_ENTRY="1.0.0-${NEW_REV}: ${CHANGELOG_MSG}."

if [ -n "$CURRENT_CHANGELOG" ]; then
    # Prepend new entry to existing changelog
    sed -i "s|^CHANGELOG\s*=\s*\".*\"|CHANGELOG = \"${NEW_CHANGELOG_ENTRY} ${CURRENT_CHANGELOG}\"|" "$MAKEFILE"
else
    # No existing changelog, create new one
    sed -i "s|^CHANGELOG\s*=\s*\".*\"|CHANGELOG = \"${NEW_CHANGELOG_ENTRY}\"|" "$MAKEFILE"
fi

echo "Bumped SPK_REV: $CURRENT_REV -> $NEW_REV"
echo "CHANGELOG updated: ${NEW_CHANGELOG_ENTRY}"
