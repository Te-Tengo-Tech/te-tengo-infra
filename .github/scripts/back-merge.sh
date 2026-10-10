#!/usr/bin/env bash
# After vX.Y.Z is live and tagged (produccion.yml), brings main back into the long-lived branches:
#   1. the pull request main → develop ("chore: merge release x.y.z back into develop"), with auto-merge
#      (merge commit) turned on when the repository allows it: it merges by itself once its checks pass
#      and it is approved. Without auto-merge it stays open for a person to merge (with a merge commit).
#   2. after a hotfix, the pull request main → release/a.b.c for every open release branch with a newer
#      version that lacks main's commits, so the next release does not lose the fix (its release gate
#      would block it anyway). No auto-merge there: the merge builds a new candidate that goes through
#      staging again.
# Run it with the token of the GitHub App te-tengo-release-bot (contents and pull requests write), so the
# pull requests start their CI. This script is the same in every Te Tengo repository.
#
#   back-merge.sh <released version x.y.z>
#
# Environment: GH_TOKEN, GITHUB_REPOSITORY, GITHUB_STEP_SUMMARY.
set -euo pipefail

version=${1:?usage: back-merge.sh <released version>}
: "${GITHUB_REPOSITORY:?}"
repo=$GITHUB_REPOSITORY
summary=${GITHUB_STEP_SUMMARY:-/dev/null}

say() {
  echo "$1"
  echo "- $1" >> "$summary"
}

# open_pr <base> <title> <body>: echoes the URL of the open main → <base> pull request, opening it if needed.
open_pr() {
  local base=$1 title=$2 body=$3 url
  url=$(gh pr list --repo "$repo" --head main --base "$base" --state open --json url --jq '.[0].url // ""')
  if [ -z "$url" ]; then
    if ! url=$(gh pr create --repo "$repo" --base "$base" --head main --title "$title" --body "$body"); then
      echo "::error title=Pull request not opened::te-tengo-release-bot could not open main → $base. Check that the App is installed on $repo with Pull requests: write." >&2
      return 1
    fi
  fi
  echo "$url"
}

# 1. main → develop.
ahead=$(gh api "repos/$repo/compare/develop...main" --jq .ahead_by)
if [ "$ahead" = 0 ]; then
  say "develop already has every commit of main: no back-merge needed"
else
  url=$(open_pr develop "chore: merge release $version back into develop" \
    "Brings release \`v$version\` (the release branch's fixes, the version bump and the CHANGELOG) from \`main\` back into \`develop\`. Merge it with a merge commit, never a squash, so develop keeps main's history and the next release branch merges into main unchanged.")
  if gh pr merge "$url" --repo "$repo" --auto --merge > /dev/null 2>&1; then
    say "Back-merge pull request: $url (auto-merge on: it merges itself, with a merge commit, once approved and green)"
  else
    echo "::warning title=Auto-merge not available::Auto-merge could not be turned on for $url (Settings → General → Allow auto-merge is off, or the pull request is already mergeable). Merge it by hand with a merge commit."
    say "Back-merge pull request: $url (merge it by hand, with a merge commit)"
  fi
fi

# 2. main → newer open release branches (a hotfix shipped while a release was in QA).
mapfile -t branches < <(gh api --paginate "repos/$repo/branches?per_page=100" --jq '.[].name' |
  { grep -E '^release/[0-9]+\.[0-9]+\.[0-9]+$' || true; })
for branch in "${branches[@]}"; do
  other=${branch#release/}
  newest=$(printf '%s\n%s\n' "$version" "$other" | sort -V | tail -n1)
  if [ "$other" = "$version" ] || [ "$newest" != "$other" ]; then
    continue # the branch just released, or an older one
  fi
  ahead=$(gh api "repos/$repo/compare/$branch...main" --jq .ahead_by)
  [ "$ahead" != 0 ] || continue
  url=$(open_pr "$branch" "chore: merge release $version into $branch" \
    "\`v$version\` reached production while \`$branch\` was being prepared. Merge \`main\` into \`$branch\` (merge commit) so release $other keeps the fix; the merge builds a new candidate of $other, and the release gate of $branch → main stays red until it has passed staging.")
  say "Pull request main → $branch: $url"
done
