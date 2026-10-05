#!/bin/sh
# Xcode Cloud: Config/Secrets.xcconfig is git-ignored, but the project uses it as
# its base configuration. Create it from the example, filling the key from an
# Xcode Cloud secret environment variable when one is set.
set -e

CONFIG_DIR="${CI_PRIMARY_REPOSITORY_PATH:-$(dirname "$0")/..}/Config"
SECRETS="$CONFIG_DIR/Secrets.xcconfig"

if [ ! -f "$SECRETS" ]; then
    cp "$CONFIG_DIR/Secrets.example.xcconfig" "$SECRETS"
fi

if [ -n "$BARCODE_LOOKUP_API_KEY" ]; then
    sed -i '' "s|^BARCODE_LOOKUP_API_KEY =.*|BARCODE_LOOKUP_API_KEY = $BARCODE_LOOKUP_API_KEY|" "$SECRETS"
fi
