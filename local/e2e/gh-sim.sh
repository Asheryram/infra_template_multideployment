#!/usr/bin/env bash
# gh-sim — behaves like GitHub + the app-kit workflow, using real local git repos and branches.
# Run as the deploy user.
#
#   gh-sim init                                       fresh repos demo-api + demo-web (branches main, staging, develop)
#   gh-sim branch   <repo> <branch> [from=develop]    create a feature branch
#   gh-sim commit   <repo> <branch> <msg> -- <cmd…>   run <cmd> inside the repo on <branch>, then commit
#   gh-sim push     <repo> <branch>                   push: develop/staging/main deploy their env; other branches deploy nothing
#   gh-sim pr-open  <repo> <n> <branch>               PR opened  → preview pr-<n>
#   gh-sim pr-sync  <repo> <n>                        new commits → redeploy pr-<n>
#   gh-sim pr-close <repo> <n> [--merge]              PR closed  → preview destroyed (+ merge into develop and push it)
#   gh-sim merge    <repo> <from> <into>              merge branches and push <into> (e.g. develop → main = release)
#
# Each deploy does what CI does: build every component image FROM THAT COMMIT, tag it sha-<12>,
# then `infra deploy --manifest <repo>/.deploy --env … --tag … --branch … --commit …`.
set -Eeuo pipefail
WORK=${E2E_WORK:-/var/tmp/infra-e2e}
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "$HERE/../.." && pwd)"

say() { printf '  \033[36mgh-sim\033[0m %s\n' "$*" >&2; }
g()   { local r=$1; shift; git -C "$WORK/$r" -c user.name=gh-sim -c user.email=gh-sim@local "$@"; }
mval() { ( set +u; set -a; . "$WORK/$1/.deploy/manifest.env"; eval "printf '%s' \"\${$2:-}\"" ); }

env_for_branch() {
  case $1 in main) echo prod ;; staging) echo staging ;; develop) echo develop ;; *) echo "" ;; esac
}

components() {
  case $1 in monolith) echo app ;; frontend) echo web ;; backend) echo api ;; split) echo "web api" ;; esac
}

build_and_deploy() { # repo branch env
  local repo=$1 branch=$2 env=$3 sha tag type img c ctx df
  g "$repo" checkout -q "$branch"
  sha=$(g "$repo" rev-parse HEAD); tag="sha-${sha:0:12}"
  type=$(mval "$repo" TYPE); img=$(mval "$repo" IMAGE_REPO)
  for c in $(components "$type"); do
    ctx=$(mval "$repo" "${c^^}_CONTEXT"); ctx=${ctx:-.}
    df=$(mval "$repo" "${c^^}_DOCKERFILE"); df=${df:-$ctx/Dockerfile}
    if ! docker image inspect "$img/$c:$tag" >/dev/null 2>&1; then
      say "build  $img/$c:$tag  ($repo@$branch)"
      docker build -q -t "$img/$c:$tag" -f "$WORK/$repo/$df" "$WORK/$repo/$ctx" >/dev/null
    fi
  done
  say "deploy $repo → $env  ($branch @ ${sha:0:8})"
  infra deploy --manifest "$WORK/$repo/.deploy" --env "$env" --tag "$tag" \
    --branch "$branch" --commit "$sha" --no-pull >/dev/null
}

cmd=${1:-}; shift || true
case $cmd in
  init)
    rm -rf "$WORK"; mkdir -p "$WORK/.prs"
    for repo in demo-api demo-web; do
      cp -r "$HERE/apps/$repo" "$WORK/$repo"
      if [[ $repo == demo-web ]]; then cp -r "$INFRA_ROOT/app-kit/dockerfiles/spa" "$WORK/$repo/deploy-spa"; fi
      git -C "$WORK/$repo" init -q -b main
      g "$repo" add -A; g "$repo" commit -qm "initial"
      g "$repo" branch staging; g "$repo" branch develop
    done
    say "repos ready in $WORK (main, staging, develop)"
    ;;
  branch)
    repo=$1 branch=$2 from=${3:-develop}
    g "$repo" checkout -q -B "$branch" "$from"; say "branch $repo:$branch from $from"
    ;;
  commit)
    repo=$1 branch=$2 msg=$3; shift 3; [[ ${1:-} == -- ]] && shift
    g "$repo" checkout -q "$branch"
    (cd "$WORK/$repo" && "$@")
    g "$repo" add -A; g "$repo" commit -qm "$msg"; say "commit $repo:$branch \"$msg\""
    ;;
  push)
    repo=$1 branch=$2 env=$(env_for_branch "$2")
    if [[ -z $env ]]; then say "push $repo:$branch — no environment for this branch (open a PR)"; exit 0; fi
    build_and_deploy "$repo" "$branch" "$env"
    ;;
  pr-open)
    repo=$1 n=$2 branch=$3
    echo "$branch" > "$WORK/.prs/$repo-$n"
    say "PR #$n opened on $repo ($branch)"
    build_and_deploy "$repo" "$branch" "pr-$n"
    ;;
  pr-sync)
    repo=$1 n=$2 branch=$(cat "$WORK/.prs/$repo-$n")
    say "PR #$n synchronized"
    build_and_deploy "$repo" "$branch" "pr-$n"
    ;;
  pr-close)
    repo=$1 n=$2 merge=${3:-} branch=$(cat "$WORK/.prs/$repo-$n")
    app=$(mval "$repo" APP_NAME)
    say "PR #$n closed${merge:+ (merged)}"
    infra destroy --app "$app" --env "pr-$n" >/dev/null
    rm -f "$WORK/.prs/$repo-$n"
    if [[ $merge == --merge ]]; then
      g "$repo" checkout -q develop; g "$repo" merge -q --no-ff "$branch" -m "Merge PR #$n ($branch)"
      say "merged $branch → develop"
      build_and_deploy "$repo" develop develop
    fi
    ;;
  merge)
    repo=$1 from=$2 into=$3
    g "$repo" checkout -q "$into"; g "$repo" merge -q --no-ff "$from" -m "Merge $from into $into"
    say "merged $from → $into"
    env=$(env_for_branch "$into"); [[ -z $env ]] || build_and_deploy "$repo" "$into" "$env"
    ;;
  *) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
