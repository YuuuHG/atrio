#!/bin/bash
# The fixed CasaOS core (atrio-core): put in place of IceWhale's v0.4.15 only, the original kept and
# put back when the fix is turned off or fails to start, never touching another version of CasaOS.
. "$(dirname "$0")/lib.sh"
sandbox

core="$SCRIPTS/atrio-core"
export ATRIO_CASAOS_BIN="$SB/bin/casaos" ATRIO_CORE_MANIFEST="$SB/share/casaos-core" ATRIO_CORE_URL="file://$SB/releases"
export ATRIO_CORE_STEADY=1
mkdir -p "$SB/bin" "$SB/share"
sum() { sha256sum < "$1" | cut -d' ' -f1; }

echo "IceWhale's casaos v0.4.15 for amd64" > "$SB/official"
cp "$SB/official" "$ATRIO_CASAOS_BIN"
export ATRIO_CORE_OFFICIAL="$(sum "$SB/official") amd64"

# release TAG FIX CONTENT: a release with its fixed core for amd64, and the manifest that names it
release() {
	mkdir -p "$SB/releases/$1"
	printf 'fixed core %s\n' "$3" > "$SB/fixed-$2"
	gzip -c "$SB/fixed-$2" > "$SB/releases/$1/casaos-core-linux-amd64.gz"
	printf 'RELEASE=%s\nFIX=%s\namd64=%s\narm64=%s\n' "$1" "$2" "$(sum "$SB/fixed-$2")" "$(printf 'b%.0s' {1..64})" > "$ATRIO_CORE_MANIFEST"
}
restarts() { grep -c '^systemctl restart casaos$' "$FAKE_DOCKER/calls.log" 2>/dev/null; }
state() { sed -n 's/.*"state":"\([a-z]*\)".*/\1/p' "$ATRIO_STATE/core-status.json"; }
runs() { [ "$(cat "$ATRIO_CASAOS_BIN")" = "$(cat "$1")" ]; }
ask() { echo "$1" > "$ATRIO_STATE/core-request"; bash "$core" --request; }

# Without a manifest (Atrio installed from its repository) nothing changes
bash "$core"
check "with no fixed core in this copy of Atrio, it says so" is "$(state)" unavailable
check "and CasaOS is left as it is" runs "$SB/official"

# The official v0.4.15: the fixed core goes in, the original is kept
release v0.1.28 1 one
bash "$core"
check "the fixed core is in place" runs "$SB/fixed-1"
check "and it says so" is "$(state)" fixed
check "the original is kept" cmp -s "$ATRIO_STATE/core/casaos.original" "$SB/official"
check "CasaOS was restarted once" is "$(restarts)" 1
check "and it is in the activity" has "$ATRIO_STATE/activity.log" "core-on	ok		1"
check "the status says which fix" has "$ATRIO_STATE/core-status.json" '"fix":"1"'
check "the binary can run" test -x "$ATRIO_CASAOS_BIN"
check "no download is left behind" is "$(ls -A "$ATRIO_STATE/core" | grep -c download)" 0

bash "$core"
check "a second run changes nothing" is "$(restarts)" 1

# Turned off in the settings: the original goes back and stays
ask off
check "turned off, the original is back" runs "$SB/official"
check "and it says so" is "$(state)" off
check "the activity has it" has "$ATRIO_STATE/activity.log" "core-off	ok"
bash "$core"
check "while off, a run does not put the fix back" runs "$SB/official"
check "nor restart CasaOS" is "$(restarts)" 2
check "the request is gone" test ! -e "$ATRIO_STATE/core-request"

ask on
check "turned on, the fix is back" runs "$SB/fixed-1"
check "and it says so" is "$(state)" fixed

# A new release with another fixed core: it replaces the old one, the original stays IceWhale's
release v0.1.29 2 two
bash "$core"
check "the newer fixed core is in place" runs "$SB/fixed-2"
check "the kept original is still the official one" cmp -s "$ATRIO_STATE/core/casaos.original" "$SB/official"

# What Atrio wrote is gone, but the core is this release's: it is still known as Atrio's
rm "$ATRIO_STATE/core/installed"
bash "$core"
check "Atrio's own core is recognised by its hash" is "$(state)" fixed
check "and left as it is" runs "$SB/fixed-2"

# A fixed core that does not stay up: back to the original, and not tried again by itself
release v0.1.30 3 three
FAKE_SYSTEMCTL_FAIL="is-active --quiet casaos" bash "$core"
check "a core that does not start is replaced by the original" runs "$SB/official"
check "it says it failed" is "$(state)" failed
check "the activity has it" has "$ATRIO_STATE/activity.log" "core-on	error		CasaOS did not stay up with it"
check "and no turned-off line for it" is "$(grep -c core-off "$ATRIO_STATE/activity.log")" 1
before=$(restarts)
bash "$core"
check "the failed core is not tried again by itself" runs "$SB/official"
check "nor is CasaOS restarted" is "$(restarts)" "$before"
ask on
check "turned on by hand, it gets another try" runs "$SB/fixed-3"

# A download that does not match the manifest is never used
ask off
release v0.1.31 4 four
printf 'something else\n' | gzip -c > "$SB/releases/v0.1.31/casaos-core-linux-amd64.gz"
before=$(restarts)
ask on
check "a core that does not match is not put in place" runs "$SB/official"
check "it says so" is "$(state)" failed
check "and CasaOS is not restarted" is "$(restarts)" "$before"
check "nothing is left behind" is "$(ls -A "$ATRIO_STATE/core" | grep -c download)" 0
rm -rf "$SB/releases/v0.1.31"
bash "$core"
check "offline, it fails the same way" is "$(state)" failed

# Another version of CasaOS: never touched, and the kept original is dropped
release v0.1.32 5 five
echo "casaos v0.4.16" > "$ATRIO_CASAOS_BIN"
cp "$ATRIO_CASAOS_BIN" "$SB/other"
bash "$core"
check "another CasaOS is left as it is" runs "$SB/other"
check "and it says so" is "$(state)" other
check "the original of v0.4.15 is not kept for it" test ! -e "$ATRIO_STATE/core/casaos.original"

# Removing Atrio puts the original back and forgets the rest
cp "$SB/official" "$ATRIO_CASAOS_BIN"
bash "$core"
check "fixed again" runs "$SB/fixed-5"
bash "$core" --restore
check "removing Atrio puts the original back" runs "$SB/official"
check "and leaves nothing of the fix" test ! -e "$ATRIO_STATE/core"
check "nor its status" test ! -e "$ATRIO_STATE/core-status.json"

# uninstall.sh, in a root of its own: IceWhale's core goes back with the CasaOS UI
uninstall_root() {
	root="$SB/root$1"
	mkdir -p "$root/var/lib/casaos/www" "$root/var/lib/casaos/atrio/casaos-ui-original" "$root/etc/systemd/system" \
		"$root/usr/local/bin" "$root/usr/local/share/atrio" "$root/usr/bin"
	echo Atrio > "$root/var/lib/casaos/www/index.html"
	echo CasaOS > "$root/var/lib/casaos/atrio/casaos-ui-original/index.html"
	cp "$core" "$root/usr/local/bin/atrio-core"
	cp "$ATRIO_CORE_MANIFEST" "$root/usr/local/share/atrio/casaos-core"
	cp "$SB/official" "$root/usr/bin/casaos"
	ATRIO_STATE="$root/var/lib/casaos/atrio" ATRIO_CASAOS_BIN="$root/usr/bin/casaos" \
		ATRIO_CORE_MANIFEST="$root/usr/local/share/atrio/casaos-core" bash "$core"
}
uninstall_root 1
check "in that root the fixed core runs" cmp -s "$root/usr/bin/casaos" "$SB/fixed-5"
ATRIO_ROOT="$root" bash "$SCRIPTS/uninstall.sh" >/dev/null 2>&1
check "uninstalling puts IceWhale's core back" cmp -s "$root/usr/bin/casaos" "$SB/official"
check "and removes atrio-core" test ! -e "$root/usr/local/bin/atrio-core"
check "and leaves nothing in Atrio's folder" test ! -e "$root/var/lib/casaos/atrio"

# The kept original is gone: the fixed core keeps running, and nothing else of the fix is deleted
uninstall_root 2
rm "$root/var/lib/casaos/atrio/core/casaos.original"
echo "kept by hand" > "$root/var/lib/casaos/atrio/core/note"
ATRIO_ROOT="$root" bash "$SCRIPTS/uninstall.sh" >/dev/null 2>&1
check "without its original, the fixed core is left running" cmp -s "$root/usr/bin/casaos" "$SB/fixed-5"
check "and Atrio's folder for the core is kept" has "$root/var/lib/casaos/atrio/core/note" "kept by hand"
check "while the CasaOS UI is back all the same" has "$root/var/lib/casaos/www/index.html" CasaOS

finish
