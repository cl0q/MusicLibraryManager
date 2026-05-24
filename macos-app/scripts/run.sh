#!/usr/bin/env bash
# Build the MLM SwiftPM executable, wrap it in a proper .app bundle,
# and launch it. Usage:
#
#   ./scripts/run.sh                # debug build, build + open
#   ./scripts/run.sh --release      # release build (optimized)
#   ./scripts/run.sh --no-open      # build only, don't launch
#   ./scripts/run.sh --clean        # nuke .build/ before building
#   ./scripts/run.sh --kill         # kill any running MLM before launch
#   ./scripts/run.sh --install      # install compiled app to /Applications/
#
# Flags can be combined, e.g. `./scripts/run.sh --release --kill`.

set -euo pipefail

# Resolve repo paths regardless of where the script is invoked from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${APP_ROOT}"

CONFIG="debug"
DO_OPEN=1
DO_CLEAN=0
DO_KILL=0
DO_INSTALL=0

for arg in "$@"; do
  case "${arg}" in
    --release)  CONFIG="release" ;;
    --debug)    CONFIG="debug" ;;
    --no-open)  DO_OPEN=0 ;;
    --clean)    DO_CLEAN=1 ;;
    --kill)     DO_KILL=1 ;;
    --install)  DO_INSTALL=1 ;;
    -h|--help)
      sed -n '2,13p' "${SCRIPT_DIR}/$(basename "$0")" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "unknown flag: ${arg}" >&2
      exit 2
      ;;
  esac
done

# Sync credentials from repo root .env → Application Support so the .app can read them.
REPO_ENV="$(cd "${APP_ROOT}/.." && pwd)/.env"
APPSUPP_MLM="${HOME}/Library/Application Support/MLM"
if [[ -f "${REPO_ENV}" ]]; then
    mkdir -p "${APPSUPP_MLM}"
    cp "${REPO_ENV}" "${APPSUPP_MLM}/.env"
fi

ARCH="$(uname -m)"   # arm64 or x86_64
BIN_PATH=".build/${ARCH}-apple-macosx/${CONFIG}/MLM"
APP_BUNDLE=".build/MLM.app"

if [[ "${DO_CLEAN}" == "1" ]]; then
  echo "› cleaning .build/"
  rm -rf .build
fi

echo "› swift build (${CONFIG})"
if [[ "${CONFIG}" == "release" ]]; then
  swift build -c release
else
  swift build
fi

if [[ ! -x "${BIN_PATH}" ]]; then
  echo "✗ binary not found at ${BIN_PATH}" >&2
  exit 1
fi

# Make sure the .app bundle exists with a valid Info.plist. We rewrite the
# plist every run so changes here propagate without needing --clean.
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cat > "${APP_BUNDLE}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>MLM</string>
  <key>CFBundleIdentifier</key><string>com.ilczuk.mlm</string>
  <key>CFBundleName</key><string>MLM</string>
  <key>CFBundleDisplayName</key><string>Music Library Manager</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
</dict>
</plist>
PLIST

cp "${BIN_PATH}" "${APP_BUNDLE}/Contents/MacOS/MLM"
chmod +x "${APP_BUNDLE}/Contents/MacOS/MLM"

# Copy app icon into the bundle
ICON_SRC="${APP_ROOT}/MLM/Resources/AppIcon.icns"
if [[ -f "${ICON_SRC}" ]]; then
  cp "${ICON_SRC}" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
  echo "› app icon installed"
fi

# Ad-hoc sign so macOS picks up Info.plist changes (bundle id, display name, etc.)
# without bumping into stale signature caches. Errors are non-fatal — unsigned
# bundles still launch from `open`.
codesign --force --sign - "${APP_BUNDLE}" 2>/dev/null || true

ABS_BUNDLE="${APP_ROOT}/${APP_BUNDLE}"

if [[ "${DO_INSTALL}" == "1" ]]; then
  echo "› installing to /Applications/MLM.app"
  if [[ ! -w "/Applications" ]] || { [[ -e "/Applications/MLM.app" ]] && [[ ! -w "/Applications/MLM.app" ]]; }; then
    echo "› Administrator privileges required to install to /Applications"
    sudo rm -rf "/Applications/MLM.app"
    sudo cp -R "${APP_BUNDLE}" "/Applications/"
  else
    rm -rf "/Applications/MLM.app"
    cp -R "${APP_BUNDLE}" "/Applications/"
  fi
  ABS_BUNDLE="/Applications/MLM.app"
fi

if [[ "${DO_KILL}" == "1" ]]; then
  echo "› killing any running MLM"
  pkill -x MLM 2>/dev/null || true
  sleep 0.2
fi

if [[ "${DO_OPEN}" == "1" ]]; then
  if [[ "${DO_INSTALL}" == "1" ]]; then
    echo "› open /Applications/MLM.app"
  else
    echo "› open ${APP_BUNDLE}"
  fi
  open "${ABS_BUNDLE}"
else
  if [[ "${DO_INSTALL}" == "1" ]]; then
    echo "› installed: ${ABS_BUNDLE}"
  else
    echo "› built: ${ABS_BUNDLE}"
  fi
fi
