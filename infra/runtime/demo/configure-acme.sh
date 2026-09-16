#!/usr/bin/env bash

set -euo pipefail

readonly ORIGIN_HOSTNAME="origin-demo.yoonec.dev"
readonly LETS_ENCRYPT_DIRECTORY="https://acme-v02.api.letsencrypt.org/directory"
readonly CERTBOT_LIVE_DIRECTORY="/etc/letsencrypt/live/$ORIGIN_HOSTNAME"
readonly CERTBOT_RENEWAL_CONFIG="/etc/letsencrypt/renewal/$ORIGIN_HOSTNAME.conf"
readonly ORIGIN_CERT_FILE="$CERTBOT_LIVE_DIRECTORY/fullchain.pem"
readonly ORIGIN_KEY_FILE="$CERTBOT_LIVE_DIRECTORY/privkey.pem"
readonly RENEW_SCRIPT_TARGET="/usr/local/sbin/ec-portfolio-renew-origin-cert"
readonly SYNC_SCRIPT_SOURCE="sync-origin-tls.sh"
# Overridable so the write-back contract can be exercised against a fake
# helper in tests, the same way DEPLOY_API_SCRIPT is overridden elsewhere.
readonly SYNC_SCRIPT_TARGET="${ORIGIN_TLS_SYNC_SCRIPT:-/usr/local/sbin/ec-portfolio-sync-origin-tls}"
readonly ORIGIN_TLS_ENV_DIRECTORY="/etc/ec-portfolio"
readonly ORIGIN_TLS_ENV_FILE="$ORIGIN_TLS_ENV_DIRECTORY/origin-tls.env"
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

    # Issuance without a durable backup is the state Phase 6B exists to remove:
    # the certificate would live only on this host's disk and a replacement host
    # would have to ask Let's Encrypt for a new one.
    [[ -n "${ORIGIN_TLS_BUCKET:-}" ]] ||
        fail "Required environment variable is missing: ORIGIN_TLS_BUCKET"
    [[ "$ORIGIN_TLS_BUCKET" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] ||
        fail "ORIGIN_TLS_BUCKET is not a valid bucket name."

    for variable_name in \
        AWS_ACCESS_KEY_ID \
        AWS_SECRET_ACCESS_KEY \
        AWS_SESSION_TOKEN \
        AWS_SECURITY_TOKEN \
        AWS_PROFILE \
        AWS_DEFAULT_PROFILE \
        AWS_CREDENTIAL_FILE \
        AWS_SHARED_CREDENTIALS_FILE \
        AWS_CONFIG_FILE \
        AWS_WEB_IDENTITY_TOKEN_FILE \
        AWS_ROLE_ARN \
        AWS_CONTAINER_CREDENTIALS_FULL_URI \
        AWS_CONTAINER_CREDENTIALS_RELATIVE_URI \
        AWS_EC2_METADATA_DISABLED \
        AWS_EC2_METADATA_SERVICE_ENDPOINT \
        AWS_EC2_METADATA_SERVICE_ENDPOINT_MODE \
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
    [[ -f "$script_directory/$SYNC_SCRIPT_SOURCE" && -x "$script_directory/$SYNC_SCRIPT_SOURCE" ]] ||
        fail "The bundled origin TLS backup script is missing or not executable."
}

# Certbot loads two configuration files automatically, before any flag on the
# command line is considered (certbot/_internal/constants.py, CLI_DEFAULTS
# "config_files"; configargparse globs each through os.path.expanduser):
#
#   /etc/letsencrypt/cli.ini
#   ${XDG_CONFIG_HOME:-~/.config}/letsencrypt/cli.ini
#
# Either may declare pre-hook, post-hook or deploy-hook, which certbot runs as
# root, and either may override --server, --authenticator or --config-dir.
# --no-directory-hooks does not help: it disables renewal-hooks/ directories and
# nothing else.
#
# The second path is caller controlled, and its resolution has edges not worth
# reproducing in shell. Measured against certbot directly:
#
#   XDG unset, HOME=/root        -> /root/.config/letsencrypt/cli.ini
#   XDG unset, HOME=/tmp/x       -> /tmp/x/.config/letsencrypt/cli.ini
#   XDG=""                       -> $PWD/letsencrypt/cli.ini
#   XDG="rel"                    -> $PWD/rel/letsencrypt/cli.ini
#   XDG=/tmp/x                   -> /tmp/x/letsencrypt/cli.ini
#
# os.environ.get() returns its default only when the name is absent, so an empty
# XDG_CONFIG_HOME is joined as an empty segment and the path becomes relative to
# the working directory. So the environment is pinned instead of predicted:
# run_certbot clears XDG_CONFIG_HOME and sets HOME to CERTBOT_HOME, which fixes
# the lookup to the two paths below. The same constant builds both, so the path
# this checks and the path certbot reads cannot drift apart.
readonly CERTBOT_HOME="/root"

# Test seam. Empty in production, so the entries below are the literal canonical
# paths; the suite sets it to a sandbox root to exercise the contract without
# touching the host.
readonly CERTBOT_CONFIG_PREFIX="${CERTBOT_CONFIG_PREFIX:-}"

readonly GLOBAL_CERTBOT_CONFIG_FILE="${CERTBOT_CONFIG_PREFIX}/etc/letsencrypt/cli.ini"
readonly USER_CERTBOT_CONFIG_FILE="${CERTBOT_CONFIG_PREFIX}${CERTBOT_HOME}/.config/letsencrypt/cli.ini"

# /etc/letsencrypt/cli.ini is not ours to forbid. On Amazon Linux 2023 it
# belongs to the certbot RPM and is written by every install, carrying only the
# packaging defaults:
#
#   preconfigured-renewal = True
#   max-log-backups = 0
#
# Refusing the file outright would block renewal on every host that has certbot
# installed, and would block issuance on every replacement host the moment
# `dnf install certbot` put it back -- which is exactly the host Phase 6B
# exists for. So the file is allowed to exist and is held to a contract instead:
# it must still be the file the package wrote, and it must say only these two
# things. Anything else -- a hook, another server, another config-dir, a key
# this project has never heard of -- fails closed.
readonly PACKAGE_CERTBOT_CONFIG_OWNER="certbot"
readonly ALLOWED_GLOBAL_CONFIG_KEYS=(
    "preconfigured-renewal"
    "max-log-backups"
)

# Narrow on purpose. A value check is what stops "max-log-backups = 0 ; pre-hook
# = ..." style smuggling through a key that is itself allowed.
global_config_value_is_allowed() {
    local key="$1" value="$2"

    case "$key" in
        preconfigured-renewal) [[ "$value" =~ ^(True|False)$ ]] ;;
        max-log-backups) [[ "$value" =~ ^[0-9]{1,4}$ ]] ;;
        *) return 1 ;;
    esac
}

key_is_allowed() {
    local candidate="$1" allowed

    for allowed in "${ALLOWED_GLOBAL_CONFIG_KEYS[@]}"; do
        [[ "$candidate" == "$allowed" ]] && return 0
    done
    return 1
}

# Every directive must be one of the allowed keys with an allowed value. The
# file is read with a redirect rather than a pipe, so the loop body runs in this
# shell and a fail() inside it actually ends the script.
verify_global_config_directives() {
    local file="$1"
    local line key value

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Comments and blank lines only. A trailing comment is not stripped:
        # certbot does not treat '#' as an inline comment in a value, so
        # ignoring it here would let one hide a directive from this check.
        [[ "$line" =~ ^[[:space:]]*(#|\;) ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue

        [[ "$line" == *=* ]] ||
            fail "The Certbot global configuration has a line that is not a directive."

        key="${line%%=*}"
        value="${line#*=}"
        # Trim surrounding whitespace without a subshell.
        key="${key#"${key%%[![:space:]]*}"}"; key="${key%"${key##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"; value="${value%"${value##*[![:space:]]}"}"

        key_is_allowed "$key" ||
            fail "The Certbot global configuration declares an unexpected directive: $key. Only the certbot package defaults are allowed here; this project passes every option on the command line."
        global_config_value_is_allowed "$key" "$value" ||
            fail "The Certbot global configuration sets $key to a value this contract does not allow."
    done <"$file"
}

# Ownership and integrity are asked of rpm, which is the only thing that knows
# what the package wrote. Both are treated as required answers: a missing rpm,
# an unowned file or a modified one ends the run. `rpm -qf` without
# --queryformat exits 0 even for a file no package owns, so the queryformat form
# is used and the name is compared as well as the status.
verify_global_config_is_package_file() {
    local file="$1"
    local owner status

    command -v rpm >/dev/null 2>&1 ||
        fail "Unable to verify $file: rpm is not available, so package ownership cannot be established."

    owner="$(rpm -qf --queryformat '%{NAME}\n' "$file" 2>/dev/null)" && status=0 || status=$?
    (( status == 0 )) ||
        fail "$file is not owned by any RPM package. This project does not create a Certbot global configuration; remove it or move it aside before re-running."
    [[ "$owner" == "$PACKAGE_CERTBOT_CONFIG_OWNER" ]] ||
        fail "$file is owned by '$owner' rather than the certbot package."

    rpm -Vf "$file" >/dev/null 2>&1 ||
        fail "$file differs from what the certbot package installed. It has been modified; review it before re-running. This script will not change it."
}

# Runs immediately before certbot, after any package installation that could
# have created the file. Checking earlier would pass on a host where certbot is
# not installed yet and then let the install write a configuration nobody looked
# at.
verify_global_certbot_config_contract() {
    # The per-user path is still refused outright: no package writes it, this
    # project never creates it, and there is no benign reason for it to exist.
    # -L as well as -e, because a dangling symlink is a path certbot would read
    # as soon as its target appeared.
    [[ ! -e "$USER_CERTBOT_CONFIG_FILE" && ! -L "$USER_CERTBOT_CONFIG_FILE" ]] ||
        fail "A per-user Certbot configuration exists: $USER_CERTBOT_CONFIG_FILE. This project does not use one; remove it before re-running."

    if [[ -L "$GLOBAL_CERTBOT_CONFIG_FILE" ]]; then
        fail "$GLOBAL_CERTBOT_CONFIG_FILE is a symlink. The certbot package installs a regular file; a symlink here is not package state."
    fi

    # Absent is fine and is the state on a host where certbot has not been
    # installed yet. There is nothing for certbot to read.
    [[ -e "$GLOBAL_CERTBOT_CONFIG_FILE" ]] || return 0

    [[ -f "$GLOBAL_CERTBOT_CONFIG_FILE" ]] ||
        fail "$GLOBAL_CERTBOT_CONFIG_FILE exists but is not a regular file."

    verify_global_config_is_package_file "$GLOBAL_CERTBOT_CONFIG_FILE"
    verify_global_config_directives "$GLOBAL_CERTBOT_CONFIG_FILE"
}

run_certbot() {
    run_with_timeout "$CERTBOT_TIMEOUT_SECONDS" env \
        -u XDG_CONFIG_HOME \
        -u AWS_ACCESS_KEY_ID \
        -u AWS_SECRET_ACCESS_KEY \
        -u AWS_SESSION_TOKEN \
        -u AWS_SECURITY_TOKEN \
        -u AWS_PROFILE \
        -u AWS_DEFAULT_PROFILE \
        -u AWS_CREDENTIAL_FILE \
        -u AWS_WEB_IDENTITY_TOKEN_FILE \
        -u AWS_ROLE_ARN \
        -u AWS_CONTAINER_CREDENTIALS_FULL_URI \
        -u AWS_CONTAINER_CREDENTIALS_RELATIVE_URI \
        -u AWS_EC2_METADATA_DISABLED \
        -u AWS_EC2_METADATA_SERVICE_ENDPOINT \
        -u AWS_EC2_METADATA_SERVICE_ENDPOINT_MODE \
        -u AWS_ENDPOINT_URL \
        -u AWS_ENDPOINT_URL_ROUTE53 \
        -u AWS_CA_BUNDLE \
        -u REQUESTS_CA_BUNDLE \
        -u SSL_CERT_FILE \
        -u SSL_CERT_DIR \
        HOME="$CERTBOT_HOME" \
        AWS_SHARED_CREDENTIALS_FILE=/dev/null \
        AWS_CONFIG_FILE=/dev/null \
        BOTO_CONFIG=/dev/null \
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

# The renewal timer runs the installed script from /usr/local/sbin, where the
# deployment bundle is not present, so the backup helper is installed to a fixed
# path too. The bucket name is account specific and generated, so it is written
# to a non-secret env file the unit reads rather than baked into a committed
# unit file.
install_origin_tls_backup() {
    install -o root -g root -m 755 \
        "$script_directory/$SYNC_SCRIPT_SOURCE" "$SYNC_SCRIPT_TARGET"

    install -d -o root -g root -m 755 "$ORIGIN_TLS_ENV_DIRECTORY"
    printf 'ORIGIN_TLS_BUCKET=%s\n' "$ORIGIN_TLS_BUCKET" >"$ORIGIN_TLS_ENV_FILE.tmp"
    install -o root -g root -m 644 "$ORIGIN_TLS_ENV_FILE.tmp" "$ORIGIN_TLS_ENV_FILE"
    rm -f "$ORIGIN_TLS_ENV_FILE.tmp"
}

# Durability step. It never touches the certificate files or Nginx, so a failure
# here leaves the freshly issued certificate and the running Nginx exactly as
# they are; only the off-host copy is missing, and that is reported rather than
# swallowed.
#
# A future phase will gate this on holding the origin EIP so only the active
# host writes. That gate belongs around this call.
back_up_origin_tls_state() {
    log "Backing up the origin TLS state."
    ORIGIN_TLS_BUCKET="$ORIGIN_TLS_BUCKET" "$SYNC_SCRIPT_TARGET" backup ||
        fail "The certificate is valid and installed, but the off-host backup failed. The local certificate and Nginx are untouched; re-run the backup before relying on host replacement."
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
        # ORIGIN_TLS_BUCKET must survive the re-exec: validate_inputs runs after
        # it, so dropping the variable here would fail every non-root run.
        exec sudo --preserve-env=ACME_EMAIL,ORIGIN_TLS_BUCKET,AWS_REGION,AWS_DEFAULT_REGION -- "$0" "$@"
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

    # After the package install, not before it. On a host without certbot the
    # file does not exist yet, so an earlier check would pass and then let dnf
    # write a global configuration that nothing looked at before certbot read
    # it. This is the last gate before certbot runs.
    verify_global_certbot_config_contract

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
    install_origin_tls_backup
    install_renewal_units
    back_up_origin_tls_state

    log "Certificate issuance and automatic renewal configuration completed successfully."
    log "The certificate paths satisfy the configure-origin.sh input contract."
}

# Sourcing exposes the contract functions to the test suite without running an
# issuance or a renewal. The same guard is used by deploy-api.sh and
# deploy-runtime.sh.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
