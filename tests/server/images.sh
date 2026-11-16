#!/bin/bash
# Unused images: listed and removed, never one a container or an installed app still uses.
. "$(dirname "$0")/lib.sh"
sandbox
add_app stopped redis:7 sha256:bbbb
docker_state "state['containers'][1]['state'] = 'exited'"
add_app gone mariadb:11 sha256:mmmm
docker_state "state['containers'] = [c for c in state['containers'] if c['project'] != 'gone']"
O1=sha256:$(printf '1%.0s' {1..64})
O2=sha256:$(printf '2%.0s' {1..64})
docker_state "state['images'] += [{'id': '$O1', 'size': 3000, 'created': '2025-01-01T00:00:00Z', 'tags': ['immich:v1'], 'digests': []}, {'id': '$O2', 'size': 500, 'created': '2025-02-01T00:00:00Z', 'tags': [], 'digests': []}]"

request ACTION=images APP=atrio
check "the unused images are listed" has "$ATRIO_STATE/images.json" '"tags":"immich:v1"'
check "an image without a name too" has "$ATRIO_STATE/images.json" "\"id\":\"$O2\""
check "not the one of a running app" lacks "$ATRIO_STATE/images.json" sha256:aaaa
check "not the one of a stopped app" lacks "$ATRIO_STATE/images.json" sha256:bbbb
check "not the one an installed app names, without containers" lacks "$ATRIO_STATE/images.json" sha256:mmmm
check "with their total" has "$ATRIO_STATE/images.json" '"total":3500'

request ACTION=remove-images APP=atrio IMAGE=sha256:not-an-image
check "a request naming no valid image is refused" is "$STATE_ $MESSAGE" "error Unknown image"
check "and removes nothing" is "$(docker_query "len(state['images'])")" 5
request ACTION=remove-images APP=atrio IMAGE=$O2 IMAGE=sha256:aaaa
check "a chosen image is removed" is "$(docker_query "len([i for i in state['images'] if i['id'] == '$O2'])")" 0
check "and only that one" is "$(docker_query "len([i for i in state['images'] if i['id'] == '$O1'])")" 1
check "an image in use is never removed, even when asked" is "$(docker_query "len([i for i in state['images'] if i['id'] == 'sha256:aaaa'])")" 1
request ACTION=remove-images APP=atrio
check "removing all leaves the images in use" is "$(docker_query "sorted(i['id'] for i in state['images'])")" "['sha256:aaaa', 'sha256:bbbb', 'sha256:mmmm']"
check "and the list is empty after it" has "$ATRIO_STATE/images.json" '"images":[]'
check "the activity log has the cleanup" has "$ATRIO_STATE/activity.log" "remove-images	ok"
finish
