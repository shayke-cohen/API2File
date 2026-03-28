#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA_PATH="$ROOT_DIR/build/DerivedData"
SOURCE_APP="$DERIVED_DATA_PATH/Build/Products/Debug/API2File.app"
DEST_APP="$ROOT_DIR/build/API2File.app"

echo "Building full app bundle..."
xcodebuild \
  -project "$ROOT_DIR/API2File.xcodeproj" \
  -scheme API2File \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

echo "Copying app bundle..."
rm -rf "$DEST_APP"
ditto "$SOURCE_APP" "$DEST_APP"

echo "Done. Restart with: pkill -f 'API2File'; open \"$DEST_APP\""
echo "Note: Finder badges require a properly signed app bundle installed in /Applications."
