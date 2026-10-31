#!/usr/bin/env bash
# Sourced by test/prepare.sh and test/smoke.sh: Azurite's development account and a helper that signs an
# account SAS with its key, on macOS and Linux. The account name and key are Azurite's published,
# well-known development values (documented by Microsoft for the emulator), not secrets.
# shellcheck disable=SC2034
AZURITE_ACCOUNT=devstoreaccount1
AZURITE_KEY='Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw=='
# Inside the test network (the API, the backup job) and as published on the Mac.
AZURITE_HOST=10.231.0.10:10000
AZURITE_MAC="${TT_TEST_AZURITE_MAC:-127.0.0.1:31000}"

azurite_urlencode() {
  local s="$1" out="" c
  while [ -n "$s" ]; do
    c="${s:0:1}"
    s="${s:1}"
    case "$c" in
      [A-Za-z0-9.~_-]) out+="$c" ;;
      *) out+="$(printf '%%%02X' "'$c")" ;;
    esac
  done
  printf '%s' "$out"
}

# azurite_sas [permissions] -> query string of a one-hour account SAS for the blob service.
azurite_sas() {
  local permissions="${1:-rwdlac}" version=2021-12-02 expiry hexkey signature
  expiry="$(date -u -v+1H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)"
  hexkey="$(printf '%s' "$AZURITE_KEY" | openssl base64 -d -A | od -An -v -tx1 | tr -d ' \n')"
  signature="$(printf '%s\n' "$AZURITE_ACCOUNT" "$permissions" b sco "" "$expiry" "" https,http "$version" "" \
    | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$hexkey" -binary | openssl base64 -A)"
  printf 'sv=%s&ss=b&srt=sco&sp=%s&se=%s&spr=https,http&sig=%s' \
    "$version" "$permissions" "$(azurite_urlencode "$expiry")" "$(azurite_urlencode "$signature")"
}
