#!/bin/bash
# History for the charts in atrio-alerts: a sample every run (CPU over the interval, memory, load,
# network of the real cards only, temperatures), kept 7 days; apps' CPU and memory kept 24 hours.
. "$(dirname "$0")/lib.sh"
sandbox
export ATRIO_PROC="$SB/proc" ATRIO_SYS="$SB/sys"
mkdir -p "$ATRIO_PROC" "$ATRIO_SYS/class/net/eth0/statistics" "$ATRIO_SYS/class/net/eth0/device" "$ATRIO_SYS/class/net/docker0/statistics" "$ATRIO_SYS/class/hwmon/hwmon0"
echo coretemp > "$ATRIO_SYS/class/hwmon/hwmon0/name"
echo 52000 > "$ATRIO_SYS/class/hwmon/hwmon0/temp1_input"
printf 'MemTotal:       16000000 kB\nMemFree:         1000000 kB\nMemAvailable:    12000000 kB\n' > "$ATRIO_PROC/meminfo"
echo "0.42 0.30 0.25 1/300 1234" > "$ATRIO_PROC/loadavg"
stat_line() { echo "cpu  $1 0 $2 $3 0 0 0 0 0 0" > "$ATRIO_PROC/stat"; }
net() { echo "$1" > "$ATRIO_SYS/class/net/eth0/statistics/rx_bytes"; echo "$2" > "$ATRIO_SYS/class/net/eth0/statistics/tx_bytes"; echo 999999999 > "$ATRIO_SYS/class/net/docker0/statistics/rx_bytes"; echo 999999999 > "$ATRIO_SYS/class/net/docker0/statistics/tx_bytes"; }
alerts() { bash "$SCRIPTS/atrio-alerts" >/dev/null 2>&1; }
row() { tail -n 1 "$ATRIO_STATE/history.tsv" | cut -f"$1"; }
docker_state "state['containers'][0].update(cpu=12.5, mem=256)"
printf '/dev/sda\tgood\t-\t2026-01-01\tMODEL=x|TEMP=38|USED=|\n/dev/sdb\tgood\t-\t2026-01-01\tMODEL=y|TEMP=44|USED=|\n' > "$ATRIO_STATE/disks.tsv"

stat_line 1000 500 8500
net 1000000 500000
alerts
check "a first sample is written" test "$(wc -l < "$ATRIO_STATE/history.tsv")" -eq 1
check "without a CPU value, as there is no interval yet" is "$(row 2)" ""
check "memory used, in tenths of a percent" is "$(row 3)" 250
check "the load" is "$(row 4)" 0.42
check "the processor temperature" is "$(row 7)" 52
check "the hottest disk" is "$(row 8)" 44

# 5 minutes later: 3000 jiffies of which 900 busy, 3 MB down and 0.6 MB up on the real card
docker_state "pass"
stat_line 1600 800 10600
net 4000000 1100000
sed -i "s/^history_net=\([0-9]*\)/history_net=$(( $(date +%s) - 300 ))/" "$ATRIO_STATE/alerts-memory"
alerts
check "CPU over the interval, in tenths of a percent" is "$(row 2)" 300
check "download per second over the interval" is "$(row 5)" 10000
check "upload per second" is "$(row 6)" 2000
check "Docker's bridge is not counted" test "$(row 5)" -lt 100000
check "the apps' CPU and memory are kept" has "$ATRIO_STATE/history-apps.tsv" "	web	12.5	256"
check "the history can be read by the web UI" is "$(stat -c %a "$ATRIO_STATE/history.tsv")" 644

# Samples older than 7 days, and apps' older than 24 hours, go away
old=$(( $(date +%s) - 8 * 86400 ))
sed -i "1s/^[0-9]*/$old/" "$ATRIO_STATE/history.tsv"
printf '%s\tweb\t1\t1\n' "$old" >> "$ATRIO_STATE/history-apps.tsv"
alerts
check "samples older than 7 days are dropped" lacks "$ATRIO_STATE/history.tsv" "$old	"
check "and apps' older than a day" lacks "$ATRIO_STATE/history-apps.tsv" "$old	"
check "the history also grows with alerts off" test "$(wc -l < "$ATRIO_STATE/history.tsv")" -eq 2
finish
