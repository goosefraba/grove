#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Grove"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA_PATH="$PROJECT_DIR/.derivedData"
INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME.app"
DEST_APP="$INSTALL_DIR/$APP_NAME.app"

mkdir -p "$INSTALL_DIR"

xcodebuild -project "$PROJECT_DIR/$APP_NAME.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  build -quiet

if [ ! -d "$APP_PATH" ]; then
  echo "Build succeeded but could not find $APP_NAME.app"
  exit 1
fi

rm -rf "$DEST_APP"
ditto "$APP_PATH" "$DEST_APP"

echo "Installed $APP_NAME to $DEST_APP"

if [ "${LAUNCH_AFTER_INSTALL:-1}" = "1" ]; then
  open "$DEST_APP"
fi
