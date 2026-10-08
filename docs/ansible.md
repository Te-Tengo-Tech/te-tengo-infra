# Ansible and Docker Compose

Ansible configures the single host (Ubuntu 24.04, arm64, created by Terraform: the OCI Ampere A1 VM in production, or EC2 on the inactive AWS alternative) and runs the Docker Compose stack in `compose/`. The connection is inventory driven: plain SSH on OCI (port 22 open only to `admin_cidrs`), SSH tunnelled through SSM on AWS; the roles are the same. The end-to-end runbook with Terraform is [deploy.md](deploy.md); the variables Terraform hands over are in [interface-terraform-ansible.md](interface-terraform-ansible.md).

## The stack (`compose/`)
```
Internet ──443/tcp+udp, 80──► caddy ──/api/*, /actuator/health──► api:8080 ──► postgres:5432
         │                     └──/vivo/* (strip prefix)──────────► mediamtx:8888 (LL-HLS)
         └──8322/tcp (RTSPS)──────────────────────────────────────► mediamtx:8322
                                         mediamtx ──auth hook──► api:8080/api/interno/mediamtx/autorizar
                                         api ──control API──► mediamtx:9997
```

| Service | Image | Exposed on the host | Notes |
|---|---|---|---|
| `caddy` | `caddy:2.11-alpine` | 80, 443 (TCP and UDP) | Let's Encrypt certificate (`cert_issuer acme`), HSTS, `-Server`. Routes `/api/*` (REST and the WebSocket endpoints `/api/agente/transmision`, `/api/vista-en-vivo/*/transmision`), `/actuator/health*` and `/vivo/*`. `/api/interno/*`, Swagger UI and `/v3/api-docs` answer 404. |
| `api` | `ghcr.io/te-tengo-tech/te-tengo-general-api:<tag>` | — | `api.env` (TT_ variables: clips in Cloudflare R2, e-mail through the SMTP relay) and `./secrets` mounted read-only at `/run/secrets/te-tengo`. Readiness healthcheck. |
| `postgres` | `postgres:18` | — | Volume `postgres-data` (mounted at `/var/lib/postgresql`, as the 18 image expects), tuned by memory profile, only on the `backend` network (`internal: true`, no egress). |
| `mediamtx` | `bluenviron/mediamtx:1.21.1` | 8322 (RTSPS) | `compose/mediamtx/mediamtx.yml`: `authMethod: http` to the API, RTSPS only (TCP, `rtspEncryption: strict`), LL-HLS on 8888 and the control API on 9997 inside the Docker network only; RTMP, WebRTC, SRT, MoQ, metrics and pprof are off. Only `camaras/<id>` paths exist. |

Every setting in `compose.yaml` uses `${VAR:?…}`: a missing value stops `docker compose up`. Ansible renders `.env` (Compose) and `api.env` (API) with mode 0600; `compose/.env.example` and `compose/api.env.example` list them.

### Live view (MediaMTX)
- The auth hook URL carries the shared secret (`MTX_AUTHHTTPADDRESS` = `http://api:8080/api/interno/mediamtx/autorizar?secreto=<vault_mediamtx_auth_secret>`); the API receives the same value as `TT_VIVO_SECRETO_AUTORIZACION`. Caddy never routes `/api/interno/*`.
- The API gets `TT_VIVO_URL_PUBLICACION=rtsps://<host>:8322/camaras/{camaraId}`, `TT_VIVO_URL_HLS=https://<host>/vivo`, `TT_VIVO_MEDIAMTX_API=http://mediamtx:9997`.
- The control API is excluded from the hook (`authHTTPExclude: [api]`) because the API itself calls it to kick publishers and readers; it is not published on the host.
- MediaMTX answers the first playlist request with a 302 to `?cookieCheck=1` (its HLS session check). Caddy rewrites that `Location` back under `/vivo/`. `hlsTrustedProxies` lets MediaMTX bind HLS sessions to the phone's IP from `X-Forwarded-For`.

### RTSPS certificate: shared from Caddy (chosen approach)
MediaMTX mounts Caddy's data volume **read-only** (`caddy-data:/caddy-data:ro`) and reads the site certificate and key that Caddy obtained:
`/caddy-data/caddy/certificates/<issuer dir>/<host>/<host>.crt|.key`.
- The issuer is pinned (`cert_issuer acme`, Let's Encrypt only, no ZeroSSL fallback), so the directory is always `acme-v02.api.letsencrypt.org-directory` (`local` with `tls internal` in the test). Ansible passes it as `CADDY_CERT_DIR`.
- Caddy's healthcheck is "the certificate file exists"; MediaMTX `depends_on` Caddy being healthy, so it never starts without a certificate.
- On renewal (about 30 days before expiry) Caddy replaces the files; MediaMTX's certificate loader watches them and reloads without a restart. A `docker compose restart mediamtx` also picks them up.
- Why not a renew hook: Caddy has no post-renewal hook in the stock image, and a second ACME client would need port 80 too. Why not let MediaMTX terminate TLS for HLS: HLS stays behind Caddy so one certificate and one TLS policy serve the whole public surface.

### Memory profiles
`ansible/group_vars/te_tengo/memory.yml`, chosen by `memory_profile` from Terraform:

| Profile | Instance | Swap | postgres | api (heap) | mediamtx | caddy |
|---|---|---|---|---|---|---|
| `large` (OCI default) | A1.Flex 1 OCPU / 6 GB | 1 GiB | 1024m (`shared_buffers` 256MB, `effective_cache_size` 1536MB) | 2048m (1280m, serial GC) | 512m | 256m |
| `micro` | t4g.micro, 1 GiB | 2 GiB | 192m | 640m (320m) | 128m | 96m |
| `small` (default) | t4g.small, 2 GiB | 2 GiB | 384m | 1024m (512m) | 192m | 128m |
| `medium` | t4g.medium or A1 4 GB | 1 GiB | 768m | 1536m (1 GiB) | 384m | 192m |

**6 GB host (OCI default, half of the tenancy's A1 allowance):** the `large` caps add up to about 3.8 GB, leaving about 2 GB for Ubuntu, Docker, `pg_dump` and the page cache that `effective_cache_size` assumes; the 1 GiB swap file absorbs peaks. One OCPU is a single Ampere core, so the JVM uses the serial collector (no parallel GC threads competing for it) and Hikari keeps 12 connections out of PostgreSQL's 40. Not measured on a real A1 yet: check `docker stats` and `free -m` after the first week.

## Roles (`ansible/roles/`)
`site.yml` runs them in order on the group `te_tengo`, each with its own tag.

| Role | What it does |
|---|---|
| `base` | Asserts Ubuntu ≥ 22.04 and a known memory profile; installs base packages; unattended upgrades (security updates daily, automatic reboot at 04:00 Lima when a kernel needs it); journald capped at 200 MB; swap file sized by profile and `vm.swappiness=10` (both switchable off: `base_manage_swap`, `base_manage_sysctl`); **host firewall on OCI images**: Oracle's Ubuntu images load `/etc/iptables/rules.v4`, which rejects every inbound connection except SSH ([Oracle: enabling network traffic to Ubuntu images](https://blogs.oracle.com/developers/enabling-network-traffic-to-ubuntu-images-in-oracle-cloud-infrastructure)); when that file ends its INPUT chain in REJECT, the role inserts ACCEPT rules for 80/TCP, 443/TCP, 443/UDP and 8322/TCP before it, in the file and in the running policy (Docker's own chains handle the forwarded container traffic); optional extra SSH keys for `ubuntu` (`te_tengo_authorized_keys`, e.g. the deploy key). |
| `docker` | Docker Engine, Buildx and the Compose plugin from Docker's official apt repository (arch-aware); `daemon.json` with json-file log rotation (10 MB × 3) and `live-restore`; `ubuntu` in the `docker` group. |
| `app` | Asserts every required variable and the vault (password length, PEM headers, secret format, Firebase key shape, R2 keys when `object_storage_auth` is `static`, SMTP password when an SMTP user is set); rejects values the env files cannot hold; installs `compose.yaml`, the Caddyfile and `mediamtx.yml`; writes `.env` and `api.env` (0600, `no_log`); writes the JWT keys and the Firebase key from the vault to `secrets/` (0600, owned by UID 10001, the image's user); gets the API image (pull, load or build, below); `docker_compose_v2` with `wait: true`; then checks over HTTPS from the host: `/actuator/health` is `UP` with HSTS, `/vivo/...m3u8` without a token is **401**, and `/api/interno/...`, `/swagger-ui.html`, `/v3/api-docs` are **404**. Handlers reload Caddy, restart MediaMTX or restart the API when their files change on a running stack. |
| `backup` | AWS CLI v2 (official installer; used only as an S3 client); `/usr/local/sbin/te-tengo-backup` (custom-format `pg_dump`, last 7 kept in `/var/backups/te-tengo`, copied to `s3://<backup_s3_bucket>/postgres/` on the **S3-compatible endpoint** of the inventory, i.e. Cloudflare R2 with the `vault_backup_s3_*` keys, region `auto`, path-style addressing, checksums only when required), a systemd service and a daily timer (08:30 UTC = 03:30 Lima, randomized 15 min, persistent); `/usr/local/sbin/te-tengo-restore <file \| s3://… \| latest>`. Credentials and settings in `/etc/te-tengo/backup.env` and `/etc/te-tengo/aws-config` (0600). On the AWS alternative with `enable_s3_buckets` it uses the instance role instead. |

### API image sources (`te_tengo_api_source`)
| Value | Use | Variables |
|---|---|---|
| `registry` (default) | Production: pulls `te_tengo_api_repository:te_tengo_api_tag` (`pull: always`) | `te_tengo_api_tag` (pin a release or `sha-…` tag); for a private package `te_tengo_registry_auth: login`, `te_tengo_registry_username`, `vault_registry_password` (token with `read:packages`) |
| `archive` | No registry: `docker load` of a `docker save` file copied from the controller | `te_tengo_api_archive` (controller path); the image must be tagged `te-tengo-general-api:local` |
| `build` | Builds on the host from a local checkout (`git archive` of `te_tengo_api_build_ref`, default `HEAD`) | `te_tengo_api_build_src`; `te_tengo_api_build_dockerfile` if the checkout has no Dockerfile |

`compose/compose.build.yaml` does the same without Ansible: `API_BUILD_CONTEXT=../te-tengo-general-api docker compose -f compose.yaml -f compose.build.yaml up -d --build`.

### Variables
Terraform's inventory sets `app_hostname`, `cloud_provider`, `memory_profile`, `object_storage_*`, `clips_s3_bucket`, `backup_s3_bucket`, `ses_sender`, `push_provider`, `sns_platform_application_arn` and `live_view_publish_port` (and `aws_region` on AWS); `group_vars/te_tengo/vars.yml` maps them to `te_tengo_*` names that the roles read (a hand-written inventory can set the `te_tengo_*` names directly). Other settings in the same file: `te_tengo_acme_email` (**required**), image names, `te_tengo_api_settings` (extra API variables, merged last), backup schedule, and the SMTP relay.

**Clips (Cloudflare R2):** with `object_storage_auth: static` the API gets `TT_CLIPS_BUCKET`, `TT_CLIPS_REGION=auto`, `TT_CLIPS_ENDPOINT=https://<ACCOUNT_ID>.r2.cloudflarestorage.com`, `TT_CLIPS_PATH_STYLE=true`, `TT_CLIPS_ACCESS_KEY` / `TT_CLIPS_SECRET_KEY` (vault `vault_clips_s3_*`) and **no AWS credentials**.

**E-mail (SMTP relay):** set in `vars.yml` (or an untracked `ansible/*.local.yml`):
| Variable | Example | API setting |
|---|---|---|
| `te_tengo_smtp_host` | the relay's SMTP host | `SPRING_MAIL_HOST`; non-empty switches `TT_CORREO_PROVEEDOR` to `smtp` |
| `te_tengo_smtp_port` | `587` | `SPRING_MAIL_PORT` |
| `te_tengo_smtp_security` | `starttls` (587), `ssl` (465) or `none` | `SPRING_MAIL_PROPERTIES_MAIL_SMTP_STARTTLS_ENABLE` / `_REQUIRED`, or `SPRING_MAIL_PROPERTIES_MAIL_SMTP_SSL_ENABLE` |
| `te_tengo_smtp_sender` | `Te Tengo <no-responder@tetengo.reqsai.tech>` | `TT_SMTP_REMITENTE` |
| vault `vault_smtp_username` / `vault_smtp_password` | relay user / password or API key | `SPRING_MAIL_USERNAME` / `SPRING_MAIL_PASSWORD`, `SPRING_MAIL_PROPERTIES_MAIL_SMTP_AUTH=true` when a user is set |

The sender's domain must be verified at the relay (SPF/DKIM records at Namify, as the relay indicates). The `smtp` provider comes with a te-tengo-general-api change made in parallel; until a release with it is deployed, leave `te_tengo_smtp_host` empty (e-mails are then only logged, `registro`). With `te_tengo_smtp_host` empty and an SES sender from the AWS module, the provider is `ses`.

Secrets live in `group_vars/te_tengo/vault.yml` (git-ignored, encrypted with `ansible-vault`); see `vault.yml.example` and the secrets inventory in [deploy.md](deploy.md#secrets-inventory).

## Commands
```bash
make galaxy                 # collections from ansible/requirements.yml
make ansible-check          # yamllint + ansible-lint (production profile) + docker compose config
make deploy                 # full site.yml against ansible/inventory/hosts.yml (asks the vault password)
make redeploy ANSIBLE_ARGS="-e te_tengo_api_tag=sha-0123abc"   # app role only
make backup-now
```

## Local test without a cloud account (`test/`)
A privileged Ubuntu 24.04 container with systemd as PID 1 and OpenSSH plays the OCI VM. Ansible reaches it **over plain SSH**, as in production: `test/prepare.sh` generates a throwaway key, authorizes it for `ubuntu` and pins the container's host key in `test/.work/known_hosts` (`StrictHostKeyChecking=yes`, the same pinning the deploy workflow uses). Ansible installs Docker inside it (Docker-in-Docker) and deploys the real stack. The image also carries an iptables policy file shaped like Oracle's (`test/host/oci-rules.v4`, not loaded) so the base role's firewall tasks run. Floci, the local AWS emulator, runs next to it as `floci.test:4566`; **its S3 API stands in for Cloudflare R2**: endpoint, path style and static keys from the (throwaway) vault, exactly the R2 code path. The only difference is the signing region: Floci rejects R2's `auto`, so the test inventory uses `us-east-1`.

```bash
make test-host-up                                       # host + Floci, SSH key + pinned host key, throwaway secrets, buckets
make test-deploy TT_API_SRC=../te-tengo-general-api      # builds the API image from that checkout, runs site.yml over SSH
make test-smoke                                          # checks from the Mac through Caddy
make test-down                                           # removes everything, test/.work included
make test-all                                            # the first three in one go
```

What differs from production, all in `test/vars.yml` and `test/inventory.yml`: `app_hostname: localhost` with Caddy's internal CA (`te_tengo_cert_issuer: internal`; the checks trust that CA, nothing uses `-k`); the API image comes from an archive built on the Mac from `TT_API_SRC` (its Dockerfile, or `test/api.Dockerfile` when the checkout has none); object storage is Floci (region `us-east-1`); e-mail and push are only logged (`registro`: no SMTP relay, no Firebase key); swap and sysctls are left alone (the container shares Docker Desktop's kernel). Host ports: 18022 (SSH), 18443 (HTTPS), 18081 (HTTP), 18322 (RTSPS), 34566 (Floci), all on 127.0.0.1.

`test/smoke.sh` checks: health over HTTPS with a verified certificate, HSTS, HTTP→HTTPS redirect, hidden endpoints (404), sign-up and sign-in, household, consent, an agent installation, camera registration, a fall event, the pre-signed clip URL on `http://floci.test:4566/te-tengo-clips/…` and the upload itself (Floci verifies the signature made with the static keys), HLS 401 without a token and with an unknown one, RTSPS presenting Caddy's certificate, that `api.env` uses the R2-style settings and holds **no AWS credentials**, that the OCI-style `rules.v4` accepts 80, 443/TCP, 443/UDP and 8322 before its REJECT, and a backup to the bucket restored with `te-tengo-restore latest`.

Result on 2026-10-08: **28/28 checks passed**; a second `make test-deploy` reported `changed=0`.

CI (`.github/workflows/ansible.yml`) runs the static checks on every change, and the same containerized deploy (`make test-all`) when the `API_REPO_TOKEN` secret (read-only access to `te-tengo-general-api`) exists; without it the job is skipped with a notice.
