#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Grove"

xcodebuild -project "$PROJECT_DIR/$APP_NAME.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Debug \
  build -quiet

APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData -name "$APP_NAME.app" -path "*/Debug/*" -maxdepth 5 2>/dev/null | head -1)

if [ -z "$APP_PATH" ]; then
  echo "Build succeeded but could not find $APP_NAME.app"
  exit 1
fi

open "$APP_PATH"
