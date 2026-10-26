#!/usr/bin/env bash
# Restore a backup bundle created by backup.sh / upgrade.sh, on this or a new server.
#
#   sudo ./restore.sh <bundle-dir>            Restore. Refuses if this server already
#                                             holds GitLab data, unless --force.
#   --force                                   Replace existing data. The current data and
#                                             config are MOVED aside (never deleted) to
#                                             $GITLAB_HOME/*.pre-restore-<time>.
#   --yes                                     Don't ask for confirmation.
#
# Steps: verify checksums -> move old data aside -> restore /etc/gitlab (secrets)
# -> start the exact GitLab version of the bundle on empty data -> gitlab-backup
# restore -> restart -> verify health, secrets, gitlab:check and that row counts
# equal the ones recorded at backup time.
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"
. ./lib.sh

BUNDLE_ARG="" FORCE=0 ASSUME_YES=0
for a in "$@"; do
  case "$a" in
    --force)  FORCE=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    -*) echo "unknown option: $a" >&2; exit 2 ;;
    *) [[ -z "$BUNDLE_ARG" ]] || die "only one bundle can be given"; BUNDLE_ARG=$a ;;
  esac
done
[[ -n "$BUNDLE_ARG" ]] || die "usage: sudo ./restore.sh <bundle-dir> [--force] [--yes]"

require_root
load_env
take_lock
check_mounts

B=$(readlink -f "$BUNDLE_ARG")
verify_bundle "$B"
ver=$(manifest_get "$B" gitlab_version)
id=$(manifest_get "$B" backup_id)
expected_fp=$(manifest_get "$B" fingerprint)
# Online backups record counts just before the dump; writes during the dump can
# only add rows. A quiesced (--migrate) backup must match exactly.
fp_mode=nodecrease; [[ "$(manifest_get "$B" quiesced)" == yes ]] && fp_mode=exact
[[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && -n "$id" ]] || die "MANIFEST in $B is incomplete"
archive="$B/${id}_gitlab_backup.tar"
case "$B/" in "$GITLAB_HOME/data/"*|"$GITLAB_HOME/config/"*) die "move the bundle out of $GITLAB_HOME/data or config first (that directory is replaced during restore)";; esac

bundle_domain=$(manifest_get "$B" domain)
[[ -z "$bundle_domain" || "$bundle_domain" == "$GITLAB_DOMAIN" ]] ||
  warn "bundle was taken from $bundle_domain, this .env serves $GITLAB_DOMAIN (fine for a rename; clone URLs will change)"

# --- What is on this server now? ------------------------------------------------

existing=0
[[ -n "$(ls -A "$GITLAB_HOME/data" 2>/dev/null)" || -n "$(ls -A "$GITLAB_HOME/config" 2>/dev/null)" ]] && existing=1
if (( existing && ! FORCE )); then
  die "$GITLAB_HOME already contains GitLab data/config (GitLab $(data_version || true)).
       Re-run with --force to replace it; the current data is moved aside, not deleted."
fi

archive_kb=$(size_kb "$archive")
# gitlab-backup needs ~3x the archive while unpacking, plus the copy we place in backups/.
need_space "$GITLAB_HOME" $(( archive_kb * 4 + 2097152 )) "restoring this bundle"

cat <<EOF

About to restore:
  bundle:   $B
  version:  GitLab $ver   (created $(manifest_get "$B" created_utc) on $(manifest_get "$B" source_host))
  into:     $GITLAB_HOME
$( (( existing )) && echo "  existing data/config will be MOVED to $GITLAB_HOME/{data,config}.pre-restore-<time>" )
EOF
if (( ! ASSUME_YES )); then confirm "Proceed?" || exit 1; fi

# --- Prepare an empty instance of the bundle's exact version --------------------

image="gitlab/gitlab-ce:$ver-ce.0"
log "Pulling $image (restore needs exactly the version the backup was made with)"
docker pull -q "$image" >/dev/null || die "could not pull $image"

if [[ -n "$(gitlab_cid)" ]]; then
  log "Stopping the current GitLab container"
  docker compose stop gitlab
fi

stamp=$(date -u +%Y%m%dT%H%M%SZ)
if (( existing )); then
  for d in data config; do
    if [[ -e "$GITLAB_HOME/$d" ]]; then
      mv "$GITLAB_HOME/$d" "$GITLAB_HOME/$d.pre-restore-$stamp"
      echo "    kept old $d at $GITLAB_HOME/$d.pre-restore-$stamp"
    fi
  done
fi
mkdir -p "$GITLAB_HOME"/{data,logs,caddy/data,caddy/config}

log "Restoring /etc/gitlab (gitlab-secrets.json, SSH host keys, gitlab.rb)"
tar -C "$GITLAB_HOME" -xzf "$B/config.tar.gz"
[[ -f "$GITLAB_HOME/config/gitlab-secrets.json" ]] || die "config.tar.gz did not contain gitlab-secrets.json"

set_env_version "$ver"
rm -f "$MARKER"

log "Starting an empty GitLab $ver (first boot takes a few minutes)"
docker compose up -d --no-deps --force-recreate gitlab
rc=0; wait_healthy 30 || rc=$?
(( rc == 0 )) || { explain_unhealthy "$rc"; die "fresh GitLab $ver did not start; nothing restored yet"; }
[[ "$(data_version)" == "$ver" ]] || die "started GitLab reports data version $(data_version), expected $ver"

# --- Restore --------------------------------------------------------------------

log "Copying archive into the container's backup directory"
mkdir -p "$GITLAB_HOME/data/backups"
cp "$archive" "$GITLAB_HOME/data/backups/"
( cd "$GITLAB_HOME/data/backups" && grep " \./${id}_gitlab_backup.tar$" "$B/SHA256SUMS" | sed 's# \./# #' | sha256sum --quiet -c - ) ||
  die "archive copy does not match its checksum (disk problem?)"
gl chown git:git "/var/opt/gitlab/backups/${id}_gitlab_backup.tar"

log "Stopping web and background jobs"
gl gitlab-ctl stop puma
gl gitlab-ctl stop sidekiq

log "Running gitlab-backup restore (this can take a long time)"
if ! docker compose exec -T -e GITLAB_ASSUME_YES=1 gitlab gitlab-backup restore BACKUP="$id" force=yes; then
  die "gitlab-backup restore FAILED. The instance is in an unknown state; do not use it.
       Old data (if any) is untouched in $GITLAB_HOME/*.pre-restore-$stamp.
       Fix the cause (docker compose logs gitlab) and re-run: sudo ./restore.sh $B --force"
fi
gl rm -f "/var/opt/gitlab/backups/${id}_gitlab_backup.tar" || true

log "Restarting GitLab"
docker compose restart gitlab
rc=0; wait_healthy 30 || rc=$?
(( rc == 0 )) || { explain_unhealthy "$rc"; die "GitLab did not come back after the restore"; }

# --- Verify ---------------------------------------------------------------------

log "Verifying the restore"
ok=1
if gl gitlab-rake gitlab:doctor:secrets >/tmp/gitlab-doctor-secrets.log 2>&1 &&
   ! grep -qE 'failures: *[1-9]' /tmp/gitlab-doctor-secrets.log; then
  echo "    secrets:      all encrypted columns decrypt with the restored gitlab-secrets.json"
else
  warn "gitlab:doctor:secrets found data that cannot be decrypted (see /tmp/gitlab-doctor-secrets.log)"; ok=0
fi

actual_fp=$(data_fingerprint) || { warn "could not read row counts"; actual_fp=""; ok=0; }
if [[ -n "$actual_fp" ]]; then
  if compare_fingerprint "$expected_fp" "$actual_fp" "$fp_mode"; then
    echo "    row counts:   match backup time ($fp_mode; $FINGERPRINT_FIELDS: $actual_fp)"
  else
    warn "row counts differ from the backup (see above)"; ok=0
  fi
fi

if gl gitlab-rake gitlab:check SANITIZE=true >/tmp/gitlab-check.log 2>&1; then
  echo "    gitlab:check: passed"
else
  warn "gitlab:check reported issues (see /tmp/gitlab-check.log)"
fi
for t in artifacts lfs uploads; do
  gl gitlab-rake "gitlab:$t:check" >"/tmp/gitlab-$t-check.log" 2>&1 || warn "gitlab:$t:check reported issues (see /tmp/gitlab-$t-check.log)"
done

recreate_caddy

if (( ok )); then
  log "Restore of GitLab $ver complete and verified: https://$GITLAB_DOMAIN"
else
  die "restore finished but verification failed (see warnings above). Do not put this instance into service yet."
fi
(( existing )) && echo "    Old data kept in $GITLAB_HOME/*.pre-restore-$stamp — delete it once you are satisfied."
echo "    Note: CI runners, webhooks and integrations pointing at the old host need DNS to move (or re-registration if the URL changed)."
