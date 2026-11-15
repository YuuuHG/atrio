#!/bin/bash
# atrio-alerts: apps installed, removed and updated go to the activity log (also with alerts off),
# a failed automatic backup sends one alert, and a test message reports the service's own answer.
. "$(dirname "$0")/lib.sh"
sandbox
alerts() { bash "$SCRIPTS/atrio-alerts" "$@" >/dev/null 2>&1; }
log="$ATRIO_STATE/activity.log"

alerts
check "the first run only takes note of the apps" test ! -s "$log"
add_app new redis:7 sha256:bbbb
alerts
check "an app installed is logged, with alerts off" has "$log" "app-installed	ok	new"
docker_state "state['containers'][0]['image'] = 'sha256:cccc'"
alerts
check "an app updated outside Atrio is logged" has "$log" "app-updated	ok	web"
alerts
check "once" is "$(grep -c "app-updated	ok	web" "$log")" 1
rm -rf "$ATRIO_APPS/new"
alerts
check "an app removed is logged" has "$log" "app-removed	ok	new"
# An update atrio-backup made itself is not logged twice
printf '%s\tupdate-app\tok\tweb\tX\n' "$(date -Iseconds)" >> "$log"
docker_state "state['containers'][0]['image'] = 'sha256:dddd'"
alerts
check "an update made by atrio-backup is not logged again" is "$(grep -c "app-updated	ok	web" "$log")" 1

printf 'ENABLED=1\nSERVICE=ntfy\nURL=https://ntfy.example\nTOPIC=test-topic\nDISK=0\nHEALTH=0\nTEMP=0\nAPPS=0\nAPP_UPDATES=0\nUPDATES=0\nLANGUAGE=it\n' > "$ATRIO_STATE/alerts.conf"
mkdir -p "$ATRIO_STATE/schedules"
printf 'EVERY=daily\nTIME=03:00\nDAY=1\nKEEP=2\nSLOT=1\nLAST_TIME=2026-11-10T03:00:00+01:00\nLAST_ERROR=The backup folder is not valid\n' > "$ATRIO_STATE/schedules/web"
alerts
check "a failed automatic backup sends an alert" has "$FAKE_DOCKER/sent.log" "Il backup automatico di web non è riuscito: The backup folder is not valid"
check "to the topic set" has "$FAKE_DOCKER/sent.log" "https://ntfy.example/test-topic"
alerts
check "only once" is "$(grep -c "non è riuscito" "$FAKE_DOCKER/sent.log")" 1
check "the alerts settings are root-only" is "$(stat -c %a "$ATRIO_STATE/alerts.conf")" 600

touch "$ATRIO_STATE/alerts-test" "$FAKE_DOCKER/push-fails"
alerts --test
check "a refused test shows the service's own answer" has "$ATRIO_STATE/alerts-status.json" 'HTTP 400: {error:refused}'
rm "$FAKE_DOCKER/push-fails"
touch "$ATRIO_STATE/alerts-test"
alerts --test
check "a test that goes through says so" has "$ATRIO_STATE/alerts-status.json" '"message":"Test sent"'

# The activity log keeps its last 1500 events
for i in $(seq 1 2100); do printf '2026-01-01T00:00:00+00:00\tbackup\tok\tweb\tmanual %s\n' "$i"; done >> "$log"
alerts
check "a long activity log is shortened" is "$(wc -l < "$log")" 1500
check "keeping the newest events" has "$log" "manual 2100"
finish
