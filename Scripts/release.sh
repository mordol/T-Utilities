#!/bin/zsh
# Builds, signs and publishes a GitHub release.
#   Scripts/release.sh 0.2.0          # bump version, commit, tag, build, upload, update the Homebrew cask
#   Scripts/release.sh 0.2.0 --dry    # bump + build + zip only (no commit/tag/upload)
# Requires the "T-Utilities Dev" signing certificate in the login keychain, `gh` logged in,
# and a clone of mordol/homebrew-tap at $TAP_DIR (default: ../homebrew-tap).
# Release notes are required: Docs/releases/v<version>.md (user-facing summary, shown by the in-app "릴리스 노트").
set -euo pipefail

VERSION=${1:?usage: Scripts/release.sh <version> [--dry]}
DRY=${2:-}
ROOT=${0:A:h:h}
TAP_DIR=${TAP_DIR:-$ROOT/../homebrew-tap}
CASK=$TAP_DIR/Casks/t-utilities.rb
cd "$ROOT"
NOTES=Docs/releases/v$VERSION.md

[[ $VERSION =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "version must be X.Y.Z"; exit 1; }
[[ -n $DRY || -s $NOTES ]] || { echo "missing release notes: $NOTES"; exit 1; }
[[ -z $DRY && -n $(git status --porcelain) ]] && { echo "working tree is not clean"; exit 1; }
[[ -n $DRY || ( -f $CASK && -z $(git -C "$TAP_DIR" status --porcelain) ) ]] || { echo "tap clone missing or dirty: $TAP_DIR"; exit 1; }

# Module rules and every package's tests (incl. the module contract tests) gate each release.
Scripts/check-modules.sh
mkdir -p build
for p in Packages/*/; do
  [[ -d $p/Tests ]] || continue
  swift test --package-path "$p" > build/test-$(basename "$p").log 2>&1 || { echo "tests failed: $p (build/test-$(basename "$p").log)"; exit 1; }
done
echo "module rules and tests passed"

BUILD=$(( $(sed -n 's/.*CFBundleVersion: "\([0-9]*\)".*/\1/p' project.yml) + 1 ))
sed -i '' -e "s/CFBundleShortVersionString: \".*\"/CFBundleShortVersionString: \"$VERSION\"/" \
          -e "s/CFBundleVersion: \".*\"/CFBundleVersion: \"$BUILD\"/" project.yml

xcodegen generate
# Separate DerivedData: `clean` must not delete the Debug app that may be running from build/DerivedData.
xcodebuild -project T-Utilities.xcodeproj -scheme T-Utilities -configuration Release \
  -derivedDataPath build/ReleaseDerivedData clean build | grep -E "error:|BUILD" || true

APP=build/ReleaseDerivedData/Build/Products/Release/T-Utilities.app
codesign --verify --deep --strict "$APP"
codesign -dr - "$APP" 2>&1 | grep -q 'certificate leaf' || { echo "app is not signed with the T-Utilities Dev certificate"; exit 1; }
[[ $(defaults read "$PWD/$APP/Contents/Info" CFBundleShortVersionString) == $VERSION ]]

ZIP=build/T-Utilities-$VERSION.zip
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "built $ZIP"
[[ -n $DRY ]] && exit 0

git commit -qam "Release $VERSION"
git tag "v$VERSION"
git push -q origin HEAD "v$VERSION"
gh release create "v$VERSION" "$ZIP" --title "T-Utilities $VERSION" --notes-file "$NOTES"

SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$CASK"
git -C "$TAP_DIR" commit -qam "t-utilities $VERSION"
git -C "$TAP_DIR" push -q origin HEAD
echo "released v$VERSION (cask updated)"
