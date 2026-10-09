#!/usr/bin/env bash
# Smoke test of the deployed test host, from the Mac, through Caddy over HTTPS (make test-smoke).
# Checks: health, HSTS, hidden endpoints, sign-up and sign-in, an agent's pre-signed clip URL on
# Floci standing in for Cloudflare R2 (and the upload itself), HLS 401 without a token, RTSPS with
# Caddy's certificate, live view end to end (an ffmpeg container publishes over RTSPS like the agent;
# LL-HLS and WebRTC/WHEP are read through Caddy with the session's token: 201 with an SDP answer that
# announces the ICE port over UDP and TCP, 401 without it or once the session is closed), the production-shaped settings (R2-style keys, no AWS credentials; the OCI image
# firewall opened on OCI and left alone on Azure), and a backup to the bucket restored back. Prints a PASS/FAIL summary; exit code 1 on any failure.
set -uo pipefail
cd "$(dirname "$0")"

BASE="${TT_TEST_BASE:-https://localhost:18443}"
RTSPS="${TT_TEST_RTSPS:-localhost:18322}"
FLOCI_MAC="${TT_TEST_FLOCI_MAC:-127.0.0.1:34566}"
FLOCI_HOST="floci.test:4566"
HOST=tt-test-host
# Plays the household agent (publishes over RTSPS from outside the 1 GiB test host); same image as the
# API's MediaMTX integration test.
FFMPEG_IMAGE="${TT_TEST_FFMPEG_IMAGE:-bluenviron/mediamtx:1.21.1-ffmpeg}"
PUBLISHER=tt-test-publisher
WEBRTC_PORT="${TT_TEST_WEBRTC_PORT:-8189}"
APP_DIR=/opt/te-tengo
WORK=.work
CA="$WORK/caddy-root.crt"
RUN_BACKUP="${TT_TEST_BACKUP:-1}"
# cloud_provider the host was deployed with (make test-deploy TEST_CLOUD=...): azure or oci.
CLOUD="${TT_TEST_CLOUD:-azure}"

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
health_headers=$(mktemp); whep_headers=$(mktemp); whep_body=$(mktemp)
trap 'rm -f "$health_headers" "$whep_headers" "$whep_body"; docker rm -f "$PUBLISHER" >/dev/null 2>&1' EXIT
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
agent=$(body "$r" | jq -r '.token // empty' 2>/dev/null); camera=$(body "$r" | jq -r '.camaraId // empty' 2>/dev/null)
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
for p in udp tcp; do
  check "MediaMTX publishes the WebRTC ICE port $WEBRTC_PORT/$p on the host" \
    grep -q ":$WEBRTC_PORT\$" <<<"$(on_host docker compose port --protocol "$p" mediamtx "$WEBRTC_PORT" 2>/dev/null)"
done
check "The ICE TCP listener answers on the host ($WEBRTC_PORT/tcp)" \
  docker exec "$HOST" bash -c "exec 3<>/dev/tcp/127.0.0.1/$WEBRTC_PORT"

# A recvonly H.264 offer as a browser sends it (no trickle: no candidates). SDP lines end in CRLF, the
# last one too.
offer() {
  printf '%s\r\n' 'v=0' 'o=- 1 2 IN IP4 127.0.0.1' 's=-' 't=0 0' 'a=group:BUNDLE 0' \
    'm=video 9 UDP/TLS/RTP/SAVPF 96' 'c=IN IP4 0.0.0.0' 'a=ice-ufrag:ttsm' 'a=ice-pwd:tetengosmoketestpassword0' \
    'a=fingerprint:sha-256 7B:8B:F0:65:5F:78:E2:51:3B:AC:6F:F3:3F:46:1B:35:DC:B8:5F:64:1A:24:C2:43:F0:A1:58:D0:A1:2C:19:08' \
    'a=setup:actpass' 'a=mid:0' 'a=recvonly' 'a=rtcp-mux' 'a=rtpmap:96 H264/90000' \
    'a=fmtp:96 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f'
}
whep() { # url -> status code; headers and answer in $whep_headers and $whep_body
  offer | curl -sS --cacert "$CA" -o "$whep_body" -D "$whep_headers" -w '%{http_code}' -X POST \
    -H 'Content-Type: application/sdp' --data-binary @- "$1"
}
check "POST /vivo-webrtc/.../whep without a token is rejected (401)" \
  [ "$(whep "$BASE/vivo-webrtc/camaras/$(uuidgen | tr 'A-Z' 'a-z')/whep")" = 401 ]
check "POST /vivo-webrtc/.../whep with an unknown token is rejected (401)" \
  [ "$(whep "$BASE/vivo-webrtc/camaras/$(uuidgen | tr 'A-Z' 'a-z')/whep?token=not-a-session")" = 401 ]
preflight=$(curl -sS --cacert "$CA" -o /dev/null -D - -X OPTIONS "$BASE/vivo-webrtc/camaras/$camera/whep" \
  -H 'Origin: https://app.tetengo.test' -H 'Access-Control-Request-Method: POST' \
  -H 'Access-Control-Request-Headers: content-type')
# shellcheck disable=SC2016
check "WHEP CORS preflight from a browser origin (204 with Access-Control-Allow-Origin)" \
  bash -c 'grep -q "^HTTP/[0-9.]* 204" <<<"$1" && grep -qi "^access-control-allow-origin: " <<<"$1"' _ "$preflight"

# Live view end to end. The camera is online (heartbeat) and has consent; the session's transmission gets
# a publish token the smoke test knows (the agent would receive it over its control channel), and ffmpeg
# publishes over RTSPS like the agent, from outside the test host.
call POST /api/agente/senal '' "$agent" >/dev/null
r=$(call POST "/api/camaras/$camera/vista-en-vivo" '{"alertaId":null}' "$token")
session_id=$(body "$r" | jq -r '.sesionId // empty' 2>/dev/null)
hls_url=$(body "$r" | jq -r '.urlTransmision // empty' 2>/dev/null)
viewer_token=${hls_url#*\?token=}
check "POST /api/camaras/{id}/vista-en-vivo opens a session (201)" [ "$(code "$r")" = 201 -a -n "$session_id" ]
api_webrtc=$(body "$r" | jq -r '.urlWebrtc // empty' 2>/dev/null)
# The API's URLs name the host as the app sees it (https://localhost); from the Mac it is $BASE.
whep_url="$BASE/vivo-webrtc/camaras/$camera/whep?token=$viewer_token"
hls_url="$BASE/vivo/camaras/$camera/index.m3u8?token=$viewer_token"
if [ -n "$api_webrtc" ]; then
  check "The session's urlWebrtc is the WHEP endpoint behind Caddy (TT_VIVO_URL_WEBRTC)" \
    [ "$api_webrtc" = "https://localhost/vivo-webrtc/camaras/$camera/whep?token=$viewer_token" ]
else
  echo "NOTE  this API image predates urlWebrtc (live view v3): the WHEP URL is built from the HLS token"
fi
publish_key="smoke-$(openssl rand -hex 16)"
psql_host -v camara="$camera" -v huella="$(printf '%s' "$publish_key" | openssl dgst -sha256 -r | cut -d' ' -f1)" >/dev/null <<'SQL'
update transmisiones_en_vivo set clave_hash = :'huella' where camara_id = :'camara';
SQL
network=$(docker inspect -f '{{range $name, $_ := .NetworkSettings.Networks}}{{$name}}{{end}}' "$HOST")
docker rm -f "$PUBLISHER" >/dev/null 2>&1
docker run -d --rm --name "$PUBLISHER" --network "$network" --entrypoint ffmpeg "$FFMPEG_IMAGE" \
  -hide_banner -loglevel warning -re -f lavfi -i testsrc=size=640x480:rate=15 -t 120 \
  -c:v libx264 -profile:v baseline -preset ultrafast -tune zerolatency -g 8 -pix_fmt yuv420p \
  -f rtsp -rtsp_transport tcp "rtsps://agente:$publish_key@$HOST:8322/camaras/$camera" >/dev/null
whep_code=000
for _ in $(seq 1 45); do
  whep_code=$(whep "$whep_url")
  [ "$whep_code" = 404 ] || break  # 404: authorized, the publisher is not on the path yet
  sleep 1
done
check "POST /vivo-webrtc/.../whep with the session's token answers 201 (WHEP through Caddy)" [ "$whep_code" = 201 ]
# shellcheck disable=SC2016
check "The WHEP answer is SDP and sends H.264 Constrained Baseline" \
  bash -c 'grep -qi "^content-type: application/sdp" "$1" && head -1 "$2" | grep -q "^v=0" && grep -q "a=sendonly" "$2" && grep -q "profile-level-id=42e01f" "$2"' _ "$whep_headers" "$whep_body"
check "The WHEP answer announces 127.0.0.1:$WEBRTC_PORT over UDP (webrtcAdditionalHosts = public_ip)" \
  grep -Eq "^a=candidate:[^ ]+ 1 udp [0-9]+ 127\.0\.0\.1 $WEBRTC_PORT typ host" "$whep_body"
check "The WHEP answer announces 127.0.0.1:$WEBRTC_PORT over TCP (networks that block UDP)" \
  grep -Eq "^a=candidate:[^ ]+ 1 tcp [0-9]+ 127\.0\.0\.1 $WEBRTC_PORT typ host tcptype passive" "$whep_body"
# shellcheck disable=SC2016
check "The WHEP answer announces no container address" bash -c '! grep -Eq "^a=candidate:.* (172\.|10\.|192\.168\.)" "$1"' _ "$whep_body"
location=$(tr -d '\r' <"$whep_headers" | awk 'tolower($1) == "location:" { print $2 }')
check "The WHEP session Location keeps the /vivo-webrtc/ prefix (Caddy header_down)" \
  grep -q "^/vivo-webrtc/camaras/$camera/whep/" <<<"$location"
check "DELETE of the WHEP session through Caddy ends it (200)" \
  [ "$(curl -sS --cacert "$CA" -o /dev/null -w '%{http_code}' -X DELETE "$BASE$location")" = 200 ]
# The LL-HLS muxer starts with the first request and needs a few segments before its first playlist.
hls_code=000
for _ in $(seq 1 30); do
  hls_code=$(curl -sS -L --cacert "$CA" -o /dev/null -w '%{http_code}' "$hls_url")
  [ "$hls_code" = 200 ] && break
  sleep 1
done
check "GET /vivo/.../index.m3u8 with the session's token serves the LL-HLS playlist (200, fallback)" [ "$hls_code" = 200 ]
check "DELETE /api/vista-en-vivo/{id} closes the session (204)" \
  [ "$(code "$(call DELETE "/api/vista-en-vivo/$session_id" '' "$token")")" = 204 ]
check "WHEP with the token of the closed session is rejected (401)" [ "$(whep "$whep_url")" = 401 ]
docker rm -f "$PUBLISHER" >/dev/null 2>&1

rtsps_subject=$(openssl s_client -connect "$RTSPS" -servername localhost -CAfile "$CA" -verify_return_error </dev/null 2>/dev/null \
  | openssl x509 -noout -ext subjectAltName 2>/dev/null | tr -d ' \n')
check "RTSPS on 8322 presents Caddy's certificate for the host name" grep -q 'DNS:localhost' <<<"$rtsps_subject"

# 6. Production-shaped configuration: R2-style object storage with static keys, no AWS credentials,
#    and the OCI image firewall: opened by the base role on OCI, untouched on Azure (the NSG is the
#    firewall there and Canonical's Azure image has no such policy).
# The bash -c bodies below are single-quoted on purpose: the file contents arrive as $1.
api_env=$(docker exec "$HOST" cat "$APP_DIR/api.env")
# shellcheck disable=SC2016
check "api.env signs clips with static keys on an S3-compatible endpoint (R2 style)" \
  bash -c 'grep -q "^TT_CLIPS_ENDPOINT=.http://floci.test:4566" <<<"$1" && grep -q "^TT_CLIPS_PATH_STYLE=.true" <<<"$1" && grep -q "^TT_CLIPS_ACCESS_KEY=" <<<"$1"' _ "$api_env"
# shellcheck disable=SC2016
check "api.env holds no AWS credentials" bash -c '! grep -q "^AWS_" <<<"$1"' _ "$api_env"
rules=$(docker exec "$HOST" cat /etc/iptables/rules.v4)
if [ "$CLOUD" != oci ]; then
  # shellcheck disable=SC2016
  check "cloud_provider $CLOUD: the OCI firewall tasks are skipped (rules.v4 untouched)" \
    bash -c '! grep -Eq -- "--dport (80|443|8322) " <<<"$1"' _ "$rules"
else
  # shellcheck disable=SC2016
  check "rules.v4 accepts 80, 443/tcp, 443/udp and 8322 before its INPUT REJECT" bash -c '
    reject=$(grep -n "^-A INPUT -j REJECT" <<<"$1" | cut -d: -f1)
    for p in "tcp.*--dport 80 " "tcp.*--dport 443 " "udp.*--dport 443 " "tcp.*--dport 8322 "; do
      line=$(grep -n -- "-A INPUT -p ${p}" <<<"$1" | head -n1 | cut -d: -f1)
      [ -n "$line" ] && [ "$line" -lt "$reject" ] || exit 1
    done' _ "$rules"
fi

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
