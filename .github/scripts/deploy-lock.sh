#!/usr/bin/env bash
# One production deploy at a time, counted only AFTER the approval (deploy.yml, first step of the deploy job).
#
# Why not `concurrency`: a job holds its concurrency group while it waits for its environment's reviewers.
# A deploy waiting for an approval nobody gives (say, an infra release not meant to ship yet) then blocks an
# API deploy dispatched behind it until te-tengo-general-api's job times out, and GitHub keeps one pending
# job per group, so a third request cancels the waiting one. This lock is taken by a step, which only runs
# once the job was approved: waiting for a reviewer blocks nobody, and nothing is ever cancelled.
#
# The deploy jobs are found through the Actions API (in-progress runs of this repository, their jobs whose
# name contains LOCK_JOB). Among them:
#   - a holder has finished its LOCK_STEP and is still running (it is deploying);
#   - a contender is still in its LOCK_STEP.
# This job enters when there is no holder and no contender with a smaller job id, seen twice, LOCK_SETTLE
# seconds apart (so a contender the API had not shown yet is seen on the second look). The waiting job with
# the smallest id always enters once the holder ends, so there is no deadlock; a job never waits for one
# that waits for it.
#
# Environment: GH_TOKEN (actions: read), GITHUB_REPOSITORY, GITHUB_RUN_ID, GITHUB_RUN_ATTEMPT, RUNNER_NAME,
# LOCK_JOB (part of the deploy jobs' name), LOCK_STEP (this step's exact name), LOCK_TIMEOUT (seconds,
# default 2400), LOCK_POLL (seconds between looks, default 15), LOCK_SETTLE (default 20).
set -euo pipefail

: "${GITHUB_REPOSITORY:?}" "${GITHUB_RUN_ID:?}" "${RUNNER_NAME:?}" "${LOCK_JOB:?}" "${LOCK_STEP:?}"
repo=$GITHUB_REPOSITORY
attempt=${GITHUB_RUN_ATTEMPT:-1}
timeout=${LOCK_TIMEOUT:-2400}
poll=${LOCK_POLL:-15}
settle=${LOCK_SETTLE:-20}
summary=${GITHUB_STEP_SUMMARY:-/dev/null}

# This job's id: the in-progress job of this run attempt on this runner.
me=""
for _ in $(seq 1 10); do
  me=$(gh api --paginate "repos/$repo/actions/runs/$GITHUB_RUN_ID/attempts/$attempt/jobs?per_page=100" |
    jq -r --arg runner "$RUNNER_NAME" '.jobs[] | select(.status == "in_progress" and .runner_name == $runner) | .id' |
    head -n1)
  [ -n "$me" ] && break
  sleep 3
done
[ -n "$me" ] || { echo "::error title=Deploy lock::Cannot find this job (runner $RUNNER_NAME) in run $GITHUB_RUN_ID."; exit 1; }

# blockers: prints "<holder|contender> <job id> <url>" for every job this one must wait for.
blockers() {
  local runs run
  runs=$(gh api --paginate "repos/$repo/actions/runs?status=in_progress&per_page=100" --jq '.workflow_runs[].id')
  for run in $runs; do
    gh api --paginate "repos/$repo/actions/runs/$run/jobs?filter=latest&per_page=100" |
      jq -r --arg job "$LOCK_JOB" --arg step "$LOCK_STEP" --argjson me "$me" '
        .jobs[]
        | select(.status == "in_progress" and .id != $me and (.name | contains($job)))
        | ([.steps[]? | select(.name == $step)] | first) as $lock
        | if $lock == null then empty
          elif $lock.status == "completed" then "holder \(.id) \(.html_url)"
          elif .id < $me then "contender \(.id) \(.html_url)"
          else empty end'
  done
}

start=$(date +%s)
clear_looks=0
announced=""
while :; do
  found=$(blockers)
  if [ -z "$found" ]; then
    clear_looks=$((clear_looks + 1))
    if [ "$clear_looks" -ge 2 ]; then
      break
    fi
    sleep "$settle"
    continue
  fi
  clear_looks=0
  if [ "$found" != "$announced" ]; then
    echo "$(date -u +%H:%M:%SZ) waiting for another production deploy to finish:"
    printf '  %s\n' "$found"
    announced=$found
  fi
  if [ $(($(date +%s) - start)) -ge "$timeout" ]; then
    echo "::error title=Deploy lock timeout::Another production deploy kept the VM for more than $((timeout / 60)) minutes: $(tr '\n' ' ' <<< "$found"). Nothing was changed by this run; re-run it when that deploy ends."
    exit 1
  fi
  sleep "$poll"
done
waited=$(($(date +%s) - start))
echo "Deploy lock taken by job $me after ${waited}s."
echo "- Deploy lock: taken after ${waited}s (no other production deploy running)" >> "$summary"
