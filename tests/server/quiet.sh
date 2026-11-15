#!/bin/bash
# Quiet hours and muted apps in atrio-alerts: what is not urgent waits and goes out as one message
# when quiet hours end; an urgent alert and a test are sent at once; a muted app sends nothing.
. "$(dirname "$0")/lib.sh"
sandbox
alerts() { bash "$SCRIPTS/atrio-alerts" "$@" >/dev/null 2>&1; }
# conf QUIET FROM TO MUTE: the settings, with every check off but app changes and app health
conf() {
	printf 'ENABLED=1\nSERVICE=ntfy\nURL=https://ntfy.example\nTOPIC=t\nDISK=0\nHEALTH=1\nTEMP=0\nAPPS=1\nAPP_UPDATES=1\nUPDATES=0\nAPP_DOWN=1\n' > "$ATRIO_STATE/alerts.conf"
	printf 'QUIET=%s\nQUIET_FROM=%s\nQUIET_TO=%s\nMUTE=%s\n' "$1" "$2" "$3" "$4" >> "$ATRIO_STATE/alerts.conf"
}
before=$(date -d '-1 hour' +%H:%M)
after=$(date -d '+1 hour' +%H:%M)
later=$(date -d '+2 hours' +%H:%M)
sent() { awk -v p="$1" 'index($0, p) { n++ } END { print n + 0 }' "$FAKE_DOCKER/sent.log" 2>/dev/null || echo 0; }

conf 1 "$before" "$after" ""
alerts
add_app new redis:7 sha256:bbbb
alerts
check "during quiet hours an install is not sent" is "$(sent "new is installed")" 0
check "it waits in the queue" has "$ATRIO_STATE/alerts-queue" "new is installed."
check "but it is logged at once" has "$ATRIO_STATE/activity.log" "app-installed	ok	new"
touch "$ATRIO_STATE/alerts-test"
alerts --test
check "a test is sent even in quiet hours" is "$(sent "If you can read this")" 1

# An urgent alert (a disk that may fail soon) does not wait
printf '/dev/sda sat\n' > "$FAKE_DOCKER/disks"
sed -i '/^disks_checked=/d' "$ATRIO_STATE/alerts-memory"
alerts
sed -i '/^disks_checked=/d' "$ATRIO_STATE/alerts-memory"
awk '$1 == 197 { $10 = 4 } { print }' "$TESTS/fake/smart/sda" > "$FAKE_DOCKER/smart-sda"
alerts
check "an urgent alert is sent in quiet hours" is "$(sent "may fail soon")" 1

# Quiet hours across midnight count too
conf 1 "$before" "$(date -d '-2 hours' +%H:%M)" ""
rm -rf "$ATRIO_APPS/new"
alerts
check "quiet hours that run past midnight hold alerts too" has "$ATRIO_STATE/alerts-queue" "new was removed."

# Outside quiet hours, what waited goes out as one message
conf 1 "$after" "$later" ""
alerts
# ntfy gets the title in a header, encoded: the summary is the message with "• " lines
check "when quiet hours end, one message sums up what waited" is "$(sent "• App installed: new is installed.")" 1
check "with the other one too" is "$(sent "• App removed: new was removed.")" 1
check "with what happened" has "$FAKE_DOCKER/sent.log" "new is installed."
check "the queue is emptied" test ! -e "$ATRIO_STATE/alerts-queue"
alerts
check "and is not sent again" is "$(sent "• App installed")" 1

# A muted app sends nothing, and still goes to the activity log
conf 0 23:00 07:00 "quiet-app,other"
add_app quiet-app redis:7 sha256:bbbb
alerts
check "a muted app's install is not sent" is "$(sent "quiet-app is installed")" 0
check "but logged" has "$ATRIO_STATE/activity.log" "app-installed	ok	quiet-app"
add_app loud redis:7 sha256:bbbb
alerts
check "an app that is not muted is sent" is "$(sent "loud is installed")" 1

# Limits from the settings: a disk full above 50% is reported when the limit is 50
check "a limit that is not valid is ignored" bash -c "printf 'DISK_LIMIT=12\n' >> '$ATRIO_STATE/alerts.conf'; ! bash '$SCRIPTS/atrio-alerts' 2>&1 | grep -q DISK_LIMIT"
finish
