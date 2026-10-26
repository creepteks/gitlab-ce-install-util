# Shared helpers for install.sh, upgrade.sh, backup.sh and restore.sh.
# Source only (expects `set -euo pipefail` and cwd = this directory).
# shellcheck shell=bash

log()  { printf '\n[%s] ==> %s\n' "$(date '+%F %T')" "$*"; }
skip() { printf '    [skip] %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Exit hooks: several cleanups can be armed at once without overwriting each
# other (a plain `trap ... EXIT` would replace the previous one).
declare -A EXIT_HOOKS=()
_run_exit_hooks() { local rc=$? k; for k in "${!EXIT_HOOKS[@]}"; do eval "${EXIT_HOOKS[$k]}" || true; done; return $rc; }
trap _run_exit_hooks EXIT
on_exit()  { EXIT_HOOKS[$1]=$2; }     # on_exit <name> <command>
off_exit() { unset "EXIT_HOOKS[$1]"; }

require_root() { [[ $EUID -eq 0 ]] || die "run as root (sudo $0)"; }

confirm() {  # confirm "question"  -> 0 on y/Y
  local ans
  read -rp "$1 [y/N] " ans || ans=""
  [[ "$ans" =~ ^[Yy]$ ]]
}

# --- .env ---------------------------------------------------------------------

# docker compose prefers variables from the caller's environment over .env, so a
# stray exported GITLAB_HOME/GITLAB_VERSION would silently point at other data.
ENV_VARS=(GITLAB_DOMAIN ACME_EMAIL GITLAB_VERSION GITLAB_HOME GITLAB_SSH_PORT TZ PUBLIC_IP BACKUP_DIR BACKUP_KEEP)

load_env() {
  [[ -f .env ]] || die ".env not found in $(pwd)"
  local v
  for v in "${ENV_VARS[@]}"; do unset "$v"; done
  set -a; . ./.env; set +a

  [[ -n "${GITLAB_HOME:-}" && "$GITLAB_HOME" == /* && "$GITLAB_HOME" != / ]] ||
    die "GITLAB_HOME must be an absolute path (not /) in .env"
  GITLAB_HOME=${GITLAB_HOME%/}
  [[ "${GITLAB_VERSION:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+-ce\.0$ ]] ||
    die "GITLAB_VERSION='${GITLAB_VERSION:-}' in .env must look like 19.5.1-ce.0 (never 'latest')"
  PINNED_VERSION=${GITLAB_VERSION%-ce.0}
  BACKUP_DIR=${BACKUP_DIR:-$GITLAB_HOME/bundles}
  BACKUP_DIR=${BACKUP_DIR%/}
  BACKUP_KEEP=${BACKUP_KEEP:-5}
  [[ "$BACKUP_KEEP" =~ ^[1-9][0-9]*$ ]] || die "BACKUP_KEEP must be a number >= 1"
  MARKER="$GITLAB_HOME/.upgrade-in-progress"
  export GITLAB_HOME GITLAB_VERSION BACKUP_DIR
}

set_env_version() {  # set_env_version 19.5.1 — updates .env atomically and verifies it
  local tmp
  tmp=$(mktemp .env.XXXXXX)
  if grep -qE '^GITLAB_VERSION=' .env; then
    sed -E "s/^GITLAB_VERSION=.*/GITLAB_VERSION=$1-ce.0/" .env > "$tmp"
  else
    { cat .env; printf '\nGITLAB_VERSION=%s-ce.0\n' "$1"; } > "$tmp"
  fi
  chmod --reference=.env "$tmp" 2>/dev/null || chmod 600 "$tmp"
  mv -f "$tmp" .env
  grep -qxF "GITLAB_VERSION=$1-ce.0" .env || die "failed to write GITLAB_VERSION=$1-ce.0 to .env"
  GITLAB_VERSION="$1-ce.0"; PINNED_VERSION=$1
  export GITLAB_VERSION
}

# --- Locking --------------------------------------------------------------------
# One maintenance task at a time (install, upgrade, backup, restore, timers).

take_lock() {
  [[ "${GITLAB_MAINT_LOCK_HELD:-0}" == 1 ]] && return 0
  exec 9>/var/lock/gitlab-maint.lock
  flock -n 9 || die "another GitLab maintenance task (install/upgrade/backup/restore) is running"
  export GITLAB_MAINT_LOCK_HELD=1
}

# --- Guards: refuse anything that could start GitLab on the wrong data ----------

# Version of the data on disk, written by GitLab itself. This, not .env, is the
# truth about which version the database schema belongs to.
data_version() {
  local f="$GITLAB_HOME/data/gitlab-rails/VERSION"
  [[ -f "$f" ]] || return 0
  grep -Eo '^[0-9]+\.[0-9]+\.[0-9]+' "$f" | head -n1
}

check_no_failed_upgrade() {
  [[ -f "$MARKER" ]] || return 0
  die "an earlier upgrade did not complete:
$(sed 's/^/       /' "$MARKER")
       Nothing will run until this is resolved. Either:
         - GitLab works on the new version (check https://$GITLAB_DOMAIN and
           'docker compose exec gitlab gitlab-rake gitlab:check'): rm $MARKER
         - or restore the pre-upgrade bundle listed above: sudo ./restore.sh <bundle> --force"
}

# Container id of the gitlab service (empty if none). Never fails: under
# pipefail a failing `docker compose ps` would otherwise abort silently.
gitlab_cid() { { docker compose ps -a -q gitlab 2>/dev/null || true; } | head -n1; }
gl() { docker compose exec -T gitlab "$@"; }

# If the existing container uses another data dir than .env says, GITLAB_HOME was
# changed; starting would bring up an empty GitLab and orphan the real data.
check_mounts() {
  local cid src
  cid=$(gitlab_cid)
  [[ -n "$cid" ]] || return 0
  src=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/opt/gitlab"}}{{.Source}}{{end}}{{end}}' "$cid")
  [[ -z "$src" || "$src" == "$GITLAB_HOME/data" ]] ||
    die "the existing GitLab container stores its data in $src, but .env has GITLAB_HOME=$GITLAB_HOME.
       Starting now would bring up an EMPTY GitLab. Fix GITLAB_HOME in .env (or move the data) first."
}

# The image must match the data: a newer image runs an unplanned upgrade without
# a backup; an older image against a newer schema corrupts the database.
check_version_matches_data() {
  local dv; dv=$(data_version)
  [[ -z "$dv" || "$dv" == "$PINNED_VERSION" ]] && return 0
  if [[ "$(printf '%s\n%s\n' "$dv" "$PINNED_VERSION" | sort -V | tail -n1)" == "$PINNED_VERSION" ]]; then
    die "data in $GITLAB_HOME is GitLab $dv but .env pins the newer $PINNED_VERSION.
       Upgrades must go through ./upgrade.sh (backups + required stops).
       Set GITLAB_VERSION=$dv-ce.0 in .env, then run ./upgrade.sh."
  else
    die "data in $GITLAB_HOME is GitLab $dv but .env pins the OLDER $PINNED_VERSION.
       Downgrades are not supported and corrupt the database.
       Set GITLAB_VERSION=$dv-ce.0 in .env (or restore an older bundle with ./restore.sh)."
  fi
}

preflight() {  # all guards, for any script about to start or touch GitLab
  check_no_failed_upgrade
  check_mounts
  check_version_matches_data
}

# --- Health -------------------------------------------------------------------

# wait_healthy [minutes] -> 0 healthy, 1 timed out, 2 exited / restart-looping
wait_healthy() {
  local minutes=${1:-30} cid info state health restarts r0 i
  cid=$(gitlab_cid); [[ -n "$cid" ]] || return 2
  r0=$(docker inspect -f '{{.RestartCount}}' "$cid" 2>/dev/null) || return 2
  for (( i = 0; i < minutes * 6; i++ )); do
    info=$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} {{.RestartCount}}' "$cid" 2>/dev/null) || return 2
    read -r state health restarts <<<"$info"
    [[ "$health" == healthy ]] && return 0
    [[ "$state" == exited || "$state" == dead ]] && return 2
    (( restarts - r0 >= 2 )) && return 2
    sleep 10
  done
  return 1
}

explain_unhealthy() {  # explain_unhealthy <rc from wait_healthy>
  if [[ "$1" == 2 ]]; then echo "GitLab container exited or is restart-looping. Last log lines:" >&2
  else echo "GitLab did not become healthy in time. Last log lines:" >&2; fi
  docker compose logs --no-log-prefix --tail 40 gitlab >&2 || true
}

running_version() {
  gl cat /opt/gitlab/embedded/service/gitlab-rails/VERSION 2>/dev/null | grep -Eo '^[0-9]+\.[0-9]+\.[0-9]+' | head -n1
}

# --- Background migrations ----------------------------------------------------

# Prints "<unfinished> <failed>" for batched background migrations.
# status: 0 paused, 1 active, 3 finished, 4 failed, 5 finalizing, 6 finalized
migration_counts() {
  gl gitlab-psql -At -F ' ' -c \
    "SELECT count(*) FILTER (WHERE status IN (0,1,5)), count(*) FILTER (WHERE status = 4) FROM batched_background_migrations;" |
    tail -n1
}

# A version hop is only safe once the previous version's migrations finished.
# Any doubt (query error, failed migration) stops the upgrade.
wait_migrations() {
  local out pending failed errors=0 i
  for (( i = 0; i < 360; i++ )); do
    if out=$(migration_counts 2>/dev/null) && read -r pending failed <<<"$out" &&
       [[ "$pending" =~ ^[0-9]+$ && "$failed" =~ ^[0-9]+$ ]]; then
      errors=0
      (( failed == 0 )) || die "$failed batched background migration(s) FAILED; upgrading now can break the database.
       Fix them first (Admin > Monitoring > Background migrations > Failed, or
       docker compose exec gitlab gitlab-rake gitlab:background_migrations:list).
       See https://docs.gitlab.com/update/background_migrations/"
      (( pending == 0 )) && return 0
      echo "    background migrations still running: $pending (checking again in 60s)"
    else
      (( ++errors < 10 )) || die "cannot read background migration status (gitlab-psql failed 10 times); not upgrading blind"
      echo "    could not read migration status yet, retrying in 60s"
    fi
    sleep 60
  done
  die "background migrations still unfinished after 6h; re-run later"
}

# --- Data fingerprint ---------------------------------------------------------
# Row counts recorded at backup time and compared after restore / upgrade, so a
# silently partial restore is caught instead of discovered weeks later.

FINGERPRINT_FIELDS="projects users namespaces issues merge_requests notes"

data_fingerprint() {
  local out
  out=$(gl gitlab-psql -At -F ' ' -c "SELECT
      (SELECT count(*) FROM projects),
      (SELECT count(*) FROM users),
      (SELECT count(*) FROM namespaces),
      (SELECT count(*) FROM issues),
      (SELECT count(*) FROM merge_requests),
      (SELECT count(*) FROM notes);" | tail -n1) || return 1
  [[ "$out" =~ ^[0-9]+(\ [0-9]+){5}$ ]] || return 1
  echo "$out"
}

# compare_fingerprint <before> <after> <exact|nodecrease>; prints differences, 1 if any
compare_fingerprint() {
  local -a names a b
  read -ra names <<<"$FINGERPRINT_FIELDS"; read -ra a <<<"$1"; read -ra b <<<"$2"
  local i rc=0 x y
  for i in "${!names[@]}"; do
    x=${a[i]:-}; y=${b[i]:-}
    [[ "$x" =~ ^[0-9]+$ && "$y" =~ ^[0-9]+$ ]] || { printf '    %-15s unreadable (before=%s after=%s)\n' "${names[i]}" "$x" "$y"; rc=1; continue; }
    if [[ $3 == exact && $x != "$y" ]] || (( y < x )); then
      printf '    %-15s before=%s after=%s\n' "${names[i]}" "$x" "$y"; rc=1
    fi
  done
  return $rc
}

# --- Disk space ---------------------------------------------------------------

avail_kb() { df -Pk "$1" | awk 'NR==2 {print $4}'; }
fs_of()    { df -P "$1" | awk 'NR==2 {print $1}'; }
size_kb()  { du -sxk "$@" 2>/dev/null | awk '{s+=$1} END {print s+0}'; }
human()    { awk -v k="$1" 'BEGIN { printf "%.1f GiB", k/1048576 }'; }

need_space() {  # need_space <path> <kb> <what>
  local have; have=$(avail_kb "$1")
  (( have >= $2 )) || die "not enough free disk on $(df -P "$1" | awk 'NR==2 {print $6}') for $3:
       need ~$(human "$2"), have $(human "$have"). Free space (or set BACKUP_DIR to a bigger disk) and retry."
}

# --- Backup bundles -----------------------------------------------------------
# A bundle is a self-contained, checksummed directory with everything needed to
# rebuild this instance on the same or another server:
#   <id>_gitlab_backup.tar   gitlab-backup archive: DB, repositories, uploads, LFS,
#                            CI artifacts, packages, registry, pages, terraform state
#   config.tar.gz            /etc/gitlab: gitlab-secrets.json (NOT in the archive —
#                            without it CI variables, 2FA, tokens are unrecoverable),
#                            gitlab.rb, SSH host keys
#   stack/                   .env, docker-compose.yml, Caddyfile
#   MANIFEST, SHA256SUMS
# A directory ending in .partial is unfinished and never valid.

create_bundle() {  # create_bundle <label> [quiesced yes|no] -> sets BUNDLE
  local label=$1 quiesced=${2:-no} ver stamp id dest part archive data_kb fp p
  ver=$(data_version); [[ -n "$ver" ]] || die "no GitLab data found in $GITLAB_HOME/data"
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  id="${label}_${stamp}_${ver}"
  dest="$BACKUP_DIR/gitlab-${stamp}-${ver}-${label}"
  part="$dest.partial"

  # gitlab-backup writes the archive into data/backups (plus STRATEGY=copy temp
  # copies); budget 1.5x the data size + 2 GiB there, and the bundle size again
  # if BACKUP_DIR is on another filesystem.
  data_kb=$(size_kb --exclude="$GITLAB_HOME/data/backups" "$GITLAB_HOME/data")
  need_space "$GITLAB_HOME/data" $(( data_kb * 3 / 2 + 2097152 )) "creating the backup archive"
  mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
  if [[ "$(fs_of "$BACKUP_DIR")" != "$(fs_of "$GITLAB_HOME/data")" ]]; then
    need_space "$BACKUP_DIR" $(( data_kb + 1048576 )) "storing the backup bundle"
  fi
  for p in "$BACKUP_DIR"/*.partial; do [[ -e "$p" ]] && warn "stale unfinished bundle (safe to delete): $p"; done
  mkdir "$part"; chmod 700 "$part"

  fp=$(data_fingerprint) || { rm -rf "$part"; die "could not read the data fingerprint from the database"; }

  log "Creating gitlab-backup archive ($id)"
  if ! gl gitlab-backup create STRATEGY=copy BACKUP="$id"; then
    rm -rf "$part"; gl rm -f "/var/opt/gitlab/backups/${id}_gitlab_backup.tar" >/dev/null 2>&1 || true
    die "gitlab-backup create failed; nothing was changed"
  fi
  archive="$GITLAB_HOME/data/backups/${id}_gitlab_backup.tar"

  # Any failure from here on: drop the half-made bundle and the bad archive.
  on_exit bundle "rm -rf -- '$part' '$archive'"
  log "Verifying archive"
  [[ -s "$archive" ]] || die "backup archive missing: $archive"
  local listing; listing=$(tar -tf "$archive") || die "backup archive is unreadable/corrupt: $archive"
  grep -Eq '(^|/)db/database\.sql\.gz$' <<<"$listing" || die "backup archive contains no database dump: $archive"
  grep -Eq '(^|/)repositories/' <<<"$listing" || warn "backup archive lists no repositories (expected only if there are no projects)"
  tar -xOf "$archive" --wildcards '*backup_information.yml' > "$part/backup_information.yml" 2>/dev/null ||
    die "backup_information.yml missing from archive"
  grep -Eq "^:gitlab_version: *['\"]?$ver" "$part/backup_information.yml" ||
    die "archive records a different GitLab version than the data ($ver)"
  # One pass over the archive: gzip -t every compressed member, so a truncated
  # archive is caught now, not on restore day.
  tar -xf "$archive" --wildcards '*.gz' --to-command='gzip -t' ||
    die "a compressed member of the archive is corrupt: $archive"

  mv "$archive" "$part/"
  tar -C "$GITLAB_HOME" -czf "$part/config.tar.gz" config
  tar -tzf "$part/config.tar.gz" | grep -qx 'config/gitlab-secrets.json' ||
    die "gitlab-secrets.json not found in $GITLAB_HOME/config — a restore would be unusable"
  mkdir "$part/stack"; cp -p .env docker-compose.yml Caddyfile "$part/stack/"

  cat > "$part/MANIFEST" <<EOF
gitlab_version=$ver
backup_id=$id
label=$label
created_utc=$stamp
source_host=$(hostname -f 2>/dev/null || hostname)
domain=${GITLAB_DOMAIN:-}
quiesced=$quiesced
fingerprint=$fp
fingerprint_fields=$FINGERPRINT_FIELDS
EOF
  ( cd "$part" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS )
  chmod -R go-rwx "$part"
  mv "$part" "$dest"
  sync -f "$dest" 2>/dev/null || sync
  off_exit bundle
  BUNDLE=$dest
  log "Backup bundle complete: $dest ($(du -sh "$dest" | cut -f1))"
}

verify_bundle() {  # verify_bundle <dir>
  local b=$1
  [[ -d "$b" && "$b" != *.partial ]] || die "$b is not a complete bundle directory"
  [[ -f "$b/MANIFEST" && -f "$b/SHA256SUMS" && -f "$b/config.tar.gz" ]] || die "$b is missing MANIFEST, SHA256SUMS or config.tar.gz"
  log "Verifying bundle checksums (reads the whole bundle)"
  ( cd "$b" && sha256sum --quiet --strict -c SHA256SUMS ) || die "checksum mismatch in $b — bundle is corrupt or incompletely copied"
  [[ -f "$b/$(manifest_get "$b" backup_id)_gitlab_backup.tar" ]] || die "archive named in MANIFEST is missing from $b"
}

manifest_get() { grep -E "^$2=" "$1/MANIFEST" | head -n1 | cut -d= -f2-; }

# Keep the newest $BACKUP_KEEP automatic bundles per label. Bundles labelled
# manual / migration / pre-restore are never deleted automatically.
prune_bundles() {
  local label old
  for label in pre-upgrade scheduled; do
    while read -r old; do
      [[ -n "$old" && -f "$old/MANIFEST" && "$old" != "${BUNDLE:-}" ]] || continue
      echo "    pruning old bundle $old"
      rm -rf -- "$old"
    done < <(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -name "gitlab-*-$label" 2>/dev/null | sort -r | tail -n +$((BACKUP_KEEP + 1)))
  done
}

# --- Caddy certificates ---------------------------------------------------------
# Earlier versions of this stack kept Caddy's certificates in named volumes.
# Copy them into the bind mounts before Caddy is recreated on the new mounts,
# so certificates and the ACME account survive (no re-issue, no rate limits).
compose_project() {
  local p; p=$(docker compose config --format json 2>/dev/null | jq -r '.name // empty' 2>/dev/null || true)
  echo "${p:-gitlab}"
}

migrate_caddy_volumes() {
  local vol sub project; project=$(compose_project)
  for sub in data config; do
    vol="${project}_caddy_${sub}"
    docker volume inspect "$vol" >/dev/null 2>&1 || continue
    if [[ -n "$(ls -A "$GITLAB_HOME/caddy/$sub" 2>/dev/null)" ]]; then
      continue   # already migrated
    fi
    log "Migrating Caddy $sub from volume $vol to $GITLAB_HOME/caddy/$sub"
    mkdir -p "$GITLAB_HOME/caddy/$sub"
    docker run --rm -v "$vol":/from:ro -v "$GITLAB_HOME/caddy/$sub":/to alpine:3 cp -a /from/. /to/ ||
      die "could not copy volume $vol; Caddy left as is"
    echo "    old volume $vol kept; remove it later with: docker volume rm $vol"
  done
}

recreate_caddy() {
  mkdir -p "$GITLAB_HOME/caddy/data" "$GITLAB_HOME/caddy/config"
  migrate_caddy_volumes
  docker compose up -d --no-deps caddy
}
