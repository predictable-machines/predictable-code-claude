#!/usr/bin/env sh
# shellcheck shell=sh
#
# Print the hosted Control Center's link to THIS project, or one line saying why
# there is none. The Control Center is hosted: there is no local app to start any
# more (`predictable serve` was deleted with it), so "open the report" means a link
# to the plane this machine is signed in to, opened on this repository.
#
# The plane is the one `predictable login` saved; the project is the checkout's
# `origin`, named the way the plane names a repository's project
# (`cloudProjectIdOf` in the Control Center: `gh-` and the `owner/repo` with every
# run of non-alphanumerics made one `-`). Exit 0 with the link, 1 with the reason.

self_dir=$(cd -- "$(dirname -- "$0")" >/dev/null 2>&1 && pwd)
# shellcheck source=scripts/lib.sh
. "$self_dir/lib.sh"

session="$HOME/.predictable-code/cloud-session.json"
if [ ! -f "$session" ] || ! pc_have_jq; then
  echo "This machine is not signed in to a Control Center; run \`predictable login\` first."
  exit 1
fi
plane=$(jq -r '.url // empty' "$session" 2>/dev/null)
if [ -z "$plane" ]; then
  echo "This machine is not signed in to a Control Center; run \`predictable login\` first."
  exit 1
fi

remote=$(git -C "$(pc_project_dir)" remote get-url origin 2>/dev/null || true)
# `git@github.com:owner/repo.git`, `https://github.com/owner/repo(.git)`, with or
# without credentials in the URL: the last two path segments are the repository.
slug=$(printf '%s' "$remote" | sed -E 's#\.git$##; s#^.*[:/]([^/:]+/[^/]+)$#\1#')
case "$slug" in
  */*) ;;
  *)
    echo "This checkout has no GitHub \`origin\`, so the Control Center has no project for it."
    exit 1
    ;;
esac
project="gh-$(printf '%s' "$slug" | sed -E 's#[^A-Za-z0-9]+#-#g')"
printf '%s/?project=%s\n' "${plane%/}" "$project"
