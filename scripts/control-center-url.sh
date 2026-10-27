#!/usr/bin/env sh
# shellcheck shell=sh
#
# Print the hosted Control Center's link to THIS project, or one line saying why
# there is none. The Control Center is hosted: there is no local app to start any
# more (`predictable serve` was deleted with it), so "open the report" means a link
# to the plane this machine is signed in to, opened on this repository.
#
# The plane is the one `predictable login` saved; the project is the checkout's
# `origin`, named EXACTLY the way the plane names a repository's project
# (`cloudProjectIdOf` in the Control Center): `gh-<owner>.<name>`, lowercased, each
# character outside its part's alphabet written as `~` and its UTF-8 bytes in hex.
# The old rule (every run of non-alphanumerics made one `-`) named a project the
# plane no longer has, and the link opened "isn't registered here" (#2527).
# Exit 0 with the link, 1 with the reason.

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
# One part of the id: lowercased, then byte by byte, a byte of the part's alphabet
# kept and any other written `~hh` — what `idPart` does over UTF-8 in the plane.
# `$2` is `name` for a repository name, which may also hold `.`.
id_part() { # text owner|name
  # ASCII lowercase on purpose (`LC_ALL=C`): GitHub owners and names are ASCII, and a locale's
  # multi-byte case mapping is exactly what `od` would then read differently on each machine.
  printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]' | od -An -v -tx1 | tr ' ' '\n' |
    while IFS= read -r h; do
      [ -n "$h" ] || continue
      case "$h" in
        3[0-9] | 6[1-9a-f] | 7[0-9a] | 5f | 2d) printf '%b' "\\0$(printf '%03o' "0x$h")" ;;
        2e) if [ "$2" = name ]; then printf '.'; else printf '~2e'; fi ;;
        *) printf '~%s' "$h" ;;
      esac
    done
}
project="gh-$(id_part "${slug%%/*}" owner).$(id_part "${slug#*/}" name)"
printf '%s/?project=%s\n' "${plane%/}" "$project"
