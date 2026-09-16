#!/usr/bin/env bash

# Persists the origin TLS state so a replacement host can serve without asking
# Let's Encrypt for a new certificate.
#
# The Certbot durable state tree is archived rather than a hand-picked list of
# files. Certbot needs more than the PEMs: live/ holds symlinks into archive/,
# renewal/ holds the plugin configuration, and accounts/ holds the ACME account
# key without which a restored host would have to register again. Copying the
# PEMs alone produces a host that serves today and cannot renew.
#
# One file is deliberately left out: /etc/letsencrypt/cli.ini. On Amazon Linux
# 2023 it belongs to the certbot RPM, not to this deployment -- it carries the
# packaging defaults and is recreated by every install. Archiving it would make
# a replacement host restore the previous host's global Certbot configuration
# over the one its own package just wrote, and would put a file this project
# does not own into durable state. The archive contract still refuses cli.ini
# on the way back in, so excluding it here is not an allowlist: a cli.ini that
# appears in an archive means someone put it there, and that is refused.
#
# tar is used instead of `aws s3 sync` because sync follows symlinks and drops
# ownership and modes. Restoring a live/ directory of regular files instead of
# symlinks breaks the renewal that this script exists to protect.
#
# Certificate material never reaches stdout, stderr or any report.

set -euo pipefail

readonly ORIGIN_HOSTNAME="origin-demo.yoonec.dev"
# The hostname contains dots, which are regex wildcards. Escaped once here so a
# pattern built from it cannot be satisfied by an arbitrary character.
readonly ORIGIN_HOSTNAME_PATTERN="${ORIGIN_HOSTNAME//./\\.}"

# The only symlink shape a certbot tree contains: live/<host>/<file>.pem points
# two levels up into archive/<host>/. Anything else is refused, which is what
# keeps a link from resolving outside the tree.
readonly ARCHIVE_SYMLINK_PATTERN="^\\.\\./\\.\\./archive/$ORIGIN_HOSTNAME_PATTERN/[A-Za-z0-9._-]+$"

# Certbot paths use only these characters. Restricting names also removes the
# quoting and separator ambiguity the metadata parser would otherwise face.
readonly ENTRY_NAME_PATTERN='^[A-Za-z0-9._/-]+$'

# Files holding key material. They must stay readable by their owner alone.
readonly PRIVATE_STATE_NAMES=(
    'privkey*.pem'
    'private_key.json'
)

# Certbot runs these as root at renewal time. renew-origin-cert.sh already
# refuses them in the renewal configuration it is about to use; refusing them
# here as well means a hostile archive is rejected at restore rather than
# installed and only caught when the timer next fires.
readonly HOOK_DIRECTIVE_PATTERN='^[[:space:]]*(pre_hook|post_hook|renew_hook|deploy_hook)[[:space:]]*='
readonly HOOK_DIRECTORY_NAME="renewal-hooks"

# Certbot loads /etc/letsencrypt/cli.ini as global configuration before any flag
# on the command line is considered, and a configuration file may declare
# pre-hook, post-hook and deploy-hook. Those run as root at renewal time, so a
# restored cli.ini is arbitrary code execution by another route --
# --no-directory-hooks does not cover it, because it disables renewal-hooks/
# directories and nothing else.
#
# The file is refused outright rather than parsed for hook directives. This
# project passes every option explicitly on the command line and has no use for
# a global configuration, so there is no benign cli.ini to preserve; refusing
# the whole file also removes --server, --authenticator and --config-dir
# override, which a hook-only filter would leave reachable.
readonly GLOBAL_CONFIG_FILE_NAME="cli.ini"

# Test seam, in the same shape as CERTBOT_CONFIG_PREFIX in the certbot scripts:
# /etc in production, a sandbox root when the suite needs create_archive to run
# against a fixture tree instead of the real /etc/letsencrypt.
readonly LETSENCRYPT_PARENT="${ORIGIN_TLS_PARENT_DIRECTORY:-/etc}"
readonly LETSENCRYPT_DIRECTORY_NAME="letsencrypt"
readonly LETSENCRYPT_DIRECTORY="$LETSENCRYPT_PARENT/$LETSENCRYPT_DIRECTORY_NAME"

readonly BACKUP_OBJECT_KEY="origin-tls/letsencrypt.tar.gz"

readonly AWS_TIMEOUT_SECONDS="120s"
readonly TIMEOUT_KILL_AFTER_SECONDS="5s"

# Directories certbot needs on a restored host. Presence is verified; the
# archive carries the whole durable state tree apart from the package-owned
# global cli.ini.
readonly REQUIRED_DIRECTORIES=(
    "live"
    "archive"
    "renewal"
    "accounts"
)

work_directory=""

log() {
    printf '[origin-tls] %s\n' "$*"
}

fail() {
    printf '[origin-tls] ERROR: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    local exit_code=$?
    trap - EXIT
    if [[ -n "$work_directory" && "$work_directory" == /tmp/ec-portfolio-origin-tls.* ]]; then
        rm -rf -- "$work_directory"
    fi
    exit "$exit_code"
}

trap cleanup EXIT

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command is not available: $1"
}

run_with_timeout() {
    local duration="$1"
    shift
    timeout --kill-after="$TIMEOUT_KILL_AFTER_SECONDS" "$duration" "$@"
}

# The bucket is supplied by the caller so the script stays free of an
# account-specific identifier.
resolve_bucket() {
    [[ -n "${ORIGIN_TLS_BUCKET:-}" ]] ||
        fail "ORIGIN_TLS_BUCKET must name the origin TLS backup bucket."
    [[ "$ORIGIN_TLS_BUCKET" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] ||
        fail "ORIGIN_TLS_BUCKET is not a valid bucket name."
}

object_uri() {
    printf 's3://%s/%s' "$ORIGIN_TLS_BUCKET" "$BACKUP_OBJECT_KEY"
}

# --- archive contract -------------------------------------------------------

# Rejects an archive that is empty, escapes its root, or is missing state the
# restored host will need. Runs against the archive, not the live tree, so a
# broken backup is caught before it is uploaded or unpacked.
verify_archive() {
    local archive_file="$1"
    local listing
    local directory

    [[ -s "$archive_file" ]] || fail "The archive is empty."

    listing="$(tar -tzf "$archive_file")" ||
        fail "The archive is not a readable gzip tar."
    [[ -n "$listing" ]] || fail "The archive contains no entries."

    # Every check below feeds grep from a here-string rather than a pipe. With
    # `printf ... | grep -q`, grep exits on its first match and the writer dies
    # of SIGPIPE; under `set -o pipefail` the pipeline then reports 141 instead
    # of grep's success, so a detected violation reads as "no violation". An
    # archive whose hostile entry comes first and whose listing outgrows the
    # pipe buffer would slip past exactly the checks meant to stop it.

    # Absolute paths and parent traversal would let an unpack write outside the
    # restore root.
    if grep -qE '^/|(^|/)\.\.(/|$)' <<<"$listing"; then
        fail "The archive contains an absolute path or a parent traversal entry."
    fi

    # Everything must live under the single expected top-level directory.
    if grep -qvE "^$LETSENCRYPT_DIRECTORY_NAME(/|$)" <<<"$listing"; then
        fail "The archive contains entries outside $LETSENCRYPT_DIRECTORY_NAME/."
    fi

    if grep -qvE "$ENTRY_NAME_PATTERN" <<<"$listing"; then
        fail "The archive contains an entry name with unexpected characters."
    fi

    # Directory entries carry a trailing slash, so anything else under
    # renewal-hooks/ is a file. Empty hook directories stay allowed because
    # certbot creates them itself.
    if grep -qE "^$LETSENCRYPT_DIRECTORY_NAME/$HOOK_DIRECTORY_NAME/.+[^/]$" <<<"$listing"; then
        fail "The archive contains a Certbot hook script."
    fi

    # Refused here, before a single byte is unpacked, so the file never reaches
    # disk even in the staging directory.
    if grep -qE "^$LETSENCRYPT_DIRECTORY_NAME/$GLOBAL_CONFIG_FILE_NAME$" <<<"$listing"; then
        fail "The archive contains a Certbot global configuration file."
    fi

    for directory in "${REQUIRED_DIRECTORIES[@]}"; do
        grep -qE "^$LETSENCRYPT_DIRECTORY_NAME/$directory(/|$)" <<<"$listing" ||
            fail "The archive is missing the $directory state certbot needs."
    done

    verify_archive_metadata "$archive_file"
}

# A name listing says nothing about what an entry IS. A character device, a FIFO
# or a symlink aimed at /etc can all carry a perfectly innocuous name under
# letsencrypt/, so types and link targets are checked here, before anything is
# unpacked.
#
# Checking after extraction would be too late. tar runs as root during a
# restore, so by then the device node exists and the escaping symlink has
# already been created; and verify_restored_tree only inspects the handful of
# paths it knows about, so it never sees the extra entries at all.
verify_archive_metadata() {
    local archive_file="$1"
    local verbose_listing
    local line
    local entry_type
    local mode
    local link_target

    verbose_listing="$(tar -tvzf "$archive_file")" ||
        fail "The archive metadata is not readable."

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue

        entry_type="${line:0:1}"
        mode="${line:0:10}"

        case "$entry_type" in
        -|d) ;;
        l)
            # Split on the last separator: a symlink whose own name contained
            # " -> " would otherwise hide its real target behind the first one.
            link_target="${line##* -> }"
            [[ "$link_target" =~ $ARCHIVE_SYMLINK_PATTERN ]] ||
                fail "The archive contains a symlink outside the certbot layout."
            ;;
        *)
            # Covers hardlinks (h), character and block devices (c, b), FIFOs
            # (p) and sockets (s).
            fail "The archive contains a forbidden entry type: $entry_type"
            ;;
        esac

        # Nothing in a certbot tree is setuid or setgid, and a restore would
        # recreate those bits as root.
        if [[ "${mode:3:1}" == [sS] || "${mode:6:1}" == [sS] ]]; then
            fail "The archive contains a setuid or setgid entry."
        fi
    done <<<"$verbose_listing"
}

# Asks the filesystem what actually landed, rather than trusting the parse of
# tar's own text output. This is the check that stays correct if a future tar
# version or flag lets something through the metadata check above.
verify_staged_tree_safety() {
    local root="$1"
    local root_real
    local offender
    local symlink_path
    local link_target
    local resolved

    root_real="$(cd -- "$root" && pwd -P)"

    offender="$(find "$root" ! -type f ! -type d ! -type l -print 2>/dev/null | head -n 1 || true)"
    [[ -z "$offender" ]] ||
        fail "The restored tree contains a device, FIFO or socket entry."

    while IFS= read -r symlink_path; do
        [[ -n "$symlink_path" ]] || continue

        link_target="$(readlink "$symlink_path")"
        [[ "$link_target" != /* ]] ||
            fail "The restored tree contains an absolute symlink."

        # Resolve the target's directory physically, from the link's own
        # location, and require the result to stay inside the restored tree.
        resolved="$(cd -- "$(dirname -- "$symlink_path")" &&
            cd -- "$(dirname -- "$link_target")" 2>/dev/null && pwd -P)" ||
            fail "The restored tree contains a symlink that leaves the tree."
        [[ "$resolved" == "$root_real" || "$resolved" == "$root_real"/* ]] ||
            fail "The restored tree contains a symlink that leaves the tree."
    done < <(find "$root" -type l)

    verify_staged_ownership "$root"
    verify_staged_modes "$root"
    verify_no_certbot_hooks "$root/$LETSENCRYPT_DIRECTORY_NAME"
}

# Extraction discards archive ownership, so every entry must belong to the user
# performing the restore - root, enforced by restore(). Asserted rather than
# assumed: if the extraction flags ever regress, this fails closed instead of
# installing a tree that a local user owns.
verify_staged_ownership() {
    local root="$1"
    local foreign

    foreign="$(find "$root" ! -uid "$EUID" -print 2>/dev/null | head -n 1 || true)"
    [[ -z "$foreign" ]] ||
        fail "The restored tree contains an entry owned by another user."
}

# Each bit is tested on its own because "any of these bits" is spelled -perm /
# by GNU find and -perm + by BSD find, while -perm -<single bit> means the same
# thing to both.
verify_staged_modes() {
    local root="$1"
    local bit
    local name
    local offender

    # Nothing in a certbot tree may be writable outside its owner, and nothing
    # may be setuid or setgid.
    for bit in 0020 0002 4000 2000; do
        offender="$(find "$root" ! -type l -perm -"$bit" -print 2>/dev/null | head -n 1 || true)"
        [[ -z "$offender" ]] ||
            fail "The restored tree contains an entry with prohibited mode bits."
    done

    # Key material must not be readable or executable by group or world.
    for name in "${PRIVATE_STATE_NAMES[@]}"; do
        for bit in 0040 0010 0004 0001; do
            offender="$(find "$root" ! -type l -name "$name" -perm -"$bit" -print 2>/dev/null |
                head -n 1 || true)"
            [[ -z "$offender" ]] ||
                fail "The restored tree exposes private key state to group or world."
        done
    done
}

# The archive is a backup of state, never a carrier for code. Certbot executes
# both renewal-hooks/ scripts and the hook directives inside a renewal
# configuration as root, so an archive that smuggles either one turns a restore
# into arbitrary root command execution on the next renewal.
#
# This project has no use for Certbot hooks: renew-origin-cert.sh reloads Nginx
# itself. Refusing them outright is therefore fail-closed at no cost.
verify_no_certbot_hooks() {
    local root="$1"
    local hook_file
    local configuration_file

    hook_file="$(find "$root/$HOOK_DIRECTORY_NAME" ! -type d -print 2>/dev/null |
        head -n 1 || true)"
    [[ -z "$hook_file" ]] ||
        fail "The restored tree contains a Certbot hook script."

    # Defence in depth. verify_archive already refuses this entry from the
    # metadata, so reaching here means the name check was bypassed rather than
    # that a cli.ini is acceptable. -e is not used on purpose: a dangling
    # symlink is still a file certbot would follow once its target existed.
    [[ ! -e "$root/$GLOBAL_CONFIG_FILE_NAME" && ! -L "$root/$GLOBAL_CONFIG_FILE_NAME" ]] ||
        fail "The restored tree contains a Certbot global configuration file."

    while IFS= read -r configuration_file; do
        [[ -n "$configuration_file" ]] || continue
        # Only the file name is reported; the configuration is never echoed.
        if grep -Eq "$HOOK_DIRECTIVE_PATTERN" "$configuration_file"; then
            fail "The restored tree declares a Certbot hook in ${configuration_file##*/}."
        fi
    done < <(find "$root/renewal" -type f -name '*.conf' 2>/dev/null || true)
}

# Confirms the restored tree can actually serve and renew: live/ must still be
# symlinks into archive/, the PEMs must parse, and the certificate must match
# its private key. Key material is compared through hashes only.
verify_restored_tree() {
    local root="$1"
    local live_directory="$root/live/$ORIGIN_HOSTNAME"
    local certificate_file="$live_directory/fullchain.pem"
    local key_file="$live_directory/privkey.pem"
    local renewal_config="$root/renewal/$ORIGIN_HOSTNAME.conf"
    local certificate_public_key
    local private_public_key
    local link_target
    local link_name
    local key_mode

    [[ -d "$live_directory" ]] || fail "The restored tree has no live directory."

    for link_name in cert.pem chain.pem fullchain.pem privkey.pem; do
        [[ -L "$live_directory/$link_name" ]] ||
            fail "The restored live/$link_name is not a symlink."
        link_target="$(readlink "$live_directory/$link_name")"
        # Anchored, not a substring match: "/etc/evil/archive/<host>/x" and
        # "../../../../archive/<host>/x" both contain the substring while
        # pointing outside the tree.
        [[ "$link_target" =~ $ARCHIVE_SYMLINK_PATTERN ]] ||
            fail "The restored live/$link_name does not point into archive/."
        [[ -f "$live_directory/$link_name" ]] ||
            fail "The restored live/$link_name does not resolve to a file."
    done

    [[ -f "$renewal_config" ]] ||
        fail "The restored tree has no renewal configuration."

    openssl x509 -in "$certificate_file" -noout >/dev/null 2>&1 ||
        fail "The restored certificate is not a readable X.509 certificate."
    openssl pkey -in "$key_file" -noout >/dev/null 2>&1 ||
        fail "The restored private key is not a readable key."

    certificate_public_key="$(openssl x509 -in "$certificate_file" -noout -pubkey 2>/dev/null | openssl sha256)"
    private_public_key="$(openssl pkey -in "$key_file" -pubout 2>/dev/null | openssl sha256)"
    [[ -n "$certificate_public_key" && "$certificate_public_key" == "$private_public_key" ]] ||
        fail "The restored certificate and private key do not match."

    # The private key must not become readable beyond root.
    key_mode="$(stat -c '%a' "$(readlink -f "$key_file")" 2>/dev/null ||
        stat -f '%Lp' "$(readlink -f "$key_file")")"
    [[ "$key_mode" =~ ^[0-7]?[0-7]00$ ]] ||
        fail "The restored private key is group or world readable (mode $key_mode)."
}

# --- commands ---------------------------------------------------------------

create_archive() {
    local archive_file="$1"

    [[ -d "$LETSENCRYPT_DIRECTORY" ]] ||
        fail "There is no $LETSENCRYPT_DIRECTORY to back up."

    # -C keeps the archive rooted at letsencrypt/ rather than /etc/letsencrypt,
    # so a restore can be aimed at any parent directory.
    #
    # The package-owned global configuration is excluded. It is not durable
    # state: the certbot RPM writes it on every install, so a restored host
    # already has its own. Carrying it would also collide with verify_archive,
    # which refuses cli.ini in an archive -- a backup taken here would fail its
    # own verification before it was ever uploaded.
    #
    # The exclude pattern is matched against the stored name, which -C roots at
    # letsencrypt/. Verified to behave identically on GNU tar 1.34 (Amazon Linux
    # 2023), GNU tar 1.35 (Ubuntu) and bsdtar 3.5.3 (macOS).
    tar -czf "$archive_file" \
        -C "$LETSENCRYPT_PARENT" \
        --exclude "$LETSENCRYPT_DIRECTORY_NAME/$GLOBAL_CONFIG_FILE_NAME" \
        "$LETSENCRYPT_DIRECTORY_NAME" ||
        fail "Unable to archive $LETSENCRYPT_DIRECTORY."

    # The exclusion is a promise about what leaves this host, so it is checked
    # rather than assumed: a tar that quietly ignored the pattern would upload
    # the file and only fail later, in verify_archive, after the work was done.
    #
    # The listing is read into a variable and matched from a here-string. Piped
    # into `grep -q`, grep would exit on the match, tar would die of SIGPIPE,
    # and `set -o pipefail` would report 141 -- so the one case this exists to
    # catch would read as "no match" and pass.
    local created_listing
    created_listing="$(tar -tzf "$archive_file")" ||
        fail "Unable to read back the archive that was just created."
    if grep -qxF "$LETSENCRYPT_DIRECTORY_NAME/$GLOBAL_CONFIG_FILE_NAME" <<<"$created_listing"; then
        fail "The archive still contains $GLOBAL_CONFIG_FILE_NAME after exclusion."
    fi
}

backup() {
    local archive_file="$work_directory/letsencrypt.tar.gz"

    (( EUID == 0 )) || fail "Run as root: the certbot state is root owned."

    log "Archiving $LETSENCRYPT_DIRECTORY."
    create_archive "$archive_file"

    log "Verifying the archive before upload."
    verify_archive "$archive_file"

    log "Uploading the origin TLS state."
    AWS_PAGER="" run_with_timeout "$AWS_TIMEOUT_SECONDS" \
        aws s3 cp "$archive_file" "$(object_uri)" \
        --sse AES256 --only-show-errors ||
        fail "Unable to upload the origin TLS state."

    log "Origin TLS state backed up."
}

restore() {
    local archive_file="$work_directory/letsencrypt.tar.gz"
    local staging_directory="$work_directory/staging"

    (( EUID == 0 )) || fail "Run as root: the certbot state is root owned."

    log "Downloading the origin TLS state."
    AWS_PAGER="" run_with_timeout "$AWS_TIMEOUT_SECONDS" \
        aws s3 cp "$(object_uri)" "$archive_file" --only-show-errors ||
        fail "Unable to download the origin TLS state."

    log "Verifying the archive before unpacking."
    verify_archive "$archive_file"

    # Unpack into staging first so a bad archive can never leave the live
    # directory half replaced.
    mkdir -p "$staging_directory"
    unpack_archive "$archive_file" "$staging_directory"
    verify_staged_tree_safety "$staging_directory"
    verify_restored_tree "$staging_directory/$LETSENCRYPT_DIRECTORY_NAME"

    [[ ! -e "$LETSENCRYPT_DIRECTORY" ]] ||
        fail "$LETSENCRYPT_DIRECTORY already exists; refusing to overwrite existing certbot state."

    log "Installing the verified state."
    mv "$staging_directory/$LETSENCRYPT_DIRECTORY_NAME" "$LETSENCRYPT_DIRECTORY" ||
        fail "Unable to install the restored state."

    log "Origin TLS state restored."
}

unpack_archive() {
    local archive_file="$1"
    local destination="$2"

    # Archive ownership is discarded, not honoured. Extracting as root with
    # --same-owner would let the archive name the owner of the private key: a
    # uid 1000 entry at mode 0600 passes a group/world readability check while
    # handing a local user ownership of the origin key. Every entry in a certbot
    # tree is root managed on Amazon Linux 2023, so there is no ownership worth
    # preserving, and --no-same-owner means the hostile uid never reaches disk.
    #
    # -p is kept so modes survive and can be verified rather than silently
    # rewritten by the umask.
    tar -xzf "$archive_file" -C "$destination" --no-same-owner -p ||
        fail "Unable to unpack the origin TLS archive."
}

# Verifies a backup without touching the host: download, check, unpack into a
# scratch directory, check again, discard.
verify() {
    local archive_file="$work_directory/letsencrypt.tar.gz"
    local staging_directory="$work_directory/staging"

    log "Downloading the origin TLS state for verification."
    AWS_PAGER="" run_with_timeout "$AWS_TIMEOUT_SECONDS" \
        aws s3 cp "$(object_uri)" "$archive_file" --only-show-errors ||
        fail "Unable to download the origin TLS state."

    verify_archive "$archive_file"

    mkdir -p "$staging_directory"
    unpack_archive "$archive_file" "$staging_directory"
    verify_staged_tree_safety "$staging_directory"
    verify_restored_tree "$staging_directory/$LETSENCRYPT_DIRECTORY_NAME"

    log "The stored origin TLS state is complete and self consistent."
}

usage() {
    fail "Usage: sync-origin-tls.sh backup|restore|verify"
}

main() {
    local command_name="${1-}"

    (( $# == 1 )) || usage

    # find, grep, head and readlink are listed because the restore safety checks
    # are built on them, and every one of those checks fails open without them.
    # Each is shaped `offender="$(find ... | head -n 1 || true)"` followed by a
    # test on the result, so a missing tool anywhere in that pipeline leaves the
    # substitution empty -- which reads as "no device node, no escaping symlink,
    # no hook script, no foreign owner". head is as load-bearing as find here:
    # without it the pipeline's status is head's, `|| true` swallows it, find
    # dies on the closed pipe, and the check approves the tree it never read.
    # A missing tool must stop the run, not silently approve the archive.
    for required in aws find grep head openssl readlink stat tar timeout; do
        require_command "$required"
    done

    resolve_bucket
    work_directory="$(mktemp -d /tmp/ec-portfolio-origin-tls.XXXXXX)"

    case "$command_name" in
    backup) backup ;;
    restore) restore ;;
    verify) verify ;;
    *) usage ;;
    esac
}

# Sourcing exposes the archive and tree contracts to the test suite without
# running a command against the host or S3.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
