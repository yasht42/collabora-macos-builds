# Collabora Office macOS Builds (GitHub Action)

Automated GitHub Action and CI/CD workflow for building, signing, packaging, and releasing **Collabora Office for macOS** (the modern **web-based frontend / CODA desktop app** powered by the `engine/` LibreOfficeKit core) for **Apple Silicon macOS (`arm64`)**.

## Overview

This repository provides:
1. **A Standalone Release Workflow** ([`.github/workflows/build-macos.yml`](.github/workflows/build-macos.yml)) that runs on GitHub's `macos-15` (`arm64`) runners, compiles the LOKit `engine/`, builds the `browser/` web frontend and native `macos/coda` application wrapper, packages `.dmg` and `.app.zip` installers with SHA-256 checksums, and publishes them to **GitHub Releases**.
2. **A Reusable Composite GitHub Action** ([`action.yml`](action.yml)) so other repositories or workflows can invoke the build pipeline directly.
3. **Modular Build & Packaging Scripts** ([`scripts/`](scripts/)) that can also be run locally on any Apple Silicon Mac.

---

## Repository Structure

```text
.
├── .github/
│   └── workflows/
│       └── build-macos.yml        # CI/CD workflow: builds & creates GitHub Releases
├── action.yml                     # Reusable composite GitHub Action definition
├── config/
│   └── autogen.input.in           # Template for engine/autogen.input (CPMacOS-LOKit)
├── scripts/
│   ├── install-deps.sh            # Installs Homebrew packages & Python modules (lxml, polib)
│   ├── build-engine.sh            # Configures & compiles Collabora core in engine/
│   ├── build-macos-wrapper.sh     # Optional: builds the outer macos/ CODA desktop wrapper
│   └── package-macos.sh           # Code-signs (Developer ID or ad-hoc), notarizes, and creates .dmg/.zip
└── README.md
```

---

## Triggering a Build & Release

### 1. Automatic Upstream Tag Polling (`schedule`)
Every 6 hours (`0 */6 * * *`), a lightweight `check-upstream` job runs on `ubuntu-latest` and queries `https://gerrit.collaboraoffice.com/online` for the latest stable `cp-*` release tag (`25.04` and newer, matching `^cp-(2[5-9]|[3-9][0-9])\.[0-9]+\.[0-9]+-[0-9]+$`).
- If a GitHub Release for that tag already exists in this repository, the workflow exits in seconds without spinning up a macOS runner.
- If a new upstream tag is detected, it automatically triggers the `macos-15` (`arm64`) build job against that exact upstream tag and publishes a matching GitHub Release.

### 2. Automatic Tag Push (`v*` or `cp-*`)
Push any Git tag starting with `v` or `cp-` (for example, `cp-25.04.2-1` or `v25.04.1`):
```bash
git tag cp-25.04.2-1
git push origin cp-25.04.2-1
```
The workflow will automatically build Collabora Office for macOS (`arm64`) (checking out the matching `cp-*` tag upstream when pushed with a `cp-*` tag) and publish a GitHub Release attached to that tag containing:
- `CollaboraOffice-<version>-macOS-arm64.dmg`
- `CollaboraOffice-<version>-macOS-arm64.app.zip`
- `SHA256SUMS.txt`

### 3. Manual Trigger (`workflow_dispatch`)
Navigate to **Actions → Build & Release Collabora Office macOS (arm64) → Run workflow** and customize:
- **`ref`**: Branch, tag, or commit in `https://gerrit.collaboraoffice.com/online` (default: `main`)
- **`distro_config`**: Engine distribution config under `engine/distro-configs/` (default: `CPMacOS-LOKit`)
- **`build_type`**: `release`, `debug`, or `dbgutil` (default: `release`)
- **`languages`**: Space-separated language list or `without-lang` (default: `without-lang`)
- **`build_macos_wrapper`**: Build the top-level web-based macOS desktop app (`browser/` JS frontend + `macos/coda` wrapper) after `engine/` completes (default: `true`)
- **`create_release`**: Publish a GitHub Release when the build finishes (default: `true`)
- **`release_tag`**: Custom tag name for the GitHub Release (defaults to `vYYYY.MM.DD-build.<run_number>`)

---

## Code Signing & Notarization (Optional Secrets)

By default, if no signing secrets are configured in the repository, [`scripts/package-macos.sh`](scripts/package-macos.sh) automatically applies an **ad-hoc code signature** (`codesign --force --deep --sign -`), which is required for arm64 binaries to execute on Apple Silicon macOS.

To enable **Apple Developer ID Application signing** and **Apple Notarization**, add the following optional secrets under **Settings → Secrets and variables → Actions**:

| Secret Name | Required For | Description |
| :--- | :--- | :--- |
| `MACOS_CERTIFICATE_P12` | Code Signing | Base64-encoded `.p12` Developer ID Application certificate (`base64 -i cert.p12 \| pbcopy`) |
| `MACOS_CERTIFICATE_PASSWORD` | Code Signing | Password used when exporting the `.p12` certificate |
| `APPLE_SIGNING_IDENTITY` | Code Signing *(optional)* | Explicit identity string (e.g. `Developer ID Application: Your Name (TEAMID)`). Auto-detected from `.p12` if omitted. |
| `APPLE_ID` | Notarization *(optional)* | Apple ID email address for `xcrun notarytool` |
| `APPLE_TEAM_ID` | Notarization *(optional)* | 10-character Apple Developer Team ID |
| `APPLE_APP_SPECIFIC_PASSWORD` | Notarization *(optional)* | App-specific password generated at `appleid.apple.com` |

---

## Local Usage on macOS (Apple Silicon)

You can run the exact same pipeline locally on an Apple Silicon Mac:

```bash
# 1. Install Homebrew & Python prerequisites
./scripts/install-deps.sh

# 2. Clone the Collabora monorepo
git clone --depth 1 https://gerrit.collaboraoffice.com/online collabora-online

# 3. Configure and build the Collabora Office LOKit engine (engine/instdir/CollaboraOffice.app)
./scripts/build-engine.sh

# 4. Build the web-based frontend (browser/) and native macOS CODA desktop app (macos/out/*.app)
./scripts/build-macos-wrapper.sh

# 5. Package into dist/*.dmg and dist/*.app.zip (with ad-hoc or Developer ID signing)
VERSION_TAG="local" ./scripts/package-macos.sh
```
