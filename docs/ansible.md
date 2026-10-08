# Ansible and Docker Compose

Ansible configures the single MVP host (Ubuntu 24.04, arm64, created by Terraform) and runs the Docker Compose stack in `compose/`. The end-to-end runbook with Terraform is [deploy.md](deploy.md); the variables Terraform hands over are in [interface-terraform-ansible.md](interface-terraform-ansible.md).

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
| `api` | `ghcr.io/te-tengo-tech/te-tengo-general-api:<tag>` | — | `api.env` (TT_ variables) and `./secrets` mounted read-only at `/run/secrets/te-tengo`. Readiness healthcheck. |
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
| `micro` | t4g.micro, 1 GiB | 2 GiB | 192m | 640m (320m) | 128m | 96m |
| `small` (default) | t4g.small, 2 GiB | 2 GiB | 384m | 1024m (512m) | 192m | 128m |
| `medium` | t4g.medium, 4 GiB | 1 GiB | 768m | 1536m (1 GiB) | 384m | 192m |

## Roles (`ansible/roles/`)
`site.yml` runs them in order on the group `te_tengo`, each with its own tag.

| Role | What it does |
|---|---|
| `base` | Asserts Ubuntu ≥ 22.04 and a known memory profile; installs base packages; unattended upgrades (security updates daily, automatic reboot at 04:00 Lima when a kernel needs it); journald capped at 200 MB; swap file sized by profile and `vm.swappiness=10` (both switchable off: `base_manage_swap`, `base_manage_sysctl`); optional extra SSH keys for `ubuntu` (`te_tengo_authorized_keys`, e.g. the deploy key). |
| `docker` | Docker Engine, Buildx and the Compose plugin from Docker's official apt repository (arch-aware); `daemon.json` with json-file log rotation (10 MB × 3) and `live-restore`; `ubuntu` in the `docker` group. |
| `app` | Asserts every required variable and the vault (password length, PEM headers, secret format, Firebase key shape); rejects values the env files cannot hold; installs `compose.yaml`, the Caddyfile and `mediamtx.yml`; writes `.env` and `api.env` (0600, `no_log`); writes the JWT keys and the Firebase key from the vault to `secrets/` (0600, owned by UID 10001, the image's user); gets the API image (pull, load or build, below); `docker_compose_v2` with `wait: true`; then checks over HTTPS from the host: `/actuator/health` is `UP` with HSTS, `/vivo/...m3u8` without a token is **401**, and `/api/interno/...`, `/swagger-ui.html`, `/v3/api-docs` are **404**. Handlers reload Caddy, restart MediaMTX or restart the API when their files change on a running stack. |
| `backup` | AWS CLI v2 (official installer); `/usr/local/sbin/te-tengo-backup` (custom-format `pg_dump`, last 7 kept in `/var/backups/te-tengo`, copied to `s3://<backup_s3_bucket>/postgres/`), a systemd service and a daily timer (08:30 UTC = 03:30 Lima, randomized 15 min, persistent); `/usr/local/sbin/te-tengo-restore <file \| s3://… \| latest>`. |

### API image sources (`te_tengo_api_source`)
| Value | Use | Variables |
|---|---|---|
| `registry` (default) | Production: pulls `te_tengo_api_repository:te_tengo_api_tag` (`pull: always`) | `te_tengo_api_tag` (pin a release or `sha-…` tag); for a private package `te_tengo_registry_auth: login`, `te_tengo_registry_username`, `vault_registry_password` (token with `read:packages`) |
| `archive` | No registry: `docker load` of a `docker save` file copied from the controller | `te_tengo_api_archive` (controller path); the image must be tagged `te-tengo-general-api:local` |
| `build` | Builds on the host from a local checkout (`git archive` of `te_tengo_api_build_ref`, default `HEAD`) | `te_tengo_api_build_src`; `te_tengo_api_build_dockerfile` if the checkout has no Dockerfile |

`compose/compose.build.yaml` does the same without Ansible: `API_BUILD_CONTEXT=../te-tengo-general-api docker compose -f compose.yaml -f compose.build.yaml up -d --build`.

### Variables
Terraform's inventory sets `app_hostname`, `aws_region`, `memory_profile`, `clips_s3_bucket`, `backup_s3_bucket`, `ses_sender`, `push_provider`, `sns_platform_application_arn` and `live_view_publish_port`; `group_vars/te_tengo/vars.yml` maps them to `te_tengo_*` names that the roles read (a hand-written inventory can set the `te_tengo_*` names directly). Other settings in the same file: `te_tengo_acme_email` (**required**), image names, `te_tengo_api_settings` (extra API variables, merged last), backup schedule. With `ses_sender` empty, e-mail falls back to `registro` (logs only).

Secrets live in `group_vars/te_tengo/vault.yml` (git-ignored, encrypted with `ansible-vault`); see `vault.yml.example` and the secrets inventory in [deploy.md](deploy.md#secrets-inventory).

## Commands
```bash
make galaxy                 # collections from ansible/requirements.yml
make ansible-check          # yamllint + ansible-lint (production profile) + docker compose config
make deploy                 # full site.yml against ansible/inventory/hosts.yml (asks the vault password)
make redeploy ANSIBLE_ARGS="-e te_tengo_api_tag=sha-0123abc"   # app role only
make backup-now
```

## Local test without AWS (`test/`)
A privileged Ubuntu 24.04 container with systemd as PID 1 plays the EC2 instance; Ansible reaches it through the `community.docker.docker` connection as `ubuntu` with sudo, installs Docker inside it (Docker-in-Docker) and deploys the real stack. Floci, the local AWS emulator, runs next to it on the same network as `floci.test:4566` (S3 for clips and backups, SES).

```bash
make test-host-up                                       # host + Floci, throwaway secrets, buckets
make test-deploy TT_API_SRC=../te-tengo-general-api      # builds the API image from that checkout, runs site.yml
make test-smoke                                          # checks from the Mac through Caddy
make test-down                                           # removes everything, test/.work included
make test-all                                            # the first three in one go
```

What differs from production, all in `test/vars.yml` and `test/inventory.yml`: `app_hostname: localhost` with Caddy's internal CA (`te_tengo_cert_issuer: internal`; the checks trust that CA, nothing uses `-k`); the API image comes from an archive built on the Mac from `TT_API_SRC` (its Dockerfile, or `test/api.Dockerfile` when the checkout has none); S3 and SES point to Floci with its `test/test` keys; `TT_PUSH_PROVEEDOR=registro` (no Firebase key anywhere); swap and sysctls are left alone (the container shares Docker Desktop's kernel). Host ports: 18443 (HTTPS), 18081 (HTTP), 18322 (RTSPS), 34566 (Floci), all on 127.0.0.1.

`test/smoke.sh` checks: health over HTTPS with a verified certificate, HSTS, HTTP→HTTPS redirect, hidden endpoints (404), sign-up and sign-in, household, consent, an agent installation, camera registration, a fall event, the pre-signed clip URL on `http://floci.test:4566/te-tengo-clips/…` and the upload itself (Floci verifies the signature), HLS 401 without a token and with an unknown one, RTSPS presenting Caddy's certificate, and a backup to Floci's S3 restored with `te-tengo-restore latest`.

CI (`.github/workflows/ansible.yml`) runs the static checks on every change, and the same containerized deploy (`make test-all`) when the `API_REPO_TOKEN` secret (read-only access to `te-tengo-general-api`) exists; without it the job is skipped with a notice.
