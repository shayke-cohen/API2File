#!/bin/bash
set -e

echo "Building..."
swift build

echo "Copying binary..."
cp .build/debug/API2FileApp build/API2File.app/Contents/MacOS/API2File

echo "Re-signing..."
codesign --force --sign - build/API2File.app

echo "Done. Restart with: pkill -f 'API2File.app'; open build/API2File.app"
