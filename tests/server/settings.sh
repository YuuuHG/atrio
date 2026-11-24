#!/bin/bash
# The settings file: saved encrypted with a password, loaded back, and refused when it is not safe.
. "$(dirname "$0")/lib.sh"
sandbox
request ACTION=backup APP=web "FOLDER=$ATRIO_APPDATA/web/config"
printf 'ENABLED=1\nSERVICE=ntfy\nTOPIC=private-topic\n' > "$ATRIO_STATE/alerts.conf"
request ACTION=schedule APP=web EVERY=daily TIME=03:00 KEEP=4
ui='{"custom":{"system":{"lang":"it_it"}},"local":{"atrio:layout-width":"1400"}}'

echo "$ui" > "$ATRIO_STATE/settings-ui.json"
request ACTION=export-settings APP=atrio PASSWORD=short
check "a short password is refused" is "$MESSAGE" "The password must be at least 8 characters long"
echo "$ui" > "$ATRIO_STATE/settings-ui.json"
request ACTION=export-settings APP=atrio "PASSWORD=a pass=word!"
check "the settings are saved" is "$STATE_" done
cp "$ATRIO_STATE/settings-export.txt" "$SB/settings.atrio"
check "the file is encrypted" lacks "$SB/settings.atrio" private-topic
check "the file is root-only on the server" is "$(stat -c %a "$ATRIO_STATE/settings-export.txt")" 600
check "the web UI's part was not left behind" test ! -e "$ATRIO_STATE/settings-ui.json"

cp "$SB/settings.atrio" "$ATRIO_STATE/settings-import.txt"
request ACTION=import-settings APP=atrio PASSWORD=wrong-password
check "a wrong password is refused" is "$MESSAGE" "Wrong password, or this is not an Atrio settings file"
check "the uploaded file is not kept" test ! -e "$ATRIO_STATE/settings-import.txt"

rm -f "$ATRIO_STATE/alerts.conf" "$ATRIO_STATE/schedules/web"
cp "$SB/settings.atrio" "$ATRIO_STATE/settings-import.txt"
request ACTION=import-settings APP=atrio "PASSWORD=a pass=word!"
check "the settings are loaded" is "$STATE_" done
check "the push alerts are back" has "$ATRIO_STATE/alerts.conf" TOPIC=private-topic
check "and root-only" is "$(stat -c %a "$ATRIO_STATE/alerts.conf")" 600
check "the schedule is back" has "$ATRIO_STATE/schedules/web" KEEP=4
check "and starts from its next time, not at once" test "$(sed -n 's/^SLOT=//p' "$ATRIO_STATE/schedules/web")" -gt 1
check "the web UI gets its part" has "$ATRIO_STATE/settings-imported.json" '"atrio:layout-width":"1400"'

# A server with another key keeps it unless asked, and then saves it
key=$(cat "$ATRIO_STATE/backup.key")
printf '%064d\n' 0 | tr 0 a > "$ATRIO_STATE/backup.key"
cp "$SB/settings.atrio" "$ATRIO_STATE/settings-import.txt"
request ACTION=import-settings APP=atrio "PASSWORD=a pass=word!"
check "another key is not replaced without asking" is "$MESSAGE" "This server already has its own backup key"
cp "$SB/settings.atrio" "$ATRIO_STATE/settings-import.txt"
request ACTION=import-settings APP=atrio "PASSWORD=a pass=word!" REPLACE_KEY=1
check "with consent the key from the file is used" is "$(cat "$ATRIO_STATE/backup.key")" "$key"
check "and the old one is kept" test -n "$(ls "$ATRIO_STATE"/backup.key.replaced-* 2>/dev/null)"

# Uninstalling keeps the keys, the one replaced too (it reads the backups made before), and nothing else
root="$SB/root"
mkdir -p "$root/var/lib/casaos/www" "$root/etc/systemd/system" "$root/usr/local/bin" "$root/usr/local/share/atrio" "$root/usr/local/lib/atrio"
echo compose > "$root/usr/local/lib/atrio/docker-compose"
echo Atrio > "$root/var/lib/casaos/www/index.html"
cp -a "$ATRIO_STATE" "$root/var/lib/casaos/atrio"
mkdir -p "$root/var/lib/casaos/atrio/casaos-ui-original"
echo CasaOS > "$root/var/lib/casaos/atrio/casaos-ui-original/index.html"
ATRIO_ROOT="$root" bash "$SCRIPTS/uninstall.sh" >/dev/null 2>&1
check "uninstalling puts the CasaOS UI back" has "$root/var/lib/casaos/www/index.html" CasaOS
check "and keeps the backup key" is "$(cat "$root/var/lib/casaos/atrio/backup.key")" "$key"
check "and the key a settings file replaced" test -n "$(ls "$root"/var/lib/casaos/atrio/backup.key.replaced-* 2>/dev/null)"
check "and nothing else" is "$(ls "$root/var/lib/casaos/atrio" | grep -cv '^backup\.key')" 0
check "the Docker Compose it downloaded goes too" test ! -e "$root/usr/local/lib/atrio"

# Files made by hand: a link, a file outside the folder, a newer format, values that are not valid
make_file() {
	printf 'evilpass1' > "$SB/pass"
	tar -czf - -C "$1" "${@:2}" | openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -a -pass "file:$SB/pass" -out "$ATRIO_STATE/settings-import.txt"
}
mkdir -p "$SB/f1/atrio-settings" && echo 1 > "$SB/f1/atrio-settings/format" && ln -s /etc/passwd "$SB/f1/atrio-settings/alerts.conf"
make_file "$SB/f1" atrio-settings
request ACTION=import-settings APP=atrio PASSWORD=evilpass1
check "a file with a link is refused" is "$MESSAGE" "This settings file contains unexpected files and was not used"
mkdir -p "$SB/f2/atrio-settings" && echo 1 > "$SB/f2/atrio-settings/format" && echo x > "$SB/f2/outside"
make_file "$SB/f2" atrio-settings outside
request ACTION=import-settings APP=atrio PASSWORD=evilpass1
check "a file with something outside its folder is refused" is "$MESSAGE" "This settings file contains unexpected files and was not used"
mkdir -p "$SB/f3/atrio-settings" && echo 9 > "$SB/f3/atrio-settings/format"
make_file "$SB/f3" atrio-settings
request ACTION=import-settings APP=atrio PASSWORD=evilpass1
check "a newer format asks to update Atrio" is "$MESSAGE" "This settings file was made by a newer Atrio: update Atrio first"
mkdir -p "$SB/f4/atrio-settings/schedules" "$SB/f4/atrio-settings/folders" && echo 1 > "$SB/f4/atrio-settings/format"
printf 'EVERY=daily\nTIME=99:00\nDAY=1\nKEEP=2\n' > "$SB/f4/atrio-settings/schedules/web"
printf '/etc\n' > "$SB/f4/atrio-settings/folders/web"
printf 'DEST=/etc/x\n' > "$SB/f4/atrio-settings/backup.conf"
make_file "$SB/f4" atrio-settings
request ACTION=import-settings APP=atrio PASSWORD=evilpass1
check "values that are not valid are skipped" has "$ATRIO_STATE/schedules/web" TIME=03:00
check "a system folder is not taken as an app folder" lacks "$ATRIO_STATE/backups/web.folders" /etc
check "a system folder is not taken as the backup folder" test ! -e "$ATRIO_STATE/backup.conf"
finish
