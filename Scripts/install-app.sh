#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="${HOME}/Applications/Quill.app"
BINARY="${APP_DIR}/Contents/MacOS/quill"
LICENSE_DIR="${APP_DIR}/Contents/Resources/Licenses"
ICON_FILE="${APP_DIR}/Contents/Resources/AppIcon.icns"
SERVICE="gui/$(id -u)/com.ohld.quill"
PLIST="${HOME}/Library/LaunchAgents/com.ohld.quill.plist"

cd "${REPO_DIR}"
swift build -c release

# Updates must not remove/re-add the login item: macOS otherwise announces a
# new background item on every local build. Stop the registered job cleanly,
# keep its registration, replace the bundle, then kickstart the same job.
SERVICE_REGISTERED=false
if launchctl print "${SERVICE}" >/dev/null 2>&1; then
    SERVICE_REGISTERED=true
    ACTIVE_PID="$(pgrep -f "^${BINARY} run$" | head -1 || true)"
    if [ -n "${ACTIVE_PID}" ] && lsof -p "${ACTIVE_PID}" 2>/dev/null \
        | grep -Eq '\.(caf|wav|m4a)$'; then
        printf 'Refusing to update while Quill is recording. Stop the recording first.\n' >&2
        exit 75
    fi
    launchctl kill SIGTERM "${SERVICE}" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        [ -z "${ACTIVE_PID}" ] || ! kill -0 "${ACTIVE_PID}" 2>/dev/null && break
        sleep 1
    done
    if [ -n "${ACTIVE_PID}" ] && kill -0 "${ACTIVE_PID}" 2>/dev/null; then
        printf 'Quill did not stop cleanly; leaving the installed app untouched.\n' >&2
        exit 76
    fi
fi

mkdir -p "${APP_DIR}/Contents/MacOS" "${LICENSE_DIR}"
# Some upstream license files are read-only. `cp` preserves that mode on the
# first install, so make existing bundle copies writable before refreshing an
# in-place app installation.
chmod u+w "${LICENSE_DIR}"/* 2>/dev/null || true
cp "${REPO_DIR}/.build/release/quill" "${BINARY}"
cp "${REPO_DIR}/Packaging/Info.plist" "${APP_DIR}/Contents/Info.plist"

# Build a complete macOS icon family from the deterministic vector source.
# Keeping the SVG in git makes future branding edits reviewable while the app
# receives the .icns resource Finder and Launchpad expect.
ICON_TMP="$(mktemp -d)"
ICONSET="${ICON_TMP}/AppIcon.iconset"
mkdir -p "${ICONSET}"
for POINTS in 16 32 128 256 512; do
    /usr/bin/sips -s format png -z "${POINTS}" "${POINTS}" \
        "${REPO_DIR}/Packaging/AppIcon.svg" \
        --out "${ICONSET}/icon_${POINTS}x${POINTS}.png" >/dev/null
    PIXELS=$((POINTS * 2))
    /usr/bin/sips -s format png -z "${PIXELS}" "${PIXELS}" \
        "${REPO_DIR}/Packaging/AppIcon.svg" \
        --out "${ICONSET}/icon_${POINTS}x${POINTS}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "${ICONSET}" -o "${ICON_FILE}"
/bin/rm -R "${ICON_TMP}"
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
# Ad-hoc signing normally uses the changing binary hash as the app identity,
# which makes TCC ask for permissions after every build. Pin a stable local
# designated requirement to this bundle identifier instead.
codesign --force --deep --sign - --identifier com.ohld.quill \
    --requirements '=designated => identifier "com.ohld.quill"' "${APP_DIR}"

# Refresh LaunchServices so Finder does not keep the generic icon cached from
# the previous icon-less bundle version.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "${APP_DIR}" >/dev/null 2>&1 || true

if [ "${SERVICE_REGISTERED}" = true ]; then
    launchctl kickstart "${SERVICE}"
    RESTARTED=false
    # A freshly re-signed bundle can remain in launchd's xpcproxy/startup
    # states for longer than five seconds even though it starts successfully.
    # Poll long enough to avoid reporting a false installation failure; the
    # normal path still returns as soon as the service reaches running.
    for _ in {1..20}; do
        if launchctl print "${SERVICE}" 2>/dev/null | grep -q 'state = running'; then
            RESTARTED=true
            break
        fi
        sleep 1
    done
    if [ "${RESTARTED}" = false ]; then
        printf 'Quill LaunchAgent did not restart after update.\n' >&2
        exit 77
    fi
else
    "${BINARY}" install --launch-at-login
fi
"${BINARY}" doctor
printf 'Installed %s\n' "${APP_DIR}"
