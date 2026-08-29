#!/bin/sh
# Install the osprey command-line scanner.
#
# Served from https://osprey-hq.com/install.sh — the same origin as the page
# that offers it — so the documented one-liner is:
#
#   curl -fsSL https://osprey-hq.com/install.sh | sh
#
# This script is written to be read before it is run. Every step is one plain
# command: work out the platform, download that platform's archive and the
# release's checksums.txt, verify the sha256, and copy one binary into a
# directory on your PATH. Nothing else is touched, nothing is reported
# anywhere, and sudo is never invoked — a script you piped into a shell that
# then asks for a root password is indistinguishable from one that is stealing
# it.
#
#   sh install.sh                     install the latest release
#   sh install.sh --version v1.0.0    install a specific release tag
#   sh install.sh --dry-run           print the plan and download nothing
#
# Through the pipe, arguments go after `-s --`:
#
#   curl -fsSL https://osprey-hq.com/install.sh | sh -s -- --dry-run
#
# It installs the CLI and nothing else. The desktop window ships in the same
# archive, but putting an application into /Applications or your desktop menu
# is a decision someone makes on purpose, not a side effect of a pipe into a
# shell. Take the archive from https://osprey-hq.com/#download for that.
set -eu

# The public repository that hosts the releases. The product repository is
# private, so the downloads live beside the landing page instead.
RELEASES="https://github.com/nitzama1/osprey-site/releases"

usage() {
	cat <<'USAGE'
usage: install.sh [--version <tag>] [--dry-run]

  --version <tag>   install a specific release, for example --version v1.0.0
  --dry-run         print what would happen and exit without downloading
  -h, --help        this text

Installs the osprey CLI to /usr/local/bin when that is already writable, and to
~/.local/bin otherwise. The desktop window is not installed.
USAGE
}

die() {
	echo "osprey: $*" >&2
	exit 1
}

have() {
	command -v "$1" >/dev/null 2>&1
}

# Every fetch is https, including after a redirect: a downloader that can be
# talked down to plain http by a Location header has no integrity left to
# offer, and the whole point of the next step is integrity.
fetch() { # fetch <url> <output-file>
	curl -fL --proto '=https' --proto-redir '=https' -o "$2" "$1"
}

# macOS ships shasum, Linux ships sha256sum, and both read the same
# "<hex>  <name>" lines, so only the command name differs.
verify_sha256() { # verify_sha256 <checksum-file>
	if have sha256sum; then
		sha256sum -c "$1"
	else
		shasum -a 256 -c "$1"
	fi
}

tag=""
dry_run=no

while [ $# -gt 0 ]; do
	case "$1" in
	--version)
		[ $# -ge 2 ] || die "--version needs a tag, for example --version v1.0.0"
		tag="$2"
		shift 2
		;;
	--dry-run)
		dry_run=yes
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		die "unknown option '$1' (try --help)"
		;;
	esac
done

# 1. Which build. This runs before anything touches the network, so a machine
#    with no build is told so immediately, and told what was detected.
os="$(uname -s)"
machine="$(uname -m)"
case "$os $machine" in
'Darwin arm64')
	platform=macos_arm64
	archive_kind=zip
	;;
'Darwin x86_64')
	platform=macos_amd64
	archive_kind=zip
	;;
'Linux x86_64')
	platform=linux_amd64
	archive_kind=tar.gz
	;;
'Linux aarch64' | 'Linux arm64')
	platform=linux_arm64
	archive_kind=tar.gz
	;;
*)
	echo "osprey: no build for '$os' on '$machine'." >&2
	echo "  builds exist for: macOS arm64, macOS x86_64, Linux x86_64, Linux aarch64." >&2
	echo "  Windows x86_64 is a download rather than a pipe: take the .zip from" >&2
	echo "  https://osprey-hq.com/#download and run install.ps1 from inside it." >&2
	exit 1
	;;
esac

asset="osprey_${platform}.${archive_kind}"

# Where the CLI sits inside each archive. Both paths are fixed by the
# packaging script rather than discovered: an installer that searches for
# "the binary that looks about right" is an installer that runs something it
# never checked.
case "$archive_kind" in
zip)
	# The macOS archive is the application bundle, and the CLI rides inside
	# it. Contents/Resources, not Contents/MacOS: the bundle executable there
	# is "Osprey", and a case-insensitive filesystem cannot hold both.
	inside='Osprey.app/Contents/Resources/osprey'
	;;
tar.gz)
	# The tarball's one top-level directory is stamped with the version
	# (osprey_1.0.0_linux_amd64/), so it is stripped on extraction below and
	# the path is the same for every release.
	inside='bin/osprey'
	;;
esac

have curl || die "curl is required (this script is normally fetched with it)"
have sha256sum || have shasum || die "no sha256sum or shasum here; refusing to install something unverified"
case "$archive_kind" in
zip) have unzip || die "unzip is required to open $asset" ;;
tar.gz) have tar || die "tar is required to open $asset" ;;
esac

# 2. Which release. The asset name carries no version, so "latest" and a
#    pinned tag differ only in the directory the file is fetched from.
if [ -n "$tag" ]; then
	base="$RELEASES/download/$tag"
	release="$tag"
else
	base="$RELEASES/latest/download"
	release="latest"
fi

# 3. Where it goes. /usr/local/bin when this user can already write it,
#    ~/.local/bin otherwise — never by escalating to get the first one.
if [ -w /usr/local/bin ]; then
	bindir=/usr/local/bin
else
	bindir="$HOME/.local/bin"
fi

case ":$PATH:" in
*":$bindir:"*) on_path="already on your PATH" ;;
*) on_path="NOT on your PATH" ;;
esac

if [ "$dry_run" = yes ]; then
	cat <<PLAN
osprey installer — plan only, nothing is downloaded

  platform     $platform (uname: $os $machine)
  release      $release
  archive      $base/$asset
  checksums    $base/checksums.txt
  verify       sha256 of the archive against its line in checksums.txt, and
               stop without installing if the two differ
  extract      $inside
  install      $bindir/osprey ($on_path)
  not touched  the desktop window, /Applications, your desktop menu, and any
               osprey database or configuration already on this machine
PLAN
	exit 0
fi

work="$(mktemp -d)"
# Clean up on every exit path, so a failed or unverified download is never
# left on disk for someone to find later and run by hand.
trap 'rm -rf "$work"' EXIT

echo "==> osprey for $platform, release $release"

echo "==> downloading $asset"
fetch "$base/$asset" "$work/$asset" ||
	die "could not download $asset from $base — see $RELEASES"

echo "==> downloading checksums.txt"
fetch "$base/checksums.txt" "$work/checksums.txt" ||
	die "no checksums.txt in that release — refusing to install unverified"

# checksums.txt covers every archive in the release and only one of them was
# downloaded, so the checker is handed just that line. No line for this asset
# is a failure, not something to shrug at: it means the file that just arrived
# is not part of the release that published those checksums.
echo "==> verifying sha256"
awk -v name="$asset" '$2 == name' "$work/checksums.txt" >"$work/expected.txt"
[ -s "$work/expected.txt" ] || die "checksums.txt lists no $asset — refusing to install"
(cd "$work" && verify_sha256 expected.txt) ||
	die "checksum mismatch on $asset — refusing to install it"

echo "==> unpacking"
mkdir -p "$work/unpacked"
case "$archive_kind" in
zip)
	unzip -q "$work/$asset" -d "$work/unpacked"
	;;
tar.gz)
	# --strip-components=1 drops the version-stamped top-level directory, so
	# $inside above holds for any release without this script knowing which
	# version it just downloaded.
	tar -xzf "$work/$asset" -C "$work/unpacked" --strip-components=1
	;;
esac
[ -f "$work/unpacked/$inside" ] || die "the archive does not contain $inside"

echo "==> installing to $bindir"
mkdir -p "$bindir"
# Copy in beside the target and rename: writing over a binary that is running
# fails outright on Linux, and rename is atomic, so there is no instant in
# which osprey is half a file.
cp "$work/unpacked/$inside" "$bindir/.osprey.new"
chmod 755 "$bindir/.osprey.new"
mv "$bindir/.osprey.new" "$bindir/osprey"

echo
echo "installed $bindir/osprey ($on_path)"
if [ "$on_path" = "NOT on your PATH" ]; then
	echo
	echo "  add it to your shell profile:"
	echo "      export PATH=\"$bindir:\$PATH\""
fi
echo
echo "  osprey version         confirm what was installed"
echo "  osprey scan aws        scan with the credentials you already have"
echo "  osprey onboard         generate a read-only role to scan through instead"
echo
echo "The desktop window is not installed; this script installs the CLI only."
echo "It is in the platform archive at https://osprey-hq.com/#download."
echo "The 30-day trial starts at your first scan and is counted on this machine."
