#!/bin/bash
# App health in atrio-alerts: an app that keeps restarting, stopped on its own, is not healthy or
# whose page does not answer is shown on its tile and reported, twice in a row before it counts.
. "$(dirname "$0")/lib.sh"
sandbox
alerts() { bash "$SCRIPTS/atrio-alerts" >/dev/null 2>&1; }
health() { python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["apps"][sys.argv[2]]["state"])' "$ATRIO_STATE/health.json" "$1"; }
printf 'x-casaos:\n    main: web\n    port_map: "8080"\n' >> "$ATRIO_APPS/web/docker-compose.yml"
# The compose file has its x-casaos block already: keep only the last one
python3 - "$ATRIO_APPS/web/docker-compose.yml" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
head, _, tail = text.partition('x-casaos:\n    main: web\n')
open(path, 'w').write(head + tail)
PY
docker_state "state['pages'] = {'8080': '401'}"
printf 'ENABLED=1\nSERVICE=ntfy\nURL=https://ntfy.example\nTOPIC=t\nDISK=0\nHEALTH=0\nTEMP=0\nAPPS=0\nAPP_UPDATES=0\nUPDATES=0\n' > "$ATRIO_STATE/alerts.conf"

alerts
check "a running app whose page answers, even 401, is fine" is "$(health web)" ok

docker_state "state['pages'] = {}"
alerts
check "one check with no answer is not enough" is "$(health web)" ok
alerts
check "two in a row: its page does not answer" is "$(health web)" no-answer
check "an alert is sent" has "$FAKE_DOCKER/sent.log" "web is running but its page does not answer."
check "and it is in the activity log" has "$ATRIO_STATE/activity.log" "app-down	error	web	no-answer"
alerts
check "the alert is not sent again" is "$(grep -c "does not answer" "$FAKE_DOCKER/sent.log")" 1

docker_state "state['pages'] = {'8080': '200'}"
alerts
check "once it answers again it is fine" is "$(health web)" ok
check "and that is said too" has "$FAKE_DOCKER/sent.log" "web is working again."
check "and logged" has "$ATRIO_STATE/activity.log" "app-up	ok	web"

docker_state "state['containers'][0].update(state='restarting')"
alerts; alerts
check "a container that keeps restarting" is "$(health web)" restarting
docker_state "state['containers'][0].update(state='running', restarts=10)"
alerts
docker_state "state['containers'][0].update(restarts=14)"
alerts; docker_state "state['containers'][0].update(restarts=18)"; alerts
check "also when it restarts again and again between checks" is "$(health web)" restarting

docker_state "state['containers'][0].update(state='exited', exit=1)"
alerts; alerts
check "an app that stopped on its own" is "$(health web)" crashed
check "with its exit code" has "$FAKE_DOCKER/sent.log" "web stopped on its own (exit code 1)."

docker_state "state['containers'][0].update(state='exited', exit=143)"
alerts; alerts
check "an app stopped by someone is not a problem" is "$(health web)" stopped
docker_state "state['containers'][0].update(state='running', health='unhealthy')"
alerts; alerts
check "an app whose own health check fails" is "$(health web)" unhealthy

# No checks while atrio-backup has stopped apps on purpose
docker_state "state['containers'][0].update(health='healthy', state='exited', exit=1)"
cp "$ATRIO_STATE/health.json" "$SB/before.json"
( exec 9>"$ATRIO_STATE/backup.lock"; flock 9; sleep 4 ) &
sleep 1
alerts; alerts
wait
check "nothing changes while a backup or an update runs" cmp -s "$SB/before.json" "$ATRIO_STATE/health.json"

# With alerts off, the tiles still know, and nothing is sent
sed -i 's/^ENABLED=1/ENABLED=0/' "$ATRIO_STATE/alerts.conf"
: > "$FAKE_DOCKER/sent.log"
alerts; alerts
check "with alerts off the state is still kept" is "$(health web)" crashed
check "and nothing is sent" test ! -s "$FAKE_DOCKER/sent.log"
finish
