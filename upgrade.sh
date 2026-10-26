#!/usr/bin/env bash
# Upgrade GitLab CE following GitLab's official upgrade path.
#
#   ./upgrade.sh                 Upgrade to the newest release, stopping at every
#                                required stop on the way (verified backup before each hop).
#   ./upgrade.sh --patch-only    Only apply the newest patch of the current minor
#                                (e.g. 19.5.1 -> 19.5.4). Used by the weekly timer.
#   ./upgrade.sh --one-hop       Do a single hop, then stop.
#   ./upgrade.sh --dry-run       Show the planned path, change nothing.
#   --yes                        Don't ask for confirmation.
#
# Safety model: a hop happens only when GitLab is healthy, all background
# migrations are finished (none failed), and a checksummed backup bundle was
# written. While a hop runs, $GITLAB_HOME/.upgrade-in-progress exists; if the new
# version fails, it stays there and blocks every script until a human decides.
# There is NO automatic rollback by starting the old image: the database has
# already been migrated, and an older GitLab on a newer schema corrupts it.
# The only safe rollback is ./restore.sh with the pre-upgrade bundle.
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"
. ./lib.sh

PATCH_ONLY=0 ONE_HOP=0 DRY_RUN=0 ASSUME_YES=0
for a in "$@"; do
  case "$a" in
    --patch-only)  PATCH_ONLY=1 ;;
    --one-hop)     ONE_HOP=1 ;;
    --dry-run)     DRY_RUN=1 ;;
    --yes|-y)      ASSUME_YES=1 ;;
    --skip-backup) die "--skip-backup was removed: every hop needs a restorable backup" ;;
    -h|--help)     sed -n '2,19p' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

require_root
for c in jq curl flock sha256sum; do command -v "$c" >/dev/null || die "$c is required"; done
load_env
take_lock
preflight

current=$(data_version)
[[ -n "$current" ]] || die "no GitLab data in $GITLAB_HOME/data — run ./install.sh first"

# --- Data sources ----------------------------------------------------------

# Every stable X.Y.Z release published on Docker Hub, sorted.
fetch_releases() {
  local url="https://hub.docker.com/v2/repositories/gitlab/gitlab-ce/tags?page_size=100&name=-ce.0"
  local page pages=0
  while [[ -n "$url" && "$url" != "null" ]]; do
    page=$(curl -fsS --retry 3 --max-time 30 "$url") || return 1
    jq -r '.results[].name' <<<"$page" || return 1
    url=$(jq -r '.next' <<<"$page")
    (( ++pages < 100 )) || return 1
  done | grep -E '^[0-9]+\.[0-9]+\.[0-9]+-ce\.0$' | sed 's/-ce\.0$//' | sort -uV
}

# Required stops (MAJOR.MINOR) from GitLab's own upgrade-path definition.
fetch_required_stops() {
  curl -fsS --retry 3 --max-time 30 https://gitlab.com/gitlab-org/gitlab/-/raw/master/config/upgrade_path.yml |
    awk '/major:/ {maj=$NF} /minor:/ {print maj "." $NF}' | sort -uV
}

latest_patch_of() { grep -E "^${1//./\\.}\.[0-9]+$" <<<"$RELEASES" | tail -n1 || true; }
mm() { cut -d. -f1,2 <<<"$1"; }
ver_gt() { [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" == "$1" ]]; }

log "Fetching release list from Docker Hub"
RELEASES=$(fetch_releases) || die "could not fetch tags from Docker Hub"
[[ -n "$RELEASES" ]] || die "empty tag list from Docker Hub"
grep -qxF "$current" <<<"$RELEASES" || warn "current version $current is not in Docker Hub's list (continuing)"
latest=$(tail -n1 <<<"$RELEASES")

if (( ! PATCH_ONLY )); then
  log "Fetching GitLab required upgrade stops"
  STOPS=$(fetch_required_stops) || die "could not fetch upgrade_path.yml; refusing to cross minor versions blind (use --patch-only)"
  [[ $(wc -l <<<"$STOPS") -ge 5 ]] || die "upgrade_path.yml parsed to almost nothing; refusing to guess the path"
fi

# Next version to jump to from $1.
next_hop() {
  local from=$1 from_mm stop p
  from_mm=$(mm "$from")
  if (( PATCH_ONLY )); then latest_patch_of "$from_mm"; return; fi
  # First the newest patch of the current minor (GitLab's recommendation).
  p=$(latest_patch_of "$from_mm")
  if [[ -n "$p" ]] && ver_gt "$p" "$from"; then echo "$p"; return; fi
  # Then the next required stop between us and latest.
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

update_caddy() {
  docker compose pull -q caddy && recreate_caddy || warn "Caddy update failed (GitLab unaffected)"
}

if (( ${#plan[@]} == 0 )); then
  log "GitLab $current is up to date ($( (( PATCH_ONLY )) && echo "newest patch of $(mm "$current")" || echo "newest release"))"
  (( DRY_RUN )) || update_caddy
  exit 0
fi

log "Upgrade path: $current -> $(echo "${plan[*]}" | sed 's/ / -> /g')"
(( DRY_RUN )) && exit 0
if (( ! ASSUME_YES )); then confirm "Proceed?" || exit 1; fi

# --- Execute ----------------------------------------------------------------

rc=0; wait_healthy 15 || rc=$?
(( rc == 0 )) || { explain_unhealthy "$rc"; die "GitLab is not healthy before upgrading; fix that first"; }

for target in "${plan[@]}"; do
  log "Hop $current -> $target"
  image="gitlab/gitlab-ce:$target-ce.0"

  wait_migrations

  # Pull before anything else changes, so a registry outage leaves no trace.
  docker_root=$(docker info -f '{{.DockerRootDir}}')
  need_space "$docker_root" $((4 * 1048576)) "pulling $image"
  docker pull -q "$image" >/dev/null || die "could not pull $image (nothing changed, still on $current)"

  BUNDLE=""
  create_bundle pre-upgrade

  before=$(data_fingerprint) || die "could not read row counts before the switch (nothing changed yet)"

  # From here on, a failure leaves the marker and blocks further automation.
  printf 'from=%s\nto=%s\nbundle=%s\nstarted=%s\n' "$current" "$target" "$BUNDLE" "$(date -u +%FT%TZ)" > "$MARKER"
  set_env_version "$target"
  docker compose up -d --no-deps gitlab

  rc=0; wait_healthy 60 || rc=$?
  if (( rc != 0 )); then
    explain_unhealthy "$rc"
    die "GitLab $target did not come up. Data is untouched on disk and the pre-upgrade backup is:
         $BUNDLE
       Do NOT set the old version back in .env (the database is already migrated).
       Inspect: docker compose logs -f gitlab  — often a fix + 'docker compose restart gitlab' is enough.
       Roll back: sudo ./restore.sh $BUNDLE --force
       Then remove $MARKER (restore.sh does this itself)."
  fi

  rv=$(running_version || true); dv=$(data_version)
  [[ "$rv" == "$target" && "$dv" == "$target" ]] ||
    die "after the hop GitLab reports version '${rv:-?}' (data: '${dv:-?}'), expected $target. Marker left at $MARKER."

  after=$(data_fingerprint) || die "GitLab is up but the database could not be queried. Marker left at $MARKER."
  if ! compare_fingerprint "$before" "$after" nodecrease; then
    die "row counts DROPPED during the upgrade (see above). Marker left at $MARKER.
       If nobody deleted data in the meantime, roll back: sudo ./restore.sh $BUNDLE --force"
  fi

  if ! gl gitlab-rake gitlab:check SANITIZE=true >/tmp/gitlab-check.log 2>&1; then
    warn "gitlab:check reported issues (see /tmp/gitlab-check.log); GitLab is up, continuing"
  fi
  rm -f "$MARKER"
  log "Now on $target (backup kept: $BUNDLE)"
  current=$target
done

prune_bundles
update_caddy
docker image prune -f >/dev/null || true
log "Done. GitLab $current"
