#!/bin/bash
# Publish a release: make release VERSION=2.1
#
# Sets the version in Resources/Info.plist, runs the tests, builds
# Blackout.app, commits "Release 2.1" on main with the tag v2.1, pushes
# both and publishes Blackout.zip as a GitHub release. Installed copies
# find it with their daily update check; install.sh downloads it.
set -euo pipefail

VERSION="${1:-}"
TAG="v$VERSION"
PLIST=Resources/Info.plist
APP=.build/Blackout.app
ZIP=.build/Blackout.zip
LOG=.build/release.log

fail() {
    echo "release: $*" >&2
    exit 1
}

# True when version $1 is newer than $2, compared number by number with a
# missing number counting as 0: the comparison the updater makes, so a
# release it would not offer (2.0.0 after 2.0) is refused here
is_newer() {
    local -a new old
    IFS=. read -ra new <<<"$1"
    IFS=. read -ra old <<<"$2"
    local i
    for ((i = 0; i < ${#new[@]} || i < ${#old[@]}; i++)); do
        local a=$((10#${new[i]:-0})) b=$((10#${old[i]:-0}))
        if ((a != b)); then
            ((a > b))
            return
        fi
    done
    return 1
}

[[ "$VERSION" =~ ^(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*))*$ ]] || fail "usage: make release VERSION=<number, like 2.1>"
cd "$(dirname "$0")/.."

# Everything that can stop the release is checked before anything changes
command -v gh >/dev/null || fail "the GitHub CLI is needed: brew install gh"
gh auth status >/dev/null 2>&1 || fail "the GitHub CLI is not logged in: gh auth login"
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || fail "releases are made from main"
[ -z "$(git status --porcelain)" ] || fail "the working tree has uncommitted changes"
git fetch --quiet origin main --tags
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || fail "main and origin/main differ: pull or push first"
if git rev-parse --quiet --verify "refs/tags/$TAG" >/dev/null; then
    fail "the tag $TAG already exists"
fi
CURRENT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
is_newer "$VERSION" "$CURRENT" || fail "$VERSION is not newer than the current version $CURRENT"

mkdir -p .build
echo "Running the tests..."
if ! swift run blackout-tests >"$LOG" 2>&1; then
    tail -30 "$LOG"
    fail "the tests fail (full output in $LOG)"
fi

echo "Building Blackout $VERSION..."
# Until the commit, any way out puts the version back
trap 'git checkout --quiet -- "$PLIST"' EXIT
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $VERSION" "$PLIST"
if ! make bundle >"$LOG" 2>&1; then
    tail -30 "$LOG"
    fail "the build fails (full output in $LOG)"
fi
BUILT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
[ "$BUILT" = "$VERSION" ] || fail "the bundle says $BUILT, not $VERSION"
codesign --verify --strict "$APP" || fail "the bundle's signature does not verify"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

# Release notes: the commits since the previous release
PREVIOUS=$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)
if [ -n "$PREVIOUS" ]; then
    NOTES=$(git log --format='- %s' --no-merges "$PREVIOUS"..HEAD)
else
    NOTES="First release published with the updater: from now on Blackout finds new releases by itself."
fi

git commit --quiet -m "Release $VERSION" -- "$PLIST"
trap - EXIT
git tag -a "$TAG" -m "Blackout $VERSION"
# Both or neither: a tag pushed without its commit would name a release
# that is not on main
if ! git push --quiet --atomic origin main "$TAG"; then
    fail "the push was refused; the commit and tag $TAG are only local (undo with: git tag -d $TAG && git reset --keep HEAD~1)"
fi
if ! gh release create "$TAG" "$ZIP" --verify-tag --title "Blackout $VERSION" --notes "$NOTES"; then
    echo "" >&2
    echo "The commit and tag $TAG are on GitHub, but the release was not published. Finish it with:" >&2
    echo "  gh release create $TAG $ZIP --verify-tag --title \"Blackout $VERSION\" --generate-notes" >&2
    exit 1
fi

echo ""
echo "Published Blackout $VERSION."
echo "Installed copies offer it within a day, or now with 'blackout update'."
