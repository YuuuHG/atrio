#!/bin/bash
# Removes Atrio and puts back the CasaOS web UI saved by install.sh.
#
#   curl -fsSL https://raw.githubusercontent.com/peppeaiello/atrio/main/scripts/uninstall.sh | sudo bash
set -euo pipefail

main() {
	# Another root folder, for the tests in tests/server only
	local ROOT="${ATRIO_ROOT:-}"
	local WWW="$ROOT/var/lib/casaos/www"
	local STATE="$ROOT/var/lib/casaos/atrio"
	local BACKUP="$STATE/casaos-ui-original"
	local UNITS="$ROOT/etc/systemd/system"

	if [ -z "$ROOT" ] && [ "$(id -u)" -ne 0 ]; then
		echo "Run it as root (with sudo)." >&2
		exit 1
	fi
	if [ ! -f "$BACKUP/index.html" ]; then
		echo "No copy of the CasaOS UI was found in $BACKUP, nothing was changed." >&2
		echo "Reinstalling or updating CasaOS puts its UI back." >&2
		exit 1
	fi

	# The restore watcher would otherwise put Atrio straight back
	systemctl disable --now atrio-update.path atrio-restore.path atrio-alerts.timer atrio-alerts-test.path atrio-backup.path atrio-backup-schedule.timer atrio-check-updates.timer >/dev/null 2>&1 || true
	systemctl stop atrio-restore.service >/dev/null 2>&1 || true

	# Stage the CasaOS UI next to the live folder, then swap with a rollback
	rm -rf "$WWW.new" "$WWW.old"
	cp -a "$BACKUP" "$WWW.new"
	# Browsers may still have Atrio's index.html cached (the gateway answers 304 to it): keep its
	# files and leave a version that differs from any release, so it reloads into CasaOS
	if [ -d "$WWW/assets" ]; then
		cp -a "$WWW/assets" "$WWW.new/assets"
	fi
	echo '{"version":"uninstalled"}' > "$WWW.new/atrio-version.json"
	chown -R root:root "$WWW.new"
	mv "$WWW" "$WWW.old"
	if ! mv "$WWW.new" "$WWW"; then
		mv "$WWW.old" "$WWW"
		echo "Could not restore the CasaOS UI, Atrio is still installed." >&2
		exit 1
	fi
	rm -rf "$WWW.old"
	# New file dates for the gateway, so browsers drop their cached Atrio
	systemctl try-restart casaos-gateway.service >/dev/null 2>&1 || true

	rm -f "$UNITS"/atrio-update.path "$UNITS"/atrio-update.service \
		"$UNITS"/atrio-restore.path "$UNITS"/atrio-restore.service "$ROOT"/usr/local/bin/atrio-update \
		"$UNITS"/atrio-alerts.service "$UNITS"/atrio-alerts.timer \
		"$UNITS"/atrio-alerts-test.service "$UNITS"/atrio-alerts-test.path "$ROOT"/usr/local/bin/atrio-alerts \
		"$UNITS"/atrio-backup.service "$UNITS"/atrio-backup.path "$ROOT"/usr/local/bin/atrio-backup \
		"$UNITS"/atrio-backup-schedule.service "$UNITS"/atrio-backup-schedule.timer \
		"$UNITS"/atrio-check-updates.service "$UNITS"/atrio-check-updates.timer
	systemctl daemon-reload
	# The backups stay where they are, and only this key can read them: it stays too, with the keys
	# a settings file replaced (backup.key.replaced-*), the only ones that read the backups made before
	if [ -f "$STATE/backup.key" ]; then
		find "$STATE" -mindepth 1 -maxdepth 1 ! -name 'backup.key' ! -name 'backup.key.replaced-*' -exec rm -rf {} + 2>/dev/null
		echo "The backup key stays in $STATE/backup.key: Atrio's backups cannot be restored without it."
	else
		rm -rf "$STATE"
	fi
	rm -rf "$ROOT"/usr/local/share/atrio
	# The Docker Compose that atrio-backup downloaded on a server without one
	rm -rf "$ROOT"/usr/local/lib/atrio
	echo "CasaOS UI restored. Reload the page in your browser (Ctrl+F5)."
}

main "$@"
