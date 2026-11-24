#!/bin/sh
# Publishes a swapify release from main.
#
#   scripts/release.sh 0.1.0 --dry-run   runs every check and prints the release notes; changes nothing
#   scripts/release.sh 0.1.0             dates the changelog, tags v0.1.0, pushes, publishes the
#                                        GitHub release, and points the Homebrew formula at the tag
#
# Before running it:
# - SwapifyInfo.version in Sources/SwapifyCore/Setup.swift is the new version.
# - CHANGELOG.md has a "## <version> (unreleased)" section. It becomes the release notes.
# - main is checked out, clean, and the same as origin/main.
# Needs swift, make, curl, shasum, and gh signed in to an account that can push to the repository.
set -eu

version=${1:?usage: scripts/release.sh <version> [--dry-run]}
mode=${2:-}
tag="v$version"
repo=tornikegomareli/swapify
archive_url="https://github.com/$repo/archive/refs/tags/$tag.tar.gz"
cd "$(dirname "$0")/.."

fail() {
  echo "release: $*" >&2
  exit 1
}

# 1. The checkout and the version.
[ "$(git branch --show-current)" = main ] || fail "check out main first"
[ -z "$(git status --porcelain)" ] || fail "the working tree has changes"
git fetch -q origin
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || fail "main is not the same as origin/main"
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null || git ls-remote --exit-code --tags origin "$tag" >/dev/null 2>&1; then
  fail "$tag already exists"
fi
grep -q "static let version = \"$version\"" Sources/SwapifyCore/Setup.swift || fail "SwapifyInfo.version is not $version"
grep -q "^## $version (unreleased)\$" CHANGELOG.md || fail "CHANGELOG.md has no \"## $version (unreleased)\" section"

# 2. The release notes: the changelog section, without its heading.
notes=$(mktemp)
trap 'rm -f "$notes"' EXIT
awk -v heading="## $version (unreleased)" '$0 == heading { on = 1; next } on && /^## / { exit } on' CHANGELOG.md > "$notes"
[ -s "$notes" ] || fail "the changelog section for $version is empty"

# 3. Tests, and a release build made the way the formula makes it.
swift test
make build
[ "$(.build/release/swapify --version)" = "$version" ] || fail "swapify --version does not print $version"

if [ "$mode" = --dry-run ]; then
  echo "All checks passed. Release notes for $tag:"
  echo
  cat "$notes"
  exit 0
fi

# 4. Date the changelog section, then commit, tag and push.
sed -i '' "s/^## $version (unreleased)\$/## $version ($(date +%Y-%m-%d))/" CHANGELOG.md
git commit -q -m "Release $version" CHANGELOG.md
git tag -a "$tag" -m "swapify $version"
git push -q origin main "$tag"

# 5. The GitHub release, with the changelog section as its notes.
gh release create "$tag" --repo "$repo" --title "swapify $version" --notes-file "$notes"

# 6. Point the formula at the source archive of the tag. The token lets this work while the
#    repository is private; Homebrew itself can download the archive only once it is public.
sha=$(curl -fsSL -H "Authorization: Bearer $(gh auth token)" "$archive_url" | shasum -a 256 | cut -d' ' -f1)
[ "${#sha}" -eq 64 ] || fail "could not download $archive_url"
if grep -q '^  url "' Formula/swapify.rb; then
  sed -i '' -e "s|^  url \".*\"|  url \"$archive_url\"|" -e "s|^  sha256 \".*\"|  sha256 \"$sha\"|" Formula/swapify.rb
else
  sed -i '' "s|^  license \"MIT\"\$|  url \"$archive_url\"\\
  sha256 \"$sha\"\\
  license \"MIT\"|" Formula/swapify.rb
fi
git commit -q -m "Point the Homebrew formula at $version" Formula/swapify.rb
git push -q origin main

echo "Released $tag: https://github.com/$repo/releases/tag/$tag"
