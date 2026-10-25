#!/usr/bin/env bash
# One-time setup of GitLab CE + Caddy on Ubuntu 22.04 / 24.04.
# Run from this directory as root:  sudo ./install.sh
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root (sudo ./install.sh)"
. /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || die "this script targets Ubuntu (found: ${ID:-unknown})"

[[ -f .env ]] || { cp .env.example .env; die "created .env from template — edit it, then re-run"; }
set -a; . ./.env; set +a
[[ "$GITLAB_DOMAIN" != "sub.domain.com" ]] || die "set GITLAB_DOMAIN in .env"
[[ "$ACME_EMAIL" != "admin@domain.com" ]] || die "set ACME_EMAIL in .env"

log "Installing prerequisites"
apt-get update -qq
apt-get install -y -qq ca-certificates curl jq dnsutils >/dev/null

if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
  log "Installing Docker Engine + Compose plugin from download.docker.com"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
fi
systemctl enable --now docker

log "Checking DNS for $GITLAB_DOMAIN"
public_ip=$(curl -fsS4 https://api.ipify.org || true)
dns_ip=$(dig +short A "$GITLAB_DOMAIN" | tail -n1)
if [[ -z "$dns_ip" ]]; then
  die "$GITLAB_DOMAIN has no A record — create it (pointing at ${public_ip:-this server}) first"
elif [[ -n "$public_ip" && "$dns_ip" != "$public_ip" ]]; then
  echo "WARNING: $GITLAB_DOMAIN resolves to $dns_ip, but this server's public IP is $public_ip."
  echo "         Let's Encrypt will fail unless that is a proxy/NAT you expect."
  read -rp "Continue anyway? [y/N] " ans; [[ "$ans" =~ ^[Yy]$ ]] || exit 1
fi

if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  log "Opening firewall ports (ufw)"
  ufw allow 80/tcp; ufw allow 443/tcp; ufw allow 443/udp; ufw allow "${GITLAB_SSH_PORT}/tcp"
fi

log "Creating data directories under $GITLAB_HOME"
mkdir -p "$GITLAB_HOME"/{config,logs,data}

log "Starting GitLab $GITLAB_VERSION and Caddy"
docker compose pull
docker compose up -d

log "Waiting for GitLab to become healthy (first boot takes 3-10 minutes)"
for _ in $(seq 1 120); do
  status=$(docker inspect -f '{{.State.Health.Status}}' "$(docker compose ps -q gitlab)" 2>/dev/null || echo starting)
  [[ "$status" == "healthy" ]] && break
  sleep 10
done
[[ "$status" == "healthy" ]] || die "GitLab not healthy after 20 min — check: docker compose logs gitlab"

log "Installing weekly automatic patch-release updates (systemd timer)"
install_dir=$(pwd)
cat > /etc/systemd/system/gitlab-patch-upgrade.service <<EOF
[Unit]
Description=Apply latest GitLab CE patch release (same minor version)
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
WorkingDirectory=$install_dir
ExecStart=$install_dir/upgrade.sh --patch-only --yes
TimeoutStartSec=3h
EOF
cat > /etc/systemd/system/gitlab-patch-upgrade.timer <<'EOF'
[Unit]
Description=Weekly GitLab CE patch upgrade

[Timer]
OnCalendar=Sun *-*-* 03:30:00
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now gitlab-patch-upgrade.timer

cat <<EOF

GitLab is up:  https://$GITLAB_DOMAIN
Git over SSH:  ssh://git@$GITLAB_DOMAIN:$GITLAB_SSH_PORT/<group>/<project>.git

Log in as 'root'. The initial password (auto-deleted after 24h) is:
  $(docker compose exec -T gitlab grep 'Password:' /etc/gitlab/initial_root_password 2>/dev/null || echo "(already removed)")

Change it right away, and turn off public sign-up if not needed:
  Admin > Settings > General > Sign-up restrictions.
EOF
