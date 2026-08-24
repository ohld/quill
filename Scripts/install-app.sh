#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="${HOME}/Applications/Quill.app"
BINARY="${APP_DIR}/Contents/MacOS/quill"
SERVICE="gui/$(id -u)/com.ohld.quill"

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

QUILL_SKIP_SWIFT_BUILD=1 QUILL_STABLE_LOCAL_IDENTITY=1 \
    "${REPO_DIR}/Scripts/build-app.sh" "${APP_DIR}"

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
