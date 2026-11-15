#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SOURCE_DIR="${SOURCE_DIR:-${REPO_ROOT}/collabora-online}"
APP_NAME="${APP_NAME:-Collabora Office}"
APP_PACKAGE_NAME="${APP_PACKAGE_NAME:-com.collabora.office}"
VENDOR="${VENDOR:-Collabora}"
BUILD_TYPE="${BUILD_TYPE:-release}"
PARALLEL_JOBS="${PARALLEL_JOBS:-$(sysctl -n hw.logicalcpu)}"

BREW_PREFIX="$(brew --prefix)"
export PATH="${BREW_PREFIX}/opt/make/libexec/gnubin:${BREW_PREFIX}/opt/libtool/libexec/gnubin:${BREW_PREFIX}/bin:${PATH}"
export PKG_CONFIG="${BREW_PREFIX}/bin/pkg-config"
export GNUMAKE="${BREW_PREFIX}/bin/gmake"

cd "${SOURCE_DIR}"

echo "==> Running top-level ./autogen.sh in ${SOURCE_DIR}..."
./autogen.sh

CONFIGURE_FLAGS=(
  --enable-macosapp
  --enable-experimental
  --with-app-name="${APP_NAME}"
  --with-app-package-name="${APP_PACKAGE_NAME}"
  --with-vendor="${VENDOR}"
)

if [[ "${BUILD_TYPE}" == "debug" || "${BUILD_TYPE}" == "dbgutil" ]]; then
  CONFIGURE_FLAGS+=(--enable-debug)
fi

echo "==> Configuring Collabora Office macOS desktop app (web-based frontend + LOKit)..."
./configure "${CONFIGURE_FLAGS[@]}"

echo "==> Building browser/ web frontend (JavaScript/CSS bundle) and common targets..."
"${GNUMAKE}" -j"${PARALLEL_JOBS}"

XCODE_CONFIG="Release"
if [[ "${BUILD_TYPE}" == "debug" || "${BUILD_TYPE}" == "dbgutil" ]]; then
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
