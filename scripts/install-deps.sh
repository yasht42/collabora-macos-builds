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

echo "==> Installing required Python packages (lxml, polib)..."
python3 -m pip install --upgrade --break-system-packages lxml polib || \
  pip3 install --upgrade --break-system-packages lxml polib

# Ensure Homebrew gnu-make (gmake) and pkg-config are prioritized in PATH
BREW_PREFIX="$(brew --prefix)"
echo "==> Homebrew prefix: ${BREW_PREFIX}"

if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "${BREW_PREFIX}/opt/make/libexec/gnubin" >> "${GITHUB_PATH}"
  echo "${BREW_PREFIX}/opt/libtool/libexec/gnubin" >> "${GITHUB_PATH}"
  echo "${BREW_PREFIX}/bin" >> "${GITHUB_PATH}"
fi

echo "==> Dependency installation complete."
