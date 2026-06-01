#!/usr/bin/env bash
set -euo pipefail

# Build, sign, optionally notarize, and optionally install the Grove macOS app
# bundle. Private Apple credentials are read from ignored local env files; do
# not commit them.

SIGNING_IDENTITY="Developer ID Application: goosefraba GmbH (PT9PGWUBJ7)"
TEAM_ID="PT9PGWUBJ7"
BUNDLE_ID="com.goosefraba.grove"
APP_NAME="Grove"
SCHEME="Grove"
PROJECT_FILE="Grove.xcodeproj"
CONFIGURATION="Release"
ENTITLEMENTS_FILE="Grove/Resources/Grove.entitlements"
RELEASE_ROOT="/tmp/grove-macos-release"
DERIVED_DATA_PATH="$RELEASE_ROOT/DerivedData"
INSTALL_ROOT="${GROVE_MACOS_INSTALL_DIR:-/Applications}"
LOCAL_ENV_FILE=".grove.env"
RELEASE_ENV_FILE="release.env"
SHARED_NOTARY_ENV_FILE="../namodb/.tauri.env"
LAUNCH_SERVICES_REGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
step()    { echo -e "\n${BOLD}${CYAN}==> $*${NC}"; }

MODE_CHECK=0
SKIP_BUILD=0
NOTARIZE=0
INSTALL=0
LAUNCH_INSTALLED=0
ALLOW_DIRTY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)       MODE_CHECK=1; shift ;;
    --skip-build)  SKIP_BUILD=1; shift ;;
    --notarize)    NOTARIZE=1; shift ;;
    --install)     INSTALL=1; shift ;;
    --launch)      INSTALL=1; LAUNCH_INSTALLED=1; shift ;;
	    --ship)        NOTARIZE=1; INSTALL=1; shift ;;
	    --allow-dirty) ALLOW_DIRTY=1; shift ;;
	    -h|--help)
	      cat <<'EOF'
Build, sign, optionally notarize, and optionally install Grove.

Usage: ./scripts/release_macos.sh [options]

Options:
  --check        Run preflight checks only
  --skip-build   Reuse the existing release build in /tmp/grove-macos-release
  --notarize     Submit the signed app archive to Apple notarization
  --install      Install the signed app bundle
  --launch       Install and launch the signed app bundle
  --ship         Notarize, staple, package, and install
  --allow-dirty  Allow releases from a dirty worktree
  -h, --help     Show this help
EOF
	      exit 0 ;;
    *) error "Unknown argument: $1 (use --help)" ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

for env_file in "$SHARED_NOTARY_ENV_FILE" "$RELEASE_ENV_FILE" "$LOCAL_ENV_FILE"; do
  if [[ -f "$env_file" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$env_file"
    set +a
  fi
done

APPLE_TEAM_ID="${APPLE_TEAM_ID:-$TEAM_ID}"
APP_BUNDLE="$RELEASE_ROOT/${APP_NAME}.app"
APP_ZIP="$RELEASE_ROOT/${APP_NAME}.app.zip"
DSYM_ZIP="$RELEASE_ROOT/${APP_NAME}.dSYM.zip"
BUILT_APP="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/${APP_NAME}.app"
BUILT_DSYM="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/${APP_NAME}.app.dSYM"
INSTALLED_APP="$INSTALL_ROOT/${APP_NAME}.app"

quit_running_app() {
  if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    return 0
  fi

  warn "$APP_NAME is running; asking it to quit before install"
  osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true

  for _ in {1..20}; do
    if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
  done

  warn "$APP_NAME did not quit cleanly; terminating the running process"
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
}

step "Preflight checks"

PREFLIGHT_FAILED=0
require_cmd() {
  if command -v "$1" >/dev/null 2>&1; then
    success "$1 found ($(command -v "$1"))"
  else
    warn "$1 NOT found"
    PREFLIGHT_FAILED=1
  fi
}

require_env() {
  local name="$1"
  if [[ -n "${!name:-}" ]]; then
    success "env var $name set"
  else
    warn "env var $name missing"
    PREFLIGHT_FAILED=1
  fi
}

require_cmd xcodebuild
require_cmd codesign
require_cmd ditto
require_cmd security
require_cmd /usr/libexec/PlistBuddy
if [[ $NOTARIZE -eq 1 ]]; then
  require_cmd xcrun
fi
if [[ $INSTALL -eq 1 ]]; then
  require_cmd mdimport
  if [[ -x "$LAUNCH_SERVICES_REGISTER" ]]; then
    success "lsregister found ($LAUNCH_SERVICES_REGISTER)"
  else
    warn "lsregister NOT found at $LAUNCH_SERVICES_REGISTER"
    PREFLIGHT_FAILED=1
  fi
  if [[ -d "$INSTALL_ROOT" && -w "$INSTALL_ROOT" ]]; then
    success "install destination is writable ($INSTALL_ROOT)"
  else
    warn "install destination is not writable: $INSTALL_ROOT"
    PREFLIGHT_FAILED=1
  fi
fi

[[ -d "$PROJECT_FILE" ]] && success "$PROJECT_FILE present" || {
  warn "$PROJECT_FILE missing"
  PREFLIGHT_FAILED=1
}

[[ -f "$ENTITLEMENTS_FILE" ]] && success "$ENTITLEMENTS_FILE present" || {
  warn "$ENTITLEMENTS_FILE missing"
  PREFLIGHT_FAILED=1
}

CODESIGN_IDS="$(security find-identity -v -p codesigning 2>/dev/null || true)"
if grep -qF "$SIGNING_IDENTITY" <<<"$CODESIGN_IDS"; then
  success "codesigning identity present in keychain"
else
  warn "codesigning identity NOT found: $SIGNING_IDENTITY"
  PREFLIGHT_FAILED=1
fi

if [[ $NOTARIZE -eq 1 ]]; then
  require_env APPLE_ID
  require_env APPLE_TEAM_ID
  require_env APPLE_PASSWORD
fi

if [[ -n "$(git status --porcelain)" && $ALLOW_DIRTY -eq 0 ]]; then
  warn "working tree is dirty; use --allow-dirty when intentionally releasing local changes"
  PREFLIGHT_FAILED=1
fi

if [[ $PREFLIGHT_FAILED -eq 1 ]]; then
  error "Preflight failed"
fi

success "Preflight passed"

if [[ $MODE_CHECK -eq 1 ]]; then
  info "Check-only mode requested. Exiting without building."
  exit 0
fi

if [[ $SKIP_BUILD -eq 0 ]]; then
  step "Building release app"
  xcodebuild \
    -project "$PROJECT_FILE" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -destination "platform=macOS" \
    -skipPackagePluginValidation \
    CODE_SIGNING_ALLOWED=NO \
    build
else
  step "Build skipped"
fi

[[ -d "$BUILT_APP" ]] || error "Missing built app bundle: $BUILT_APP"

step "Preparing app bundle"
rm -rf "$APP_BUNDLE" "$APP_ZIP"
ditto "$BUILT_APP" "$APP_BUNDLE"
success "Prepared $APP_BUNDLE"

step "Signing app bundle"
codesign --force --deep --timestamp --options runtime \
  --entitlements "$ENTITLEMENTS_FILE" \
  --sign "$SIGNING_IDENTITY" \
  "$APP_BUNDLE"

codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
codesign --display --entitlements :- "$APP_BUNDLE" >/dev/null 2>&1
success "Code signature verified"

step "Packaging signed app"
rm -f "$DSYM_ZIP"
ditto -c -k --keepParent "$APP_BUNDLE" "$APP_ZIP"
success "Created $APP_ZIP"

if [[ -d "$BUILT_DSYM" ]]; then
  ditto -c -k --keepParent "$BUILT_DSYM" "$DSYM_ZIP"
  success "Created $DSYM_ZIP"
else
  warn "Missing dSYM bundle: $BUILT_DSYM"
fi

if [[ $NOTARIZE -eq 1 ]]; then
  step "Notarizing"
  xcrun notarytool submit "$APP_ZIP" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_PASSWORD" \
    --wait

  step "Stapling notarization ticket"
  xcrun stapler staple "$APP_BUNDLE"
  xcrun stapler validate "$APP_BUNDLE"

  step "Repackaging stapled app"
  rm -f "$APP_ZIP"
  ditto -c -k --keepParent "$APP_BUNDLE" "$APP_ZIP"
  success "Created notarized $APP_ZIP"
fi

if [[ $INSTALL -eq 1 ]]; then
  step "Installing app bundle"
  quit_running_app

  rm -rf "$INSTALLED_APP"
  ditto "$APP_BUNDLE" "$INSTALLED_APP"
  touch "$INSTALLED_APP"

  codesign --verify --deep --strict --verbose=2 "$INSTALLED_APP"

  if [[ $NOTARIZE -eq 1 ]]; then
    spctl --assess --type execute --verbose=2 "$INSTALLED_APP"
  else
    warn "Installed app is signed but not notarized; use --ship or --notarize for Gatekeeper approval."
  fi

  "$LAUNCH_SERVICES_REGISTER" -f "$INSTALLED_APP" >/dev/null 2>&1 || warn "Launch Services registration failed"
  mdimport "$INSTALLED_APP" >/dev/null 2>&1 || warn "Spotlight import failed"

  success "Installed $INSTALLED_APP"

  if [[ $LAUNCH_INSTALLED -eq 1 ]]; then
    open "$INSTALLED_APP"
  fi
fi

step "Release artifacts ready"
cat <<EOF
  App bundle: $APP_BUNDLE
  Zip:        $APP_ZIP
  Symbols:    $([[ -f "$DSYM_ZIP" ]] && echo "$DSYM_ZIP" || echo "<not available>")
  Installed:  $([[ $INSTALL -eq 1 ]] && echo "$INSTALLED_APP" || echo "<not installed>")
EOF
