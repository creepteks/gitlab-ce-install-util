#!/usr/bin/env bash
# Upgrade GitLab CE following GitLab's official upgrade path.
#
#   ./upgrade.sh                 Upgrade to the newest release, stopping at every
#                                required stop on the way (backup before each hop).
#   ./upgrade.sh --patch-only    Only apply the newest patch of the current minor
#                                (e.g. 19.5.1 -> 19.5.4). Safe to automate.
#   ./upgrade.sh --one-hop       Do a single hop, then stop.
#   ./upgrade.sh --dry-run       Show the planned path, change nothing.
#   --yes                        Don't ask for confirmation.
#   --skip-backup                Skip gitlab-backup (config + secrets are still saved).
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

PATCH_ONLY=0 ONE_HOP=0 DRY_RUN=0 ASSUME_YES=0 SKIP_BACKUP=0
for a in "$@"; do
  case "$a" in
    --patch-only)  PATCH_ONLY=1 ;;
    --one-hop)     ONE_HOP=1 ;;
    --dry-run)     DRY_RUN=1 ;;
    --yes|-y)      ASSUME_YES=1 ;;
    --skip-backup) SKIP_BACKUP=1 ;;
    -h|--help)     sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

log() { printf '\n[%s] ==> %s\n' "$(date '+%F %T')" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root"
command -v jq >/dev/null || die "jq is required (apt install jq)"
[[ -f .env ]] || die ".env not found"

# Only one upgrade at a time (manual run vs. systemd timer).
exec 9>/var/lock/gitlab-upgrade.lock
flock -n 9 || die "another upgrade is already running"

env_get() { grep -E "^$1=" .env | tail -n1 | cut -d= -f2-; }
GITLAB_HOME=$(env_get GITLAB_HOME); GITLAB_HOME=${GITLAB_HOME:-/srv/gitlab}

current_tag=$(env_get GITLAB_VERSION)
current=${current_tag%-ce.*}
[[ "$current" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "can't parse GITLAB_VERSION=$current_tag"

# --- Data sources ----------------------------------------------------------

# Every stable X.Y.Z release published on Docker Hub, sorted.
fetch_releases() {
  local url="https://hub.docker.com/v2/repositories/gitlab/gitlab-ce/tags?page_size=100&name=-ce.0"
  while [[ -n "$url" && "$url" != "null" ]]; do
    local page; page=$(curl -fsS --retry 3 "$url") || return 1
    jq -r '.results[].name' <<<"$page"
    url=$(jq -r '.next' <<<"$page")
  done | grep -E '^[0-9]+\.[0-9]+\.[0-9]+-ce\.0$' | sed 's/-ce\.0$//' | sort -uV
}

# Required stops (MAJOR.MINOR) from GitLab's own upgrade-path definition.
fetch_required_stops() {
  curl -fsS --retry 3 https://gitlab.com/gitlab-org/gitlab/-/raw/master/config/upgrade_path.yml |
    awk '/major:/ {maj=$NF} /minor:/ {print maj "." $NF}' | sort -uV
}

latest_patch_of() { grep -E "^${1//./\\.}\.[0-9]+$" <<<"$RELEASES" | tail -n1; }
mm() { cut -d. -f1,2 <<<"$1"; }
ver_gt() { [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" == "$1" ]]; }

log "Fetching release list from Docker Hub"
RELEASES=$(fetch_releases) || die "could not fetch tags from Docker Hub"
[[ -n "$RELEASES" ]] || die "empty tag list from Docker Hub"
latest=$(tail -n1 <<<"$RELEASES")

if (( ! PATCH_ONLY )); then
  log "Fetching GitLab required upgrade stops"
  STOPS=$(fetch_required_stops) || die "could not fetch upgrade_path.yml; refusing to cross minor versions blind (use --patch-only)"
  [[ -n "$STOPS" ]] || die "upgrade_path.yml parsed empty"
fi

# Next version to jump to from $1.
next_hop() {
  local from=$1 from_mm stop
  from_mm=$(mm "$from")
  if (( PATCH_ONLY )); then latest_patch_of "$from_mm"; return; fi
  # First finish the current minor's newest patch (GitLab's recommendation).
  local p; p=$(latest_patch_of "$from_mm")
  if ver_gt "$p" "$from"; then echo "$p"; return; fi
  # Then the next required stop, if one lies between us and latest.
  while read -r stop; do
    if ver_gt "$stop.999" "$from_mm.999" && ! ver_gt "$stop.0" "$latest"; then
      p=$(latest_patch_of "$stop")
      [[ -n "$p" ]] && { echo "$p"; return; }
    fi
  done <<<"$STOPS"
  echo "$latest"
}

# --- Plan --------------------------------------------------------------------

plan=() v=$current
while :; do
  n=$(next_hop "$v")
  [[ -n "$n" ]] && ver_gt "$n" "$v" || break
  plan+=("$n"); v=$n
  (( ONE_HOP )) && break
done

if (( ${#plan[@]} == 0 )); then
  log "GitLab $current is up to date ($( (( PATCH_ONLY )) && echo "newest patch of $(mm "$current")" || echo "newest release"))"
  (( DRY_RUN )) || { docker compose pull -q caddy && docker compose up -d caddy; }
  exit 0
fi

log "Upgrade path: $current -> $(echo "${plan[*]}" | sed 's/ / -> /g')"
(( DRY_RUN )) && exit 0
if (( ! ASSUME_YES )); then
  read -rp "Proceed? [y/N] " ans; [[ "$ans" =~ ^[Yy]$ ]] || exit 1
fi

# --- Helpers that touch the running instance ---------------------------------

gl() { docker compose exec -T gitlab "$@"; }

wait_healthy() {
  local status cid
  for _ in $(seq 1 180); do
    cid=$(docker compose ps -q gitlab)
    status=$(docker inspect -f '{{.State.Health.Status}}' "$cid" 2>/dev/null || echo starting)
    [[ "$status" == "healthy" ]] && return 0
    sleep 10
  done
  return 1
}

# A hop is only safe once the previous version's background migrations are done.
wait_migrations() {
  local n
  for _ in $(seq 1 360); do
    n=$(gl gitlab-rails runner -e production '
      a = (Gitlab::BackgroundMigration.remaining rescue 0)
      b = (Gitlab::Database::BackgroundMigration::BatchedMigration.queued.count rescue 0)
      puts a.to_i + b.to_i' 2>/dev/null | tail -n1) || n=""
    [[ "$n" == "0" ]] && return 0
    echo "  background migrations pending: ${n:-?} (checking again in 60s)"
    sleep 60
  done
  return 1
}

backup() {
  local stamp; stamp=$(date +%Y%m%d-%H%M%S)
  mkdir -p "$GITLAB_HOME/config-backups"
  # gitlab-secrets.json is NOT inside gitlab-backup archives; without it a restore is useless.
  tar -C "$GITLAB_HOME" -czf "$GITLAB_HOME/config-backups/config-$current-$stamp.tgz" config
  chmod 600 "$GITLAB_HOME/config-backups/config-$current-$stamp.tgz"
  if (( ! SKIP_BACKUP )); then
    gl gitlab-backup create STRATEGY=copy BACKUP="pre-upgrade-$current-$stamp" ||
      die "backup failed; aborting before any change"
  fi
  echo "  backups in $GITLAB_HOME/data/backups and $GITLAB_HOME/config-backups"
}

set_version() { sed -i -E "s/^GITLAB_VERSION=.*/GITLAB_VERSION=$1-ce.0/" .env; }

# --- Execute ----------------------------------------------------------------

wait_healthy || die "GitLab is not healthy before upgrading; fix that first"
for target in "${plan[@]}"; do
  log "Hop $current -> $target"
  wait_migrations || die "background migrations didn't finish; re-run later"
  backup
  set_version "$target"
  if ! docker compose pull -q gitlab; then
    set_version "$current"; die "could not pull gitlab-ce:$target-ce.0 (still on $current)"
  fi
  docker compose up -d gitlab
  if ! wait_healthy; then
    die "GitLab $target did not become healthy. Inspect: docker compose logs -f gitlab
       Restore: set GITLAB_VERSION=$current-ce.0 in .env and restore the backup taken above (see README)."
  fi
  gl gitlab-rake gitlab:check SANITIZE=true >/dev/null 2>&1 || echo "  WARNING: gitlab:check reported issues; review with: docker compose exec gitlab gitlab-rake gitlab:check"
  log "Now on $target"
  current=$target
done

docker compose pull -q caddy && docker compose up -d caddy
docker image prune -f >/dev/null
log "Done. GitLab $current"
