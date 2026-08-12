#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="${HOME}/Applications/Quill.app"
BINARY="${APP_DIR}/Contents/MacOS/quill"

cd "${REPO_DIR}"
swift build -c release

# Stop a previous login item before replacing its executable. The install
# command below bootstraps the updated copy again.
launchctl bootout "gui/$(id -u)" \
    "${HOME}/Library/LaunchAgents/com.ohld.quill.plist" 2>/dev/null || true

mkdir -p "${APP_DIR}/Contents/MacOS"
cp "${REPO_DIR}/.build/release/quill" "${BINARY}"
cp "${REPO_DIR}/Packaging/Info.plist" "${APP_DIR}/Contents/Info.plist"
chmod 755 "${BINARY}"
codesign --force --deep --sign - --identifier com.ohld.quill "${APP_DIR}"

"${BINARY}" install --launch-at-login
"${BINARY}" doctor
printf 'Installed %s\n' "${APP_DIR}"
