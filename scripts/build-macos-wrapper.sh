#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SOURCE_DIR="${SOURCE_DIR:-${REPO_ROOT}/collabora-online}"
APP_NAME="${APP_NAME:-Collabora Office}"
APP_PACKAGE_NAME="${APP_PACKAGE_NAME:-com.collabora.office}"
VENDOR="${VENDOR:-Collabora}"
COLLABORA_BUILD_TYPE="${COLLABORA_BUILD_TYPE:-${BUILD_TYPE:-release}}"
unset BUILD_TYPE
PARALLEL_JOBS="${PARALLEL_JOBS:-$(sysctl -n hw.logicalcpu)}"

BREW_PREFIX="$(brew --prefix)"
export PATH="${BREW_PREFIX}/opt/make/libexec/gnubin:${BREW_PREFIX}/opt/libtool/libexec/gnubin:${BREW_PREFIX}/bin:${PATH}"
export PKG_CONFIG="${BREW_PREFIX}/bin/pkg-config"
export GNUMAKE="${BREW_PREFIX}/bin/gmake"
export PYTHON="${BREW_PREFIX}/bin/python3"

cd "${SOURCE_DIR}"

echo "==> Running top-level ./autogen.sh in ${SOURCE_DIR}..."
./autogen.sh

# Locate the built engine .app bundle so we can pass --with-lo-path=<...>.app
# On macOS, engine/ builds into engine/instdir/<AppName>.app/Contents/Frameworks/libmergedlo.dylib.
# Top-level configure appends /Contents/Frameworks to --with-lo-path, so when --with-lo-path is omitted
# on release tags (which default to $(pwd)/engine/instdir), it looks in engine/instdir/Contents/Frameworks
# instead of engine/instdir/<AppName>.app/Contents/Frameworks.
ENGINE_APP_BUNDLE="$(find "${SOURCE_DIR}/engine/instdir" -maxdepth 2 -name "*.app" -type d | head -n 1 || true)"
if [[ -z "${ENGINE_APP_BUNDLE}" ]]; then
  echo "Error: No .app bundle found under ${SOURCE_DIR}/engine/instdir" >&2
  exit 1
fi
echo "==> Detected built engine .app bundle: ${ENGINE_APP_BUNDLE}"

# Also create convenience symlinks in engine/instdir/Contents/... -> <AppName>.app/Contents/...
# in case any Makefile or Xcode build phase hardcodes $(abs_top_builddir)/engine/instdir/Contents
if [[ -d "${ENGINE_APP_BUNDLE}/Contents" && ! -e "${SOURCE_DIR}/engine/instdir/Contents" ]]; then
  ln -s "$(basename "${ENGINE_APP_BUNDLE}")/Contents" "${SOURCE_DIR}/engine/instdir/Contents"
fi

CONFIGURE_FLAGS=(
  --enable-macosapp
  --enable-experimental
  --with-app-name="${APP_NAME}"
  --with-app-package-name="${APP_PACKAGE_NAME}"
  --with-vendor="${VENDOR}"
  --with-lo-path="${ENGINE_APP_BUNDLE}"
)

if [[ "${COLLABORA_BUILD_TYPE}" == "debug" || "${COLLABORA_BUILD_TYPE}" == "dbgutil" ]]; then
  CONFIGURE_FLAGS+=(--enable-debug)
fi

echo "==> Configuring Collabora Office macOS desktop app (web-based frontend + LOKit)..."
./configure "${CONFIGURE_FLAGS[@]}"

echo "==> Building browser/ web frontend (JavaScript/CSS bundle) and common targets..."
"${GNUMAKE}" -j"${PARALLEL_JOBS}"

XCODE_CONFIG="Release"
if [[ "${COLLABORA_BUILD_TYPE}" == "debug" || "${COLLABORA_BUILD_TYPE}" == "dbgutil" ]]; then
  XCODE_CONFIG="Debug"
fi

MACOS_OUT_DIR="${SOURCE_DIR}/macos/out"
rm -rf "${MACOS_OUT_DIR}"
mkdir -p "${MACOS_OUT_DIR}"

echo "==> Building macOS native CODA application bundle (make -C macos app)..."
if ! "${GNUMAKE}" -C macos app; then
  echo "==> 'make -C macos app' failed (often due to missing Xcode Team provisioning in CI); retrying via xcodebuild with unsigned build settings..."
  xcodebuild \
    -project "${SOURCE_DIR}/macos/coda/coda.xcodeproj" \
    -scheme coda \
    -configuration "${XCODE_CONFIG}" \
    -derivedDataPath "${SOURCE_DIR}/macos/DerivedData" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    build
fi

# Locate the produced CODA .app bundle from macos/ or Xcode DerivedData
FOUND_APP="$(find "${SOURCE_DIR}/macos" -name "*.app" -type d | grep -v "/out/" | head -n 1 || true)"
if [[ -z "${FOUND_APP}" && -d "${HOME}/Library/Developer/Xcode/DerivedData" ]]; then
  FOUND_APP="$(find "${HOME}/Library/Developer/Xcode/DerivedData" -path "*coda*/Build/Products/*.app" -type d | head -n 1 || true)"
fi

if [[ -z "${FOUND_APP}" || ! -d "${FOUND_APP}" ]]; then
  echo "Error: Could not find built macOS CODA .app bundle after building macos/" >&2
  exit 1
fi

echo "==> Staging built web-based macOS app (${FOUND_APP}) to ${MACOS_OUT_DIR}..."
ditto "${FOUND_APP}" "${MACOS_OUT_DIR}/$(basename "${FOUND_APP}")"

echo "==> macOS web-based desktop app build complete: ${MACOS_OUT_DIR}/$(basename "${FOUND_APP}")"
