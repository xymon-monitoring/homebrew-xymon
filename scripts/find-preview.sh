#!/usr/bin/env bash
# find-preview.sh -- print the preview the preview formulae should follow, as
#   version=4.3.31-preview2
#   url=https://.../xymon-4.3.31-preview2.tar.gz
#   sha256=...
# or nothing when there is none.
#
# find-preview.sh --all -- print every unreleased milestone that has a
# published preview, lowest first, with its highest preview, one a line:
#   4.3.31 4.3.31-preview2 https://.../xymon-4.3.31-preview2.tar.gz SHA256
# the plan scripts/gen-preview.rb takes (its first line is the next release).
#
# It follows the next release: the lowest milestone with a published preview
# in xymon-experimental and no release tag (rel-<milestone>) in xymon yet, and
# that milestone's highest preview. Drafts are not published, so not seen.
# Previews of later milestones stay downloads on the releases page: the number
# only goes up, so `brew upgrade` follows without anyone choosing a milestone.
set -euo pipefail

EXP=xymon-monitoring/xymon-experimental
released=$(git ls-remote --tags --refs "https://github.com/xymon-monitoring/xymon" 'refs/tags/rel-*' |
	sed 's|.*refs/tags/rel-||')

previews=$(gh release list -R "$EXP" --exclude-drafts --limit 200 --json tagName -q '.[].tagName' |
	sed -n 's/^preview-\([0-9][0-9.]*\)-\([0-9][0-9]*\)$/\1 \2/p')
[ -n "$previews" ] || exit 0

# Unreleased milestones with a preview, lowest first.
milestones=$(printf '%s\n' "$previews" | cut -d' ' -f1 | sort -uV |
	while read -r v; do printf '%s\n' "$released" | grep -qxF "$v" || echo "$v"; done)
[ -n "$milestones" ] || exit 0

line() {
	local m=$1 n version url sha256
	n=$(printf '%s\n' "$previews" | awk -v m="$m" '$1 == m { print $2 }' | sort -n | tail -1)
	version="$m-preview$n"
	url="https://github.com/$EXP/releases/download/preview-$m-$n/xymon-$version.tar.gz"
	sha256=$(curl -fsSL "$url.sha256" | awk '{ print $1 }')
	[[ $sha256 =~ ^[0-9a-f]{64}$ ]] || { echo "no checksum at $url.sha256" >&2; exit 1; }
	echo "$m $version $url $sha256"
}

if [ "${1:-}" = --all ]; then
	for m in $milestones; do line "$m"; done
else
	next=$(line "$(head -1 <<<"$milestones")")
	read -r _ version url sha256 <<<"$next"
	printf 'version=%s\nurl=%s\nsha256=%s\n' "$version" "$url" "$sha256"
fi
