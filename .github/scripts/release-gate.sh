#!/usr/bin/env bash
# Release gate of a pull request into main (release-gate.yml). The pull request may be merged only when
#   1. it comes from release/x.y.z or hotfix/x.y.z of this repository and x.y.z is the version of its head;
#   2. vX.Y.Z is not released yet;
#   3. merging it puts into main exactly the git tree of the head (main has nothing the branch lacks), and
#   4. a release candidate of x.y.z with that tree exists and was approved: it passed staging (or staging
#      was switched off), or its automatic verification passed. produccion.yml looks for that same
#      candidate after the merge, with the same command, so a green gate means production will find it.
# A push to the release branch fails the gate until the Release run of that commit has a candidate; that
# run then edits the pull request (as te-tengo-release-bot), and the `edited` event runs the gate again.
#
#   release-gate.sh <version of the head> <find-candidate command> [arguments...]
#
# The find-candidate command is run with "<version> <tree>" appended. It must exit 0 only when an approved
# candidate of <version> records <tree>, and explain itself otherwise. This script is the same in every
# Te Tengo repository; only the find-candidate command differs.
#
# Environment: GH_TOKEN (contents and pull requests read), GITHUB_REPOSITORY, PR_NUMBER, HEAD_REF,
# HEAD_SHA, HEAD_REPO (owner/name of the head repository), GITHUB_STEP_SUMMARY.
set -euo pipefail

version=${1:?usage: release-gate.sh <version> <find-candidate command...>}
shift
[ $# -gt 0 ] || { echo "usage: release-gate.sh <version> <find-candidate command...>" >&2; exit 2; }
: "${GITHUB_REPOSITORY:?}" "${PR_NUMBER:?}" "${HEAD_REF:?}" "${HEAD_SHA:?}" "${HEAD_REPO:?}"
summary=${GITHUB_STEP_SUMMARY:-/dev/null}
repo=$GITHUB_REPOSITORY

blocked() {
  echo "::error title=$1::$2"
  {
    echo "### release-gate: not mergeable yet"
    echo "$2"
  } >> "$summary"
  exit 1
}

if [ "$HEAD_REPO" != "$repo" ]; then
  blocked "Not a branch of this repository" "Pull requests into main come only from release/x.y.z or hotfix/x.y.z of $repo, not from $HEAD_REPO."
fi
if [[ ! "$HEAD_REF" =~ ^(release|hotfix)/([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
  blocked "Not a release branch" "Only release/x.y.z (from develop) and hotfix/x.y.z (from main) are merged into main. Open the pull request from $HEAD_REF against develop instead."
fi
if [ "${BASH_REMATCH[2]}" != "$version" ]; then
  blocked "Branch and version differ" "$HEAD_REF must carry version ${BASH_REMATCH[2]}, but its head says $version. Bump the version on the branch (a new candidate is built) or rename the branch."
fi
if gh api "repos/$repo/git/ref/tags/v$version" > /dev/null 2>&1; then
  blocked "v$version is already released" "The tag v$version exists. A change to a released version is a new version: bump it on the branch (hotfix/x.y.z+1)."
fi

# GitHub's test merge of the pull request is what main will contain after a merge commit. It is computed
# in the background after every push to either branch: wait until it is ready and belongs to this head.
pr="" mergeable=null merge=""
for _ in $(seq 1 24); do
  pr=$(gh api "repos/$repo/pulls/$PR_NUMBER")
  mergeable=$(jq -r '.mergeable' <<< "$pr")
  merge=$(jq -r '.merge_commit_sha // ""' <<< "$pr")
  if [ "$mergeable" != null ] && [ -n "$merge" ]; then
    break
  fi
  sleep 5
done
if [ "$(jq -r .state <<< "$pr")" != open ]; then
  blocked "Pull request not open" "Pull request #$PR_NUMBER is $(jq -r .state <<< "$pr")."
fi
current=$(jq -r .head.sha <<< "$pr")
if [ "$current" != "$HEAD_SHA" ]; then
  blocked "Superseded" "$HEAD_REF moved on to ${current:0:12}; this run checked ${HEAD_SHA:0:12}. The run of the newer commit decides."
fi
if [ "$mergeable" = null ] || [ -z "$merge" ]; then
  blocked "Test merge not ready" "GitHub has not computed the test merge of #$PR_NUMBER yet. Re-run this check in a minute."
fi
if [ "$mergeable" != true ]; then
  blocked "Merge conflicts" "$HEAD_REF conflicts with main. Merge main into $HEAD_REF (that builds a new candidate), then this check runs again."
fi
if ! gh api "repos/$repo/commits/$merge" --jq '.parents[].sha' | grep -qx "$HEAD_SHA"; then
  blocked "Test merge out of date" "The test merge ${merge:0:12} is not based on ${HEAD_SHA:0:12} yet. Re-run this check in a minute."
fi
tree=$(gh api "repos/$repo/git/commits/$merge" --jq .tree.sha)
head_tree=$(gh api "repos/$repo/git/commits/$HEAD_SHA" --jq .tree.sha)
if [ "$tree" != "$head_tree" ]; then
  blocked "main has changes this branch lacks" "Merging would put the tree ${tree:0:12} into main, not the tree ${head_tree:0:12} of $HEAD_REF that the candidates are built from: main has commits $HEAD_REF lacks (a hotfix?). Merge main into $HEAD_REF; that builds and tests a new candidate."
fi

if ! "$@" "$version" "$tree"; then
  blocked "No approved candidate yet" "No candidate of $version with the tree ${tree:0:12} of ${HEAD_SHA:0:12} has passed staging or its verification yet. The Release run of this commit builds it; when it passes, that run updates this pull request and the gate runs again."
fi
{
  echo "### release-gate: passed"
  echo "\`$HEAD_REF\` (\`${HEAD_SHA:0:12}\`, tree \`${tree:0:12}\`) merges into main unchanged, and an approved candidate of $version has this tree: \`produccion.yml\` will deploy it after the merge."
} >> "$summary"
echo "release-gate passed: $HEAD_REF ${HEAD_SHA:0:12}, tree $tree, version $version"
