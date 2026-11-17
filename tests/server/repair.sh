#!/bin/bash
# The self-repair of the services (repairServer in src/plugins/atrioRelease.js): on a server whose
# updater is old, the web UI writes the updater shipped in www/server over it and asks for an
# update. Here that write is done like the CasaOS file API does it (in place), for the updaters of
# each family of old installs, and the new updater must then adopt the key, check the signature,
# install the services, and put everything back when their setup fails half way.
. "$(dirname "$0")/lib.sh"
sandbox
export GNUPGHOME="$SB/gnupg"
mkdir -p "$GNUPGHOME" "$SB/rel" "$SB/build/server" "$SB/server"
chmod 700 "$GNUPGHOME"
gpg --batch --quiet --passphrase '' --quick-gen-key "Atrio test key" ed25519 sign never 2>/dev/null
gpg --export > "$SB/key.gpg"

# Release 9.9.9 as scripts/release.sh makes it, with the updater and the key inside the web UI
echo '<html>Atrio</html>' > "$SB/build/index.html"
echo '{"version":"9.9.9"}' > "$SB/build/atrio-version.json"
cp "$SCRIPTS/atrio-update" "$SB/build/server/"
cp "$SB/key.gpg" "$SB/build/server/atrio-release-key.gpg"
tar -czf "$SB/rel/atrio.tar.gz" -C "$SB/build" .
(cd "$SB/rel" && sha256sum atrio.tar.gz > atrio.tar.gz.sha256)
cp "$SCRIPTS"/atrio-update "$SCRIPTS"/atrio-alerts "$SCRIPTS"/atrio-backup "$SCRIPTS"/atrio-setup "$SB/server/"
cp "$SB/key.gpg" "$SB/server/atrio-release-key.gpg"
echo 9.9.9 > "$SB/server/VERSION"
tar -czf "$SB/rel/atrio-server.tar.gz" -C "$SB/server" .
for file in atrio.tar.gz atrio-server.tar.gz; do gpg --batch --yes --detach-sign -o "$SB/rel/$file.sig" "$SB/rel/$file"; done
export ATRIO_DOWNLOAD="file://$SB/rel"
status() { sed -n 's/.*"message":"\([^"]*\)".*/\1/p' "$ATRIO_STATE/update-status.json"; }

# A server as an old install left it: its own updater, the web UI 9.9.9 that this old updater has
# just installed (so the shipped updater and key are in www), and what that version had besides
# $1: the tag of the old install; $2: key | nokey; $3: the services' version or nothing
old_server() {
	export ATRIO_ROOT="$SB/root-$1" ATRIO_STATE="$SB/state-$1" ATRIO_WWW="$SB/www-$1"
	export ATRIO_RELEASE_KEY="$ATRIO_ROOT/usr/local/share/atrio/release-key.gpg"
	rm -rf "$ATRIO_ROOT" "$ATRIO_STATE" "$ATRIO_WWW"
	mkdir -p "$ATRIO_ROOT/etc/systemd/system" "$ATRIO_ROOT/usr/local/bin" "$ATRIO_STATE" "$ATRIO_WWW"
	tar -xzf "$SB/rel/atrio.tar.gz" -C "$ATRIO_WWW"
	git -C "$SCRIPTS/.." show "$1:scripts/atrio-update" > "$ATRIO_ROOT/usr/local/bin/atrio-update"
	chmod 755 "$ATRIO_ROOT/usr/local/bin/atrio-update"
	if [ "$2" = key ]; then
		mkdir -p "$(dirname "$ATRIO_RELEASE_KEY")"
		cp "$SB/key.gpg" "$ATRIO_RELEASE_KEY"
	fi
	[ -z "${3:-}" ] || echo "$3" > "$ATRIO_STATE/server-version"
}

# What the web UI does: the shipped updater written over the installed one, in place, then a request
web_ui_repairs() {
	cat "$ATRIO_WWW/server/atrio-update" > "$ATRIO_ROOT/usr/local/bin/atrio-update"
	echo "repair-token" > "$ATRIO_STATE/update-request"
	bash "$ATRIO_ROOT/usr/local/bin/atrio-update" >/dev/null 2>&1
}

# Every family of old installs: no key (up to 0.1.14), a key but no services' version (0.1.15-0.1.16),
# and older services (0.1.17 on)
for family in "v0.1.0 nokey" "v0.1.3 nokey" "v0.1.9 nokey" "v0.1.14 nokey" "v0.1.16 key" "v0.1.20 key 0.1.20"; do
	set -- $family
	old_server "$1" "$2" "${3:-}"
	web_ui_repairs
	check "$1: the updater on the server is the new one" cmp -s "$ATRIO_ROOT/usr/local/bin/atrio-update" "$SCRIPTS/atrio-update"
	check "$1: it is still executable" is "$(stat -c %a "$ATRIO_ROOT/usr/local/bin/atrio-update")" 755
	check "$1: the release key is in place" cmp -s "$ATRIO_RELEASE_KEY" "$SB/key.gpg"
	check "$1: the services are installed" test -x "$ATRIO_ROOT/usr/local/bin/atrio-backup"
	check "$1: with their timers" test -f "$ATRIO_ROOT/etc/systemd/system/atrio-check-updates.timer"
	check "$1: their version is recorded" is "$(cat "$ATRIO_STATE/server-version" 2>/dev/null)" 9.9.9
	check "$1: the run is the web UI's" has "$ATRIO_STATE/update-status.json" '"token":"repair-token"'
	check "$1: the web UI is left as it is" is "$(status)" "Atrio 9.9.9 is already installed"
done

# A key already there is never replaced by the one in www: the release is then refused
old_server v0.1.16 key
gpg --batch --quiet --passphrase '' --quick-gen-key "Another key" ed25519 sign never 2>/dev/null
gpg --export "Another key" > "$ATRIO_RELEASE_KEY"
cp "$ATRIO_RELEASE_KEY" "$SB/other.gpg"
web_ui_repairs
check "an installed key is kept" cmp -s "$ATRIO_RELEASE_KEY" "$SB/other.gpg"
check "and a release it did not sign is refused" is "$(status)" "The release on GitHub is not signed by Atrio, so it was not installed"
check "with no services installed" test ! -e "$ATRIO_ROOT/usr/local/bin/atrio-backup"

# A key in www that is a link (pointing anywhere) is not adopted
old_server v0.1.9 nokey
mv "$ATRIO_WWW/server/atrio-release-key.gpg" "$SB/key-elsewhere.gpg"
ln -s "$SB/key-elsewhere.gpg" "$ATRIO_WWW/server/atrio-release-key.gpg"
web_ui_repairs
check "a key that is a link is not adopted" test ! -e "$ATRIO_RELEASE_KEY"
check "and no services come without a key" test ! -e "$ATRIO_ROOT/usr/local/bin/atrio-backup"

# Once adopted, the key is enforced: a server bundle changed after signing is refused
old_server v0.1.9 nokey
cp "$SB/rel/atrio-server.tar.gz" "$SB/bundle.orig"
echo x >> "$SB/rel/atrio-server.tar.gz"
web_ui_repairs
check "the adopted key refuses a changed server bundle" is "$(status)" "Atrio 9.9.9 is installed, but the services on the server could not be updated"
check "and installs no services" test ! -e "$ATRIO_ROOT/usr/local/bin/atrio-backup"
cp "$SB/bundle.orig" "$SB/rel/atrio-server.tar.gz"

# The services of another release, signed too, are not installed under this release's name
old_server v0.1.20 key 0.1.20
cp "$SB/rel/atrio-server.tar.gz" "$SB/bundle.orig"; cp "$SB/rel/atrio-server.tar.gz.sig" "$SB/bundle.sig.orig"
echo 9.9.8 > "$SB/server/VERSION"
tar -czf "$SB/rel/atrio-server.tar.gz" -C "$SB/server" .
gpg --batch --yes --detach-sign -o "$SB/rel/atrio-server.tar.gz.sig" "$SB/rel/atrio-server.tar.gz"
web_ui_repairs
check "services of another version are refused" is "$(status)" "Atrio 9.9.9 is installed, but the services on the server could not be updated"
check "and not installed" test ! -e "$ATRIO_ROOT/usr/local/bin/atrio-backup"
echo 9.9.9 > "$SB/server/VERSION"
cp "$SB/bundle.orig" "$SB/rel/atrio-server.tar.gz"; cp "$SB/bundle.sig.orig" "$SB/rel/atrio-server.tar.gz.sig"

# The new updater written over itself while it runs (what the web UI may do): bash read the whole
# script first, so it goes on with its own text and runs none of the new one
old_server v0.1.20 key 0.1.20
cp "$SCRIPTS/atrio-update" "$ATRIO_ROOT/usr/local/bin/atrio-update"
echo '<html>CasaOS</html>' > "$ATRIO_WWW/index.html"
ATRIO_RESTORE_DELAY=2 bash "$ATRIO_ROOT/usr/local/bin/atrio-update" --restore >/dev/null 2>&1 &
pid=$!
sleep 0.5
{ printf '#!/bin/bash\n'; for i in $(seq 400); do printf 'touch %q\n' "$SB/ran-new-text"; done; } > "$ATRIO_ROOT/usr/local/bin/atrio-update"
wait "$pid"
check "an updater written over while it runs runs none of the new text" test ! -e "$SB/ran-new-text"
check "and finishes its own work" has "$ATRIO_WWW/index.html" Atrio

# A setup that fails half way: the services of before come back as they were
old_server v0.1.20 key 0.1.20
for name in atrio-alerts atrio-backup; do printf '#!/bin/bash\n# old %s\n' "$name" > "$ATRIO_ROOT/usr/local/bin/$name"; chmod 755 "$ATRIO_ROOT/usr/local/bin/$name"; done
echo "[Unit]" > "$ATRIO_ROOT/etc/systemd/system/atrio-update.path"
FAKE_SYSTEMCTL_FAIL="enable --now atrio-check-updates.timer" web_ui_repairs
check "a failed setup puts the old services back" has "$ATRIO_ROOT/usr/local/bin/atrio-backup" "# old atrio-backup"
check "and the old units" is "$(cat "$ATRIO_ROOT/etc/systemd/system/atrio-update.path")" "[Unit]"
check "and removes the units it had added" test ! -e "$ATRIO_ROOT/etc/systemd/system/atrio-check-updates.timer"
check "the scripts stay executable" is "$(stat -c %a "$ATRIO_ROOT/usr/local/bin/atrio-backup")" 755
check "the services' version is not moved on" is "$(cat "$ATRIO_STATE/server-version")" 0.1.20
check "the status says so" is "$(status)" "Atrio 9.9.9 is installed, but the services on the server could not be updated"
check "and the activity log too" has "$ATRIO_STATE/activity.log" "atrio-update	error		services 9.9.9"
FAKE_SYSTEMCTL_FAIL="" web_ui_repairs
check "the next try installs them" test -f "$ATRIO_ROOT/etc/systemd/system/atrio-check-updates.timer"
check "and records their version" is "$(cat "$ATRIO_STATE/server-version")" 9.9.9
finish
