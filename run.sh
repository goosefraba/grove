#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Grove"
DERIVED_DATA_PATH="$PROJECT_DIR/.derivedData"

xcodebuild -project "$PROJECT_DIR/$APP_NAME.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  build -quiet

APP_PATH="$DERIVED_DATA_PATH/Build/Products/Debug/$APP_NAME.app"

if [ ! -d "$APP_PATH" ]; then
  echo "Build succeeded but could not find $APP_NAME.app"
  exit 1
fi

open "$APP_PATH"
