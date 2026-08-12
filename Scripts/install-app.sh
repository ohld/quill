#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="${HOME}/Applications/Quill.app"
BINARY="${APP_DIR}/Contents/MacOS/quill"
LICENSE_DIR="${APP_DIR}/Contents/Resources/Licenses"

cd "${REPO_DIR}"
swift build -c release

# Stop a previous login item before replacing its executable. The install
# command below bootstraps the updated copy again.
launchctl bootout "gui/$(id -u)" \
    "${HOME}/Library/LaunchAgents/com.ohld.quill.plist" 2>/dev/null || true

mkdir -p "${APP_DIR}/Contents/MacOS" "${LICENSE_DIR}"
# Some upstream license files are read-only. `cp` preserves that mode on the
# first install, so make existing bundle copies writable before refreshing an
# in-place app installation.
chmod u+w "${LICENSE_DIR}"/* 2>/dev/null || true
cp "${REPO_DIR}/.build/release/quill" "${BINARY}"
cp "${REPO_DIR}/Packaging/Info.plist" "${APP_DIR}/Contents/Info.plist"
cp "${REPO_DIR}/LICENSE" "${LICENSE_DIR}/Quill-MIT.txt"
cp "${REPO_DIR}/COPYRIGHT" "${LICENSE_DIR}/COPYRIGHT.txt"
cp "${REPO_DIR}/THIRD_PARTY_NOTICES.md" "${LICENSE_DIR}/THIRD_PARTY_NOTICES.md"
cp "${REPO_DIR}/MODEL_NOTICES.md" "${LICENSE_DIR}/MODEL_NOTICES.md"
cp "${REPO_DIR}/.build/checkouts/FluidAudio/LICENSE" \
    "${LICENSE_DIR}/FluidAudio-Apache-2.0.txt"
cp "${REPO_DIR}/.build/checkouts/FluidAudio/ThirdPartyLicenses/fastcluster-LICENSE.md" \
    "${LICENSE_DIR}/fastcluster-BSD-2-Clause.md"
cp "${REPO_DIR}/.build/checkouts/FluidAudio/ThirdPartyLicenses/vbx-LICENSE.md" \
    "${LICENSE_DIR}/VBx-Apache-2.0.md"
cp "${REPO_DIR}/.build/checkouts/swift-argument-parser/LICENSE.txt" \
    "${LICENSE_DIR}/Swift-Argument-Parser-Apache-2.0-with-Swift-exception.txt"
cp "${REPO_DIR}/ThirdParty/Lucide-LICENSE.txt" \
    "${LICENSE_DIR}/Lucide-ISC-and-Feather-MIT.txt"
chmod 644 "${LICENSE_DIR}"/*
chmod 755 "${BINARY}"
codesign --force --deep --sign - --identifier com.ohld.quill "${APP_DIR}"

"${BINARY}" install --launch-at-login
"${BINARY}" doctor
printf 'Installed %s\n' "${APP_DIR}"
