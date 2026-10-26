#!/usr/bin/env bash
# Setup of GitLab CE + Caddy on Ubuntu 22.04 / 24.04.
# Run from this directory as root:
#   sudo ./install.sh                     fresh install, or re-run safely on an existing one
#   sudo ./install.sh --redeploy          recreate containers (same pinned version, data kept)
#   sudo ./install.sh --restore <bundle>  new server: install, then restore a backup bundle
#
# Safe to re-run: packages, Docker Engine, Compose and an already running GitLab
# stack are detected and left alone. It never starts GitLab on data from another
# version, on a changed GITLAB_HOME, or after a failed upgrade.
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"
. ./lib.sh

REDEPLOY=0 RESTORE_BUNDLE=""
while (( $# )); do
  case "$1" in
    --redeploy) REDEPLOY=1 ;;
    --restore)  [[ -n "${2:-}" ]] || die "--restore needs a bundle directory"; RESTORE_BUNDLE=$(readlink -f "$2"); shift ;;
    -h|--help)  sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

require_root
. /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || die "this script targets Ubuntu (found: ${ID:-unknown})"

if [[ ! -f .env ]]; then
  if [[ -n "$RESTORE_BUNDLE" && -f "$RESTORE_BUNDLE/stack/.env" ]]; then
    cp "$RESTORE_BUNDLE/stack/.env" .env; chmod 600 .env
    echo "Copied .env from the bundle. Review it (GITLAB_DOMAIN, PUBLIC_IP, GITLAB_HOME), then re-run the same command."
    exit 1
  fi
  cp .env.example .env; chmod 600 .env
  die "created .env from template — edit it, then re-run"
fi
load_env
[[ "$GITLAB_DOMAIN" != "sub.domain.com" ]] || die "set GITLAB_DOMAIN in .env"
[[ "$ACME_EMAIL" != "admin@domain.com" ]] || die "set ACME_EMAIL in .env"
[[ -z "$RESTORE_BUNDLE" || -d "$RESTORE_BUNDLE" ]] || die "bundle not found: $RESTORE_BUNDLE"
take_lock

# --- Prerequisites (install only what is missing) ---------------------------

pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"; }

apt_updated=0
apt_install() {
  (( apt_updated )) || { apt-get update -qq; apt_updated=1; }
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >/dev/null
}

log "Checking prerequisites"
missing=()
for p in ca-certificates curl jq dnsutils iproute2; do
  if pkg_installed "$p"; then skip "$p already installed"; else missing+=("$p"); fi
done
if (( ${#missing[@]} )); then
  echo "    installing: ${missing[*]}"
  apt_install "${missing[@]}"
fi

add_docker_repo() {
  if [[ -f /etc/apt/sources.list.d/docker.list || -f /etc/apt/sources.list.d/docker.sources ]]; then
    return
  fi
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt_updated=0
}

# --- Docker Engine ------------------------------------------------------------
# Any existing install (docker-ce, Ubuntu's docker.io, snap) is kept as is; we
# never replace or upgrade it.

log "Checking Docker Engine"
if command -v docker >/dev/null; then
  skip "$(docker --version)"
else
  echo "    installing Docker Engine from download.docker.com"
  add_docker_repo
  apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

if docker info >/dev/null 2>&1; then
  skip "Docker daemon already running"
  # Make sure it comes back after reboot (no-op when already enabled / not systemd-managed).
  systemctl is-enabled --quiet docker 2>/dev/null || systemctl enable docker >/dev/null 2>&1 || true
elif systemctl cat docker.service >/dev/null 2>&1; then
  echo "    starting docker.service"
  systemctl enable --now docker
elif command -v snap >/dev/null && snap list docker >/dev/null 2>&1; then
  echo "    starting snap docker"
  snap start --enable docker
fi
docker info >/dev/null 2>&1 || die "Docker is installed but the daemon is not reachable (check: systemctl status docker)"

# --- Docker Compose v2 --------------------------------------------------------
# `docker compose` (plugin) is required; the legacy standalone docker-compose v1 is not.

log "Checking Docker Compose"
if docker compose version >/dev/null 2>&1; then
  skip "Docker Compose $(docker compose version --short)"
else
  echo "    installing Docker Compose v2 plugin"
  if pkg_installed docker-ce; then
    add_docker_repo
    apt_install docker-compose-plugin
  elif pkg_installed docker.io; then
    apt_install docker-compose-v2      # Ubuntu's plugin package matching docker.io
  else
    die "Docker was not installed via apt; install the Compose v2 plugin manually: https://docs.docker.com/compose/install/linux/"
  fi
  docker compose version >/dev/null 2>&1 || die "docker compose still unavailable after install"
fi

# --- DNS sanity check -----------------------------------------------------------
# The domain's A record(s) must point at this server, or Let's Encrypt fails.
# "This server" means any of:
#   - PUBLIC_IP from .env (if set, it replaces auto-detection; space/comma list allowed)
#   - an IPv4 address on a local interface (covers multiple IPs, floating IPs bound to the NIC)
#   - the outbound IP seen by ipify, fetched without any HTTP proxy
# Behind 1:1 NAT (AWS elastic IP, GCP external IP) none of the auto-detected
# addresses may equal the public one; set PUBLIC_IP in that case.

ipv4_only() { grep -Eo '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || true; }

check_dns() {
  log "Checking DNS for $GITLAB_DOMAIN"

  local dns_ips expected source
  # +short may print CNAME targets first; keep only the addresses.
  dns_ips=$(dig +short A "$GITLAB_DOMAIN" | ipv4_only | sort -u)

  if [[ -n "${PUBLIC_IP:-}" ]]; then
    expected=$(tr ', ' '\n\n' <<<"$PUBLIC_IP" | ipv4_only | sort -u)
    [[ -n "$expected" ]] || die "PUBLIC_IP='$PUBLIC_IP' in .env is not a valid IPv4 address"
    source="PUBLIC_IP (.env)"
  else
    local local_ips outbound_ip
    local_ips=$(ip -4 -o addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]}' | sort -u)
    outbound_ip=$(curl -fsS4 --noproxy '*' --max-time 10 https://api.ipify.org 2>/dev/null | ipv4_only)
    expected=$(printf '%s\n%s\n' "$local_ips" "$outbound_ip" | sed '/^$/d' | sort -u)
    source="auto-detected"
  fi

  if [[ -z "$dns_ips" ]]; then
    die "$GITLAB_DOMAIN has no A record — create one pointing at this server's public IP first
       ($source addresses: $(echo $expected))"
  fi

  local match
  match=$(comm -12 <(echo "$dns_ips") <(echo "$expected"))
  if [[ -n "$match" ]]; then
    skip "$GITLAB_DOMAIN -> $(echo $match) matches this server ($source)"
    return
  fi

  echo "WARNING: $GITLAB_DOMAIN does not resolve to any address of this server."
  echo "    DNS A record(s):        $(echo $dns_ips)"
  if [[ -n "${PUBLIC_IP:-}" ]]; then
    echo "    PUBLIC_IP (.env):       $(echo $expected)"
  else
    echo "    Local interface IPv4:   $(echo ${local_ips:-none})"
    echo "    Outbound IP (ipify):    ${outbound_ip:-unavailable}"
    echo "    If the server is behind NAT/an elastic IP, set PUBLIC_IP=<dns ip> in .env."
  fi
  echo "    Cloudflare-proxied records (orange cloud) must be set to DNS only for Let's Encrypt HTTP-01."
  read -rp "Continue anyway? [y/N] " ans || ans=""
  [[ "$ans" =~ ^[Yy]$ ]] || exit 1
}

# --- Existing deployments -----------------------------------------------------

project=$(compose_project)

stack_running=0
if [[ -n "$(docker compose ps -q --status running gitlab 2>/dev/null)" ]]; then
  stack_running=1
fi

# A GitLab container that is NOT part of this compose project would clash on
# ports and data. Don't touch it — stop and let the operator decide.
foreign=$(docker ps --format '{{.Names}}|{{.Image}}|{{.Label "com.docker.compose.project"}}' 2>/dev/null |
  awk -F'|' -v p="$project" '$2 ~ /^(docker\.io\/)?gitlab\/gitlab-(ce|ee)(:|@|$)/ && $3 != p {print $1}' || true)
if [[ -n "$foreign" ]]; then
  die "another GitLab container is already running outside this stack: $foreign
       Leaving it untouched. Stop/remove it first, or manage that deployment instead."
fi

prepare_host() {
  check_dns
  # Fail early if something other than this stack already holds the needed ports.
  if [[ -z "$(docker compose ps -q 2>/dev/null)" ]]; then
    busy=$(ss -Hltnp "( sport = :80 or sport = :443 or sport = :${GITLAB_SSH_PORT} )" 2>/dev/null || true)
    [[ -z "$busy" ]] || die "ports 80/443/${GITLAB_SSH_PORT} are already in use:
$busy
       Stop that service (or put it behind Caddy) first."
  fi
  if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
    log "Opening firewall ports (ufw)"
    ufw allow 80/tcp; ufw allow 443/tcp; ufw allow 443/udp; ufw allow "${GITLAB_SSH_PORT}/tcp"
  fi
  mkdir -p "$GITLAB_HOME"/{config,logs,data,caddy/data,caddy/config}
  chmod 755 "$GITLAB_HOME"
}

if [[ -n "$RESTORE_BUNDLE" ]]; then
  # --- New server from a backup bundle ------------------------------------------
  prepare_host
  log "Restoring bundle $RESTORE_BUNDLE"
  ./restore.sh "$RESTORE_BUNDLE" $( [[ -n "$(ls -A "$GITLAB_HOME/data" 2>/dev/null)" ]] && echo --force )
  load_env      # restore.sh pinned GITLAB_VERSION to the bundle's version
elif (( stack_running && ! REDEPLOY )); then
  preflight
  log "GitLab stack '$project' is already running; leaving containers untouched"
  docker compose ps --format 'table {{.Service}}\t{{.Image}}\t{{.Status}}'
  echo "    Use ./upgrade.sh to change versions, or ./install.sh --redeploy to recreate."
else
  # --- Fresh install, or start/recreate an existing one on the SAME version -----
  preflight
  dv=$(data_version)
  if [[ -n "$dv" ]]; then
    log "Existing GitLab $dv data found in $GITLAB_HOME/data; it will be reused as-is"
  elif [[ -n "$(ls -A "$GITLAB_HOME/data" 2>/dev/null)" ]]; then
    die "$GITLAB_HOME/data is not empty but has no GitLab VERSION file. Refusing to start on unknown data."
  fi
  prepare_host


  migrate_caddy_volumes
  log "Starting GitLab $GITLAB_VERSION and Caddy"
  docker compose pull -q
  docker compose up -d
fi

log "Waiting for GitLab to become healthy (first boot takes 3-10 minutes)"
rc=0; wait_healthy 30 || rc=$?
(( rc == 0 )) || { explain_unhealthy "$rc"; die "GitLab is not healthy — check: docker compose logs gitlab"; }
recreate_caddy

# --- Timers (rewritten each run, so path changes apply) -------------------------

install_dir=$(pwd)
write_timer() {  # write_timer <name> <description> <OnCalendar> <command>
  cat > "/etc/systemd/system/$1.service" <<UNIT
[Unit]
Description=$2
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
WorkingDirectory=$install_dir
ExecStart=$4
TimeoutStartSec=6h
UNIT
  cat > "/etc/systemd/system/$1.timer" <<UNIT
[Unit]
Description=$2

[Timer]
OnCalendar=$3
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
UNIT
}

log "Installing timers: daily backup, weekly patch-release upgrade"
write_timer gitlab-backup "Daily GitLab backup bundle" "*-*-* 02:15:00" "$install_dir/backup.sh --scheduled"
write_timer gitlab-patch-upgrade "Apply latest GitLab CE patch release (same minor version)" "Sun *-*-* 03:30:00" "$install_dir/upgrade.sh --patch-only --yes"
systemctl daemon-reload
systemctl enable --now gitlab-backup.timer gitlab-patch-upgrade.timer

cat <<EOF

GitLab is up:  https://$GITLAB_DOMAIN
Git over SSH:  ssh://git@$GITLAB_DOMAIN:$GITLAB_SSH_PORT/<group>/<project>.git
Backups:       $BACKUP_DIR  (daily; copy them OFF this server)
EOF
if pw=$(docker compose exec -T gitlab grep 'Password:' /etc/gitlab/initial_root_password 2>/dev/null); then
  cat <<EOF

Log in as 'root'. The initial password (auto-deleted after 24h) is:
  $pw
Change it right away, and turn off public sign-up if not needed:
  Admin > Settings > General > Sign-up restrictions.
EOF
fi
