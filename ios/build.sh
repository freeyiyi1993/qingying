#!/bin/zsh
# 构建并安装到已配对的 iPhone：DEVICE=<udid> DEVELOPMENT_TEAM=<team> ./build.sh
set -euo pipefail
cd "$(dirname "$0")"
: "${DEVELOPMENT_TEAM:?需要 DEVELOPMENT_TEAM}" "${DEVICE:?需要 DEVICE udid}"
xcodegen generate -q
xcodebuild -project BooheeLite.xcodeproj -scheme BooheeLite -configuration Debug \
  -destination "id=$DEVICE" -derivedDataPath build -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" build | tail -5
APP=build/Build/Products/Debug-iphoneos/BooheeLite.app
xcrun devicectl device install app --device "$DEVICE" "$APP"
xcrun devicectl device process launch --device "$DEVICE" dev.mindbar.boohee
