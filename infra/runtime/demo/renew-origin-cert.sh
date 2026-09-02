#!/usr/bin/env bash

set -euo pipefail

readonly ORIGIN_HOSTNAME="origin-demo.yoonec.dev"
readonly LETS_ENCRYPT_DIRECTORY="https://acme-v02.api.letsencrypt.org/directory"
readonly CERTBOT_LIVE_DIRECTORY="/etc/letsencrypt/live/$ORIGIN_HOSTNAME"
readonly CERTBOT_RENEWAL_CONFIG="/etc/letsencrypt/renewal/$ORIGIN_HOSTNAME.conf"
readonly ORIGIN_CERT_FILE="$CERTBOT_LIVE_DIRECTORY/fullchain.pem"
readonly ORIGIN_KEY_FILE="$CERTBOT_LIVE_DIRECTORY/privkey.pem"
readonly NGINX_ORIGIN_CONFIG="/etc/nginx/ec-portfolio-demo/origin-server.conf"
readonly CERTBOT_TIMEOUT_SECONDS="15m"
readonly SYSTEMCTL_TIMEOUT_SECONDS="30s"
readonly TIMEOUT_KILL_AFTER_SECONDS="5s"

log() {
    printf '[acme-renew] %s\n' "$*"
}

fail() {
    printf '[acme-renew] ERROR: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command is not available: $1"
}

run_with_timeout() {
    local duration="$1"
    shift
    timeout --signal=TERM --kill-after="$TIMEOUT_KILL_AFTER_SECONDS" "$duration" "$@"
}

run_systemctl() {
    run_with_timeout "$SYSTEMCTL_TIMEOUT_SECONDS" systemctl "$@"
}

validate_platform() {
    local command_name

    [[ -r /etc/os-release ]] || fail "Cannot identify the operating system."
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ "${ID:-}" == "amzn" && "${VERSION_ID:-}" == 2023* ]] ||
        fail "Amazon Linux 2023 is required."

    for command_name in awk certbot env grep openssl sha256sum stat systemctl timeout; do
        require_command "$command_name"
    done
}

validate_inputs() {
    local variable_name

    (( $# == 0 )) || fail "This script does not accept arguments."

    for variable_name in \
        AWS_ACCESS_KEY_ID \
        AWS_SECRET_ACCESS_KEY \
        AWS_SESSION_TOKEN \
        AWS_SECURITY_TOKEN \
        AWS_PROFILE \
        AWS_DEFAULT_PROFILE \
        AWS_SHARED_CREDENTIALS_FILE \
        AWS_CONFIG_FILE \
        AWS_WEB_IDENTITY_TOKEN_FILE \
        AWS_ROLE_ARN \
        AWS_CONTAINER_CREDENTIALS_FULL_URI \
        AWS_CONTAINER_CREDENTIALS_RELATIVE_URI \
        AWS_EC2_METADATA_DISABLED \
        AWS_ENDPOINT_URL \
        AWS_ENDPOINT_URL_ROUTE53 \
        AWS_CA_BUNDLE \
        REQUESTS_CA_BUNDLE \
        SSL_CERT_FILE \
        SSL_CERT_DIR \
        BOTO_CONFIG; do
        [[ -z "${!variable_name:-}" ]] ||
            fail "Static or delegated AWS credential input is prohibited: $variable_name"
    done

    [[ ! -e /root/.aws/credentials && ! -e /root/.aws/config ]] ||
        fail "AWS credential or config files are prohibited; use the EC2 instance role."
}

run_certbot() {
    run_with_timeout "$CERTBOT_TIMEOUT_SECONDS" env \
        -u AWS_ACCESS_KEY_ID \
        -u AWS_SECRET_ACCESS_KEY \
        -u AWS_SESSION_TOKEN \
        -u AWS_SECURITY_TOKEN \
        -u AWS_PROFILE \
        -u AWS_DEFAULT_PROFILE \
        -u AWS_WEB_IDENTITY_TOKEN_FILE \
        -u AWS_ROLE_ARN \
        -u AWS_CONTAINER_CREDENTIALS_FULL_URI \
        -u AWS_CONTAINER_CREDENTIALS_RELATIVE_URI \
        -u AWS_EC2_METADATA_DISABLED \
        -u AWS_ENDPOINT_URL \
        -u AWS_ENDPOINT_URL_ROUTE53 \
        -u AWS_CA_BUNDLE \
        -u REQUESTS_CA_BUNDLE \
        -u SSL_CERT_FILE \
        -u SSL_CERT_DIR \
        -u BOTO_CONFIG \
        AWS_SHARED_CREDENTIALS_FILE=/dev/null \
        AWS_CONFIG_FILE=/dev/null \
        "$@"
}

validate_renewal_configuration() {
    [[ -f "$CERTBOT_RENEWAL_CONFIG" ]] ||
        fail "The Certbot renewal configuration is missing."
    grep -Fqx "server = $LETS_ENCRYPT_DIRECTORY" "$CERTBOT_RENEWAL_CONFIG" ||
        fail "The certificate is not configured for the Let's Encrypt production endpoint."
    grep -Fqx 'authenticator = dns-route53' "$CERTBOT_RENEWAL_CONFIG" ||
        fail "The certificate is not configured for the Route 53 DNS authenticator."
    if grep -Eq '^[[:space:]]*(pre_hook|post_hook|renew_hook|deploy_hook)[[:space:]]*=' \
        "$CERTBOT_RENEWAL_CONFIG"; then
        fail "External Certbot renewal hooks are prohibited by the managed renewal contract."
    fi
}

validate_certificate_contract() {
    local certificate_public_key_hash
    local key_mode
    local key_mode_value
    local key_owner
    local private_public_key_hash
    local san_output
    local validity_requirement="${1:-current}"

    [[ -f "$ORIGIN_CERT_FILE" && -r "$ORIGIN_CERT_FILE" ]] ||
        fail "The origin full certificate chain is missing or unreadable."
    [[ -f "$ORIGIN_KEY_FILE" && -r "$ORIGIN_KEY_FILE" ]] ||
        fail "The origin private key is missing or unreadable."

    read -r key_owner key_mode < <(stat -Lc '%u %a' "$ORIGIN_KEY_FILE")
    [[ "$key_owner" == "0" ]] || fail "The origin private key must be owned by root."
    key_mode_value=$((8#$key_mode))
    (( (key_mode_value & 0400) != 0 && (key_mode_value & 0077) == 0 )) ||
        fail "The origin private key must be readable only by root."

    openssl x509 -in "$ORIGIN_CERT_FILE" -noout >/dev/null 2>&1 ||
        fail "The origin certificate is invalid."
    if [[ "$validity_requirement" == "current" ]]; then
        openssl x509 -in "$ORIGIN_CERT_FILE" -noout -checkend 0 >/dev/null 2>&1 ||
            fail "The renewed origin certificate is expired."
    elif [[ "$validity_requirement" != "allow-expired" ]]; then
        fail "Unknown certificate validity requirement."
    fi
    openssl pkey -in "$ORIGIN_KEY_FILE" -passin pass: -noout >/dev/null 2>&1 ||
        fail "The origin private key is invalid or requires interactive input."

    san_output="$(
        openssl x509 -in "$ORIGIN_CERT_FILE" -noout -ext subjectAltName |
            awk 'NR > 1 { gsub(/[[:space:]]/, ""); printf "%s", $0 }'
    )"
    [[ "$san_output" == "DNS:$ORIGIN_HOSTNAME" ]] ||
        fail "The certificate must contain only the architecture-approved origin SAN."

    certificate_public_key_hash="$({
        openssl x509 -in "$ORIGIN_CERT_FILE" -pubkey -noout |
            openssl pkey -pubin -outform DER
    } | sha256sum | awk '{print $1}')"
    private_public_key_hash="$({
        openssl pkey -in "$ORIGIN_KEY_FILE" -passin pass: -pubout -outform DER
    } | sha256sum | awk '{print $1}')"
    [[ "$certificate_public_key_hash" == "$private_public_key_hash" ]] ||
        fail "The origin certificate and private key do not match."

    validate_renewal_configuration
}

reload_nginx_after_change() {
    if ! command -v nginx >/dev/null 2>&1; then
        log "Nginx is not installed; certificate renewal completed without reload."
        return
    fi
    if [[ ! -f "$NGINX_ORIGIN_CONFIG" ]]; then
        log "The Demo origin configuration is not installed; certificate renewal completed without reload."
        return
    fi
    if ! run_systemctl is-active --quiet nginx; then
        log "Nginx is not active; certificate renewal completed without reload."
        return
    fi

    log "Validating Nginx before loading the renewed certificate."
    run_with_timeout "$SYSTEMCTL_TIMEOUT_SECONDS" nginx -t >/dev/null ||
        fail "Nginx configuration validation failed or timed out."
    run_systemctl reload nginx || fail "Nginx reload failed or timed out."
}

main() {
    local certificate_hash_after
    local certificate_hash_before

    (( EUID == 0 )) || fail "This script must run as root."
    validate_platform
    validate_inputs "$@"
    umask 077
    validate_certificate_contract allow-expired

    certificate_hash_before="$(sha256sum "$ORIGIN_CERT_FILE" | awk '{print $1}')"
    log "Checking the architecture-approved certificate for renewal."
    run_certbot certbot renew \
        --non-interactive \
        --server "$LETS_ENCRYPT_DIRECTORY" \
        --cert-name "$ORIGIN_HOSTNAME" \
        --no-directory-hooks ||
        fail "Certificate renewal failed or timed out; the existing certificate remains in place."

    validate_certificate_contract
    certificate_hash_after="$(sha256sum "$ORIGIN_CERT_FILE" | awk '{print $1}')"

    if [[ "$certificate_hash_before" == "$certificate_hash_after" ]]; then
        log "The certificate is not due for renewal; Nginx reload is unnecessary."
        return
    fi

    reload_nginx_after_change
    log "Certificate renewal completed successfully."
}

main "$@"
