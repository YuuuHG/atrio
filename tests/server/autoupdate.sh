#!/bin/bash
# Automatic updates: turned on per app, run once a night after the planned time, the way an update
# by hand runs, and a new image that does not start is not tried again.
. "$(dirname "$0")/lib.sh"
sandbox
new=sha256:$(printf '2%.0s' {1..64})
docker_state "state['remote'] = {'registry-1.docker.io/library/nginx:1.0': '$new'}"
docker_state "state['registry'] = {'nginx:1.0': {'id': 'sha256:cccc', 'digest': '$new'}}"
log="$ATRIO_STATE/activity.log"
image() { docker_query "state['containers'][0]['image']"; }
# The planned time was a few minutes ago; night N: the last run was the night before
export ATRIO_AUTO_UPDATE_TIME="$(date -d '-5 min' +%H:%M)"
night() {
	printf '1\n' > "$ATRIO_STATE/auto-update-slot"
	bash "$SCRIPTS/atrio-backup" --scheduled >/dev/null 2>&1
}

request ACTION=auto-updates APP=web AUTO=1
check "automatic updates can be turned on" has "$ATRIO_STATE/updates.json" '"auto":["web"]'
check "and the change is logged" has "$log" "auto-updates	ok	web	1"
request ACTION=ignore-updates APP=web IGNORE=1
check "ignoring the updates turns them off" has "$ATRIO_STATE/updates.json" '"auto":[]'
request ACTION=auto-updates APP=web AUTO=1
check "turning them on shows the updates again" has "$ATRIO_STATE/updates.json" '"ignored":[]'
check "and keeps them on" has "$ATRIO_STATE/updates.json" '"auto":["web"]'
request ACTION=auto-updates APP=nope AUTO=1
check "an unknown app is refused" is "$MESSAGE" "Unknown app"

bash "$SCRIPTS/atrio-backup" --scheduled >/dev/null 2>&1
check "the first run only marks the time" is "$(image)" sha256:aaaa
check "with the time saved" test -s "$ATRIO_STATE/auto-update-slot"
bash "$SCRIPTS/atrio-backup" --scheduled >/dev/null 2>&1
check "the same night is not run twice" is "$(image)" sha256:aaaa

night
check "at night the app gets the newer image" is "$(image)" sha256:cccc
check "after a backup" has "$ATRIO_STATE/backups/web.json" '"reason":"before-update"'
check "the log tells it was automatic" has "$log" "auto-update	ok	web"
check "the result is saved" has "$ATRIO_STATE/auto-update-results" "web	"
check "as done" is "$(cut -f3 "$ATRIO_STATE/auto-update-results")" ok
check "the remote image is in the check" has "$ATRIO_STATE/updates.json" "\"remote\":\"$new\""

# Too late: a server off all night does not update in the middle of the day
newer=sha256:$(printf '3%.0s' {1..64})
docker_state "state['remote']['registry-1.docker.io/library/nginx:1.0'] = '$newer'"
docker_state "state['registry']['nginx:1.0'] = {'id': 'sha256:dddd', 'digest': '$newer'}"
ATRIO_AUTO_UPDATE_TIME="$(date -d '-5 hours' +%H:%M)" night
check "more than four hours after the time nothing is updated" is "$(image)" sha256:cccc

# Turned off: nothing happens
request ACTION=auto-updates APP=web AUTO=0
night
check "an app turned off is not updated" is "$(image)" sha256:cccc
request ACTION=auto-updates APP=web AUTO=1

# The new image does not start: back to the backup, and the same image is not tried again
echo sha256:dddd > "$FAKE_DOCKER/crash"
night
check "a new image that does not start goes back" is "$(image)" sha256:cccc
check "the failure is saved" is "$(cut -f3 "$ATRIO_STATE/auto-update-results")" error
check "with the reason" has "$ATRIO_STATE/auto-update-results" "The new version did not start"
check "and logged" has "$log" "auto-update	error	web"
before=$(count_backups web)
night
check "the next night the same image is not tried again" is "$(count_backups web)" "$before"
rm "$FAKE_DOCKER/crash"

# A newer image is tried
newest=sha256:$(printf '4%.0s' {1..64})
docker_state "state['remote']['registry-1.docker.io/library/nginx:1.0'] = '$newest'"
docker_state "state['registry']['nginx:1.0'] = {'id': 'sha256:eeee', 'digest': '$newest'}"
night
check "a newer image is tried again" is "$(image)" sha256:eeee
check "and the result is done" is "$(cut -f3 "$ATRIO_STATE/auto-update-results")" ok

# The backup folder is missing: nothing changes, and it is tried again the next night
printf 'DEST=/proc/nope/atrio-backups\nMOUNT=\n' > "$ATRIO_STATE/backup.conf"
newer2=sha256:$(printf '5%.0s' {1..64})
docker_state "state['remote']['registry-1.docker.io/library/nginx:1.0'] = '$newer2'"
docker_state "state['registry']['nginx:1.0'] = {'id': 'sha256:ffff', 'digest': '$newer2'}"
night
check "without a backup folder the app is not changed" is "$(image)" sha256:eeee
check "and the failure is saved" is "$(cut -f3 "$ATRIO_STATE/auto-update-results")" error
rm -f "$ATRIO_STATE/backup.conf"
night
check "the next night it is tried again" is "$(image)" sha256:ffff

# Going back fails too (neither version starts): the same image is still not tried again
broken=sha256:$(printf '6%.0s' {1..64})
docker_state "state['remote']['registry-1.docker.io/library/nginx:1.0'] = '$broken'"
docker_state "state['registry']['nginx:1.0'] = {'id': 'sha256:abab', 'digest': '$broken'}"
pulls() { grep -c ' pull$' "$FAKE_DOCKER/calls.log"; }
echo nginx:1.0 > "$FAKE_DOCKER/crash"
night
check "when going back fails too, the old image is put back" is "$(image)" sha256:ffff
check "with the reason of that failure" has "$ATRIO_STATE/auto-update-results" "The files are back, but"
before=$(pulls)
night
check "and the same image is not tried again" is "$(pulls)" "$before"
rm "$FAKE_DOCKER/crash"

# Uninstalled apps leave both lists; installed ones stay
add_app other redis:7 sha256:bbbb
add_app quiet postgres:16 sha256:9999
request ACTION=auto-updates APP=other AUTO=1
request ACTION=ignore-updates APP=quiet IGNORE=1
rm -r "$ATRIO_APPS/web" "$ATRIO_APPS/quiet"
bash "$SCRIPTS/atrio-backup" --scheduled >/dev/null 2>&1
check "an uninstalled app leaves the automatic updates" lacks "$ATRIO_STATE/auto-updates" web
check "and the ignored updates" lacks "$ATRIO_STATE/updates-ignored" quiet
check "an installed app stays" has "$ATRIO_STATE/auto-updates" other
add_app web nginx:1.0 sha256:aaaa
request ACTION=check-updates APP=web
check "installed again, it has automatic updates off" has "$ATRIO_STATE/updates.json" '"auto":["other"]'
finish
