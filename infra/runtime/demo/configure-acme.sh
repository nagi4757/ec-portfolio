#!/usr/bin/env bash

set -euo pipefail

readonly ORIGIN_HOSTNAME="origin-demo.yoonec.dev"
readonly LETS_ENCRYPT_DIRECTORY="https://acme-v02.api.letsencrypt.org/directory"
readonly CERTBOT_LIVE_DIRECTORY="/etc/letsencrypt/live/$ORIGIN_HOSTNAME"
readonly CERTBOT_RENEWAL_CONFIG="/etc/letsencrypt/renewal/$ORIGIN_HOSTNAME.conf"
readonly ORIGIN_CERT_FILE="$CERTBOT_LIVE_DIRECTORY/fullchain.pem"
readonly ORIGIN_KEY_FILE="$CERTBOT_LIVE_DIRECTORY/privkey.pem"
readonly RENEW_SCRIPT_TARGET="/usr/local/sbin/ec-portfolio-renew-origin-cert"
readonly RENEW_SERVICE_NAME="ec-portfolio-certbot-renew.service"
readonly RENEW_TIMER_NAME="ec-portfolio-certbot-renew.timer"
readonly VENDOR_RENEW_TIMER_NAME="certbot-renew.timer"
readonly SYSTEMD_DIRECTORY="/etc/systemd/system"
readonly DNF_TIMEOUT_SECONDS="10m"
readonly CERTBOT_TIMEOUT_SECONDS="15m"
readonly SYSTEMCTL_TIMEOUT_SECONDS="30s"
readonly TIMEOUT_KILL_AFTER_SECONDS="5s"

script_directory=""

log() {
    printf '[acme-configure] %s\n' "$*"
}

fail() {
    printf '[acme-configure] ERROR: %s\n' "$*" >&2
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

    for command_name in awk dirname dnf env grep install openssl sha256sum stat systemctl timeout; do
        require_command "$command_name"
    done
}

validate_inputs() {
    local variable_name

    (( $# == 0 )) || fail "This script does not accept arguments."
    [[ -n "${ACME_EMAIL:-}" ]] || fail "Required environment variable is missing: ACME_EMAIL"
    [[ "$ACME_EMAIL" != *$'\n'* && "$ACME_EMAIL" != *$'\r'* ]] ||
        fail "ACME_EMAIL must not contain line breaks."
    [[ "$ACME_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,63}$ ]] ||
        fail "ACME_EMAIL must be a valid email address."

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

resolve_bundle_paths() {
    local source_directory

    source_directory="$(dirname -- "${BASH_SOURCE[0]}")"
    if ! script_directory="$(cd -- "$source_directory" && pwd -P)"; then
        fail "Cannot resolve the runtime bundle directory."
    fi

    [[ -f "$script_directory/renew-origin-cert.sh" && -x "$script_directory/renew-origin-cert.sh" ]] ||
        fail "The bundled renewal script is missing or not executable."
    [[ -f "$script_directory/$RENEW_SERVICE_NAME" ]] ||
        fail "The bundled renewal service is missing."
    [[ -f "$script_directory/$RENEW_TIMER_NAME" ]] ||
        fail "The bundled renewal timer is missing."
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

    [[ -f "$ORIGIN_CERT_FILE" && -r "$ORIGIN_CERT_FILE" ]] ||
        fail "The issued full certificate chain is missing or unreadable."
    [[ -f "$ORIGIN_KEY_FILE" && -r "$ORIGIN_KEY_FILE" ]] ||
        fail "The issued private key is missing or unreadable."

    read -r key_owner key_mode < <(stat -Lc '%u %a' "$ORIGIN_KEY_FILE")
    [[ "$key_owner" == "0" ]] || fail "The origin private key must be owned by root."
    key_mode_value=$((8#$key_mode))
    (( (key_mode_value & 0400) != 0 && (key_mode_value & 0077) == 0 )) ||
        fail "The origin private key must be readable only by root."

    openssl x509 -in "$ORIGIN_CERT_FILE" -noout -checkend 0 >/dev/null 2>&1 ||
        fail "The origin certificate is invalid or expired."
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

install_renewal_units() {
    install -o root -g root -m 755 \
        "$script_directory/renew-origin-cert.sh" "$RENEW_SCRIPT_TARGET"
    install -o root -g root -m 644 \
        "$script_directory/$RENEW_SERVICE_NAME" "$SYSTEMD_DIRECTORY/$RENEW_SERVICE_NAME"
    install -o root -g root -m 644 \
        "$script_directory/$RENEW_TIMER_NAME" "$SYSTEMD_DIRECTORY/$RENEW_TIMER_NAME"

    run_systemctl daemon-reload
    run_systemctl enable --now "$RENEW_TIMER_NAME"
    run_systemctl is-enabled --quiet "$RENEW_TIMER_NAME" ||
        fail "The certificate renewal timer is not enabled."
    run_systemctl is-active --quiet "$RENEW_TIMER_NAME" ||
        fail "The certificate renewal timer is not active."

    if [[ -e "/usr/lib/systemd/system/$VENDOR_RENEW_TIMER_NAME" ||
        -e "$SYSTEMD_DIRECTORY/$VENDOR_RENEW_TIMER_NAME" ]]; then
        run_systemctl disable --now "$VENDOR_RENEW_TIMER_NAME" ||
            fail "The vendor Certbot timer could not be disabled."
    fi
}

main() {
    if (( EUID != 0 )); then
        require_command sudo
        log "Root privileges are required; re-running with sudo."
        exec sudo --preserve-env=ACME_EMAIL,AWS_REGION,AWS_DEFAULT_REGION -- "$0" "$@"
    fi

    validate_platform
    validate_inputs "$@"
    resolve_bundle_paths
    umask 077

    log "Installing the Certbot Route 53 DNS plugin when necessary."
    run_with_timeout "$DNF_TIMEOUT_SECONDS" \
        dnf install -y certbot python3-certbot-dns-route53 ||
        fail "Certbot package installation failed or timed out."
    require_command certbot

    log "Requesting the architecture-approved origin certificate with DNS-01."
    run_certbot certbot certonly \
        --non-interactive \
        --agree-tos \
        --email "$ACME_EMAIL" \
        --server "$LETS_ENCRYPT_DIRECTORY" \
        --authenticator dns-route53 \
        --preferred-challenges dns-01 \
        --domains "$ORIGIN_HOSTNAME" \
        --cert-name "$ORIGIN_HOSTNAME" \
        --no-directory-hooks \
        --keep-until-expiring ||
        fail "Certificate issuance failed or timed out."

    validate_certificate_contract
    install_renewal_units

    log "Certificate issuance and automatic renewal configuration completed successfully."
    log "The certificate paths satisfy the configure-origin.sh input contract."
}

main "$@"
