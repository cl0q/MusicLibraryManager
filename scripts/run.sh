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
#   ./scripts/run.sh --fast         # use all CPU cores during compile
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
DO_FAST=0

for arg in "$@"; do
  case "${arg}" in
    --release)  CONFIG="release" ;;
    --debug)    CONFIG="debug" ;;
    --no-open)  DO_OPEN=0 ;;
    --clean)    DO_CLEAN=1 ;;
    --kill)     DO_KILL=1 ;;
    --install)  DO_INSTALL=1 ;;
    --fast)     DO_FAST=1 ;;
    -h|--help)
      sed -n '2,14p' "${SCRIPT_DIR}/$(basename "$0")" | sed 's/^# \{0,1\}//'
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
SANDBOX_MLM="${HOME}/Library/Containers/com.ilczuk.mlm/Data/Library/Application Support/MLM"
if [[ -f "${REPO_ENV}" ]]; then
    mkdir -p "${APPSUPP_MLM}"
    cp "${REPO_ENV}" "${APPSUPP_MLM}/.env"
    mkdir -p "${SANDBOX_MLM}"
    cp "${REPO_ENV}" "${SANDBOX_MLM}/.env"
fi

ARCH="$(uname -m)"   # arm64 or x86_64
BIN_PATH=".build/out/Products/${CONFIG^}/MLM"
APP_BUNDLE=".build/MLM.app"

if [[ "${DO_CLEAN}" == "1" ]]; then
  echo "› cleaning .build/"
  rm -rf .build
fi

echo "› swift build (${CONFIG})"
EXTRA_FLAGS=""
if [[ "${DO_FAST}" == "1" ]]; then
  CORES="$(sysctl -n hw.ncpu 2>/dev/null || echo 1)"
  echo "› compiling in fast mode using all ${CORES} cores"
  EXTRA_FLAGS="-j ${CORES}"
fi

if [[ "${CONFIG}" == "release" ]]; then
  swift build -c release ${EXTRA_FLAGS}
else
  swift build ${EXTRA_FLAGS}
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
  <key>LSMinimumSystemVersion</key><string>27.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <!-- Library files (A3, A0 D9): a .mlibm directory Finder shows as one file. -->
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>com.ilczuk.mlm.library</string>
      <key>UTTypeDescription</key><string>MLM Library File</string>
      <key>UTTypeConformsTo</key>
      <array>
        <string>com.apple.package</string>
        <string>public.data</string>
      </array>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>public.filename-extension</key>
        <array>
          <string>mlibm</string>
        </array>
      </dict>
    </dict>
  </array>
  <!-- TODO(B1): dedicated .mlibm document icon; until then macOS derives one from the app icon. -->
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>MLM Library File</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Owner</string>
      <key>LSTypeIsPackage</key><true/>
      <key>LSItemContentTypes</key>
      <array>
        <string>com.ilczuk.mlm.library</string>
      </array>
    </dict>
  </array>
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

# Copy SPM resource bundle and YAMNet model into the app bundle
SPM_BUNDLE_PATH="${APP_ROOT}/.build/out/Products/${CONFIG^}/MLM_MLM.bundle"
if [[ -d "${SPM_BUNDLE_PATH}" ]]; then
  echo "› installing SPM resource bundle"
  rm -rf "${APP_BUNDLE}/Contents/Resources/MLM_MLM.bundle"
  cp -R "${SPM_BUNDLE_PATH}" "${APP_BUNDLE}/Contents/Resources/MLM_MLM.bundle"

  # The Bundle.module accessor SwiftPM generates for executable targets resolves
  # the bundle at Bundle.main.bundleURL (the .app top level) and only otherwise
  # via the absolute .build path baked in at compile time — it never looks in
  # Contents/Resources. Without this copy an installed app fatalErrors at launch
  # as soon as the .build directory from build time disappears.
  rm -rf "${APP_BUNDLE}/MLM_MLM.bundle"
  cp -R "${SPM_BUNDLE_PATH}" "${APP_BUNDLE}/MLM_MLM.bundle"
  
  # Also copy YAMNet.mlmodelc directly to Resources for Bundle.main access
  if [[ -d "${SPM_BUNDLE_PATH}/YAMNet.mlmodelc" ]]; then
    echo "› installing YAMNet.mlmodelc to Resources"
    rm -rf "${APP_BUNDLE}/Contents/Resources/YAMNet.mlmodelc"
    cp -R "${SPM_BUNDLE_PATH}/YAMNet.mlmodelc" "${APP_BUNDLE}/Contents/Resources/"
  fi
fi

# --- Auth helper (mlm-auth) -------------------------------------------------
# The app delegates ALL keychain access to this helper binary, so it must be
# installed into the bundle's MacOS/ dir — the app locates it via
# Bundle.main.url(forAuxiliaryExecutable: "mlm-auth"). Sign it with the
# stable "MLM Dev" identity when available (a one-time keychain "Always
# Allow" then survives app rebuilds — see scripts/setup-dev-signing.sh);
# otherwise fall back to ad-hoc so the flow keeps working with no setup.
# This MUST happen before the final .app signing step below.
HELPER_BIN=".build/out/Products/${CONFIG^}/mlm-auth"
if [[ -f "${HELPER_BIN}" ]]; then
  cp "${HELPER_BIN}" "${APP_BUNDLE}/Contents/MacOS/mlm-auth"
  chmod +x "${APP_BUNDLE}/Contents/MacOS/mlm-auth"
  if security find-identity -v -p codesigning 2>/dev/null | grep -q '"MLM Dev"'; then
    echo "› signing mlm-auth with stable identity 'MLM Dev'"
    codesign --force --sign "MLM Dev" "${APP_BUNDLE}/Contents/MacOS/mlm-auth" 2>/dev/null || true
  else
    echo "› signing mlm-auth ad-hoc (run scripts/setup-dev-signing.sh for a stable identity)"
    codesign --force --sign - "${APP_BUNDLE}/Contents/MacOS/mlm-auth" 2>/dev/null || true
  fi
else
  echo "⚠ mlm-auth helper not found at ${HELPER_BIN} — token storage will be unavailable until it is built"
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
