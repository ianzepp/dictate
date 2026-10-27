#!/bin/bash
# Build and sign an inactive candidate. install.sh swaps it into place after
# stopping the running app, so a failed build never damages the installed app.
set -euo pipefail
cd "$(dirname "$0")/.."
swift package resolve --skip-update
xcodebuild -scheme Dictate -configuration Release -destination 'platform=macOS' \
  -derivedDataPath .build/xcode -clonedSourcePackagesDirPath .build \
  -disableAutomaticPackageResolution build CODE_SIGNING_ALLOWED=NO \
  ENABLE_CODE_COVERAGE=NO CLANG_COVERAGE_MAPPING=NO
PRODUCTS="$PWD/.build/xcode/Build/Products/Release"
mkdir -p dist
STAGE="$(mktemp -d "$PWD/dist/.native-build.XXXXXX")"
trap '/bin/rm -r "$STAGE"' EXIT
APP="$STAGE/Dictate.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PRODUCTS/Dictate" "$APP/Contents/MacOS/Dictate"
cp Info.plist "$APP/Contents/Info.plist"
for bundle in "$PRODUCTS"/*.bundle; do
  [ -d "$bundle" ] || continue
  ditto "$bundle" "$APP/Contents/Resources/$(basename "$bundle")"
done
METAL="../Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
[ -f "$APP/Contents/MacOS/$METAL" ] || { echo 'Metal library was not built' >&2; exit 1; }
# MLX first looks beside the executable. Keep one physical copy in Resources.
ln -s "$METAL" "$APP/Contents/MacOS/mlx.metallib"
# Ad-hoc signatures get a new identity every build, so macOS drops the
# Accessibility grant. A stable local certificate keeps the approval.
SIGN_ID="Dictate Local Code Sign"
if security find-identity -v -p codesigning | grep -q "$SIGN_ID"; then
  codesign --force --sign "$SIGN_ID" --identifier com.ianzepp.dictate "$APP"
else
  echo "warning: $SIGN_ID is missing; Accessibility will not stick" >&2
  codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"
NEXT="$PWD/dist/Dictate.next.app"
if [ -d "$NEXT" ]; then /bin/rm -r "$NEXT"; fi
mv "$APP" "$NEXT"
echo "built $NEXT; run launchd/install.sh to install"
