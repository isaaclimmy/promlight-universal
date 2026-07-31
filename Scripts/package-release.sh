#!/bin/bash

set -euo pipefail
IFS=$'\n\t'
umask 022
export TZ=UTC

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_PATH="${PROM_LIGHT_APP_PATH:-$PROJECT_ROOT/dist/PromLight.app}"
RELEASE_ROOT="${PROM_LIGHT_RELEASE_DIR:-$PROJECT_ROOT/release}"
INSTALL_TEMPLATE="$PROJECT_ROOT/Packaging/INSTALL.txt.in"
LICENSE_SOURCE="$PROJECT_ROOT/LICENSE"
ARCHIVE_TIMESTAMP="${PROM_LIGHT_ARCHIVE_TIMESTAMP:-202601010000.00}"

die() {
    printf 'package-release: %s\n' "$*" >&2
    exit 1
}

require_tool() {
    command -v "$1" >/dev/null 2>&1 || die "required tool not found: $1"
}

verify_universal_macho_files() {
    local bundle="$1"
    local macho_count=0
    local candidate
    local description
    local architectures
    local architecture_count

    while IFS= read -r -d '' candidate; do
        description="$(file -b "$candidate")"

        case "$description" in
            *Mach-O*)
                macho_count=$((macho_count + 1))
                if LC_ALL=C grep -aFq '/Users/' "$candidate"; then
                    die "local user path found in release executable: $candidate"
                fi
                lipo "$candidate" -verify_arch arm64 x86_64 || \
                    die "missing a required architecture: $candidate"
                architectures="$(lipo -archs "$candidate")"
                architecture_count="$(wc -w <<< "$architectures" | tr -d ' ')"
                [[ "$architecture_count" == "2" ]] || \
                    die "unexpected architecture set for $candidate: $architectures"
                ;;
        esac
    done < <(find "$bundle" -type f -print0)

    [[ "$macho_count" -gt 0 ]] || die "no Mach-O executable found in $bundle"
}

verify_app() {
    local app="$1"
    local signature_info
    local icon_file

    [[ -d "$app" ]] || die "app bundle not found: $app"
    [[ -f "$app/Contents/Info.plist" ]] || die "Info.plist not found in $app"
    icon_file="$(plutil -extract CFBundleIconFile raw "$app/Contents/Info.plist")"
    [[ "$icon_file" == "PromLight.icns" ]] || die "unexpected app icon: $icon_file"
    [[ -f "$app/Contents/Resources/$icon_file" ]] || \
        die "app icon is missing from the bundle: $icon_file"
    [[ "$(file -b "$app/Contents/Resources/$icon_file")" == *"Mac OS X icon"* ]] || \
        die "app icon is not a valid ICNS resource: $icon_file"

    codesign --verify --deep --strict --verbose=4 "$app"
    signature_info="$(codesign -d --verbose=4 "$app" 2>&1)"
    grep -q 'Signature=adhoc' <<< "$signature_info" || \
        die "this preview packager expects an ad-hoc signed app"
    grep -Eq 'flags=.*runtime' <<< "$signature_info" || \
        die "hardened runtime is missing from the app signature"

    verify_universal_macho_files "$app"
}

for tool in codesign lipo plutil ditto shasum sed mktemp file find xattr \
    touch wc tr grep awk cmp; do
    require_tool "$tool"
done

[[ "$(uname -s)" == "Darwin" ]] || die "this packaging script must run on macOS"
[[ -f "$INSTALL_TEMPLATE" ]] || die "missing install template: $INSTALL_TEMPLATE"
[[ -f "$LICENSE_SOURCE" ]] || die "missing license: $LICENSE_SOURCE"
[[ -n "$RELEASE_ROOT" && "$RELEASE_ROOT" != "/" ]] || \
    die "unsafe release directory: $RELEASE_ROOT"
[[ "$ARCHIVE_TIMESTAMP" =~ ^[0-9]{12}\.[0-9]{2}$ ]] || \
    die "PROM_LIGHT_ARCHIVE_TIMESTAMP must use YYYYMMDDhhmm.ss"

verify_app "$APP_PATH"

INFO_PLIST="$APP_PATH/Contents/Info.plist"
VERSION="$(plutil -extract CFBundleShortVersionString raw "$INFO_PLIST")"
MINIMUM_SYSTEM_VERSION="$(plutil -extract LSMinimumSystemVersion raw "$INFO_PLIST")"
EXECUTABLE_NAME="$(plutil -extract CFBundleExecutable raw "$INFO_PLIST")"

[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || die "invalid app version: $VERSION"
[[ "$MINIMUM_SYSTEM_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || \
    die "invalid minimum macOS version: $MINIMUM_SYSTEM_VERSION"
[[ "$EXECUTABLE_NAME" == "PromLight" ]] || \
    die "unexpected executable name: $EXECUTABLE_NAME"

RELEASE_NAME="PromLight-${VERSION}-macos-universal"
ZIP_NAME="$RELEASE_NAME.zip"
CHECKSUM_NAME="$ZIP_NAME.sha256"
FINAL_ZIP="$RELEASE_ROOT/$ZIP_NAME"
FINAL_CHECKSUM="$RELEASE_ROOT/$CHECKSUM_NAME"
FINAL_INSTALL="$RELEASE_ROOT/INSTALL.txt"

mkdir -p "$RELEASE_ROOT"
STAGE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/promlight-release.XXXXXX")"
trap 'rm -rf -- "$STAGE_ROOT"' EXIT

PAYLOAD_ROOT="$STAGE_ROOT/$RELEASE_NAME"
PAYLOAD_APP="$PAYLOAD_ROOT/PromLight.app"
PAYLOAD_INSTALL="$PAYLOAD_ROOT/INSTALL.txt"
PAYLOAD_LICENSE="$PAYLOAD_ROOT/LICENSE"
STAGED_ZIP="$STAGE_ROOT/$ZIP_NAME"
STAGED_CHECKSUM="$STAGE_ROOT/$CHECKSUM_NAME"
STAGED_INSTALL="$STAGE_ROOT/INSTALL.txt"

mkdir -p "$PAYLOAD_ROOT"
/usr/bin/ditto "$APP_PATH" "$PAYLOAD_APP"
/usr/bin/ditto "$LICENSE_SOURCE" "$PAYLOAD_LICENSE"

# Local provenance and quarantine metadata are not part of the release. The
# recipient's browser will apply quarantine to the downloaded ZIP normally.
xattr -cr "$PAYLOAD_APP"

sed \
    -e "s|@VERSION@|$VERSION|g" \
    -e "s|@MINIMUM_SYSTEM_VERSION@|$MINIMUM_SYSTEM_VERSION|g" \
    -e "s|@RELEASE_NAME@|$RELEASE_NAME|g" \
    -e "s|@ZIP_NAME@|$ZIP_NAME|g" \
    -e "s|@CHECKSUM_NAME@|$CHECKSUM_NAME|g" \
    "$INSTALL_TEMPLATE" > "$PAYLOAD_INSTALL"

if grep -Eq '@[A-Z_]+@' "$PAYLOAD_INSTALL"; then
    die "unresolved placeholder in generated INSTALL.txt"
fi

verify_app "$PAYLOAD_APP"

# Verification reads the executable and can update its access time. Normalize
# both access and modification times only after those reads so repeated runs
# produce a byte-for-byte identical ZIP.
find "$PAYLOAD_ROOT" -exec touch -t "$ARCHIVE_TIMESTAMP" {} +

/usr/bin/ditto \
    -c \
    -k \
    --norsrc \
    --noextattr \
    --noqtn \
    --noacl \
    --keepParent \
    "$PAYLOAD_ROOT" \
    "$STAGED_ZIP"

EXTRACT_ROOT="$STAGE_ROOT/extracted"
mkdir -p "$EXTRACT_ROOT"
/usr/bin/ditto -x -k "$STAGED_ZIP" "$EXTRACT_ROOT"

EXTRACTED_ROOT="$EXTRACT_ROOT/$RELEASE_NAME"
[[ -f "$EXTRACTED_ROOT/INSTALL.txt" ]] || die "INSTALL.txt is missing from ZIP"
[[ -f "$EXTRACTED_ROOT/LICENSE" ]] || die "LICENSE is missing from ZIP"
cmp "$PAYLOAD_INSTALL" "$EXTRACTED_ROOT/INSTALL.txt" >/dev/null || \
    die "INSTALL.txt changed during archiving"
cmp "$LICENSE_SOURCE" "$EXTRACTED_ROOT/LICENSE" >/dev/null || \
    die "LICENSE changed during archiving"
verify_app "$EXTRACTED_ROOT/PromLight.app"

ZIP_SHA256="$(shasum -a 256 "$STAGED_ZIP" | awk '{print $1}')"
printf '%s  %s\n' "$ZIP_SHA256" "$ZIP_NAME" > "$STAGED_CHECKSUM"
/usr/bin/ditto "$PAYLOAD_INSTALL" "$STAGED_INSTALL"

for output in "$FINAL_ZIP" "$FINAL_CHECKSUM" "$FINAL_INSTALL"; do
    [[ ! -d "$output" || -L "$output" ]] || \
        die "refusing to replace a directory: $output"
done

mv -f "$STAGED_ZIP" "$FINAL_ZIP"
mv -f "$STAGED_CHECKSUM" "$FINAL_CHECKSUM"
mv -f "$STAGED_INSTALL" "$FINAL_INSTALL"

(
    cd "$RELEASE_ROOT"
    shasum -a 256 -c "$CHECKSUM_NAME"
)

printf 'Packaged %s\n' "$FINAL_ZIP"
printf 'SHA-256: %s\n' "$ZIP_SHA256"
printf 'Install guide: %s\n' "$FINAL_INSTALL"
printf 'Security: ad-hoc signed and not notarized; Gatekeeper override required\n'
