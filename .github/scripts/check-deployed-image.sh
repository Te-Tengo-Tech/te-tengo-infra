#!/usr/bin/env bash
# Post-deploy check of the API image actually running on the host (deploy.yml; the containerized test host
# in ansible.yml and release.yml through `make test-running-image`). /actuator/health only says that some
# API answers; this reads, over the same SSH connection as Ansible:
#   - the API_IMAGE the app role wrote to <app dir>/.env (the configured image);
#   - the image of the running `api` container, and the repository digests of that image.
# It fails unless the container is running the configured image and, when a digest is given (an image
# deploy: release or rollback), the configured image is pinned to that digest and the running image carries
# ghcr.io/te-tengo-tech/te-tengo-general-api@<digest>.
#
#   check-deployed-image.sh <expected digest sha256:... or ""> [ansible ad-hoc arguments...]
#
# Run it from the ansible/ directory (ansible.cfg), with the inventory and connection arguments of the
# playbook, e.g. --inventory hosts.yml --extra-vars ansible_ssh_private_key_file=id_deploy.
# Environment: APP_DIR (default /opt/te-tengo), API_IMAGE (default ghcr.io/te-tengo-tech/te-tengo-general-api),
# GITHUB_STEP_SUMMARY.
set -euo pipefail

expected=${1-}
shift || true
app_dir=${APP_DIR:-/opt/te-tengo}
repository=${API_IMAGE:-ghcr.io/te-tengo-tech/te-tengo-general-api}
summary=${GITHUB_STEP_SUMMARY:-/dev/null}
if [ -n "$expected" ] && [[ ! "$expected" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "::error title=Invalid digest::'$expected' is not sha256:<64 hex digits>."
  exit 1
fi

# The script run on the host (as root). Ansible templates ad-hoc arguments, so the docker --format braces
# are wrapped in raw; __APP_DIR__ is replaced below. The first line must not start with "{": ad-hoc
# arguments that do are parsed as JSON.
remote=$(
  cat << 'EOF'
# te-tengo: running API image
{% raw %}
cd '__APP_DIR__' || exit 3
configured=$(sed -n "s/^API_IMAGE='\(.*\)'$/\1/p" .env)
printf 'configured=%s\n' "$configured"
cid=$(docker compose ps -q api)
if [ -z "$cid" ]; then printf 'status=absent\n'; exit 0; fi
img=$(docker inspect --format '{{.Image}}' "$cid")
printf 'status=%s\n' "$(docker inspect --format '{{.State.Status}}' "$cid")"
printf 'running_image=%s\n' "$img"
printf 'configured_image=%s\n' "$(docker image inspect --format '{{.Id}}' "$configured" 2>/dev/null)"
printf 'repo_digests=%s\n' "$(docker image inspect --format '{{join .RepoDigests " "}}' "$img")"
{% endraw %}
EOF
)
remote=${remote//__APP_DIR__/$app_dir}

json=$(ANSIBLE_LOAD_CALLBACK_PLUGINS=true ANSIBLE_STDOUT_CALLBACK=ansible.builtin.json \
  ansible te_tengo "$@" --become -m ansible.builtin.shell -a "$remote") || {
  echo "::error title=Image check failed::Could not read the API container on the host."
  jq -r '.. | .msg? // empty' <<< "$json" 2> /dev/null | head -n 5 || true
  exit 1
}
# Plain loops, no mapfile: `make test-running-image` also runs on the operator's Mac (bash 3.2).
hosts=$(jq -r '.plays[0].tasks[0].hosts | keys[]' <<< "$json")
[ -n "$hosts" ] || { echo "::error title=Image check failed::No host answered."; exit 1; }

failed=0
for host in $hosts; do
  out=$(jq -r --arg h "$host" '.plays[0].tasks[0].hosts[$h].stdout // ""' <<< "$json")
  value() { sed -n "s/^$1=//p" <<< "$out" | head -n1; }
  configured=$(value configured)
  status=$(value status)
  running=$(value running_image)
  configured_image=$(value configured_image)
  digests=$(value repo_digests)
  problems=()
  [ "$status" = running ] || problems+=("the api container is ${status:-unknown}, not running")
  if [ -z "$configured_image" ] || [ "$running" != "$configured_image" ]; then
    problems+=("the api container runs image ${running:-none}, but API_IMAGE=$configured is ${configured_image:-not on the host}")
  fi
  if [ -n "$expected" ]; then
    [[ "$configured" == *"@$expected" ]] || problems+=("API_IMAGE=$configured is not pinned to $expected")
    [[ " $digests " == *" $repository@$expected "* ]] || problems+=("the running image's digests ($digests) do not include $repository@$expected")
  fi
  {
    echo "### Running API image on $host"
    echo "- Configured: \`$configured\`"
    echo "- Container: ${status:-unknown}, image \`${running:-none}\`${digests:+ (\`$digests\`)}"
    [ -z "$expected" ] || echo "- Expected digest: \`$expected\`"
  } >> "$summary"
  if [ ${#problems[@]} -gt 0 ]; then
    for p in "${problems[@]}"; do echo "::error title=Wrong API image on $host::$p"; done
    echo "- **Mismatch:** ${problems[*]}" >> "$summary"
    failed=1
  else
    echo "$host: the api container runs $configured${expected:+ ($expected)}"
    echo "- Matches${expected:+ the requested digest}" >> "$summary"
  fi
done
exit "$failed"
