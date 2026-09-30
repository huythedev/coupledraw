#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
xcodebuild \
  -project CoupleDraw.xcodeproj \
  -scheme CoupleDraw \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
