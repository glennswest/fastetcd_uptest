#!/usr/bin/env bash
# DNS helpers against MicroDNS at 192.168.8.252 (g8.lo zone).
# Idempotent: ensure_a_record can be called repeatedly.

set -euo pipefail

MICRODNS="${MICRODNS:-http://192.168.8.252:8080/api/v1}"
G8_ZONE_ID="${G8_ZONE_ID:-9bed60c8-1664-4183-88f9-a1a21b927edc}"

dns_record_id() {
    local name="$1"
    curl --silent --max-time 5 "${MICRODNS}/zones/${G8_ZONE_ID}/records?limit=500" \
        | python3 -c "
import json, sys
data = json.load(sys.stdin)
for r in data:
    if r['name'] == '$name' and r['data'].get('type') == 'A':
        print(r['id'])
        break
"
}

ensure_a_record() {
    local name="$1"
    local ip="$2"
    local existing
    existing=$(dns_record_id "${name}")
    if [[ -n "${existing}" ]]; then
        # Update in place.
        curl --silent --max-time 5 -X PUT \
            "${MICRODNS}/zones/${G8_ZONE_ID}/records/${existing}" \
            -H 'Content-Type: application/json' \
            -d "{\"data\":{\"type\":\"A\",\"data\":\"${ip}\"},\"ttl\":300}" \
            > /dev/null
        echo "DNS: ${name}.g8.lo -> ${ip} (updated, id=${existing})"
    else
        curl --silent --max-time 5 -X POST \
            "${MICRODNS}/zones/${G8_ZONE_ID}/records" \
            -H 'Content-Type: application/json' \
            -d "{\"name\":\"${name}\",\"ttl\":300,\"data\":{\"type\":\"A\",\"data\":\"${ip}\"},\"enabled\":true}" \
            > /dev/null
        echo "DNS: ${name}.g8.lo -> ${ip} (created)"
    fi
}

delete_a_record() {
    local name="$1"
    local existing
    existing=$(dns_record_id "${name}")
    if [[ -n "${existing}" ]]; then
        curl --silent --max-time 5 -X DELETE \
            "${MICRODNS}/zones/${G8_ZONE_ID}/records/${existing}" \
            > /dev/null
        echo "DNS: ${name}.g8.lo removed (was id=${existing})"
    else
        echo "DNS: ${name}.g8.lo already absent"
    fi
}
