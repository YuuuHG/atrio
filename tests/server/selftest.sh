#!/bin/bash
# SMART self-tests in atrio-alerts: a short test each week and a long one each month, at night unless
# late, never over a test already running, the result logged, and a test started from the panel.
. "$(dirname "$0")/lib.sh"
sandbox
printf '/dev/nvme0 nvme\n/dev/sda sat\n/dev/sdb sat\n' > "$FAKE_DOCKER/disks"
printf 'ENABLED=1\nSERVICE=ntfy\nURL=https://ntfy.example\nTOPIC=t\nDISK=0\nTEMP=0\nAPPS=0\nAPP_UPDATES=0\nUPDATES=0\nAPP_DOWN=0\n' > "$ATRIO_STATE/alerts.conf"
MEM="$ATRIO_STATE/alerts-memory"
# alerts HOUR: a run at that hour of the day, an hour after the last one
alerts() { sed -i '/^disks_checked=/d' "$MEM" 2>/dev/null; ATRIO_HOUR="$1" bash "$SCRIPTS/atrio-alerts" >/dev/null 2>&1; }
disk() { python3 -c 'import json, sys; print(next(d for d in json.load(open(sys.argv[1]))["disks"] if d["device"] == sys.argv[2]).get(sys.argv[3], ""))' "$ATRIO_STATE/disks.json" "$1" "$2"; }
started() { grep -c "smartctl -t $1 -d $2 $3" "$FAKE_DOCKER/calls.log"; }
# ago KEY DAYS: the memory says it happened that many days ago
ago() { sed -i "/^$1=/d" "$MEM"; printf '%s=%s\n' "$1" "$(($(date +%s) - $2 * 86400))" >> "$MEM"; }
# log DISK LINE: the newest line of the disk's self-test log
nvme_log() {
	sed "s/^ 0   Short .*/$1/" "$TESTS/fake/smart/nvme0" > "$FAKE_DOCKER/smart-nvme0"
}

alerts 14
check "the self-tests a disk can run are read" is "$(disk /dev/nvme0 selftest) $(disk /dev/sda selftest) $(disk /dev/sdb selftest)" "yes yes "
check "with the latest result" is "$(disk /dev/nvme0 test) $(disk /dev/nvme0 testkind) $(disk /dev/nvme0 testhours)" "passed short 4210"
check "an ATA disk's latest result" is "$(disk /dev/sda test) $(disk /dev/sda testkind) $(disk /dev/sda testhours)" "passed long 21000"
check "the log rows are not read as SMART attributes" is "$(disk /dev/nvme0 hours) $(disk /dev/nvme0 realloc)" "4215 "
check "a disk never tested by Atrio gets a short test, at any hour" is "$(started short nvme /dev/nvme0) $(started short sat /dev/sda)" "1 1"
check "a disk that cannot run tests gets none" is "$(grep -c "smartctl -t .* /dev/sdb" "$FAKE_DOCKER/calls.log")" 0
check "no long test on the first day" is "$(grep -c 'smartctl -t long' "$FAKE_DOCKER/calls.log")" 0
check "the start is logged" has "$ATRIO_STATE/activity.log" "disk-test	ok		short started /dev/nvme0"

alerts 3
check "no second test the next hour" is "$(grep -c 'smartctl -t' "$FAKE_DOCKER/calls.log")" 2

ago test_short_2345E6789ABC 8
alerts 14
check "a week later, not in the afternoon" is "$(started short nvme /dev/nvme0)" 1
alerts 3
check "but at night" is "$(started short nvme /dev/nvme0)" 2
ago test_short_2345E6789ABC 10
alerts 14
check "two days late, at any hour" is "$(started short nvme /dev/nvme0)" 3

alerts 3
check "the first long test waits a week" is "$(started long nvme /dev/nvme0)" 0
ago test_long_2345E6789ABC 31
ago test_short_2345E6789ABC 8
alerts 4
check "a month later the long test runs" is "$(started long nvme /dev/nvme0)" 1
check "in place of the short one" is "$(started short nvme /dev/nvme0)" 3
alerts 4
check "and it counts as the week's short test" is "$(started short nvme /dev/nvme0)" 3

# A test running on the disk: shown, and nothing else started over it
sed 's/^Self-test status: .*/Self-test status: Short self-test in progress (40% completed)/' "$TESTS/fake/smart/nvme0" > "$FAKE_DOCKER/smart-nvme0"
ago test_short_2345E6789ABC 8
alerts 3
check "a running test shows how far it is" is "$(disk /dev/nvme0 running)" 40
check "and no test is started over it" is "$(started short nvme /dev/nvme0)" 3
sed 's/^Self-test execution status: .*/Self-test execution status:      ( 249)	Self-test routine in progress.../; s/^					without error or no self-test has ever $/					70% of test remaining./' "$TESTS/fake/smart/sda" > "$FAKE_DOCKER/smart-sda"
alerts 3
check "an ATA disk's running test too" is "$(disk /dev/sda running)" 30

# While a test runs the disks are read every 5 minutes, not hourly, and the history keeps hourly points
points=$(wc -l < "$ATRIO_STATE/history-disks.tsv")
reads=$(grep -c 'smartctl -n standby' "$FAKE_DOCKER/calls.log")
ATRIO_HOUR=3 bash "$SCRIPTS/atrio-alerts" >/dev/null 2>&1
check "a running test is read again 5 minutes later" is "$(grep -c 'smartctl -n standby' "$FAKE_DOCKER/calls.log")" $((reads + 3))
check "without an extra point in the temperature history" is "$(wc -l < "$ATRIO_STATE/history-disks.tsv")" "$points"
rm -f "$FAKE_DOCKER/smart-sda" "$FAKE_DOCKER/smart-nvme0"
ATRIO_HOUR=14 bash "$SCRIPTS/atrio-alerts" >/dev/null 2>&1
check "the end of the test is seen" is "$(disk /dev/sda running)" ""
ATRIO_HOUR=14 bash "$SCRIPTS/atrio-alerts" >/dev/null 2>&1
check "then back to once an hour" is "$(grep -c 'smartctl -n standby' "$FAKE_DOCKER/calls.log")" $((reads + 6))

# Results: a new one is logged, a failed one makes the disk one to replace and sends the alert
nvme_log ' 0   Short             Completed without error                4300            -     -   -   -    -'
alerts 14
check "a new result is logged" has "$ATRIO_STATE/activity.log" "disk-test	ok		short passed /dev/nvme0"
nvme_log ' 0   Extended          Completed: failed segments             4400            -     -   7   -    -'
alerts 14
check "a failed test: replace soon" is "$(disk /dev/nvme0 verdict) $(disk /dev/nvme0 reasons)" "replace test-failed"
check "it is logged as an error" has "$ATRIO_STATE/activity.log" "disk-test	error		long failed /dev/nvme0"
check "and the alert is sent" has "$FAKE_DOCKER/sent.log" "Disk /dev/nvme0 (CT1000P3PSSD8) may fail soon"
alerts 14
check "the same result is logged once" is "$(grep -c 'long failed /dev/nvme0' "$ATRIO_STATE/activity.log")" 1
nvme_log ' 0   Short             Aborted: Controller Reset              4500            -     -   -   -    -'
alerts 14
check "an aborted test is no failure" is "$(disk /dev/nvme0 test) $(disk /dev/nvme0 verdict)" "aborted good"

# A disk that refuses is not asked again every hour
rm -f "$FAKE_DOCKER/smart-sda"
touch "$FAKE_DOCKER/refuse-sda"
ago test_short_WD_WCC7K1234567 8
alerts 3
check "a test the disk refuses is logged" has "$ATRIO_STATE/activity.log" "disk-test	error		short not-started /dev/sda"
alerts 3
check "and not asked again the next hour" is "$(started short sat /dev/sda)" 2
rm "$FAKE_DOCKER/refuse-sda"

# A sleeping disk is not woken for a scheduled test
touch "$FAKE_DOCKER/asleep-sda"
ago test_short_WD_WCC7K1234567 8
alerts 3
check "a sleeping disk waits" is "$(started short sat /dev/sda)" 2
rm "$FAKE_DOCKER/asleep-sda"

# Turned off in the settings, and with push alerts off (they run anyway)
printf 'SELFTEST=0\n' >> "$ATRIO_STATE/alerts.conf"
alerts 3
check "turned off: no scheduled test" is "$(started short sat /dev/sda)" 2
sed -i '/^SELFTEST=/d; s/^ENABLED=1/ENABLED=0/' "$ATRIO_STATE/alerts.conf"
alerts 3
check "with push alerts off the tests still run" is "$(started short sat /dev/sda)" 3

# From the hardware panel, through atrio-backup
touch "$FAKE_DOCKER/asleep-sda"
ATRIO_TEST_WAIT=0 request ACTION=disk-test APP=atrio DEVICE=/dev/sda KIND=long
check "a test started from the panel" is "$STATE_ $(started long sat /dev/sda)" "done 1"
check "wakes the disk it was asked for" is "$(disk /dev/sda selftest)" yes
rm "$FAKE_DOCKER/asleep-sda"
cp "$TESTS/fake/smart/sda" "$FAKE_DOCKER/smart-sda"
sed -i 's/^Self-test execution status: .*/Self-test execution status:      ( 249)	Self-test routine in progress.../' "$FAKE_DOCKER/smart-sda"
sed -i 's/^					without error or no self-test has ever $/					90% of test remaining./' "$FAKE_DOCKER/smart-sda"
ATRIO_TEST_WAIT=0 request ACTION=disk-test APP=atrio DEVICE=/dev/sda KIND=short
check "not over a running test" is "$STATE_ $MESSAGE" "error A test is already running on this disk"
check "and the panel then shows it running" is "$(disk /dev/sda running)" 10
ATRIO_TEST_WAIT=0 request ACTION=disk-test APP=atrio DEVICE=/dev/sdc KIND=short
check "only a disk smartctl lists" is "$STATE_ $MESSAGE" "error The disk did not start the test"
ATRIO_TEST_WAIT=0 request ACTION=disk-test APP=atrio DEVICE='/dev/sda;reboot' KIND=short
check "a device name is checked" is "$STATE_ $MESSAGE" "error Unknown disk"
ATRIO_TEST_WAIT=0 request ACTION=disk-test APP=atrio DEVICE=/dev/sda KIND=conveyance
check "and the kind of test" is "$STATE_ $MESSAGE" "error Unknown disk"
finish
