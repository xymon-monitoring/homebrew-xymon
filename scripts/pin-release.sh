#!/usr/bin/env bash
# pin-release.sh VERSION [SHA256] -- point the normal formulae at the release
# tarball of Xymon VERSION (rel-VERSION in xymon-monitoring/xymon) and
# regenerate the preview formulae, whose plan loses the milestone just
# released. Prints what changed; changes nothing when the pin is already
# VERSION. SHA256 is read from the release's .sha256 asset unless given, and
# the tarball is downloaded and checked against it either way.
#
# .github/workflows/release.yml runs this when a newer rel-* tag appears;
# by hand: scripts/pin-release.sh 4.3.32
set -euo pipefail

version=${1:?usage: pin-release.sh VERSION [SHA256]}
sha256=${2:-}
case $version in *[!0-9.]*|"") echo "not a version: $version" >&2; exit 2 ;; esac
url="https://github.com/xymon-monitoring/xymon/releases/download/rel-$version/xymon-$version.tar.gz"
cd "$(dirname "$0")/.."

pinned=$(sed -n 's|^  url ".*/rel-\([0-9.]*\)/xymon-.*"$|\1|p' Formula/xymon-server.rb)
if [ "$pinned" = "$version" ]; then
	echo "already pinned to $version"
	exit 0
fi

if [ -z "$sha256" ]; then
	sha256=$(curl -fsSL "$url.sha256" | awk '{ print $1 }')
fi
[[ $sha256 =~ ^[0-9a-f]{64}$ ]] || { echo "no checksum for $url" >&2; exit 1; }
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
curl -fsSL -o "$tmp" "$url"
got=$(shasum -a 256 "$tmp" | awk '{ print $1 }')
[ "$got" = "$sha256" ] || { echo "$url: sha256 $got, expected $sha256" >&2; exit 1; }

for role in server client; do
	URL=$url SHA=$sha256 ruby -i -pe '
		$_ = "  url \"#{ENV["URL"]}\"\n" if $_ =~ /^  url "https:/
		$_ = "  sha256 \"#{ENV["SHA"]}\"\n" if $_ =~ /^  sha256 "/
	' "Formula/xymon-$role.rb"
	grep -q "^  url \"$url\"\$" "Formula/xymon-$role.rb" || { echo "xymon-$role.rb: url line not replaced" >&2; exit 1; }
	grep -q "^  sha256 \"$sha256\"\$" "Formula/xymon-$role.rb" || { echo "xymon-$role.rb: sha256 line not replaced" >&2; exit 1; }
done

# The previews: the released milestone drops out of the plan, and the
# normal formulae they are copied from changed.
scripts/find-preview.sh --all > plan.tsv || true
if [ -s plan.tsv ]; then
	ruby scripts/gen-preview.rb plan.tsv
else
	echo "no unreleased milestone has a preview: the preview formulae are left as they are" >&2
fi
rm -f plan.tsv
git status --short -- Formula
echo "pinned $pinned -> $version"
