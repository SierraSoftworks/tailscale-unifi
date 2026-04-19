#!/bin/sh

set -eu

cert_uuid="${1:-}"
cert_file="${2:-}"
key_file="${3:-}"
hostname="${4:-$(hostname)}"

if [ -z "$cert_uuid" ] || [ -z "$cert_file" ] || [ -z "$key_file" ]; then
    echo "Usage: $0 <uuid> <cert_file> <key_file> [hostname]"
    exit 1
fi

if [ ! -f "$cert_file" ] || [ ! -f "$key_file" ]; then
    echo "Certificate or key file not found"
    exit 1
fi

escape_sql() {
    sed "s/'/''/g"
}

parse_cert_date() {
    cert_date="$1"

    if date -u -d "$cert_date" "+%Y-%m-%dT%H:%M:%SZ" >/dev/null 2>&1; then
        date -u -d "$cert_date" "+%Y-%m-%dT%H:%M:%SZ"
        return 0
    fi

    if date -j -u -f "%b %e %H:%M:%S %Y %Z" "$cert_date" "+%Y-%m-%dT%H:%M:%SZ" >/dev/null 2>&1; then
        date -j -u -f "%b %e %H:%M:%S %Y %Z" "$cert_date" "+%Y-%m-%dT%H:%M:%SZ"
        return 0
    fi

    return 1
}

run_psql() {
    if command -v sudo >/dev/null 2>&1; then
        sudo -u unifi-core env LANG=C LC_ALL=C psql -v ON_ERROR_STOP=1 -h /run/postgresql -p 5432 -d unifi-core
        return $?
    fi

    if command -v psql >/dev/null 2>&1; then
        env LANG=C LC_ALL=C psql -v ON_ERROR_STOP=1 -h /run/postgresql -p 5432 -U unifi-core -d unifi-core
        return $?
    fi

    echo "PostgreSQL client not found. Cannot register certificate in database."
    exit 1
}

cert_content=$(escape_sql < "$cert_file")
key_content=$(escape_sql < "$key_file")

valid_from=$(date -u "+%Y-%m-%dT%H:%M:%SZ")
valid_to=$(date -u -v+90d "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "+90 days" "+%Y-%m-%dT%H:%M:%SZ")
subject_cn="$hostname"
issuer_cn="Unknown issuer"
serial_number="0"
fingerprint="0"
version="3"

if command -v openssl >/dev/null 2>&1; then
    not_before=$(openssl x509 -noout -startdate -in "$cert_file" | cut -d= -f2-)
    not_after=$(openssl x509 -noout -enddate -in "$cert_file" | cut -d= -f2-)

    parsed_valid_from=$(parse_cert_date "$not_before" 2>/dev/null || true)
    parsed_valid_to=$(parse_cert_date "$not_after" 2>/dev/null || true)

    if [ -n "$parsed_valid_from" ]; then
        valid_from="$parsed_valid_from"
    fi

    if [ -n "$parsed_valid_to" ]; then
        valid_to="$parsed_valid_to"
    fi

    subject_cn=$(openssl x509 -noout -subject -in "$cert_file" | sed -n 's/.*CN[[:space:]]*=[[:space:]]*\([^,/]*\).*/\1/p')
    issuer_cn=$(openssl x509 -noout -issuer -in "$cert_file" | sed -n 's/.*CN[[:space:]]*=[[:space:]]*\([^,/]*\).*/\1/p')
    serial_number=$(openssl x509 -noout -serial -in "$cert_file" | cut -d= -f2-)
    fingerprint=$(openssl x509 -noout -fingerprint -sha256 -in "$cert_file" | cut -d= -f2- | tr -d ':')
    version=$(openssl x509 -noout -text -in "$cert_file" | awk '/Version:/{print $2; exit}')

    if [ -z "$subject_cn" ]; then
        subject_cn="$hostname"
    fi

    if [ -z "$issuer_cn" ]; then
        issuer_cn="Unknown issuer"
    fi

    if [ -z "$serial_number" ]; then
        serial_number="0"
    fi

    if [ -z "$fingerprint" ]; then
        fingerprint="0"
    fi

    if [ -z "$version" ]; then
        version="3"
    fi
fi

cert_name=$(printf "Tailscale Certificate - %s" "$hostname" | escape_sql)
subject_cn_escaped=$(printf "%s" "$subject_cn" | escape_sql)
issuer_cn_escaped=$(printf "%s" "$issuer_cn" | escape_sql)
hostname_escaped=$(printf "%s" "$hostname" | escape_sql)
serial_number_escaped=$(printf "%s" "$serial_number" | escape_sql)
fingerprint_escaped=$(printf "%s" "$fingerprint" | escape_sql)

run_psql <<EOF
INSERT INTO user_certificates (
    id,
    name,
    key,
    cert,
    version,
    serial_number,
    fingerprint,
    subject,
    issuer,
    subject_alt_name,
    valid_from,
    valid_to,
    created_at,
    updated_at
) VALUES (
    '$cert_uuid'::uuid,
    '$cert_name',
    E'$key_content',
    E'$cert_content',
    $version,
    '$serial_number_escaped',
    '$fingerprint_escaped',
    '{"CN":"$subject_cn_escaped"}'::jsonb,
    '{"CN":"$issuer_cn_escaped"}'::jsonb,
    '["$hostname_escaped"]'::jsonb,
    '$valid_from'::timestamp with time zone,
    '$valid_to'::timestamp with time zone,
    NOW(),
    NOW()
) ON CONFLICT (id) DO UPDATE SET
    name = EXCLUDED.name,
    key = EXCLUDED.key,
    cert = EXCLUDED.cert,
    version = EXCLUDED.version,
    serial_number = EXCLUDED.serial_number,
    fingerprint = EXCLUDED.fingerprint,
    subject = EXCLUDED.subject,
    issuer = EXCLUDED.issuer,
    subject_alt_name = EXCLUDED.subject_alt_name,
    valid_from = EXCLUDED.valid_from,
    valid_to = EXCLUDED.valid_to,
    updated_at = NOW();
EOF

echo "Certificate registered in database with UUID: $cert_uuid"
