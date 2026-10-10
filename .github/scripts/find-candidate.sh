#!/usr/bin/env bash
# Finds the verified release candidate for a git tree (docs/DEPLOYMENT.md): the newest pre-release
# vX.Y.Z-rc.N whose notes (the ```text block written by release.yml, key=value lines) record
# `tree=<tree>` and `verification=passed`, and whose tag points at a commit with that same tree. Used by
# produccion.yml (the tree of main) and release-gate.yml (the tree of the pull request's test merge), so
# both accept exactly the same candidates. The same script serves te-tengo-general-api and te-tengo-infra.
#
#   find-candidate.sh <version x.y.z> <git tree sha>
#
# Exit 0 when found, with tag=vX.Y.Z-rc.N and every key=value line of the record (candidate, version,
# build, commit, tree, digest when the record has one, verification) written to $GITHUB_OUTPUT; exit 1
# with a ::error and the list of candidates in the summary otherwise.
# Environment: GH_TOKEN, GITHUB_REPOSITORY, GITHUB_OUTPUT, GITHUB_STEP_SUMMARY.
set -euo pipefail

version=${1:?usage: find-candidate.sh <version> <tree>}
tree=${2:?usage: find-candidate.sh <version> <tree>}
: "${GITHUB_REPOSITORY:?}"
repo=$GITHUB_REPOSITORY
out=${GITHUB_OUTPUT:-/dev/null}
summary=${GITHUB_STEP_SUMMARY:-/dev/null}
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "::error title=Invalid version::'$version' is not x.y.z."; exit 1; }

notes=$(mktemp)
trap 'rm -f "$notes"' EXIT
field() { sed -n "s/^$1=//p" "$notes" | head -n 1; }

mapfile -t numbers < <(gh api "repos/$repo/git/matching-refs/tags/v$version-rc." --jq '.[].ref' |
  sed -n "s|^refs/tags/v${version//./\\.}-rc\.\([0-9][0-9]*\)$|\1|p" | sort -rn)
checked=()
for n in "${numbers[@]}"; do
  tag="v$version-rc.$n"
  if ! gh release view "$tag" -R "$repo" --json body,isPrerelease,isDraft \
    --jq 'select(.isPrerelease and (.isDraft | not)) | .body' 2> /dev/null | tr -d '\r' > "$notes"; then
    continue
  fi
  checked+=("\`$tag\`: tree \`$(field tree | cut -c1-12)\`, verification $(field verification)")
  [ "$(field tree)" = "$tree" ] || continue
  [ "$(field version)" = "$version" ] || continue
  if [ "$(field verification)" != passed ]; then
    continue # built from this tree but not verified (pending or failed)
  fi
  digest=$(field digest)
  if [ -n "$digest" ] && [[ ! "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "::error title=Invalid candidate record::$tag records the digest '$digest'."
    exit 1
  fi
  # The record is in the notes; the tag itself must point at a commit with that same tree.
  if [ "$(gh api "repos/$repo/commits/$tag" --jq .commit.tree.sha)" != "$tree" ]; then
    echo "::warning title=Candidate record mismatch::$tag records the tree ${tree:0:12}, but its tag points at a commit with another tree; ignored."
    continue
  fi
  {
    echo "tag=$tag"
    # shellcheck disable=SC2016 # the backticks are the literal Markdown fence of the record
    sed -n '/^```text$/,/^```$/{/^[a-z_]*=/p;}' "$notes"
  } >> "$out"
  echo "- Candidate [\`$tag\`](${GITHUB_SERVER_URL:-https://github.com}/$repo/releases/tag/$tag) (build $(field build), commit \`$(field commit | cut -c1-12)\`) has the tree \`${tree:0:12}\` and passed its verification${digest:+; image \`$digest\`}" >> "$summary"
  echo "$tag (verification passed) has the tree $tree"
  exit 0
done

echo "::error title=No verified candidate for this tree::No candidate of $version records the tree ${tree:0:12} with verification=passed. Candidates of $version: ${#checked[@]}; the run summary lists them."
{
  echo "### No verified candidate of $version has the tree \`${tree:0:12}\`"
  if [ ${#checked[@]} -eq 0 ]; then
    echo "- none yet"
  else
    printf -- '- %s\n' "${checked[@]}"
  fi
} >> "$summary"
exit 1
