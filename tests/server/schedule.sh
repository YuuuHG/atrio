#!/bin/bash
# Automatic backups: schedules, when they run, how many are kept, and what a failure leaves.
. "$(dirname "$0")/lib.sh"
sandbox
# run_due: the planned time has come (the last one done is long ago), then the timer runs
run_due() {
	sed -i 's/^SLOT=.*/SLOT=1/' "$ATRIO_STATE/schedules/web"
	bash "$SCRIPTS/atrio-backup" --scheduled >/dev/null 2>&1
	sleep 1
}

request ACTION=backup APP=web "FOLDER=$ATRIO_APPDATA/web/config"
request ACTION=schedule APP=web EVERY=daily TIME=03:00 KEEP=2 "FOLDER=$ATRIO_APPDATA/web/config"
check "a daily schedule is saved" is "$STATE_" done
check "the tab sees it" has "$ATRIO_STATE/backups/web.json" '"schedule":{"every":"daily","time":"03:00","day":1,"keep":2'
bash "$SCRIPTS/atrio-backup" --scheduled >/dev/null 2>&1
check "nothing runs before the next planned time" is "$(count_backups web)" 1

run_due
check "a backup runs once its time has come" is "$(count_backups web)" 2
check "it is marked as automatic" has "$ATRIO_STATE/backups/web.json" '"reason":"scheduled"'
check "the tab shows the last one" has "$ATRIO_STATE/backups/web.json" '"last_error":""'
bash "$SCRIPTS/atrio-backup" --scheduled >/dev/null 2>&1
check "and does not run twice for the same time" is "$(count_backups web)" 2
run_due
run_due
check "only the last 2 automatic ones are kept, and the one by hand" is "$(count_backups web)" 3
check "the one by hand stays" test "$(grep -l REASON=manual "$ATRIO_BACKUP_DEST"/web/*.info | wc -l)" -eq 1

request ACTION=schedule APP=web EVERY=weekly TIME=04:30 DAY=3 KEEP=5
check "a weekly schedule is saved" has "$ATRIO_STATE/schedules/web" "DAY=3"
slot=$(sed -n 's/^SLOT=//p' "$ATRIO_STATE/schedules/web")
check "its first time is a Wednesday at 04:30" is "$(date -d "@$slot" '+%u %H:%M')" "3 04:30"
for bad in "EVERY=hourly TIME=03:00 KEEP=2" "EVERY=daily TIME=25:00 KEEP=2" "EVERY=daily TIME=03:00 KEEP=99" "EVERY=weekly TIME=03:00 DAY=9 KEEP=2"; do
	# shellcheck disable=SC2086
	request ACTION=schedule APP=web $bad
	check "a schedule with $bad is refused" is "$MESSAGE" "The schedule is not valid"
done

# A failure is kept for the tab and the push alert, and the other apps still get theirs
add_app other redis:7 sha256:bbbb
request ACTION=schedule APP=other EVERY=daily TIME=03:00 KEEP=2 "FOLDER=$ATRIO_APPDATA/other/config"
request ACTION=schedule APP=web EVERY=daily TIME=03:00 KEEP=2
printf 'DEST=/proc/nope/atrio-backups\nMOUNT=\n' > "$ATRIO_STATE/backup.conf"
sed -i 's/^SLOT=.*/SLOT=1/' "$ATRIO_STATE/schedules/web" "$ATRIO_STATE/schedules/other"
bash "$SCRIPTS/atrio-backup" --scheduled >/dev/null 2>&1
check "a failed automatic backup is recorded" has "$ATRIO_STATE/schedules/web" "LAST_ERROR=The backup folder is not valid"
check "and the next app is still tried" has "$ATRIO_STATE/schedules/other" "LAST_ERROR=The backup folder is not valid"
rm -f "$ATRIO_STATE/backup.conf"

request ACTION=schedule APP=web EVERY=off
check "a schedule can be turned off" test ! -e "$ATRIO_STATE/schedules/web"
check "the tab sees no schedule" has "$ATRIO_STATE/backups/web.json" '"schedule":null'

# An app that is uninstalled loses its schedule, and its list once it has no backups
rm -rf "$ATRIO_APPS/other"
bash "$SCRIPTS/atrio-backup" --scheduled >/dev/null 2>&1
check "the schedule of an app not installed waits (loaded with the settings on a new machine)" test -e "$ATRIO_STATE/schedules/other"
touch -d '8 days ago' "$ATRIO_STATE/schedules/other"
bash "$SCRIPTS/atrio-backup" --scheduled >/dev/null 2>&1
check "the schedule of an uninstalled app goes away after a week" test ! -e "$ATRIO_STATE/schedules/other"
check "and its list too, as it has no backups" test ! -e "$ATRIO_STATE/backups/other.json"
finish
