#!/bin/bash
# Network per app: exact counters from each container's network, rates every 5 minutes in the
# history, a live measure for the network detail, and apps on the host's network told apart.
. "$(dirname "$0")/lib.sh"
sandbox
export ATRIO_PROC="$SB/proc" ATRIO_SYS="$SB/sys" ATRIO_NETWORK_WAIT=2
mkdir -p "$ATRIO_PROC/101/net" "$ATRIO_PROC/102/net" "$ATRIO_SYS/class/net/eth0/statistics" "$ATRIO_SYS/class/net/eth0/device"
printf 'MemTotal: 1000 kB\nMemAvailable: 500 kB\n' > "$ATRIO_PROC/meminfo"
echo "cpu  1 0 1 1 0 0 0 0 0 0" > "$ATRIO_PROC/stat"
echo "0.1 0.1 0.1 1/1 1" > "$ATRIO_PROC/loadavg"
add_app media redis:7 sha256:bbbb
add_app home redis:7 sha256:bbbb
docker_state "state['containers'][0].update(pid=101); state['containers'][1].update(pid=102); state['containers'][2].update(pid=1, mode='host')"
# dev PID RX TX: the network of a container, with its loopback
dev() {
	printf 'Inter-|   Receive                                                |  Transmit\n face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed\n'
	printf '    lo: 999999 1 0 0 0 0 0 0 999999 1 0 0 0 0 0 0\n  eth0: %s 1 0 0 0 0 0 0 %s 1 0 0 0 0 0 0\n' "$2" "$3"
}
server() { echo "$1" > "$ATRIO_SYS/class/net/eth0/statistics/rx_bytes"; echo "$2" > "$ATRIO_SYS/class/net/eth0/statistics/tx_bytes"; }
dev 101 1000000 200000 > "$ATRIO_PROC/101/net/dev"
dev 102 50000 10000 > "$ATRIO_PROC/102/net/dev"
server 5000000 1000000
alerts() { bash "$SCRIPTS/atrio-alerts" "$@" >/dev/null 2>&1; }
apps_row() { awk -F'\t' -v app="$1" '$2 == app' "$ATRIO_STATE/history-apps.tsv" | tail -n 1 | cut -f"$2"; }

alerts
check "the first sample has no rate yet" is "$(apps_row web 5)" ""
check "an app on the host's network has no counters" is "$(apps_row home 5)" "-"
dev 101 4000000 800000 > "$ATRIO_PROC/101/net/dev"
sed -i "s/^apps_net=\([0-9]*\)/apps_net=$(( $(date +%s) - 300 ))/" "$ATRIO_STATE/alerts-memory"
alerts
check "an app's download over 5 minutes, exact, without its loopback" is "$(apps_row web 5)" 10000
check "and its upload" is "$(apps_row web 6)" 2000
check "an app with no traffic" is "$(apps_row media 5)" 0

# The live measure: counters read twice a few seconds apart
( sleep 1; dev 101 4600000 800000 > "$ATRIO_PROC/101/net/dev"; server 6000000 1000000 ) &
printf '%s\n' ACTION=network APP=atrio > "$ATRIO_STATE/backup-request"
bash "$SCRIPTS/atrio-backup" >/dev/null 2>&1
wait
read_status
check "the network is measured on request" is "$STATE_" done
net() { python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$ATRIO_STATE/network.json" "$1"; }
check "an app downloading now" test "$(net "next(a['down'] for a in d['apps'] if a['app'] == 'web')")" -ge 250000
check "an app doing nothing now" is "$(net "next(a['down'] for a in d['apps'] if a['app'] == 'media')")" 0
check "an app on the host's network is marked" is "$(net "next(a.get('host') for a in d['apps'] if a['app'] == 'home')")" True
check "the whole server too" test "$(net "d['server']['down']")" -ge 400000
check "the result can be read by the web UI" is "$(stat -c %a "$ATRIO_STATE/network.json")" 644
finish
