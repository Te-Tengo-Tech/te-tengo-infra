#!/usr/bin/env bash
# Smoke test of the deployed test host, from the Mac, through Caddy over HTTPS (make test-smoke).
# Checks: health, HSTS, hidden endpoints, sign-up and sign-in, an agent's pre-signed clip URL on
# Floci standing in for Cloudflare R2 (and the upload itself), HLS 401 without a token, RTSPS with
# Caddy's certificate, the production-shaped settings (R2-style keys, no AWS credentials, OCI image
# firewall), and a backup to the bucket restored back. Prints a PASS/FAIL summary; exit code 1 on any failure.
set -uo pipefail
cd "$(dirname "$0")"

BASE="${TT_TEST_BASE:-https://localhost:18443}"
RTSPS="${TT_TEST_RTSPS:-localhost:18322}"
FLOCI_MAC="${TT_TEST_FLOCI_MAC:-127.0.0.1:34566}"
FLOCI_HOST="floci.test:4566"
HOST=tt-test-host
APP_DIR=/opt/te-tengo
WORK=.work
CA="$WORK/caddy-root.crt"
RUN_BACKUP="${TT_TEST_BACKUP:-1}"

for tool in curl jq openssl docker; do
  command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 2; }
done

results=()
failed=0
pass() { results+=("PASS  $1"); echo "PASS  $1"; }
fail() { results+=("FAIL  $1${2:+ — $2}"); echo "FAIL  $1${2:+ — $2}" >&2; failed=1; }
check() { local name="$1"; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }

on_host() { docker exec -w "$APP_DIR" "$HOST" "$@"; }
psql_host() { docker exec -i -w "$APP_DIR" "$HOST" docker compose exec -T postgres psql -U tetengo -d tetengo -v ON_ERROR_STOP=1 -qtA "$@"; }

# curl through Caddy, trusting only Caddy's local CA (no -k anywhere).
call() { # method path [json] [token] -> body, then the status code on the last line
  curl -sS --cacert "$CA" -X "$1" "$BASE$2" -H 'Api-Version: 1' -H 'Content-Type: application/json' \
    ${4:+-H "Authorization: Bearer $4"} ${3:+--data "$3"} -w '\n%{http_code}'
}
body() { sed '$d' <<<"$1"; }
code() { tail -n1 <<<"$1"; }

echo "== Te Tengo test host smoke test against $BASE"
on_host cat "$APP_DIR/caddy/local-root.crt" >"$CA" 2>/dev/null || { echo "Run make test-deploy first" >&2; exit 2; }

# 1. Health over HTTPS, verified against Caddy's local CA.
health_headers=$(mktemp); trap 'rm -f "$health_headers"' EXIT
status=$(curl -sS --cacert "$CA" -D "$health_headers" "$BASE/actuator/health" | jq -r .status 2>/dev/null)
check "GET /actuator/health over HTTPS is UP (certificate verified)" [ "$status" = UP ]
check "Strict-Transport-Security header" grep -qi '^strict-transport-security: max-age=' "$health_headers"
check "HTTP redirects to HTTPS" [ "$(curl -s -o /dev/null -w '%{http_code}' http://localhost:18081/actuator/health)" = 308 ]

# 2. Endpoints that must not be reachable from the Internet.
for path in /api/interno/mediamtx/autorizar /swagger-ui.html /v3/api-docs; do
  check "POST $path is not exposed (404)" \
    [ "$(curl -s --cacert "$CA" -o /dev/null -w '%{http_code}' -X POST "$BASE$path")" = 404 ]
done

# 3. Sign-up and sign-in (family member).
email="smoke-$(date +%s)-$RANDOM@tetengo.test"
password="Smoke-$(openssl rand -hex 8)"
r=$(call POST /api/cuentas "$(jq -nc --arg c "$email" --arg p "$password" '{correo:$c,contrasena:$p,nombre:"Prueba Humo"}')")
check "POST /api/cuentas creates an account (201)" [ "$(code "$r")" = 201 ]
r=$(call POST /api/sesiones "$(jq -nc --arg c "$email" --arg p "$password" '{correo:$c,contrasena:$p}')")
token=$(body "$r" | jq -r '.tokenAcceso // empty' 2>/dev/null)
check "POST /api/sesiones signs in and returns an access token" [ "$(code "$r")" = 200 -a -n "$token" ]

# 4. Household, consent, agent installation, camera registration, fall event, clip URL.
r=$(call POST /api/hogar '{"adultoMayor":{"nombre":"Rosa Prueba","direccion":"Jr. Prueba 123, Lima","edad":78,"convivencia":"SOLO"}}' "$token")
token=$(body "$r" | jq -r '.tokenAcceso // empty' 2>/dev/null); household=$(body "$r" | jq -r '.hogarId // empty' 2>/dev/null)
check "POST /api/hogar creates the household (201)" [ "$(code "$r")" = 201 -a -n "$household" ]
r=$(call POST /api/hogar/consentimiento '{"otorgadoPor":"Prueba Humo","aceptadoPorAdultoMayor":true,"vistaEnVivoAceptada":true}' "$token")
check "POST /api/hogar/consentimiento records consent (201)" [ "$(code "$r")" = 201 ]

credential="$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n')"
psql_host -v hogar="$household" -v credencial="$credential" >/dev/null <<'SQL'
insert into instalaciones (id, hogar_id, credencial_hash, creado_en, actualizado_en)
values (uuidv7(), :'hogar', encode(sha256(convert_to(:'credencial', 'UTF8')), 'hex'), now(), now());
SQL
check "Agent installation inserted in PostgreSQL on the host" [ $? -eq 0 ]

r=$(call POST /api/agente/camaras/registro "$(jq -nc --arg c "$credential" '{credencialInstalacion:$c,nombreHabitacion:"Sala",versionAgente:"smoke"}')")
agent=$(body "$r" | jq -r '.token // empty' 2>/dev/null)
check "POST /api/agente/camaras/registro registers the camera (200)" [ "$(code "$r")" = 200 -a -n "$agent" ]

event_id=$(uuidgen | tr 'A-Z' 'a-z')
r=$(call POST /api/agente/eventos "$(jq -nc --arg e "$event_id" --arg t "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" \
  '{eventoId:$e,tipo:"caida",ocurridoEn:$t,parametros:{angulo_grados:22.1}}')" "$agent")
check "POST /api/agente/eventos accepts a fall (202, alert created)" \
  [ "$(code "$r")" = 202 -a -n "$(body "$r" | jq -r '.alertaId // empty' 2>/dev/null)" ]

r=$(call POST "/api/agente/eventos/$event_id/clip" '{"contentType":"video/mp4","tamanoBytes":16}' "$agent")
upload_url=$(body "$r" | jq -r '.urlSubida // empty' 2>/dev/null)
check "POST .../clip returns a pre-signed URL (201)" [ "$(code "$r")" = 201 -a -n "$upload_url" ]
echo "      urlSubida: ${upload_url%%\?*}?…"
check "The pre-signed URL points to the test Floci (http://$FLOCI_HOST/te-tengo-clips/)" \
  [ "${upload_url#http://$FLOCI_HOST/te-tengo-clips/}" != "$upload_url" ]
headers=()
while IFS= read -r h; do [ -n "$h" ] && headers+=(-H "$h"); done < <(body "$r" | jq -r '.cabeceras // {} | to_entries[] | "\(.key): \(.value)"')
put_code=$(printf 'smoke-test-clip!' | curl -sS -o /dev/null -w '%{http_code}' --connect-to "$FLOCI_HOST:$FLOCI_MAC" \
  -X PUT ${headers[@]+"${headers[@]}"} --data-binary @- "$upload_url")
check "The clip upload to the pre-signed URL is accepted by Floci (signature verified)" [ "$put_code" = 200 ]

# 5. Live view: HLS needs a viewer token; RTSPS serves Caddy's certificate.
hls=$(curl -sS -L --cacert "$CA" -o /dev/null -w '%{http_code}' "$BASE/vivo/camaras/$(uuidgen | tr 'A-Z' 'a-z')/index.m3u8")
check "GET /vivo/.../index.m3u8 without a token is rejected (401)" [ "$hls" = 401 ]
hls=$(curl -sS -L --cacert "$CA" -o /dev/null -w '%{http_code}' "$BASE/vivo/camaras/$(uuidgen | tr 'A-Z' 'a-z')/index.m3u8?token=not-a-session")
check "GET /vivo/.../index.m3u8 with an unknown token is rejected (401)" [ "$hls" = 401 ]
rtsps_subject=$(openssl s_client -connect "$RTSPS" -servername localhost -CAfile "$CA" -verify_return_error </dev/null 2>/dev/null \
  | openssl x509 -noout -ext subjectAltName 2>/dev/null | tr -d ' \n')
check "RTSPS on 8322 presents Caddy's certificate for the host name" grep -q 'DNS:localhost' <<<"$rtsps_subject"

# 6. Production-shaped configuration: R2-style object storage with static keys, no AWS credentials,
#    and the OCI image firewall opened by the base role.
# The bash -c bodies below are single-quoted on purpose: the file contents arrive as $1.
api_env=$(docker exec "$HOST" cat "$APP_DIR/api.env")
# shellcheck disable=SC2016
check "api.env signs clips with static keys on an S3-compatible endpoint (R2 style)" \
  bash -c 'grep -q "^TT_CLIPS_ENDPOINT=.http://floci.test:4566" <<<"$1" && grep -q "^TT_CLIPS_PATH_STYLE=.true" <<<"$1" && grep -q "^TT_CLIPS_ACCESS_KEY=" <<<"$1"' _ "$api_env"
# shellcheck disable=SC2016
check "api.env holds no AWS credentials" bash -c '! grep -q "^AWS_" <<<"$1"' _ "$api_env"
rules=$(docker exec "$HOST" cat /etc/iptables/rules.v4)
# shellcheck disable=SC2016
check "rules.v4 accepts 80, 443/tcp, 443/udp and 8322 before its INPUT REJECT" bash -c '
  reject=$(grep -n "^-A INPUT -j REJECT" <<<"$1" | cut -d: -f1)
  for p in "tcp.*--dport 80 " "tcp.*--dport 443 " "udp.*--dport 443 " "tcp.*--dport 8322 "; do
    line=$(grep -n -- "-A INPUT -p ${p}" <<<"$1" | head -n1 | cut -d: -f1)
    [ -n "$line" ] && [ "$line" -lt "$reject" ] || exit 1
  done' _ "$rules"

# 7. Backup to the bucket (Floci as R2) and restore.
if [ "$RUN_BACKUP" = 1 ]; then
  check "te-tengo-backup.timer is scheduled" docker exec "$HOST" systemctl is-enabled --quiet te-tengo-backup.timer
  docker exec "$HOST" systemctl start te-tengo-backup.service
  check "te-tengo-backup.service dumps PostgreSQL" [ $? -eq 0 ]
  listing=$(docker exec "$HOST" sh -c 'set -a; . /etc/te-tengo/backup.env; aws s3 ls s3://te-tengo-backups/postgres/ --endpoint-url http://floci.test:4566' 2>&1)
  check "The dump is in s3://te-tengo-backups/postgres/ (Floci as R2, static keys)" grep -q 'te-tengo-.*\.dump' <<<"$listing"

  psql_host </dev/null -c "delete from instalaciones where hogar_id = '$household'" >/dev/null
  docker exec "$HOST" /usr/local/sbin/te-tengo-restore latest >/dev/null 2>&1
  check "te-tengo-restore latest restores the dump from the bucket" [ $? -eq 0 ]
  for _ in $(seq 1 60); do
    [ "$(curl -s --cacert "$CA" "$BASE/actuator/health" | jq -r .status 2>/dev/null)" = UP ] && break
    sleep 3
  done
  restored=$(psql_host </dev/null -c "select count(*) from instalaciones where hogar_id = '$household'")
  check "The restored database has the data deleted after the backup" [ "$restored" = 1 ]
  r=$(call POST /api/sesiones "$(jq -nc --arg c "$email" --arg p "$password" '{correo:$c,contrasena:$p}')")
  check "Sign-in works again after the restore" [ "$(code "$r")" = 200 ]
fi

echo
echo "== Summary"
printf '%s\n' "${results[@]}"
total=${#results[@]}
failures=$(printf '%s\n' "${results[@]}" | grep -c '^FAIL' || true)
echo "== $((total - failures))/$total checks passed"
exit "$failed"
