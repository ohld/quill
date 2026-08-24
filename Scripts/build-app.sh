#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="${1:-${REPO_DIR}/dist/Quill.app}"
SIGN_IDENTITY="${QUILL_SIGN_IDENTITY:--}"
STABLE_LOCAL_IDENTITY="${QUILL_STABLE_LOCAL_IDENTITY:-0}"
LICENSE_DIR="${APP_DIR}/Contents/Resources/Licenses"
BINARY="${APP_DIR}/Contents/MacOS/quill"

case "${APP_DIR}" in
    /*/Quill.app) ;;
    *)
        printf 'Output must be an absolute path ending in /Quill.app: %s\n' "${APP_DIR}" >&2
        exit 64
        ;;
esac

cd "${REPO_DIR}"
if [ "${QUILL_SKIP_SWIFT_BUILD:-0}" != "1" ]; then
    swift build -c release
fi

mkdir -p "${APP_DIR}/Contents/MacOS" "${LICENSE_DIR}"
chmod u+w "${LICENSE_DIR}"/* 2>/dev/null || true
cp "${REPO_DIR}/.build/release/quill" "${BINARY}"
cp "${REPO_DIR}/Packaging/Info.plist" "${APP_DIR}/Contents/Info.plist"

ICON_TMP="$(mktemp -d)"
trap '/bin/rm -R "${ICON_TMP}"' EXIT
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
/usr/bin/iconutil -c icns "${ICONSET}" \
    -o "${APP_DIR}/Contents/Resources/AppIcon.icns"

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

if [ "${SIGN_IDENTITY}" = "-" ]; then
    if [ "${STABLE_LOCAL_IDENTITY}" = "1" ]; then
        # Personal source rebuilds opt into the existing stable TCC identity.
        # Public archives deliberately do not use this identifier-only rule.
        codesign --force --deep --sign - --identifier com.ohld.quill \
            --requirements '=designated => identifier "com.ohld.quill"' "${APP_DIR}"
    else
        codesign --force --deep --sign - --identifier com.ohld.quill "${APP_DIR}"
    fi
else
    codesign --force --deep --options runtime --timestamp \
        --entitlements "${REPO_DIR}/Packaging/Quill.entitlements" \
        --sign "${SIGN_IDENTITY}" "${APP_DIR}"
fi

codesign --verify --deep --strict --verbose=2 "${APP_DIR}"
printf 'Built %s\n' "${APP_DIR}"
