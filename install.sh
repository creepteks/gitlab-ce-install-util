#!/usr/bin/env bash
# One-time setup of GitLab CE + Caddy on Ubuntu 22.04 / 24.04.
# Run from this directory as root:  sudo ./install.sh [--redeploy]
#
# Safe to re-run: packages, Docker Engine, Compose and an already running
# GitLab stack are detected and left alone; only missing pieces are installed.
#   --redeploy   pull images and recreate the containers even if the stack is running
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

REDEPLOY=0
for a in "$@"; do
  case "$a" in
    --redeploy) REDEPLOY=1 ;;
    -h|--help)  sed -n '2,7p' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

log()  { printf '\n==> %s\n' "$*"; }
skip() { printf '    [skip] %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root (sudo ./install.sh)"
. /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || die "this script targets Ubuntu (found: ${ID:-unknown})"

[[ -f .env ]] || { cp .env.example .env; die "created .env from template — edit it, then re-run"; }
set -a; . ./.env; set +a
[[ "$GITLAB_DOMAIN" != "sub.domain.com" ]] || die "set GITLAB_DOMAIN in .env"
[[ "$ACME_EMAIL" != "admin@domain.com" ]] || die "set ACME_EMAIL in .env"

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

project=$(docker compose config --format json 2>/dev/null | jq -r '.name // empty')
project=${project:-gitlab}

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

if (( stack_running && ! REDEPLOY )); then
  log "GitLab stack '$project' is already running; leaving containers untouched"
  docker compose ps --format 'table {{.Service}}\t{{.Image}}\t{{.Status}}'
  echo "    Use ./upgrade.sh to change versions, or ./install.sh --redeploy to pull and recreate."
else
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

  log "Creating data directories under $GITLAB_HOME"
  mkdir -p "$GITLAB_HOME"/{config,logs,data}

  log "Starting GitLab $GITLAB_VERSION and Caddy"
  docker compose pull
  docker compose up -d
fi

log "Waiting for GitLab to become healthy (first boot takes 3-10 minutes)"
status=starting
for _ in $(seq 1 120); do
  status=$(docker inspect -f '{{.State.Health.Status}}' "$(docker compose ps -q gitlab)" 2>/dev/null || echo starting)
  [[ "$status" == "healthy" ]] && break
  sleep 10
done
[[ "$status" == "healthy" ]] || die "GitLab not healthy after 20 min — check: docker compose logs gitlab"

# --- Weekly patch-upgrade timer (rewritten each run, so path changes apply) ---

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
