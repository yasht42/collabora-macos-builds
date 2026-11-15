#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SOURCE_DIR="${SOURCE_DIR:-${REPO_ROOT}/collabora-online}"
ENGINE_DIR="${ENGINE_DIR:-${SOURCE_DIR}/engine}"
DISTRO_CONFIG="${DISTRO_CONFIG:-CPMacOS-LOKit}"
VENDOR="${VENDOR:-Collabora}"
COLLABORA_BUILD_TYPE="${COLLABORA_BUILD_TYPE:-${BUILD_TYPE:-release}}"
# Unset BUILD_TYPE from environment because engine/configure.ac checks `test -n "$BUILD_TYPE"`
# to detect if config_host.mk was accidentally sourced into the shell.
unset BUILD_TYPE
LANGUAGES="${LANGUAGES:-without-lang}"
PACKAGE_FORMAT="${PACKAGE_FORMAT:-}"
PARALLEL_JOBS="${PARALLEL_JOBS:-$(sysctl -n hw.logicalcpu)}"

if [[ ! -d "${ENGINE_DIR}" ]]; then
  echo "Error: Engine directory not found at '${ENGINE_DIR}'." >&2
  echo "Make sure the Collabora monorepo (or core repository) was cloned properly." >&2
  exit 1
fi

BREW_PREFIX="$(brew --prefix)"
export PATH="${BREW_PREFIX}/opt/make/libexec/gnubin:${BREW_PREFIX}/bin:${PATH}"
export PKG_CONFIG="${BREW_PREFIX}/bin/pkg-config"
export GNUMAKE="${BREW_PREFIX}/bin/gmake"
export PYTHON="${BREW_PREFIX}/bin/python3"

# Ensure PYTHON can execute Homebrew's meson script directly
if [[ -f "${BREW_PREFIX}/bin/meson" ]]; then
  if ! "${PYTHON}" "${BREW_PREFIX}/bin/meson" --version >/dev/null 2>&1; then
    MESON_SHEBANG_PY="$(head -n 1 "${BREW_PREFIX}/bin/meson" | sed -e 's/^#!//' -e 's/[[:space:]]*$//')"
    if [[ -x "${MESON_SHEBANG_PY}" ]] && "${MESON_SHEBANG_PY}" "${BREW_PREFIX}/bin/meson" --version >/dev/null 2>&1; then
      export PYTHON="${MESON_SHEBANG_PY}"
    fi
  fi
fi
echo "==> Using PYTHON=${PYTHON}"

# Configure ccache if available
if command -v ccache >/dev/null 2>&1; then
  export CCACHE_DIR="${CCACHE_DIR:-${HOME}/Library/Caches/ccache}"
  export CCACHE_CPP2=yes
  export CCACHE_SLOPPINESS=pch_defines,time_macros
  ccache -M "${CCACHE_MAXSIZE:-10G}" || true
  ccache -s || true
fi

# Determine language flag
if [[ -z "${LANGUAGES}" || "${LANGUAGES}" == "without-lang" || "${LANGUAGES}" == "none" ]]; then
  LANG_FLAG="--without-lang"
else
  LANG_FLAG="--with-lang=${LANGUAGES}"
fi

# Determine build type flags (release is the default when neither debug nor dbgutil is enabled)
case "${COLLABORA_BUILD_TYPE}" in
  release)
    BUILD_TYPE_FLAGS=""
    ;;
  debug)
    BUILD_TYPE_FLAGS=$'--enable-debug\n--enable-symbols'
    ;;
  dbgutil)
    BUILD_TYPE_FLAGS=$'--enable-dbgutil\n--enable-symbols'
    ;;
  *)
    echo "Error: Unsupported COLLABORA_BUILD_TYPE '${COLLABORA_BUILD_TYPE}' (expected release, debug, or dbgutil)" >&2
    exit 1
    ;;
esac

# Optional package format (e.g. dmg)
if [[ -n "${PACKAGE_FORMAT}" ]]; then
  BUILD_TYPE_FLAGS="${BUILD_TYPE_FLAGS}"$'\n'"--with-package-format=${PACKAGE_FORMAT}"
fi

# Enable ccache in autogen.input if installed
if command -v ccache >/dev/null 2>&1; then
  BUILD_TYPE_FLAGS="${BUILD_TYPE_FLAGS}"$'\n'"--enable-ccache"
fi

echo "==> Generating ${ENGINE_DIR}/autogen.input..."
TEMPLATE_FILE="${REPO_ROOT}/config/autogen.input.in"

sed \
  -e "s|PKG_CONFIG=/opt/homebrew/bin/pkg-config|PKG_CONFIG=${PKG_CONFIG}|g" \
  -e "s|GNUMAKE=/opt/homebrew/bin/gmake|GNUMAKE=${GNUMAKE}|g" \
  -e "s|PYTHON=/opt/homebrew/bin/python3|PYTHON=${PYTHON}|g" \
  -e "s|__DISTRO_CONFIG__|${DISTRO_CONFIG}|g" \
  -e "s|__VENDOR__|${VENDOR}|g" \
  -e "s|__LANG_FLAG__|${LANG_FLAG}|g" \
  "${TEMPLATE_FILE}" > "${ENGINE_DIR}/autogen.input.tmp"

# Replace multiline __BUILD_TYPE_FLAGS__
python3 - "${ENGINE_DIR}/autogen.input.tmp" "${ENGINE_DIR}/autogen.input" "${BUILD_TYPE_FLAGS}" <<'EOF'
import sys
src, dst, flags = sys.argv[1], sys.argv[2], sys.argv[3].strip()
with open(src, "r", encoding="utf-8") as f:
    content = f.read()
content = content.replace("__BUILD_TYPE_FLAGS__", flags)
with open(dst, "w", encoding="utf-8") as f:
    f.write(content)
EOF
rm -f "${ENGINE_DIR}/autogen.input.tmp"

echo "----- engine/autogen.input -----"
cat "${ENGINE_DIR}/autogen.input"
echo "--------------------------------"

cd "${ENGINE_DIR}"

echo "==> Running ./autogen.sh in ${ENGINE_DIR}..."
./autogen.sh

echo "==> Fetching external tarballs..."
"${GNUMAKE}" fetch

echo "==> Building Collabora Office Engine (${PARALLEL_JOBS} parallel jobs)..."
"${GNUMAKE}" -j"${PARALLEL_JOBS}"

if command -v ccache >/dev/null 2>&1; then
  echo "==> ccache statistics after build:"
  ccache -s || true
fi

echo "==> Checking built application bundle in ${ENGINE_DIR}/instdir..."
APP_BUNDLE="$(find "${ENGINE_DIR}/instdir" -maxdepth 2 -name "*.app" | head -n 1 || true)"
if [[ -z "${APP_BUNDLE}" ]]; then
  echo "Error: No .app bundle found under ${ENGINE_DIR}/instdir" >&2
  ls -la "${ENGINE_DIR}/instdir" || true
  exit 1
fi

echo "==> Successfully built core application bundle: ${APP_BUNDLE}"
