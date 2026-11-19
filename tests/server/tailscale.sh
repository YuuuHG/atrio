#!/bin/bash
# Tailscale from Atrio's settings: installed with Tailscale's own script, signed in with a link, turned
# on and off through the daemon's local API, and its status left in tailscale.json for the page.
. "$(dirname "$0")/lib.sh"
sandbox
export ATRIO_TS_WAIT=2
TS="$FAKE_DOCKER/tailscale.json"
ts_set() { printf '{"backend":"%s","auth":""}\n' "$1" > "$TS"; }
page() { python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$ATRIO_STATE/tailscale.json" "$1"; }
ask() { request ACTION=tailscale APP=atrio "OP=$1"; }

# Not installed
touch "$FAKE_DOCKER/ts-missing"
ask status
check "the status is read without Tailscale" is "$STATE_ $(page 'd["installed"]')" "done False"
check "and nothing is logged for a look" lacks "$ATRIO_STATE/activity.log" "tailscale"
ask up
check "turning on needs Tailscale" is "$STATE_ $MESSAGE" "error Tailscale is not installed"

# Installed with Tailscale's script
touch "$FAKE_DOCKER/ts-install-fails"
ask install
check "a failed install says so" is "$STATE_ $MESSAGE" "error Tailscale could not be installed: the installer's messages are in /var/lib/casaos/atrio/tailscale-install.log"
check "and keeps the installer's output" has "$ATRIO_STATE/tailscale-install.log" "installing"
check "without leaving the script behind" is "$(ls "$ATRIO_STATE"/tailscale-install.sh 2>/dev/null)" ""
rm "$FAKE_DOCKER/ts-install-fails"
ask install
check "installed" is "$STATE_ $(page 'd["installed"]') $(page 'd["status"]["BackendState"]')" "done True NeedsLogin"
check "from tailscale.com" has "$FAKE_DOCKER/calls.log" "curl https://tailscale.com/install.sh"
check "with its daemon running" has "$FAKE_DOCKER/calls.log" "systemctl is-active --quiet tailscaled"
check "the log of the install is gone once it worked" is "$(ls "$ATRIO_STATE"/tailscale-install.log 2>/dev/null)" ""
check "the install is logged" has "$ATRIO_STATE/activity.log" "tailscale	ok		install"
check "the status file is only for root" is "$(stat -c %a "$ATRIO_STATE/tailscale.json")" 600
check "the version is shown" is "$(page 'd["version"]')" "1.104.7"
lines=$(grep -c 'curl https://tailscale.com' "$FAKE_DOCKER/calls.log")
ask install
check "installing again does nothing" is "$STATE_ $(grep -c 'curl https://tailscale.com' "$FAKE_DOCKER/calls.log")" "done $lines"

# Signing in gives a link
ask login
check "signing in gives a link" is "$STATE_ $(page 'd["status"]["AuthURL"]')" "done https://login.tailscale.com/a/fake123"
check "after asking the daemon to run" has "$FAKE_DOCKER/calls.log" 'localapi PATCH prefs {"WantRunningSet":true,"WantRunning":true}'
check "and to start a sign-in" has "$FAKE_DOCKER/calls.log" "localapi POST login-interactive"
check "its status read from the same daemon" has "$FAKE_DOCKER/calls.log" "tailscale-socket /var/run/tailscale/tailscaled.sock"
ts_set NeedsLogin
touch "$FAKE_DOCKER/ts-no-link"
ask login
check "no link in time: an error" is "$STATE_ $MESSAGE" "error Tailscale did not give a sign-in link: check the server's internet connection"
rm "$FAKE_DOCKER/ts-no-link"

# Signed in: on, off, signed out
ts_set Running
ask status
check "running: the address is there" is "$(page 'd["status"]["Self"]["DNSName"]') $(page 'd["status"]["TailscaleIPs"][0]')" "atrio-demo.tail0000.ts.net. 100.64.0.10"
ask down
check "turned off" is "$STATE_ $(page 'd["status"]["BackendState"]')" "done Stopped"
check "only through its prefs, keeping the rest" has "$FAKE_DOCKER/calls.log" 'localapi PATCH prefs {"WantRunningSet":true,"WantRunning":false}'
check "never with tailscale up, which would reset its settings" lacks "$FAKE_DOCKER/calls.log" "tailscale up"
check "turning off is logged" has "$ATRIO_STATE/activity.log" "tailscale	ok		down"
ask up
check "turned on" is "$STATE_ $(page 'd["status"]["BackendState"]')" "done Running"
ask logout
check "signed out" is "$STATE_ $(page 'd["status"]["BackendState"]')" "done NeedsLogin"

# Failures and bad requests
touch "$FAKE_DOCKER/ts-api-fails"
ask up
check "a daemon that does not answer" is "$STATE_ $MESSAGE" "error Tailscale did not start"
check "is logged as an error" has "$ATRIO_STATE/activity.log" "tailscale	error		up: Tailscale did not start"
rm "$FAKE_DOCKER/ts-api-fails"
ask reboot
check "only known operations" is "$STATE_ $MESSAGE" "error Unknown request"
request ACTION=tailscale APP=atrio
check "and one is needed" is "$STATE_ $MESSAGE" "error Unknown request"
finish
