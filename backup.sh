#!/usr/bin/env bash
# Create a verified, self-contained backup bundle of this GitLab instance.
#
#   sudo ./backup.sh                  Online backup (GitLab keeps serving). Label: manual
#   sudo ./backup.sh --scheduled      Same, label "scheduled" (pruned to BACKUP_KEEP; used by the daily timer)
#   sudo ./backup.sh --migrate        For moving to a new server: stops web + background jobs
#                                     so nothing changes during the dump, then KEEPS them stopped
#                                     (users get 502) so no write is lost after the snapshot.
#                                     Restart with:  docker compose restart gitlab
#   --keep-running                    With --migrate: start web + jobs again after the dump.
#
# Bundles go to $BACKUP_DIR (default $GITLAB_HOME/bundles). Each contains the
# gitlab-backup archive, /etc/gitlab (incl. gitlab-secrets.json), the stack files,
# a MANIFEST and SHA256SUMS. Copy them OFF this server; see README.
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"
. ./lib.sh

LABEL=manual MIGRATE=0 KEEP_RUNNING=0
for a in "$@"; do
  case "$a" in
    --scheduled)    LABEL=scheduled ;;
    --migrate)      MIGRATE=1; LABEL=migration ;;
    --keep-running) KEEP_RUNNING=1 ;;
    -h|--help)      sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

require_root
load_env
take_lock
preflight

rc=0; wait_healthy 15 || rc=$?
(( rc == 0 )) || { explain_unhealthy "$rc"; die "GitLab is not healthy; not backing up a broken instance"; }

restart_services() { gl gitlab-ctl start puma >/dev/null 2>&1 || true; gl gitlab-ctl start sidekiq >/dev/null 2>&1 || true; }

quiesced=no
if (( MIGRATE )); then
  log "Stopping web (puma) and background jobs (sidekiq) for a consistent snapshot"
  # If anything below fails, bring the instance back instead of leaving it down.
  on_exit services 'warn "backup failed; starting web + jobs again"; restart_services'
  gl gitlab-ctl stop puma
  gl gitlab-ctl stop sidekiq
  quiesced=yes
fi

BUNDLE=""
create_bundle "$LABEL" "$quiesced"
off_exit services

if (( MIGRATE )); then
  if (( KEEP_RUNNING )); then
    restart_services
    warn "GitLab is serving again: changes made from now on are NOT in this bundle."
  else
    cat <<EOF

GitLab web and background jobs are STOPPED, so no changes can happen after this snapshot.
Next steps for the move:
  1. Copy the bundle to the new server (resumable, checksummed):
       rsync -aH --info=progress2 '$BUNDLE' root@NEW_SERVER:/root/
  2. On the new server, in a copy of this directory:
       sudo ./install.sh --restore /root/$(basename "$BUNDLE")
  3. Point DNS for ${GITLAB_DOMAIN} at the new server.
To abort the move and resume service here:  docker compose restart gitlab
EOF
  fi
fi

[[ "$LABEL" == scheduled ]] && prune_bundles
log "Bundle: $BUNDLE"
echo "    Copy it off this server, e.g.: rsync -aH '$BUNDLE' backup-host:/backups/gitlab/"
