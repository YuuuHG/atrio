#!/bin/bash
# Backups by hand, restores, deletes, backup folders and the checks that keep a restore safe.
. "$(dirname "$0")/lib.sh"
sandbox

request ACTION=scan APP=web
check "scan writes the app's folders" has "$ATRIO_STATE/backups/web.json" "\"path\":\"$ATRIO_APPDATA/web/config\",\"size\":10,\"selected\":true"

request ACTION=backup APP=web "FOLDER=$ATRIO_APPDATA/web/config"
check "a backup by hand ends done" is "$STATE_" done
first="$ID"
archive="$ATRIO_BACKUP_DEST/web/$first.tar.gz"
check "the archive is there" test -s "$archive"
check "the archive is encrypted, not a plain tar.gz" bash -c "! head -c 2 '$archive' | od -An -tx1 | grep -q '1f 8b'"
check "the archive has a signature" has "$ATRIO_BACKUP_DEST/web/$first.info" "MAC="
check "the app runs again after it" is "$(docker_query "state['containers'][0]['state']")" running
check "the folders chosen are remembered" has "$ATRIO_STATE/backups/web.folders" "$ATRIO_APPDATA/web/config"
check "the key is root-only" is "$(stat -c %a "$ATRIO_STATE/backup.key")" 600

echo "version 2" > "$ATRIO_APPDATA/web/config/data.txt"
echo "new file" > "$ATRIO_APPDATA/web/config/new.txt"
request ACTION=restore APP=web "ID=$first"
check "a restore ends done" is "$STATE_" done
check "the data are back as they were" is "$(cat "$ATRIO_APPDATA/web/config/data.txt")" "version 1"
check "files made later are gone" test ! -e "$ATRIO_APPDATA/web/config/new.txt"
check "a copy of the state before the restore is kept" has "$ATRIO_STATE/backups/web.json" '"reason":"before-restore"'
check "the app runs after the restore" is "$(docker_query "state['containers'][0]['state']")" running

# A backup changed after it was made is never restored
cp "$ATRIO_BACKUP_DEST/web/$first.info" "$SB/info.orig"
sed -i 's/^BYTES=.*/BYTES=1/' "$ATRIO_BACKUP_DEST/web/$first.info"
request ACTION=restore APP=web "ID=$first"
check "a changed backup is refused" is "$MESSAGE" "This backup was changed after it was made, or made on another server, and was not restored"
cp "$SB/info.orig" "$ATRIO_BACKUP_DEST/web/$first.info"

# An archive with a file outside the app's folders, signed with the right key, is refused too
key=$(cat "$ATRIO_STATE/backup.key")
mkdir -p "$SB/evil/etc" && echo x > "$SB/evil/etc/cron.txt"
evil="$ATRIO_BACKUP_DEST/web/20990101-000000"
tar -czf - -C "$SB/evil" etc | openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -pass "file:$ATRIO_STATE/backup.key" -out "$evil.tar.gz"
{
	printf 'TIME=2099-01-01T00:00:00+00:00\nREASON=manual\nBYTES=10\nIMAGES=\nRUNNING=1\nENCRYPTED=aes-256-cbc\nSHA256=%s\n' "$(sha256sum "$evil.tar.gz" | cut -d' ' -f1)"
	printf 'FOLDER=%s\nFOLDER=%s\n' "$ATRIO_APPS/web" "$ATRIO_APPDATA/web/config"
} > "$evil.info"
printf 'MAC=%s\n' "$({ printf '%s\n' "$key"; cat "$evil.info"; printf '%s\n' "$key"; } | sha256sum | cut -d' ' -f1)" >> "$evil.info"
request ACTION=restore APP=web ID=20990101-000000
check "an archive with files outside the app is refused" is "$MESSAGE" "This backup contains files outside the folders of this app and was not restored"
check "and nothing outside was written" test ! -e /etc/cron.txt

request ACTION=delete APP=web "ID=$first"
check "a delete ends done" is "$STATE_" done
check "the deleted backup is gone" test ! -e "$archive"

# Another backup folder, chosen like in the tab: Atrio adds atrio-backups inside it
mkdir -p "$SB/disk2"
request ACTION=destination APP=web "DEST=$SB/disk2"
check "a new backup folder is accepted" is "$STATE_" done
request ACTION=backup APP=web "FOLDER=$ATRIO_APPDATA/web/config"
check "backups then go there" test -n "$(ls "$SB/disk2/atrio-backups/web/"*.tar.gz 2>/dev/null)"
request ACTION=destination APP=web DEST=/etc
check "a system folder is refused" is "$MESSAGE" "This folder cannot hold backups: choose another one"
# A disk that is gone leaves an empty folder behind: backups must not fill the main disk
sed -i 's|^MOUNT=.*|MOUNT=/media/gone|' "$ATRIO_STATE/backup.conf"
request ACTION=backup APP=web "FOLDER=$ATRIO_APPDATA/web/config"
check "a folder whose disk is gone is not used" is "$MESSAGE" "The backup folder is not connected: plug in the disk or reconnect the folder, or choose another one"
request ACTION=destination APP=web DEST=
check "back to the default folder" is "$STATE_" done

request ACTION=backup APP=nope
check "an unknown app is refused" is "$MESSAGE" "Unknown app"
request ACTION=nonsense APP=web
check "an unknown request is refused" is "$MESSAGE" "Unknown request"
request ACTION=backup "APP=../etc"
check "an app name with a path is refused" is "$MESSAGE" "Unknown app"

# A request that comes during another run waits for it, instead of starting the service again and again
( exec 9>"$ATRIO_STATE/backup.lock"; flock 9; sleep 3 ) &
sleep 1
start=$(date +%s)
request ACTION=scan APP=web
check "a request waits for the lock" test $(( $(date +%s) - start )) -ge 1
check "and then runs" is "$STATE_" done
wait

check "the activity log has the backups and restores" has "$ATRIO_STATE/activity.log" "	restore	ok	web	"
check "and the refusals, with their reason" has "$ATRIO_STATE/activity.log" "	restore	error	web	This backup was changed"
finish
