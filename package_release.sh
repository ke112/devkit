#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="DevKit.app"
BUILD_DIR="$ROOT_DIR/build"
APP_PATH="$BUILD_DIR/$APP_NAME"
ZIP_PATH="$BUILD_DIR/DevKit.zip"
INSTALL_APP_PATH="/Applications/$APP_NAME"
BUNDLE_IDENTIFIER="com.zhihua.devkit"
XCODE_DERIVED_DATA_DIR="${HOME}/Library/Developer/Xcode/DerivedData"
PACKAGE_DIR="$(mktemp -d /tmp/DevKitPackage.XXXXXX)"
ARCHIVE_PATH="$PACKAGE_DIR/DevKit.xcarchive"
ARCHIVED_APP_PATH="$ARCHIVE_PATH/Products/Applications/$APP_NAME"

cleanup() {
  rm -rf "$PACKAGE_DIR"
}
trap cleanup EXIT

cleanup_non_installed_apps() {
  local search_root app_path bundle_id

  for search_root in "$ROOT_DIR" "$XCODE_DERIVED_DATA_DIR"; do
    [[ -d "$search_root" ]] || continue
    while IFS= read -r app_path; do
      [[ -n "$app_path" ]] || continue
      [[ "$app_path" == "$INSTALL_APP_PATH" ]] && continue
      [[ -f "$app_path/Contents/Info.plist" ]] || continue

      bundle_id=$(
        /usr/libexec/PlistBuddy \
          -c 'Print :CFBundleIdentifier' \
          "$app_path/Contents/Info.plist" 2>/dev/null || true
      )
      [[ "$bundle_id" == "$BUNDLE_IDENTIFIER" ]] || continue

      rm -rf "$app_path"
      echo "Removed non-installed app: $app_path"
    done < <(
      find "$search_root" -type d -name "$APP_NAME" -prune -print 2>/dev/null
    )
  done
}

if [[ "$APP_PATH" != "$ROOT_DIR/build/DevKit.app" || "$INSTALL_APP_PATH" != "/Applications/DevKit.app" ]]; then
  echo "Unexpected DevKit package path." >&2
  exit 1
fi

cd "$ROOT_DIR"

xcodebuild \
  -project devkit.xcodeproj \
  -scheme devkit \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -archivePath "$ARCHIVE_PATH" \
  archive

if [[ ! -d "$ARCHIVED_APP_PATH" ]]; then
  echo "Archived app not found: $ARCHIVED_APP_PATH" >&2
  exit 1
fi

codesign --verify --deep --strict "$ARCHIVED_APP_PATH"
mkdir -p "$BUILD_DIR"

REPO_APP_TEMP="${APP_PATH}.tmp.$$"
rm -rf "$REPO_APP_TEMP"
ditto "$ARCHIVED_APP_PATH" "$REPO_APP_TEMP"
rm -rf "$APP_PATH"
mv "$REPO_APP_TEMP" "$APP_PATH"

ZIP_TEMP="$PACKAGE_DIR/DevKit.zip"
ditto -c -k --sequesterRsrc --keepParent "$ARCHIVED_APP_PATH" "$ZIP_TEMP"
mv -f "$ZIP_TEMP" "$ZIP_PATH"

INSTALL_APP_TEMP="${INSTALL_APP_PATH}.tmp.$$"
if [[ -w "/Applications" ]]; then
  rm -rf "$INSTALL_APP_TEMP"
  ditto "$ARCHIVED_APP_PATH" "$INSTALL_APP_TEMP"
  rm -rf "$INSTALL_APP_PATH"
  mv "$INSTALL_APP_TEMP" "$INSTALL_APP_PATH"
else
  sudo rm -rf "$INSTALL_APP_TEMP"
  sudo ditto "$ARCHIVED_APP_PATH" "$INSTALL_APP_TEMP"
  sudo rm -rf "$INSTALL_APP_PATH"
  sudo mv "$INSTALL_APP_TEMP" "$INSTALL_APP_PATH"
fi

codesign --verify --deep --strict "$APP_PATH"
codesign --verify --deep --strict "$INSTALL_APP_PATH"

cleanup_non_installed_apps

echo "Repository app: removed after install"
echo "Repository zip: $ZIP_PATH"
echo "Installed app: $INSTALL_APP_PATH"
