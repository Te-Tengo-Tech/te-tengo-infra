#!/usr/bin/env bash
# Opens the pull request <release branch> → main, or updates the title and description of the one that is
# already open (release.yml, after a candidate passed staging or its verification). Run it with the token
# of the GitHub App te-tengo-release-bot: a pull request opened or edited by the App starts the
# pull_request workflows (CI's ci-ok and release-gate), unlike one opened with GITHUB_TOKEN. Editing the
# description fires `edited`, which runs release-gate again for the new candidate.
#
#   open-release-pr.sh <title> <body file> [<comment for an existing pull request>]
#
# The body should name the pipeline run (with its attempt), so that it always changes and `edited` fires.
# Output: url=<pull request URL> to $GITHUB_OUTPUT. This script is the same in every Te Tengo repository.
#
# Environment: GH_TOKEN (the App token: pull requests write), GITHUB_REPOSITORY, GITHUB_REF_NAME (the
# release or hotfix branch), GITHUB_OUTPUT, GITHUB_STEP_SUMMARY.
set -euo pipefail

title=${1:?usage: open-release-pr.sh <title> <body file> [comment]}
body=${2:?usage: open-release-pr.sh <title> <body file> [comment]}
comment=${3:-}
: "${GITHUB_REPOSITORY:?}" "${GITHUB_REF_NAME:?}"
repo=$GITHUB_REPOSITORY
head=$GITHUB_REF_NAME
[ -s "$body" ] || { echo "::error title=Empty pull request description::$body is empty."; exit 1; }

number=$(gh pr list --repo "$repo" --head "$head" --base main --state open --json number --jq '.[0].number // ""')
if [ -n "$number" ]; then
  gh api --method PATCH "repos/$repo/pulls/$number" -f title="$title" -F "body=@$body" > /dev/null
  if [ -n "$comment" ]; then
    gh pr comment "$number" --repo "$repo" --body "$comment" > /dev/null
  fi
  url=$(gh pr view "$number" --repo "$repo" --json url --jq .url)
  echo "- Release pull request updated: $url" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
else
  if ! url=$(gh pr create --repo "$repo" --base main --head "$head" --title "$title" --body-file "$body"); then
    echo "::error title=Pull request not opened::te-tengo-release-bot could not open $head → main. Check that the App is installed on $repo with Pull requests: write."
    exit 1
  fi
  echo "- Release pull request opened: $url" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
fi
echo "url=$url" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "$url"
