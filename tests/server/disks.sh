#!/bin/bash
# Disk health in atrio-alerts: SMART data read once an hour, a verdict from the signs that go with
# disks that fail, an alert when it gets worse, and sleeping disks left asleep.
. "$(dirname "$0")/lib.sh"
sandbox
printf '/dev/nvme0 nvme\n/dev/sda sat\n/dev/sdb sat\n' > "$FAKE_DOCKER/disks"
printf 'ENABLED=1\nSERVICE=ntfy\nURL=https://ntfy.example\nTOPIC=t\nDISK=0\nTEMP=0\nAPPS=0\nAPP_UPDATES=0\nUPDATES=0\nAPP_DOWN=0\n' > "$ATRIO_STATE/alerts.conf"
alerts() { bash "$SCRIPTS/atrio-alerts" >/dev/null 2>&1; }
# disk DEVICE FIELD: a value of disks.json
disk() { python3 -c 'import json, sys; print(next(d for d in json.load(open(sys.argv[1]))["disks"] if d["device"] == sys.argv[2]).get(sys.argv[3], ""))' "$ATRIO_STATE/disks.json" "$1" "$2"; }
# again: the next run reads the disks again (an hour has passed)
again() { sed -i '/^disks_checked=/d' "$ATRIO_STATE/alerts-memory"; alerts; }
# smart DEVICE ATTRIBUTE_ID RAW: a disk whose attribute changed
smart() {
	local name src
	name=$(basename "$1")
	src="$FAKE_DOCKER/smart-$name"
	[ -f "$src" ] || src="$TESTS/fake/smart/$name"
	awk -v id="$2" -v raw="$3" '$1 == id { $10 = raw } { print }' "$src" > "$FAKE_DOCKER/smart-$name.new"
	mv "$FAKE_DOCKER/smart-$name.new" "$FAKE_DOCKER/smart-$name"
}

alerts
check "an NVMe disk is read" is "$(disk /dev/nvme0 model)" CT1000P3PSSD8
check "with its kind, temperature, hours and wear" is "$(disk /dev/nvme0 kind) $(disk /dev/nvme0 temp) $(disk /dev/nvme0 hours) $(disk /dev/nvme0 used)" "nvme 41 4215 2"
check "and its size" is "$(disk /dev/nvme0 size)" 1000204886016
check "a healthy NVMe disk is good" is "$(disk /dev/nvme0 verdict)" good
check "a hard disk is read" is "$(disk /dev/sda kind) $(disk /dev/sda temp) $(disk /dev/sda hours)" "hdd 32 21346"
check "a healthy hard disk is good" is "$(disk /dev/sda verdict)" good
check "an SSD's wear comes from its wear attribute" is "$(disk /dev/sdb kind) $(disk /dev/sdb used) $(disk /dev/sdb temp)" "ssd 5 33"

check "each disk's temperature is kept, by serial number" is "$(cut -f2,3 "$ATRIO_STATE/history-disks.tsv" | tr '\t\n' ': ')" "2345E6789ABC:41 WD_WCC7K1234567:32 S6PWNX0R123456:33 "
check "the history can be read by the web UI" is "$(stat -c %a "$ATRIO_STATE/history-disks.tsv")" 644
alerts
check "the disks are not read again within the hour" is "$(grep -c 'smartctl -n standby' "$FAKE_DOCKER/calls.log")" 3

smart /dev/sda 5 8
again
check "a few reallocated sectors: keep an eye on it" is "$(disk /dev/sda verdict) $(disk /dev/sda reasons)" "watch reallocated"
check "an alert is sent" has "$FAKE_DOCKER/sent.log" "Disk /dev/sda (WDC WD40EFRX-68N32N0) shows the first signs of trouble"
check "and it is logged" has "$ATRIO_STATE/activity.log" "disk-health	error		watch /dev/sda reallocated"
again
check "the same verdict is not sent again" is "$(grep -c "first signs" "$FAKE_DOCKER/sent.log")" 1

smart /dev/sda 197 3
again
check "pending sectors: replace it soon" is "$(disk /dev/sda verdict)" replace
check "with both reasons" is "$(disk /dev/sda reasons)" "pending reallocated"
check "an urgent alert is sent" has "$FAKE_DOCKER/sent.log" "Disk /dev/sda (WDC WD40EFRX-68N32N0) may fail soon"

sed 's/^Percentage Used: .*/Percentage Used:                    100%/; s/^Temperature: .*/Temperature:                        74 Celsius/' "$TESTS/fake/smart/nvme0" > "$FAKE_DOCKER/smart-nvme0"
again
check "an NVMe disk worn out and hot" is "$(disk /dev/nvme0 verdict) $(disk /dev/nvme0 reasons)" "replace worn-out hot"
sed 's/^SMART overall-health self-assessment test result: .*/SMART overall-health self-assessment test result: FAILED!/' "$TESTS/fake/smart/sdb" > "$FAKE_DOCKER/smart-sdb"
again
check "a disk that fails its own test" is "$(disk /dev/sdb verdict) $(disk /dev/sdb reasons)" "replace failed"

check "a point each hour" is "$(grep -c 2345E6789ABC "$ATRIO_STATE/history-disks.tsv")" 6
check "with the temperature of that hour" is "$(tail -n 3 "$ATRIO_STATE/history-disks.tsv" | grep 2345E6789ABC | cut -f3)" 74
# Points older than a week go
sed -i "1s/^[0-9]*/$(($(date +%s) - 8 * 86400))/" "$ATRIO_STATE/history-disks.tsv"
again
check "a week of history is kept" is "$(grep -c 2345E6789ABC "$ATRIO_STATE/history-disks.tsv")" 6

# A sleeping disk is not woken up: it keeps the data of its last check
rm "$FAKE_DOCKER/smart-sdb"
touch "$FAKE_DOCKER/asleep-sdb"
again
check "a sleeping disk keeps its last data" is "$(disk /dev/sdb verdict)" replace
check "smartctl is asked not to wake it" has "$FAKE_DOCKER/calls.log" "smartctl -n standby"
check "and no temperature is made up for it" is "$(tail -n 2 "$ATRIO_STATE/history-disks.tsv" | grep -c S6PWNX0R123456)" 0

# With alerts off the hardware panel still gets the data, and nothing is sent
sed -i 's/^ENABLED=1/ENABLED=0/' "$ATRIO_STATE/alerts.conf"
: > "$FAKE_DOCKER/sent.log"
rm "$FAKE_DOCKER/asleep-sdb"
smart /dev/sdb 199 12
again
check "with alerts off the data are still read" is "$(disk /dev/sdb verdict) $(disk /dev/sdb reasons)" "watch cable"
check "and nothing is sent" test ! -s "$FAKE_DOCKER/sent.log"
finish
