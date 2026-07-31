#!/bin/bash

set -euo pipefail
IFS=$'\n\t'
umask 022

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PRODUCT_NAME="PromLight"
EXECUTABLE_NAME="PromLight"
MINIMUM_SYSTEM_VERSION="${PROM_LIGHT_MINIMUM_MACOS:-13.0}"
MARKETING_VERSION="${PROM_LIGHT_VERSION:-0.2.1}"
BUILD_VERSION="${PROM_LIGHT_BUILD_VERSION:-3}"
BUNDLE_IDENTIFIER="${PROM_LIGHT_BUNDLE_IDENTIFIER:-com.isaaclim.promlight.universal}"
DIST_ROOT="${PROM_LIGHT_OUTPUT_DIR:-$PROJECT_ROOT/dist}"
BUILD_ROOT="${PROM_LIGHT_BUILD_DIR:-$PROJECT_ROOT/.build/universal}"
INFO_TEMPLATE="$PROJECT_ROOT/Packaging/Info.plist.in"
RESOURCE_ROOT="$PROJECT_ROOT/Packaging/Resources"
ICON_FILE_NAME="PromLight.icns"
ICON_RESOURCE="$RESOURCE_ROOT/$ICON_FILE_NAME"
FINAL_APP="$DIST_ROOT/$PRODUCT_NAME.app"
FINAL_DSYM="$DIST_ROOT/$PRODUCT_NAME.app.dSYM"

die() {
    printf 'build-universal: %s\n' "$*" >&2
    exit 1
}

require_tool() {
    command -v "$1" >/dev/null 2>&1 || die "required tool not found: $1"
}

validate_version() {
    local label="$1"
    local value="$2"

    [[ "$value" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || \
        die "$label must contain one to three dot-separated integers: $value"
}

validate_bundle_identifier() {
    [[ "$BUNDLE_IDENTIFIER" =~ ^[A-Za-z0-9]+([.-][A-Za-z0-9]+)+$ ]] || \
        die "invalid bundle identifier: $BUNDLE_IDENTIFIER"
}

safe_remove_output() {
    local target="$1"

    case "$target" in
        "$DIST_ROOT"/*.app|"$DIST_ROOT"/*.app.dSYM)
            if [[ -e "$target" || -L "$target" ]]; then
                rm -rf -- "$target"
            fi
            ;;
        *)
            die "refusing to remove unexpected output path: $target"
            ;;
    esac
}

build_architecture() {
    local architecture="$1"
    local triple="${architecture}-apple-macosx${MINIMUM_SYSTEM_VERSION}"
    local scratch="$BUILD_ROOT/$architecture"
    local module_cache="$BUILD_ROOT/module-cache-$architecture"

    mkdir -p "$scratch" "$module_cache" "$BUILD_ROOT/cache" \
        "$BUILD_ROOT/config" "$BUILD_ROOT/security"

    env \
        CLANG_MODULE_CACHE_PATH="$module_cache" \
        SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" \
        swift build \
            --package-path "$PROJECT_ROOT" \
            --disable-sandbox \
            --cache-path "$BUILD_ROOT/cache" \
            --config-path "$BUILD_ROOT/config" \
            --security-path "$BUILD_ROOT/security" \
            --scratch-path "$scratch" \
            --configuration release \
            --triple "$triple" \
            --product "$PRODUCT_NAME" >&2

    local executable="$scratch/${architecture}-apple-macosx/release/$EXECUTABLE_NAME"
    [[ -x "$executable" ]] || die "SwiftPM did not produce $executable"
    printf '%s\n' "$executable"
}

for tool in swift lipo codesign plutil dsymutil strip sed mktemp grep; do
    require_tool "$tool"
done

[[ "$(uname -s)" == "Darwin" ]] || die "this build must run on macOS"
[[ -f "$INFO_TEMPLATE" ]] || die "missing Info.plist template: $INFO_TEMPLATE"
[[ -f "$ICON_RESOURCE" ]] || die "missing application icon: $ICON_RESOURCE"
validate_version "PROM_LIGHT_VERSION" "$MARKETING_VERSION"
validate_version "PROM_LIGHT_BUILD_VERSION" "$BUILD_VERSION"
validate_version "PROM_LIGHT_MINIMUM_MACOS" "$MINIMUM_SYSTEM_VERSION"
validate_bundle_identifier
[[ -n "$DIST_ROOT" && "$DIST_ROOT" != "/" ]] || die "unsafe output directory: $DIST_ROOT"
[[ -n "$BUILD_ROOT" && "$BUILD_ROOT" != "/" ]] || die "unsafe build directory: $BUILD_ROOT"

mkdir -p "$DIST_ROOT" "$BUILD_ROOT"
STAGE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/promlight-universal.XXXXXX")"
trap 'rm -rf -- "$STAGE_ROOT"' EXIT

ARM64_EXECUTABLE="$(build_architecture arm64)"
X86_64_EXECUTABLE="$(build_architecture x86_64)"

STAGED_APP="$STAGE_ROOT/$PRODUCT_NAME.app"
STAGED_CONTENTS="$STAGED_APP/Contents"
STAGED_EXECUTABLE="$STAGED_CONTENTS/MacOS/$EXECUTABLE_NAME"
STAGED_DSYM="$STAGE_ROOT/$PRODUCT_NAME.app.dSYM"

mkdir -p "$STAGED_CONTENTS/MacOS" "$STAGED_CONTENTS/Resources"

lipo -create \
    "$ARM64_EXECUTABLE" \
    "$X86_64_EXECUTABLE" \
    -output "$STAGED_EXECUTABLE"
chmod 0755 "$STAGED_EXECUTABLE"

sed \
    -e "s|@BUNDLE_IDENTIFIER@|$BUNDLE_IDENTIFIER|g" \
    -e "s|@MARKETING_VERSION@|$MARKETING_VERSION|g" \
    -e "s|@BUILD_VERSION@|$BUILD_VERSION|g" \
    -e "s|@MINIMUM_SYSTEM_VERSION@|$MINIMUM_SYSTEM_VERSION|g" \
    "$INFO_TEMPLATE" > "$STAGED_CONTENTS/Info.plist"
plutil -lint "$STAGED_CONTENTS/Info.plist" >/dev/null

if [[ -d "$RESOURCE_ROOT" ]]; then
    /usr/bin/ditto "$RESOURCE_ROOT" "$STAGED_CONTENTS/Resources"
fi

PLIST_ICON_FILE="$(plutil -extract CFBundleIconFile raw "$STAGED_CONTENTS/Info.plist")"
[[ "$PLIST_ICON_FILE" == "$ICON_FILE_NAME" ]] || \
    die "Info.plist icon does not match the packaged resource: $PLIST_ICON_FILE"
[[ -f "$STAGED_CONTENTS/Resources/$ICON_FILE_NAME" ]] || \
    die "application icon was not copied into the bundle"

lipo "$STAGED_EXECUTABLE" -verify_arch arm64 x86_64
ARCHITECTURES="$(lipo -archs "$STAGED_EXECUTABLE")"
[[ " $ARCHITECTURES " == *" arm64 "* ]] || die "arm64 slice is missing"
[[ " $ARCHITECTURES " == *" x86_64 "* ]] || die "x86_64 slice is missing"
[[ "$(wc -w <<< "$ARCHITECTURES" | tr -d ' ')" == "2" ]] || \
    die "unexpected architecture set: $ARCHITECTURES"

dsymutil "$STAGED_EXECUTABLE" -o "$STAGED_DSYM"

# Keep full symbols in the local dSYM, but do not ship build-machine paths in
# the application executable. Swift's release link still includes N_OSO debug
# records until they are explicitly stripped.
/usr/bin/strip -S "$STAGED_EXECUTABLE"
if LC_ALL=C grep -aFq "$PROJECT_ROOT" "$STAGED_EXECUTABLE"; then
    die "builder source path remains in the stripped executable"
fi
if LC_ALL=C grep -aFq '/Users/' "$STAGED_EXECUTABLE"; then
    die "a local user path remains in the stripped executable"
fi

# Lipo invalidates the linker-created signatures on both thin binaries. Sign
# the completed bundle only after stripping and all resource bytes are final.
codesign \
    --force \
    --options runtime \
    --sign - \
    "$STAGED_APP"

codesign --verify --deep --strict --verbose=4 "$STAGED_APP"

verify_executable_version() {
    local architecture="$1"
    local reported_version

    reported_version="$(arch -"$architecture" "$STAGED_EXECUTABLE" --version)"
    [[ "$reported_version" == "$MARKETING_VERSION" ]] || \
        die "$architecture executable version $reported_version does not match bundle version $MARKETING_VERSION"
}

case "$(uname -m)" in
    arm64)
        verify_executable_version arm64
        verify_executable_version x86_64
        ;;
    x86_64)
        verify_executable_version x86_64
        ;;
esac

safe_remove_output "$FINAL_APP"
safe_remove_output "$FINAL_DSYM"
mv "$STAGED_APP" "$FINAL_APP"
mv "$STAGED_DSYM" "$FINAL_DSYM"

printf 'Built %s\n' "$FINAL_APP"
printf 'Architectures: %s\n' "$(lipo -archs "$FINAL_APP/Contents/MacOS/$EXECUTABLE_NAME")"
printf 'Signature: ad hoc with hardened runtime\n'
