# GitLab CE behind Caddy (Docker, Ubuntu)

```
Internet ──443/80──► Caddy (Let's Encrypt, auto-renew) ──http──► GitLab CE (omnibus container)
         ──2222────────────────────────────────────────────────► GitLab sshd (git over SSH)
```

- **GitLab CE** official `gitlab/gitlab-ce` image. Its version is **pinned** in `.env` (currently `19.5.1-ce.0`, the latest release as of 2026-10-21).
- **Caddy 2** gets and renews the Let's Encrypt certificate itself, sends HTTP to HTTPS, and adds HSTS.
- All state lives in `/srv/gitlab/{config,data,logs}` plus the `caddy_data` volume (certificates). You can delete the containers at any time without losing data.
- Docker's `restart: unless-stopped` and the systemd-managed `docker.service` bring everything back after a reboot.

## Files

| File | Purpose |
|---|---|
| `docker-compose.yml` | Both services. All GitLab settings are in `GITLAB_OMNIBUS_CONFIG` |
| `Caddyfile` | Reverse proxy and TLS |
| `.env.example` | Domain, email, pinned version, paths. Copy it to `.env` |
| `install.sh` | Installs Docker, checks DNS and the firewall, starts the stack, installs the weekly patch timer |
| `upgrade.sh` | Upgrades along GitLab's required upgrade path, with a backup before each step |

## Prerequisites

- Ubuntu 22.04 or 24.04. **At least 4 vCPU and 8 GB RAM** recommended (4 GB works with the memory tweaks in the compose file). SSD storage.
- A DNS **A record** `sub.domain.com → <server public IP>` (and AAAA if you use IPv6).
- Ports **80, 443 (tcp+udp), 2222** open in any cloud security group. Port 80 is needed for the ACME HTTP-01 challenge.

## Install

```bash
scp -r gitlab-caddy/ user@server:/opt/
ssh user@server
cd /opt/gitlab-caddy
cp .env.example .env && nano .env        # set GITLAB_DOMAIN, ACME_EMAIL
chmod +x install.sh upgrade.sh
sudo ./install.sh
```

The script prints the initial `root` password. Log in at `https://sub.domain.com` and change it right away. Then, under **Admin → Settings → General → Sign-up restrictions**, turn off open sign-up if you don't need it.

Check the certificate: `curl -vI https://sub.domain.com 2>&1 | grep -E 'issuer|HTTP/'` should show Let's Encrypt and a 302 to `/users/sign_in`.

## Upgrading

GitLab does **not** support jumping across minor versions at will. You must stop at the "required stops" (e.g. 18.11 → 19.2 → 19.5 …), and each stop's background migrations must finish before the next step. For that reason this setup never uses the `latest` tag. `upgrade.sh` does the work:

1. Gets the list of releases from Docker Hub and the required stops from GitLab's own [`config/upgrade_path.yml`](https://gitlab.com/gitlab-org/gitlab/-/blob/master/config/upgrade_path.yml).
2. Plans the path: newest patch of the current minor → each required stop (its newest patch) → newest release.
3. For each step it waits for background migrations, saves `/etc/gitlab` (which holds **`gitlab-secrets.json`, not included in GitLab backups**), runs `gitlab-backup create`, changes the pinned version in `.env`, pulls the image, restarts GitLab, waits for the healthcheck, and runs `gitlab:check`.
4. Updates Caddy and removes old images.

```bash
sudo ./upgrade.sh --dry-run       # show the plan only
sudo ./upgrade.sh                 # full upgrade to the newest release
sudo ./upgrade.sh --one-hop       # one step at a time
sudo ./upgrade.sh --patch-only    # security/bug-fix patches only (same minor)
```

**Automatic security patches:** `install.sh` enables `gitlab-patch-upgrade.timer` (Sundays 03:30). It runs `upgrade.sh --patch-only --yes`. Patch releases are where GitLab ships its security fixes, and they never include breaking changes. Minor and major upgrades stay **manual** on purpose: read the [release notes / upgrade notes](https://docs.gitlab.com/update/versions/) first.

```bash
systemctl list-timers gitlab-patch-upgrade.timer
journalctl -u gitlab-patch-upgrade.service -e
sudo systemctl disable --now gitlab-patch-upgrade.timer   # opt out
```

To get notices of new security releases, subscribe at https://about.gitlab.com/company/contact/ (Security Notices) or watch the [releases RSS](https://about.gitlab.com/security-releases.xml). GitLab's admin area also shows a version-check badge.

## Backup and restore

- Automatic backups are taken before each upgrade. You can also run `docker compose exec gitlab gitlab-backup create` from cron, e.g. daily.
- **Copy `/srv/gitlab/data/backups/` and `/srv/gitlab/config-backups/` off the server.** A backup on the same disk is not a backup.

Restore (the version must match the backup exactly):

```bash
# set GITLAB_VERSION in .env to the version in the backup name, then:
docker compose up -d
tar -C /srv/gitlab -xzf /srv/gitlab/config-backups/config-<ver>-<stamp>.tgz   # restores gitlab-secrets.json
docker compose exec gitlab gitlab-ctl stop puma
docker compose exec gitlab gitlab-ctl stop sidekiq
docker compose exec gitlab gitlab-backup restore BACKUP=<name without _gitlab_backup.tar>
docker compose restart gitlab
docker compose exec gitlab gitlab-rake gitlab:check SANITIZE=true
```

## Operations cheat-sheet

```bash
docker compose ps                                   # status / health
docker compose logs -f gitlab                       # GitLab logs
docker compose logs -f caddy                        # TLS / ACME issues
docker compose exec gitlab gitlab-ctl status
docker compose exec gitlab gitlab-rake gitlab:env:info
docker compose up -d                                # apply changes to docker-compose.yml
```

To change GitLab settings (SMTP, registry, etc.), edit `GITLAB_OMNIBUS_CONFIG` in `docker-compose.yml`, then run `docker compose up -d`.

## Notes and choices

- **Docker instead of the native `.deb`:** an upgrade is just a tag change in one file, and rolling back is just the previous tag plus a backup restore. The host OS stays clean, and both services run the same way. The native omnibus package (`apt install gitlab-ce` + systemd `gitlab-runsvdir`) would also work, but then GitLab's bundled nginx competes with Caddy for ports and the OS upgrades are tied to GitLab upgrades.
- **Git SSH runs on port 2222** so the host's own sshd keeps port 22. To serve git on 22, move host sshd to another port first, then set `GITLAB_SSH_PORT=22`.
- **Fixed subnet `172.30.0.0/24`:** GitLab trusts `X-Forwarded-For` only from Caddy, so logs and rate limits see the real client IPs. Change it if it collides with an existing network.
- **Container Registry / Pages:** these are disabled by default. To enable the registry, add `registry_external_url 'https://registry.domain.com'` with `registry_nginx['listen_https']=false` and `registry_nginx['listen_port']=5050`, then add a second Caddy site block pointing at `gitlab:5050`.
