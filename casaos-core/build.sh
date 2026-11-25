#!/usr/bin/env bash
# Builds the CasaOS core that Atrio puts on servers in place of the official v0.4.15: the same
# source, with fix-network-counters.patch (CasaOS issue #2581), for the three processors CasaOS is
# released for. Run by scripts/release.sh; the result is in build/casaos-core/out:
#   casaos-linux-amd64  casaos-linux-arm64  casaos-linux-arm-7  SHA256SUMS
#
# Everything that goes in is pinned (CasaOS's commit, the message bus API, the code generator, Go
# itself and, through go.sum, every module), so the same inputs give the same files, byte for byte:
#   casaos-core/build.sh --force && sha256sum -c build/casaos-core/out/SHA256SUMS
#
# Needs git, curl and Go 1.23.4 (the version IceWhale built v0.4.15 with), by default in ~/.local/go.
set -euo pipefail

CASAOS_REPO=https://github.com/IceWhaleTech/CasaOS.git
CASAOS_TAG=v0.4.15
CASAOS_COMMIT=ba285cb8bddb85fbd93060b3a8b944f35dd7a7ad
# The message bus API in effect when v0.4.15 was built (CasaOS's go:generate reads it from main)
MESSAGE_BUS_API=https://raw.githubusercontent.com/IceWhaleTech/CasaOS-MessageBus/bfbc6ee46327a99d06af62120f907dfb11c843a1/api/message_bus/openapi.yaml
OAPI_CODEGEN=github.com/deepmap/oapi-codegen/cmd/oapi-codegen@v1.12.4
GO_VERSION=go1.23.4
# Goes up by one each time the patch changes; CasaOS prints it at start ("git commit: …+atrio.1")
FIX=1
FIX_DATE=2026-11-25T00:00:00Z

here=$(cd "$(dirname "$0")" && pwd)
work="$here/../build/casaos-core"
out="$work/out"
go="${ATRIO_GO:-$HOME/.local/go/bin/go}"

die() { echo "$1" >&2; exit 1; }

[ -x "$go" ] || die "Go is missing: install $GO_VERSION in ~/.local/go, or set ATRIO_GO"
[ "$("$go" env GOVERSION)" = "$GO_VERSION" ] || die "Needs $GO_VERSION, $go is $("$go" env GOVERSION)"

# The inputs of this build: when they did not change, the files already built are the same ones
stamp=$(cat "$here/build.sh" "$here/fix-network-counters.patch" | sha256sum | cut -d' ' -f1)
if [ "${1:-}" != "--force" ] && [ -f "$out/STAMP" ] && [ "$(cat "$out/STAMP")" = "$stamp" ] \
	&& (cd "$out" && sha256sum -c --quiet SHA256SUMS) 2>/dev/null; then
	echo "CasaOS core already built: $out"
	exit 0
fi

rm -rf "$work"
mkdir -p "$work" "$out"
git clone -q --depth 1 --branch "$CASAOS_TAG" "$CASAOS_REPO" "$work/src" 2>/dev/null
[ "$(git -C "$work/src" rev-parse HEAD)" = "$CASAOS_COMMIT" ] || die "$CASAOS_TAG is not commit $CASAOS_COMMIT any more"
git -C "$work/src" apply "$here/fix-network-counters.patch"

cd "$work/src"
export GOTOOLCHAIN=local GOFLAGS=-mod=readonly CGO_ENABLED=0
# What CasaOS's go:generate lines do, with the message bus API pinned
mkdir -p codegen/message_bus
"$go" run "$OAPI_CODEGEN" -generate types,server,spec -package codegen api/casaos/openapi.yaml > codegen/casaos_api.go
"$go" run "$OAPI_CODEGEN" -generate types,client -package message_bus "$MESSAGE_BUS_API" > codegen/message_bus/api.go
"$go" test ./model/ >/dev/null

# As IceWhale's .goreleaser.yaml builds it, without their keys for Google Drive, OneDrive and Dropbox
# (connecting a new cloud drive needs the original core), and without upx
ldflags="-s -w -buildid= -X main.commit=$CASAOS_COMMIT+atrio.$FIX -X main.date=$FIX_DATE"
for target in amd64 arm64 arm-7; do
	arch=${target%-7}
	GOARCH=$arch GOARM=7 "$go" build -tags "musl netgo osusergo" -trimpath -ldflags "$ldflags" \
		-o "$out/casaos-linux-$target" .
done

cd "$out"
sha256sum casaos-linux-amd64 casaos-linux-arm64 casaos-linux-arm-7 > SHA256SUMS
echo "$stamp" > STAMP
cat SHA256SUMS
