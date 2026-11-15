#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SOURCE_DIR="${SOURCE_DIR:-${REPO_ROOT}/collabora-online}"
ENGINE_DIR="${ENGINE_DIR:-${SOURCE_DIR}/engine}"
OUTPUT_DIR="${OUTPUT_DIR:-${REPO_ROOT}/dist}"
VERSION_TAG="${VERSION_TAG:-dev}"
ARCH="${ARCH:-arm64}"
BUILD_MACOS_WRAPPER="${BUILD_MACOS_WRAPPER:-true}"

mkdir -p "${OUTPUT_DIR}"

# Locate the built .app bundle
APP_BUNDLE=""
if [[ "${BUILD_MACOS_WRAPPER}" == "true" ]]; then
  if [[ -d "${SOURCE_DIR}/macos/out" ]]; then
    APP_BUNDLE="$(find "${SOURCE_DIR}/macos/out" -maxdepth 2 -name "*.app" -type d | head -n 1 || true)"
  fi
  if [[ -z "${APP_BUNDLE}" && -d "${SOURCE_DIR}/macos" ]]; then
    APP_BUNDLE="$(find "${SOURCE_DIR}/macos" -name "*.app" -type d | head -n 1 || true)"
  fi
  if [[ -z "${APP_BUNDLE}" ]]; then
    echo "Error: BUILD_MACOS_WRAPPER=true, but no built .app bundle was found under ${SOURCE_DIR}/macos." >&2
    exit 1
  fi
else
  APP_BUNDLE="$(find "${ENGINE_DIR}/instdir" -maxdepth 2 -name "*.app" -type d | head -n 1 || true)"
fi

if [[ -z "${APP_BUNDLE}" || ! -d "${APP_BUNDLE}" ]]; then
  echo "Error: Could not find built .app bundle to package." >&2
  exit 1
fi

APP_BASENAME="$(basename "${APP_BUNDLE}")"
STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/collabora-pkg.XXXXXX")"
STAGED_APP="${STAGE_DIR}/${APP_BASENAME}"

cleanup() {
  rm -rf "${STAGE_DIR}"
  if [[ -n "${KEYCHAIN_PATH:-}" && -f "${KEYCHAIN_PATH}" ]]; then
    security delete-keychain "${KEYCHAIN_PATH}" || true
  fi
}
trap cleanup EXIT

echo "==> Copying ${APP_BUNDLE} to staging directory ${STAGED_APP}..."
ditto "${APP_BUNDLE}" "${STAGED_APP}"

# Determine whether Developer ID signing secrets are configured
SIGNED_WITH_DEV_ID="false"
if [[ -n "${MACOS_CERTIFICATE_P12:-}" && -n "${MACOS_CERTIFICATE_PASSWORD:-}" ]]; then
  echo "==> Developer ID certificate detected in environment. Setting up temporary keychain..."
  KEYCHAIN_PASSWORD="$(uuidgen)"
  KEYCHAIN_PATH="${STAGE_DIR}/build-signing.keychain-db"
  CERT_PATH="${STAGE_DIR}/certificate.p12"

  echo "${MACOS_CERTIFICATE_P12}" | base64 --decode > "${CERT_PATH}"

  security create-keychain -p "${KEYCHAIN_PASSWORD}" "${KEYCHAIN_PATH}"
  security set-keychain-settings -lut 21600 "${KEYCHAIN_PATH}"
  security unlock-keychain -p "${KEYCHAIN_PASSWORD}" "${KEYCHAIN_PATH}"
  security import "${CERT_PATH}" -P "${MACOS_CERTIFICATE_PASSWORD}" -A -t cert -f pkcs12 -k "${KEYCHAIN_PATH}"
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "${KEYCHAIN_PASSWORD}" "${KEYCHAIN_PATH}"
  security list-keychains -d user -s "${KEYCHAIN_PATH}" $(security list-keychains -d user | tr -d '"')

  SIGNING_IDENTITY="${APPLE_SIGNING_IDENTITY:-}"
  if [[ -z "${SIGNING_IDENTITY}" ]]; then
    SIGNING_IDENTITY="$(security find-identity -v -p codesigning "${KEYCHAIN_PATH}" | head -n 1 | awk -F '"' '{print $2}' || true)"
  fi

  if [[ -z "${SIGNING_IDENTITY}" ]]; then
    echo "Error: Could not find a valid codesigning identity in imported certificate." >&2
    exit 1
  fi

  echo "==> Signing ${APP_BASENAME} with identity: ${SIGNING_IDENTITY}"
  codesign --force --deep --options runtime --timestamp --sign "${SIGNING_IDENTITY}" "${STAGED_APP}"
  SIGNED_WITH_DEV_ID="true"
else
  echo "==> No Developer ID certificate provided; applying ad-hoc signature for Apple Silicon compatibility..."
  codesign --force --deep --sign - "${STAGED_APP}"
fi

echo "==> Verifying code signature on ${STAGED_APP}..."
codesign --verify --deep --strict --verbose=2 "${STAGED_APP}"

ARTIFACT_PREFIX="CollaboraOffice-${VERSION_TAG}-macOS-${ARCH}"
ZIP_PATH="${OUTPUT_DIR}/${ARTIFACT_PREFIX}.app.zip"
DMG_PATH="${OUTPUT_DIR}/${ARTIFACT_PREFIX}.dmg"

echo "==> Creating .app.zip archive at ${ZIP_PATH}..."
rm -f "${ZIP_PATH}"
ditto -c -k --sequesterRsrc --keepParent "${STAGED_APP}" "${ZIP_PATH}"

# Check if engine already produced a .dmg inside workdir/installation (only when packaging engine-only), otherwise build one from STAGED_APP
EXISTING_DMG=""
if [[ "${BUILD_MACOS_WRAPPER}" != "true" ]]; then
  EXISTING_DMG="$(find "${ENGINE_DIR}/workdir/installation" -name "*.dmg" -type f 2>/dev/null | head -n 1 || true)"
fi
if [[ -n "${EXISTING_DMG}" && "${SIGNED_WITH_DEV_ID}" == "false" ]]; then
  echo "==> Found engine-generated DMG (${EXISTING_DMG}); copying to ${DMG_PATH}..."
  cp -f "${EXISTING_DMG}" "${DMG_PATH}"
else
  echo "==> Creating DMG installer at ${DMG_PATH}..."
  rm -f "${DMG_PATH}"
  DMG_SRC_DIR="${STAGE_DIR}/dmg-root"
  mkdir -p "${DMG_SRC_DIR}"
  ditto "${STAGED_APP}" "${DMG_SRC_DIR}/${APP_BASENAME}"
  ln -s /Applications "${DMG_SRC_DIR}/Applications"

  hdiutil create \
    -volname "Collabora Office" \
    -srcfolder "${DMG_SRC_DIR}" \
    -ov \
    -format UDZO \
    "${DMG_PATH}"
fi

if [[ "${SIGNED_WITH_DEV_ID}" == "true" ]]; then
  echo "==> Signing DMG with Developer ID..."
  codesign --force --timestamp --sign "${SIGNING_IDENTITY}" "${DMG_PATH}"

  if [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]]; then
    echo "==> Submitting ${DMG_PATH} for Apple Notarization..."
    xcrun notarytool submit "${DMG_PATH}" \
      --apple-id "${APPLE_ID}" \
      --team-id "${APPLE_TEAM_ID}" \
      --password "${APPLE_APP_SPECIFIC_PASSWORD}" \
      --wait

    echo "==> Stapling notarization ticket to ${DMG_PATH}..."
    xcrun stapler staple "${DMG_PATH}"
  else
    echo "==> Skipping notarization (APPLE_ID / APPLE_TEAM_ID / APPLE_APP_SPECIFIC_PASSWORD not set)."
  fi
fi

echo "==> Generating SHA256 checksums..."
(
  cd "${OUTPUT_DIR}"
  shasum -a 256 *.dmg *.zip > SHA256SUMS.txt
  cat SHA256SUMS.txt
)

echo "==> Packaging complete! Artifacts in ${OUTPUT_DIR}:"
ls -lh "${OUTPUT_DIR}"
