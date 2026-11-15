#!/bin/bash
# New versions: by digest (same tag) and from the App Store (another version of the same image),
# with the backup first, a failed download that changes nothing, and the way back when the new
# version does not start. Also the apps whose updates are ignored.
. "$(dirname "$0")/lib.sh"
sandbox
new=sha256:$(printf '2%.0s' {1..64})
docker_state "state['remote'] = {'registry-1.docker.io/library/nginx:1.0': '$new', 'registry-1.docker.io/library/nginx:1.1': '$new'}"
docker_state "state['registry'] = {'nginx:1.0': {'id': 'sha256:cccc', 'digest': '$new'}, 'nginx:1.1': {'id': 'sha256:dddd', 'digest': '$new'}}"

bash "$SCRIPTS/atrio-backup" --check-updates
check "a newer image of the same tag is found" has "$ATRIO_STATE/updates.json" '"web":{"state":"update"'

request ACTION=update-app APP=web
check "an update by digest ends done" is "$STATE_" done
check "a backup was made first" has "$ATRIO_STATE/backups/web.json" '"reason":"before-update"'
check "the app runs the new image" is "$(docker_query "state['containers'][0]['image']")" sha256:cccc
check "the tag is the same" has "$ATRIO_APPS/web/docker-compose.yml" "        image: nginx:1.0"
check "and the app counts as current now" has "$ATRIO_STATE/updates.json" '"web":{"state":"current"'

# The App Store's version: only the service's own image line changes
request ACTION=update-app APP=web SET_IMAGE=web=nginx:1.1
check "an update to the App Store's version ends done" is "$STATE_" done
check "the compose file has the new version" has "$ATRIO_APPS/web/docker-compose.yml" "        image: nginx:1.1"
check "an image line nested deeper is left alone" has "$ATRIO_APPS/web/docker-compose.yml" "            image: not-the-image"
check "the app runs the new version" is "$(docker_query "state['containers'][0]['image']")" sha256:dddd

before=$(count_backups web)
request ACTION=update-app APP=web SET_IMAGE=web=someone-else/nginx:2
check "another image is refused" is "$MESSAGE" "The App Store's version does not match this app, it was not changed"
check "before any backup is made" is "$(count_backups web)" "$before"
check "and the compose file is unchanged" has "$ATRIO_APPS/web/docker-compose.yml" "        image: nginx:1.1"
request ACTION=update-app APP=web SET_IMAGE=other=nginx:2
check "a service the app does not have is refused" is "$MESSAGE" "The App Store's version does not match this app, it was not changed"

docker_state "state['registry']['nginx:1.2'] = {'id': 'sha256:eeee', 'digest': '$new'}"
touch "$FAKE_DOCKER/pull-fails"
request ACTION=update-app APP=web SET_IMAGE=web=nginx:1.2
check "a failed download is reported" is "$MESSAGE" "The new version could not be downloaded, the app was not changed"
check "and puts the compose file back" has "$ATRIO_APPS/web/docker-compose.yml" "        image: nginx:1.1"
rm "$FAKE_DOCKER/pull-fails"

# The new version keeps restarting: back to the backup made just before, compose file and data
echo "version 1" > "$ATRIO_APPDATA/web/config/data.txt"
echo nginx:1.2 > "$FAKE_DOCKER/crash"
request ACTION=update-app APP=web SET_IMAGE=web=nginx:1.2
check "an update that does not start goes back on its own" is "$MESSAGE" "The new version did not start, so the app went back to how it was before the update"
check "the compose file is the one from before" has "$ATRIO_APPS/web/docker-compose.yml" "        image: nginx:1.1"
check "the data are the ones from before" is "$(cat "$ATRIO_APPDATA/web/config/data.txt")" "version 1"
check "no copy of the compose file is left behind" test -z "$(ls "$ATRIO_APPS/web" | grep -v '^docker-compose.yml$')"
check "the activity log says it went back" has "$ATRIO_STATE/activity.log" "update-app	error	web	The new version did not start"

# A stopped app gets the new version and stays stopped
docker_state "state['containers'][0]['state'] = 'exited'"
docker_state "state['registry']['nginx:1.1'] = {'id': 'sha256:ffff', 'digest': 'sha256:' + '3' * 64}"
request ACTION=update-app APP=web
check "a stopped app is updated" is "$STATE_" done
check "and stays stopped" is "$(docker_query "state['containers'][0]['state']")" exited

request ACTION=ignore-updates APP=web IGNORE=1
check "an app's updates can be ignored" has "$ATRIO_STATE/updates.json" '"ignored":["web"]'
request ACTION=ignore-updates APP=web IGNORE=0
check "and shown again" has "$ATRIO_STATE/updates.json" '"ignored":[]'

# Images that cannot be checked: built on the server, or pinned to a digest
add_app local local-build:latest sha256:9999
bash "$SCRIPTS/atrio-backup" --check-updates
check "an image built on the server is not checked" has "$ATRIO_STATE/updates.json" '"local":{"state":"unknown"'
finish
