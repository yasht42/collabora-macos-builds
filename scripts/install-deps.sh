#!/usr/bin/env bash
set -euo pipefail

echo "==> Checking Xcode & macOS SDK environment..."
xcode-select -p
xcrun --show-sdk-path
sw_vers
uname -m

echo "==> Installing Homebrew dependencies for Collabora Office macOS build..."
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_INSTALL_CLEANUP=1

BREW_PACKAGES=(
  automake
  autoconf
  libtool
  make
  gperf
  meson
  ninja
  pkg-config
  ccache
  create-dmg
  python3
)

brew install "${BREW_PACKAGES[@]}"

BREW_PREFIX="$(brew --prefix)"
echo "==> Homebrew prefix: ${BREW_PREFIX}"

BREW_PYTHON="${BREW_PREFIX}/bin/python3"
echo "==> Installing required Python packages (lxml, polib, meson) into ${BREW_PYTHON}..."
"${BREW_PYTHON}" -m pip install --upgrade --break-system-packages lxml polib meson

# If Homebrew's meson uses an isolated Python formula in its shebang, install lxml & polib there too
if [[ -f "${BREW_PREFIX}/bin/meson" ]]; then
  MESON_PYTHON="$(head -n 1 "${BREW_PREFIX}/bin/meson" | sed -e 's/^#!//' -e 's/[[:space:]]*$//')"
  if [[ -x "${MESON_PYTHON}" && "${MESON_PYTHON}" != "${BREW_PYTHON}" ]]; then
    echo "==> Also ensuring lxml and polib are present in meson's Python (${MESON_PYTHON})..."
    "${MESON_PYTHON}" -m pip install --upgrade --break-system-packages lxml polib || true
  fi
fi

if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "${BREW_PREFIX}/opt/make/libexec/gnubin" >> "${GITHUB_PATH}"
  echo "${BREW_PREFIX}/opt/libtool/libexec/gnubin" >> "${GITHUB_PATH}"
  echo "${BREW_PREFIX}/bin" >> "${GITHUB_PATH}"
fi

echo "==> Dependency installation complete."
