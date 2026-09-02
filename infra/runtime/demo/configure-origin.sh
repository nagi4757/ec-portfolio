#!/usr/bin/env bash

set -euo pipefail

readonly ORIGIN_VERIFY_PARAMETER="/ec-portfolio/demo/origin/verify-token"
readonly NGINX_MAIN_CONFIG="/etc/nginx/nginx.conf"
readonly NGINX_RUNTIME_CONFIG_DIRECTORY="/etc/nginx/ec-portfolio-demo"
readonly NGINX_SECRET_CONFIG="$NGINX_RUNTIME_CONFIG_DIRECTORY/origin-secret.conf"
readonly NGINX_SERVER_CONFIG="$NGINX_RUNTIME_CONFIG_DIRECTORY/origin-server.conf"

runtime_directory=""
origin_verify_token=""
configuration_installed="false"
configuration_committed="false"
main_config_existed="false"
secret_config_existed="false"
server_config_existed="false"
runtime_config_directory_existed="false"
nginx_was_active="false"
nginx_was_enabled="false"

log() {
    printf '[origin-configure] %s\n' "$*"
}

fail() {
    printf '[origin-configure] ERROR: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command is not available: $1"
}

restore_file() {
    local target_file="$1"
    local backup_file="$2"
    local existed_before="$3"

    if [[ "$existed_before" == "true" ]]; then
        cp -p -- "$backup_file" "$target_file" || true
    else
        rm -f -- "$target_file" || true
    fi
}

restore_nginx_configuration() {
    restore_file "$NGINX_MAIN_CONFIG" "$runtime_directory/nginx.conf.backup" "$main_config_existed"
    restore_file "$NGINX_SECRET_CONFIG" "$runtime_directory/origin-secret.conf.backup" "$secret_config_existed"
    restore_file "$NGINX_SERVER_CONFIG" "$runtime_directory/origin-server.conf.backup" "$server_config_existed"

    if [[ "$runtime_config_directory_existed" != "true" ]]; then
        rmdir "$NGINX_RUNTIME_CONFIG_DIRECTORY" >/dev/null 2>&1 || true
    fi

    if [[ "$nginx_was_active" == "true" ]]; then
        if nginx -t >/dev/null 2>&1; then
            systemctl reload nginx >/dev/null 2>&1 || true
        fi
    else
        systemctl stop nginx >/dev/null 2>&1 || true
    fi

    if [[ "$nginx_was_enabled" != "true" ]]; then
        systemctl disable nginx >/dev/null 2>&1 || true
    fi
}

cleanup() {
    local exit_code=$?
    trap - EXIT

    if (( exit_code != 0 )) && [[ "$configuration_installed" == "true" && "$configuration_committed" != "true" ]]; then
        restore_nginx_configuration
    fi

    if [[ -n "$runtime_directory" && "$runtime_directory" == /run/ec-portfolio-demo-origin.* ]]; then
        rm -rf -- "$runtime_directory"
    fi

    unset origin_verify_token
    exit "$exit_code"
}

trap cleanup EXIT

require_environment() {
    local variable_name="$1"
    local variable_value="${!variable_name-}"
    [[ -n "$variable_value" ]] || fail "Required environment variable is missing: $variable_name"
}

validate_single_line() {
    local variable_name="$1"
    local variable_value="$2"

    case "$variable_value" in
        *$'\n'* | *$'\r'*)
            fail "$variable_name must not contain line breaks."
            ;;
    esac
}

validate_config_path() {
    local variable_name="$1"
    local variable_value="$2"

    [[ "$variable_value" =~ ^/[A-Za-z0-9_./@+-]+$ ]] ||
        fail "$variable_name must be an absolute path containing only approved characters."
    [[ "$variable_value" != *"//"* && "$variable_value" != *"/../"* && "$variable_value" != */.. ]] ||
        fail "$variable_name must not contain ambiguous path segments."
}

validate_inputs() {
    local certificate_issuer
    local certificate_subject
    local key_mode
    local key_mode_value
    local key_owner
    local variable_name

    (( $# == 0 )) || fail "This script does not accept arguments."

    for variable_name in ORIGIN_SERVER_NAME ORIGIN_CERT_FILE ORIGIN_KEY_FILE; do
        require_environment "$variable_name"
        validate_single_line "$variable_name" "${!variable_name}"
    done

    [[ "$ORIGIN_SERVER_NAME" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ &&
        "$ORIGIN_SERVER_NAME" == *.* && "$ORIGIN_SERVER_NAME" != *..* ]] ||
        fail "ORIGIN_SERVER_NAME must be a valid DNS hostname."

    validate_config_path ORIGIN_CERT_FILE "$ORIGIN_CERT_FILE"
    validate_config_path ORIGIN_KEY_FILE "$ORIGIN_KEY_FILE"
    [[ "$ORIGIN_CERT_FILE" != "$ORIGIN_KEY_FILE" ]] ||
        fail "Certificate and private key paths must be different."

    [[ -f "$ORIGIN_CERT_FILE" && -r "$ORIGIN_CERT_FILE" ]] ||
        fail "The origin certificate file is missing or unreadable."
    [[ -f "$ORIGIN_KEY_FILE" && -r "$ORIGIN_KEY_FILE" ]] ||
        fail "The origin private key file is missing or unreadable."

    read -r key_owner key_mode < <(stat -Lc '%u %a' "$ORIGIN_KEY_FILE")
    [[ "$key_owner" == "0" ]] || fail "The origin private key must be owned by root."
    key_mode_value=$((8#$key_mode))
    (( (key_mode_value & 0400) != 0 && (key_mode_value & 0077) == 0 )) ||
        fail "The origin private key must be readable only by root."

    openssl x509 -in "$ORIGIN_CERT_FILE" -noout >/dev/null 2>&1 ||
        fail "The origin certificate is not a readable X.509 certificate."
    certificate_subject="$(openssl x509 -in "$ORIGIN_CERT_FILE" -noout -subject -nameopt RFC2253)"
    certificate_issuer="$(openssl x509 -in "$ORIGIN_CERT_FILE" -noout -issuer -nameopt RFC2253)"
    [[ "${certificate_subject#subject=}" != "${certificate_issuer#issuer=}" ]] ||
        fail "Self-signed origin certificates are prohibited."
    openssl pkey -in "$ORIGIN_KEY_FILE" -passin pass: -noout >/dev/null 2>&1 ||
        fail "The origin private key is invalid or requires interactive input."
}

validate_platform() {
    local command_name

    [[ -r /etc/os-release ]] || fail "Cannot identify the operating system."
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ "${ID:-}" == "amzn" && "${VERSION_ID:-}" == 2023* ]] ||
        fail "Amazon Linux 2023 is required."

    for command_name in aws cp dnf grep install mktemp openssl rm rmdir ss stat systemctl; do
        require_command "$command_name"
    done
}

read_origin_verify_token() {
    local aws_region="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
    local -a region_arguments=()

    if [[ -n "$aws_region" ]]; then
        [[ "$aws_region" =~ ^[a-z0-9-]{5,32}$ ]] || fail "The configured AWS Region is invalid."
        region_arguments=(--region "$aws_region")
    fi

    origin_verify_token="$(
        AWS_PAGER="" aws ssm get-parameter \
            "${region_arguments[@]}" \
            --name "$ORIGIN_VERIFY_PARAMETER" \
            --with-decryption \
            --query 'Parameter.Value' \
            --output text
    )"

    [[ "$origin_verify_token" != "None" && ${#origin_verify_token} -ge 32 && ${#origin_verify_token} -le 128 &&
        "$origin_verify_token" =~ ^[A-Za-z0-9_-]+$ ]] ||
        fail "The origin verification parameter is missing or does not satisfy the token policy."
}

prepare_runtime_directory() {
    umask 077
    runtime_directory="$(mktemp -d /run/ec-portfolio-demo-origin.XXXXXX)"

    if [[ -e "$NGINX_MAIN_CONFIG" ]]; then
        cp -p -- "$NGINX_MAIN_CONFIG" "$runtime_directory/nginx.conf.backup"
        main_config_existed="true"
    fi
    if [[ -e "$NGINX_SECRET_CONFIG" ]]; then
        cp -p -- "$NGINX_SECRET_CONFIG" "$runtime_directory/origin-secret.conf.backup"
        secret_config_existed="true"
    fi
    if [[ -e "$NGINX_SERVER_CONFIG" ]]; then
        cp -p -- "$NGINX_SERVER_CONFIG" "$runtime_directory/origin-server.conf.backup"
        server_config_existed="true"
    fi
    if [[ -d "$NGINX_RUNTIME_CONFIG_DIRECTORY" ]]; then
        runtime_config_directory_existed="true"
    fi
}

write_staged_configuration() {
    printf '%s\n' \
        'user nginx;' \
        'worker_processes auto;' \
        'error_log /var/log/nginx/error.log warn;' \
        'pid /run/nginx.pid;' \
        '' \
        'events {' \
        '    worker_connections 1024;' \
        '}' \
        '' \
        'http {' \
        '    include /etc/nginx/mime.types;' \
        '    default_type application/octet-stream;' \
        '    server_tokens off;' \
        '    sendfile on;' \
        '    keepalive_timeout 65;' \
        '    log_format origin escape=json '\''{"time":"$time_iso8601","remote_addr":"$remote_addr","method":"$request_method","uri":"$uri","status":$status,"bytes":$body_bytes_sent,"request_time":$request_time}'\'';' \
        '    access_log /var/log/nginx/access.log origin;' \
        '' \
        '    include /etc/nginx/ec-portfolio-demo/origin-secret.conf;' \
        '    include /etc/nginx/ec-portfolio-demo/origin-server.conf;' \
        '}' >"$runtime_directory/nginx.conf"

    {
        printf '%s\n' \
            'map $http_x_origin_verify $ec_portfolio_origin_verified {' \
            '    default 0;'
        printf '    ~^%s$ 1;\n' "$origin_verify_token"
        printf '%s\n' '}'
    } >"$runtime_directory/origin-secret.conf"

    {
        printf '%s\n' \
            'server {' \
            '    listen 443 ssl;' \
            "    server_name $ORIGIN_SERVER_NAME;" \
            '' \
            '    ssl_protocols TLSv1.2 TLSv1.3;' \
            '    ssl_session_cache shared:SSL:10m;' \
            '    ssl_session_timeout 10m;' \
            '    ssl_session_tickets off;' \
            "    ssl_certificate $ORIGIN_CERT_FILE;" \
            "    ssl_certificate_key $ORIGIN_KEY_FILE;" \
            '' \
            '    if ($ec_portfolio_origin_verified = 0) {' \
            '        return 403;' \
            '    }' \
            '' \
            '    location / {' \
            '        proxy_pass http://127.0.0.1:8080;' \
            '        proxy_http_version 1.1;' \
            '        proxy_set_header Host $host;' \
            '        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;' \
            '        proxy_set_header X-Forwarded-Proto $scheme;' \
            '        proxy_set_header X-Origin-Verify "";' \
            '        proxy_connect_timeout 5s;' \
            '        proxy_read_timeout 60s;' \
            '    }' \
            '}'
    } >"$runtime_directory/origin-server.conf"
}

install_configuration() {
    install -d -o root -g root -m 700 "$NGINX_RUNTIME_CONFIG_DIRECTORY"
    configuration_installed="true"
    install -o root -g root -m 600 "$runtime_directory/nginx.conf" "$NGINX_MAIN_CONFIG"
    install -o root -g root -m 600 "$runtime_directory/origin-secret.conf" "$NGINX_SECRET_CONFIG"
    install -o root -g root -m 600 "$runtime_directory/origin-server.conf" "$NGINX_SERVER_CONFIG"
}

listener_exists() {
    local port="$1"
    ss -H -ltn "sport = :$port" | grep -q .
}

activate_nginx() {
    nginx -t >/dev/null

    if [[ "$nginx_was_active" == "true" ]]; then
        systemctl reload nginx
    else
        systemctl start nginx
    fi

    systemctl enable nginx >/dev/null
    systemctl is-active --quiet nginx || fail "Nginx is not active."
    listener_exists 443 || fail "Nginx is not listening on TCP 443."
    if listener_exists 80; then
        fail "A TCP 80 listener is prohibited by the Demo origin contract."
    fi

    configuration_committed="true"
}

main() {
    if (( EUID != 0 )); then
        require_command sudo
        log "Root privileges are required; re-running with sudo."
        exec sudo --preserve-env=ORIGIN_SERVER_NAME,ORIGIN_CERT_FILE,ORIGIN_KEY_FILE,AWS_REGION,AWS_DEFAULT_REGION -- "$0" "$@"
    fi

    validate_platform
    validate_inputs "$@"
    log "Installing the Nginx package when necessary."
    dnf install -y nginx
    require_command nginx

    if systemctl is-active --quiet nginx; then
        nginx_was_active="true"
    fi
    if systemctl is-enabled --quiet nginx; then
        nginx_was_enabled="true"
    fi

    prepare_runtime_directory
    log "Reading the origin verification SecureString with the EC2 instance role."
    read_origin_verify_token
    write_staged_configuration
    install_configuration
    activate_nginx

    log "Demo HTTPS origin configuration completed successfully."
}

main "$@"
