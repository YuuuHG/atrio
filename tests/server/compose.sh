#!/bin/bash
# Servers without the Docker Compose plugin (#11): CasaOS has compose built in, so Docker from the
# distribution's packages often comes without it. Everything that does not recreate containers works
# without compose; restoring and updating use the standalone docker-compose when it is there, and
# otherwise stop before changing anything, saying what to install.
. "$(dirname "$0")/lib.sh"
sandbox
new=sha256:$(printf '2%.0s' {1..64})
docker_state "state['remote'] = {'registry-1.docker.io/library/nginx:1.0': '$new'}"
docker_state "state['registry'] = {'nginx:1.0': {'id': 'sha256:cccc', 'digest': '$new'}}"
touch "$FAKE_DOCKER/no-compose-plugin"

# The standalone docker-compose is used in place of the plugin
request ACTION=backup APP=web "FOLDER=$ATRIO_APPDATA/web/config"
check "a backup works without the plugin" is "$STATE_" done
backup_id=$ID
request ACTION=update-app APP=web
check "an update works with the standalone docker-compose" is "$STATE_ $MESSAGE" "done "
check "which is the one that ran" has "$FAKE_DOCKER/calls.log" "docker-compose -p web"
check "and the app runs the new image" is "$(docker_query "state['containers'][0]['image']")" sha256:cccc

# Neither the plugin nor the standalone one
touch "$FAKE_DOCKER/no-standalone"
docker_state "state['registry']['nginx:1.0'] = {'id': 'sha256:dddd', 'digest': 'sha256:' + '3' * 64}"
docker_state "state['remote']['registry-1.docker.io/library/nginx:1.0'] = 'sha256:' + '3' * 64"
request ACTION=images APP=atrio
check "unused images are listed without compose" is "$STATE_" done
bash "$SCRIPTS/atrio-backup" --check-updates
check "updates are checked without compose" has "$ATRIO_STATE/updates.json" '"web":{"state":"update"'
request ACTION=backup APP=web "FOLDER=$ATRIO_APPDATA/web/config"
check "a backup still works" is "$STATE_" done
check "and the app is running again after it" is "$(docker_query "state['containers'][0]['state']")" running
request ACTION=update-app APP=web
check "an update says what to install" is "$MESSAGE" "Docker Compose is not installed on the server, and restoring or updating an app needs it: install the docker-compose-plugin package"
check "and changes nothing" is "$(docker_query "state['containers'][0]['image']")" sha256:cccc
check "the app keeps running" is "$(docker_query "state['containers'][0]['state']")" running
request ACTION=restore APP=web "ID=$backup_id"
check "a restore says so too, before touching anything" is "$MESSAGE" "Docker Compose is not installed on the server, and restoring or updating an app needs it: install the docker-compose-plugin package"
check "with the app still running" is "$(docker_query "state['containers'][0]['state']")" running
bash "$SCRIPTS/atrio-backup" --auto-update-app web >/dev/null 2>&1
read_status
check "a nightly update stops the same way" is "$MESSAGE" "Docker Compose is not installed on the server, and restoring or updating an app needs it: install the docker-compose-plugin package"
finish
