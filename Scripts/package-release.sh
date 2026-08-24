#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="${1:-${REPO_DIR}/dist}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "${REPO_DIR}/Packaging/Info.plist")"

if ! [[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'Release version must use MAJOR.MINOR.PATCH: %s\n' "${VERSION}" >&2
    exit 65
fi

mkdir -p "${DIST_DIR}"
STAGE="$(mktemp -d)"
trap '/bin/rm -R "${STAGE}"' EXIT
APP="${STAGE}/Quill.app"

"${REPO_DIR}/Scripts/build-app.sh" "${APP}"
ARCH="$(lipo -archs "${APP}/Contents/MacOS/quill" | tr ' ' '-')"
ASSET="Quill-${ARCH}.zip"
ARCHIVE="${DIST_DIR}/${ASSET}"

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "${APP}" "${ARCHIVE}"
VERIFY_DIR="${STAGE}/verify"
mkdir -p "${VERIFY_DIR}"
/usr/bin/ditto -x -k "${ARCHIVE}" "${VERIFY_DIR}"
codesign --verify --deep --strict --verbose=2 "${VERIFY_DIR}/Quill.app"

test -x "${VERIFY_DIR}/Quill.app/Contents/MacOS/quill"
test -f "${VERIFY_DIR}/Quill.app/Contents/Resources/AppIcon.icns"
test -f "${VERIFY_DIR}/Quill.app/Contents/Resources/Licenses/Quill-MIT.txt"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "${VERIFY_DIR}/Quill.app/Contents/Info.plist")" = "${VERSION}"

(cd "${DIST_DIR}" && shasum -a 256 "${ASSET}" > SHA256SUMS.txt)
printf 'Packaged Quill %s (%s): %s\n' "${VERSION}" "${ARCH}" "${ARCHIVE}"
if [ "${QUILL_SIGN_IDENTITY:--}" = "-" ]; then
    printf 'Note: ad-hoc build. Allow first launch in System Settings → Privacy & Security.\n'
fi
