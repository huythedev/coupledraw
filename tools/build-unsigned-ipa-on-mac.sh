#!/bin/sh
# Build a device binary and package it without an Apple code signature.
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
output_dir="$project_dir/dist"
derived_data="$project_dir/build/unsigned-derived-data"

# macOS may point xcodebuild at the standalone Command Line Tools even when
# full Xcode is installed. Select the app only for this process, without sudo.
if ! xcodebuild -version >/dev/null 2>&1; then
    xcode_app="${XCODE_APP_PATH:-/Applications/Xcode.app}"
    if [ -d "$xcode_app/Contents/Developer" ]; then
        export DEVELOPER_DIR="$xcode_app/Contents/Developer"
    else
        echo "Install the full Xcode app, or set XCODE_APP_PATH to its location." >&2
        echo "The standalone Command Line Tools cannot build an iPhone app." >&2
        exit 1
    fi
fi
if ! xcodebuild -version >/dev/null 2>&1; then
    echo "Xcode is present but not ready. Open it once to finish setup, then retry." >&2
    exit 1
fi

mkdir -p "$output_dir"
xcodebuild \
    -project "$project_dir/CoupleDraw.xcodeproj" \
    -scheme CoupleDraw \
    -configuration Release \
    -sdk iphoneos \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$derived_data" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY='' \
    build

app="$derived_data/Build/Products/Release-iphoneos/CoupleDraw.app"
if [ ! -d "$app" ] || [ ! -d "$app/PlugIns/CoupleDrawWidget.appex" ]; then
    echo "The built app or its Lock Screen widget was not found: $app" >&2
    exit 1
fi

staging=$(mktemp -d "$output_dir/.ipa-payload.XXXXXX")
trap 'rm -rf -- "$staging"' EXIT HUP INT TERM
mkdir -p "$staging/Payload"
ditto "$app" "$staging/Payload/CoupleDraw.app"
ipa="$output_dir/CoupleDraw-unsigned.ipa"
ditto -c -k --sequesterRsrc --keepParent "$staging/Payload" "$ipa"
echo "Unsigned device IPA: $ipa"
echo "Sign the main app and embedded widget before installing on an iPhone."
