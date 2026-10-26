# GitLab CE behind Caddy (Docker, Ubuntu)

```
Internet ──443/80──► Caddy (Let's Encrypt, auto-renew) ──http──► GitLab CE (omnibus container)
         ──2222────────────────────────────────────────────────► GitLab sshd (git over SSH)
```

- **GitLab CE** official `gitlab/gitlab-ce` image. Its version is **pinned** in `.env` (currently `19.5.1-ce.0`, the latest release as of 2026-10-21).
- **Caddy 2** gets and renews the Let's Encrypt certificate itself, sends HTTP to HTTPS, and adds HSTS.
- All state lives in `/srv/gitlab`: GitLab config, data and logs, Caddy certificates, and backup bundles. You can delete the containers at any time without losing data (see [Data safety](#data-safety-what-can-and-cannot-lose-data)).
- Docker's `restart: unless-stopped` and the systemd-managed `docker.service` bring everything back after a reboot.

## Files

| File | Purpose |
|---|---|
| `docker-compose.yml` | Both services. All GitLab settings are in `GITLAB_OMNIBUS_CONFIG` |
| `Caddyfile` | Reverse proxy and TLS |
| `.env.example` | Domain, email, pinned version, paths. Copy it to `.env` |
| `install.sh` | Installs Docker, checks DNS and the firewall, starts the stack (or restores a bundle with `--restore`), installs the backup and patch timers |
| `upgrade.sh` | Upgrades along GitLab's required upgrade path, with a verified backup before each step |
| `backup.sh` | Writes a verified, checksummed backup bundle (`--migrate` when moving servers) |
| `restore.sh` | Restores a bundle on this or a new server and verifies the result |
| `lib.sh` | Shared safety checks used by all scripts |

## Prerequisites

- Ubuntu 22.04 or 24.04. **At least 4 vCPU and 8 GB RAM** recommended (4 GB works with the memory tweaks in the compose file). SSD storage.
- A DNS **A record** `sub.domain.com → <server public IP>` (and AAAA if you use IPv6). `install.sh` checks that the record matches one of the server's interface IPs or its outbound IP. If the server sits behind NAT, an elastic/floating IP, or an outbound proxy/VPN, set `PUBLIC_IP=` in `.env`; this replaces auto-detection.
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

## Data safety: what can and cannot lose data

All state lives under `GITLAB_HOME` (default `/srv/gitlab`) as **bind mounts**:

| Path | Contents |
|---|---|
| `data/` | PostgreSQL, Git repositories (Gitaly), uploads, LFS, CI artifacts, packages, Redis |
| `config/` | `gitlab.rb`, **`gitlab-secrets.json`**, SSH host keys |
| `logs/` | logs |
| `caddy/` | TLS certificates and ACME account |
| `bundles/` | backup bundles (or `BACKUP_DIR`) |

Containers are disposable. `docker compose down`, `down -v`, `rm`, recreating, image prunes and reboots do **not** touch these directories. The scripts refuse to go on whenever continuing could lose data:

| Risk | Guard |
|---|---|
| `GITLAB_HOME` changed or mistyped, so an empty GitLab starts and the real data is orphaned | Compose fails if it is unset. The scripts compare it with the existing container's mount and stop on a mismatch |
| Image newer than the data, so an unplanned upgrade runs with no backup | The scripts compare the data's own `gitlab-rails/VERSION` with `GITLAB_VERSION` and refuse. `pull_policy: missing` prevents surprise pulls |
| Image older than the data (a downgrade), which corrupts the DB | Same check. Downgrades are refused |
| Docker's 10 s stop timeout kills PostgreSQL mid-write | `stop_grace_period: 5m` |
| A hop starts before the previous version's background migrations finish, or after one failed | `upgrade.sh` waits for 0 pending migrations. It stops on any *failed* one, and also stops if their status can't be read |
| Backup lacks `gitlab-secrets.json`, so CI variables, 2FA and tokens can't be decrypted after a restore | Every bundle includes `/etc/gitlab`. Creation fails if the secrets file is missing |
| Corrupt or truncated backup that is only noticed on restore day | Every `.gz` member is `gzip -t`-tested, and the DB dump and version are checked. The bundle gets `SHA256SUMS`, which are verified before any restore |
| Backup reported OK, but the restore is silently partial | Row counts (projects, users, namespaces, issues, MRs, notes) are recorded at backup time. They are compared after a restore and after every upgrade hop. `gitlab:doctor:secrets` checks decryption |
| Upgrade fails halfway and automation keeps going, or someone "rolls back" by setting the old tag | A `.upgrade-in-progress` marker blocks **all** scripts and timers until a person resolves it. The only rollback is through `restore.sh` |
| Restore runs over existing data by mistake | `restore.sh` refuses without `--force`. With `--force`, the old `data/` and `config/` are **moved** aside, never deleted |
| Two maintenance jobs at once (timer + manual run) | One global `flock` |
| Disk fills up during a backup or restore | Free space is checked up front. A failed bundle is deleted, so it can't later pose as valid |
| Certificates in Caddy named volumes from earlier versions of this stack | Copied once into the bind mount before Caddy is recreated |

Not covered: failure of the disk holding `GITLAB_HOME`. That is why bundles must be copied **off the server**. If you configure external object storage later, back it up separately.

## Upgrading

GitLab does **not** support jumping across minor versions at will. You must stop at the "required stops" (e.g. 18.11 → 19.2 → 19.5 …), and each stop's background migrations must finish before the next step. For that reason this setup never uses the `latest` tag. `upgrade.sh` gets the release list from Docker Hub and the required stops from GitLab's [`config/upgrade_path.yml`](https://gitlab.com/gitlab-org/gitlab/-/blob/master/config/upgrade_path.yml), then does each hop like this:

1. Checks GitLab is healthy. Waits until batched background migrations are finished, and aborts if any **failed**.
2. Pulls the new image first, so a registry outage changes nothing.
3. Writes a verified backup bundle (see below).
4. Writes the `.upgrade-in-progress` marker, pins the new version in `.env`, and recreates GitLab.
5. Waits for health (up to 60 min). Then confirms that the running version and the data version equal the target, that row counts did not drop, and runs `gitlab:check`. Only then does it remove the marker and move to the next hop.

```bash
sudo ./upgrade.sh --dry-run       # show the plan only
sudo ./upgrade.sh                 # full upgrade to the newest release
sudo ./upgrade.sh --one-hop       # one step at a time
sudo ./upgrade.sh --patch-only    # security/bug-fix patches only (same minor)
```

**If a hop fails**, the data is untouched on disk and the pre-upgrade bundle path is printed. **Do not set the old version back in `.env`**: the database may already be migrated, and an older GitLab on a newer schema corrupts it. Instead, do one of the following:
- Often the new version only needs a fix and `docker compose restart gitlab`. Once it is healthy and `gitlab:check` passes, run `rm /srv/gitlab/.upgrade-in-progress`.
- Or roll back fully with `sudo ./restore.sh <pre-upgrade bundle> --force`. This restores the old version and clears the marker.

**Automatic security patches:** `install.sh` enables `gitlab-patch-upgrade.timer` (Sundays 03:30). It runs `upgrade.sh --patch-only --yes`, with the same backup and checks as above. Patch releases are where GitLab ships its security fixes. Minor and major upgrades stay **manual** on purpose: read the [upgrade notes](https://docs.gitlab.com/update/versions/) first.

```bash
systemctl list-timers 'gitlab-*'
journalctl -u gitlab-patch-upgrade.service -e
sudo systemctl disable --now gitlab-patch-upgrade.timer   # opt out
```

For notices of new security releases, subscribe at https://about.gitlab.com/company/contact/ (Security Notices) or watch the [security releases RSS](https://about.gitlab.com/security-releases.xml).

## Backup and restore

A **bundle** is one directory with everything needed to rebuild the instance, here or on another server:

```
gitlab-20261026T021500Z-19.5.1-scheduled/
  scheduled_..._19.5.1_gitlab_backup.tar   DB, repositories, uploads, LFS, artifacts, packages, ...
  config.tar.gz                             /etc/gitlab incl. gitlab-secrets.json + SSH host keys
  stack/                                    .env, docker-compose.yml, Caddyfile
  MANIFEST  SHA256SUMS
```

```bash
sudo ./backup.sh                  # manual bundle; GitLab keeps serving
sudo ./backup.sh --scheduled      # what the daily timer runs (02:15)
```

**Retention:**
- `scheduled` and `pre-upgrade` bundles: the newest `BACKUP_KEEP` (default 5) of each kind are kept.
- `manual` and `migration` bundles are never deleted automatically.
- A directory ending in `.partial` is an unfinished bundle and is safe to delete.

**Copy bundles off the server.** A backup on the same disk is not a backup. Bundles contain secrets, so keep the target private:

```bash
rsync -aH /srv/gitlab/bundles/ backup-host:/backups/gitlab/
```

Run this from cron or a timer after 02:15. On the target, check a bundle with `cd <bundle> && sha256sum -c SHA256SUMS`.

**Restore** (same or new server): `restore.sh` does the following:
- verifies the checksums;
- moves existing data aside;
- restores `/etc/gitlab`;
- starts the **exact** GitLab version of the bundle;
- runs `gitlab-backup restore`;
- verifies health, secrets, row counts and `gitlab:check`.

```bash
sudo ./restore.sh /srv/gitlab/bundles/gitlab-<...>           # refuses if data exists
sudo ./restore.sh /srv/gitlab/bundles/gitlab-<...> --force   # replace; old data moved aside
```

Test a restore on a spare VM now and then. It is the only real proof that a backup works.

## Migrating to a new server

1. **Old server:** take a consistent final snapshot. Web and background jobs stay **stopped** afterwards, so nothing written after the snapshot is lost:
   ```bash
   sudo ./backup.sh --migrate
   ```
   ```bash
   rsync -aH --info=progress2 /srv/gitlab/bundles/gitlab-<...>-migration root@NEW:/root/
   ```
2. **New server:** copy this directory over (e.g. `git clone`), then run:
   ```bash
   sudo ./install.sh --restore /root/gitlab-<...>-migration
   ```
   The first run copies `.env` from the bundle and stops so you can review it (update `PUBLIC_IP` if you use it). Run the same command again. It then:
   - installs Docker;
   - restores the bundle on its exact version and verifies it;
   - starts Caddy and enables the timers.

   Upgrade afterwards with `./upgrade.sh`, not during the move.
3. Point DNS at the new server. Caddy gets a certificate on the first request. The SSH host keys are restored, so users see no host-key warning.
4. Before the DNS switch you can still abort: `docker compose restart gitlab` on the old server resumes service there.

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
