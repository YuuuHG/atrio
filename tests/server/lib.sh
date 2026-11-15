#!/bin/bash
# Shared helpers for the tests of the services on the server. Each test file sources this, calls
# `sandbox` for a fresh folder, and uses `request` and `check`. Nothing outside the sandbox is
# touched: the services run with ATRIO_* paths inside it and a fake docker (fake/docker).
set -uo pipefail

TESTS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPTS=$(cd "$TESTS/../../scripts" && pwd)
PASSED=0
FAILED=0

# A new sandbox with one app; $1: what the app's container runs (default ok)
sandbox() {
	# Not under /tmp: the services refuse /tmp as a backup folder
	mkdir -p "${ATRIO_TEST_TMP:-$TESTS/.tmp}"
	SB=$(mktemp -d "${ATRIO_TEST_TMP:-$TESTS/.tmp}/atrio-test.XXXXXX")
	export FAKE_DOCKER="$SB/docker"
	export ATRIO_STATE="$SB/state" ATRIO_APPS="$SB/apps" ATRIO_APPDATA="$SB/data" ATRIO_BACKUP_DEST="$SB/data/.atrio-backups"
	export ATRIO_CASAOS_ENV="$SB/casaos.env" ATRIO_WWW="$SB/www" ATRIO_HEALTH_WAIT=4 ATRIO_HEALTH_STEADY=2
	export PATH="$TESTS/fake:$PATH"
	mkdir -p "$FAKE_DOCKER" "$ATRIO_STATE" "$ATRIO_APPS" "$ATRIO_APPDATA"
	: > "$SB/casaos.env"
	add_app web nginx:1.0 sha256:aaaa
	trap 'rm -rf "$SB"' EXIT
}

# add_app NAME REF IMAGE_ID: a compose file as CasaOS writes it, a data folder and a running container
add_app() {
	local name="$1" ref="$2" image="$3"
	mkdir -p "$ATRIO_APPS/$name" "$ATRIO_APPDATA/$name/config"
	echo "version 1" > "$ATRIO_APPDATA/$name/config/data.txt"
	cat > "$ATRIO_APPS/$name/docker-compose.yml" <<COMPOSE
name: $name
services:
    $name:
        environment:
            image: not-the-image
        image: $ref
        volumes:
            - type: bind
              source: $ATRIO_APPDATA/$name/config
              target: /config
x-casaos:
    main: $name
COMPOSE
	python3 - "$FAKE_DOCKER/state.json" "$name" "$ref" "$image" "$ATRIO_APPDATA/$name/config" <<'PY'
import json, os, sys
path, name, ref, image, mount = sys.argv[1:]
state = json.load(open(path)) if os.path.exists(path) else {'containers': [], 'images': [], 'registry': {}}
state['containers'].append({'id': 'c-' + name, 'project': name, 'service': name, 'ref': ref, 'image': image, 'state': 'running', 'mounts': [mount]})
if not any(i['id'] == image for i in state['images']):
    state['images'].append({'id': image, 'size': 1000, 'created': '2026-01-01T00:00:00Z', 'tags': [ref], 'digests': ['sha256:' + '1' * 64]})
json.dump(state, open(path, 'w'), indent=1)
PY
}

# Changes the fake docker's state with a line of Python on `state`
docker_state() {
	python3 - "$FAKE_DOCKER/state.json" "$1" <<'PY'
import json, sys
path, code = sys.argv[1:]
state = json.load(open(path))
exec(code)
json.dump(state, open(path, 'w'), indent=1)
PY
}

docker_query() {
	python3 -c 'import json, sys; state = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$FAKE_DOCKER/state.json" "$1"
}

# request KEY=value...: sends it as the web UI does and runs atrio-backup; sets STATE_, MESSAGE, ID
request() {
	printf '%s\n' "$@" > "$ATRIO_STATE/backup-request"
	bash "$SCRIPTS/atrio-backup" >/dev/null 2>&1
	read_status
}

read_status() {
	STATE_=$(sed -n 's/.*"state":"\([a-z]*\)".*/\1/p' "$ATRIO_STATE/backup-status.json")
	MESSAGE=$(sed -n 's/.*"message":"\([^"]*\)".*/\1/p' "$ATRIO_STATE/backup-status.json")
	ID=$(sed -n 's/.*"id":"\([^"]*\)".*/\1/p' "$ATRIO_STATE/backup-status.json")
}

# check "what should be true" COMMAND...
check() {
	local what="$1"
	shift
	if "$@" >/dev/null 2>&1; then
		PASSED=$((PASSED + 1))
	else
		FAILED=$((FAILED + 1))
		printf '  FAIL %s: %s\n' "$(basename "$0" .sh)" "$what"
		[ -n "${MESSAGE:-}" ] && printf '       last message: %s\n' "$MESSAGE"
	fi
}

is() { [ "$1" = "$2" ]; }
has() { grep -qF -- "$2" "$1"; }
lacks() { ! grep -qF -- "$2" "$1"; }
count_backups() { ls "$ATRIO_BACKUP_DEST/$1"/*.info 2>/dev/null | wc -l; }

finish() {
	printf '%s: %s passed, %s failed\n' "$(basename "$0" .sh)" "$PASSED" "$FAILED"
	[ "$FAILED" -eq 0 ]
}
