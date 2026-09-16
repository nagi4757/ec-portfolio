#!/usr/bin/env bash

# Behaviour tests for the origin TLS state archive contract.
#
# Everything runs in a temporary sandbox. The production /etc/letsencrypt is
# never read, written, moved or archived, and no AWS call is made: the tests
# drive the archive and verification contracts in their own subprocesses.
#
# The fixture is a throwaway self-signed certificate generated at run time. No
# certificate or private key is committed to the repository, and no key material
# is printed.

set -euo pipefail

readonly SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SYNC_SCRIPT="$SCRIPT_DIRECTORY/sync-origin-tls.sh"
readonly HOSTNAME_UNDER_TEST="origin-demo.yoonec.dev"

work_directory=""

cleanup_tests() {
    local exit_code=$?
    trap - EXIT
    if [[ -n "$work_directory" && "$work_directory" == /tmp/ec-portfolio-origin-tls-test.* ]]; then
        rm -rf -- "$work_directory"
    fi
    exit "$exit_code"
}

trap cleanup_tests EXIT

fail() {
    printf '[origin-tls-test] FAIL: %s\n' "$*" >&2
    exit 1
}

# Substring matching is done in the shell rather than through `printf | grep -q`.
# grep -q exits on its first match, the writer dies of SIGPIPE, and pipefail then
# reports 141 instead of success, so the assertion silently inverts on large
# inputs. The production script avoids the same trap with here-strings.
assert_contains() {
    [[ "$1" == *"$2"* ]] || fail "$3 (expected to find: $2)"
}

assert_absent() {
    [[ "$1" != *"$2"* ]] || fail "$3 (unexpectedly found: $2)"
}

# Builds a certbot-shaped tree: archive/ holds the real files, live/ holds
# relative symlinks into it, renewal/ and accounts/ carry the rest of the state.
build_fixture() {
    local root="$1"
    local live="$root/live/$HOSTNAME_UNDER_TEST"
    local archive="$root/archive/$HOSTNAME_UNDER_TEST"

    mkdir -p "$live" "$archive" "$root/renewal" \
        "$root/accounts/acme-v02.api.letsencrypt.org/directory/deadbeef" \
        "$root/renewal-hooks/deploy"

    # Throwaway key pair; never leaves the sandbox.
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$archive/privkey1.pem" \
        -out "$archive/cert1.pem" \
        -days 1 -subj "/CN=$HOSTNAME_UNDER_TEST" >/dev/null 2>&1 ||
        fail "Could not generate the sandbox certificate fixture."

    cp "$archive/cert1.pem" "$archive/chain1.pem"
    cp "$archive/cert1.pem" "$archive/fullchain1.pem"
    chmod 600 "$archive/privkey1.pem"

    ln -s "../../archive/$HOSTNAME_UNDER_TEST/cert1.pem" "$live/cert.pem"
    ln -s "../../archive/$HOSTNAME_UNDER_TEST/chain1.pem" "$live/chain.pem"
    ln -s "../../archive/$HOSTNAME_UNDER_TEST/fullchain1.pem" "$live/fullchain.pem"
    ln -s "../../archive/$HOSTNAME_UNDER_TEST/privkey1.pem" "$live/privkey.pem"

    printf 'version = 2.6.0\nauthenticator = dns-route53\n' \
        >"$root/renewal/$HOSTNAME_UNDER_TEST.conf"
    printf '{"body": {}}\n' \
        >"$root/accounts/acme-v02.api.letsencrypt.org/directory/deadbeef/regr.json"
    printf '{"n": "synthetic"}\n' \
        >"$root/accounts/acme-v02.api.letsencrypt.org/directory/deadbeef/private_key.json"
    # Certbot stores the ACME account key owner readable only; the fixture has
    # to match, because the restore contract enforces it.
    chmod 600 "$root/accounts/acme-v02.api.letsencrypt.org/directory/deadbeef/private_key.json"
}

# Archives a sandbox tree the same way the script archives /etc/letsencrypt:
# rooted at letsencrypt/ so a restore can target any parent.
archive_fixture() {
    local parent="$1"
    local archive_file="$2"

    tar -czf "$archive_file" -C "$parent" letsencrypt
}

work_directory="$(mktemp -d /tmp/ec-portfolio-origin-tls-test.XXXXXX)"

# The contract functions are invoked in their own process rather than sourced
# here. Sourcing would replace this suite's own work_directory, fail() and EXIT
# trap with the script's, which silently broke the sandbox.
verify_archive_ok() {
    bash -c 'source "$1"; verify_archive "$2"' _ "$SYNC_SCRIPT" "$1" >/dev/null 2>&1
}

verify_restored_tree_ok() {
    bash -c 'source "$1"; verify_restored_tree "$2"' _ "$SYNC_SCRIPT" "$1" >/dev/null 2>&1
}

# --- 1. a well formed archive passes both contracts -------------------------
fixture_parent="$work_directory/fixture"
mkdir -p "$fixture_parent/letsencrypt"
build_fixture "$fixture_parent/letsencrypt"
good_archive="$work_directory/good.tar.gz"
archive_fixture "$fixture_parent" "$good_archive"

verify_archive_ok "$good_archive" ||
    fail "A complete archive must pass verify_archive."

# --- 2. restore into a sandbox preserves symlinks, modes and the key pair ----
restore_root="$work_directory/restored"
mkdir -p "$restore_root"
tar -xzf "$good_archive" -C "$restore_root" -p

restored_live="$restore_root/letsencrypt/live/$HOSTNAME_UNDER_TEST"
for link_name in cert.pem chain.pem fullchain.pem privkey.pem; do
    [[ -L "$restored_live/$link_name" ]] ||
        fail "Restore must keep live/$link_name a symlink, not a copied file."
    [[ -f "$restored_live/$link_name" ]] ||
        fail "Restore must leave live/$link_name resolving to a real file."
done

target="$(readlink "$restored_live/privkey.pem")"
assert_contains "$target" "archive/$HOSTNAME_UNDER_TEST/privkey1.pem" \
    "The restored symlink must still point into archive/."

restored_key="$restore_root/letsencrypt/archive/$HOSTNAME_UNDER_TEST/privkey1.pem"
key_mode="$(stat -c '%a' "$restored_key" 2>/dev/null || stat -f '%Lp' "$restored_key")"
[[ "$key_mode" =~ ^[0-7]?[0-7]00$ ]] ||
    fail "Restore must keep the private key unreadable to group and world (mode $key_mode)."

# The full tree contract, including the certificate/private-key pair match.
verify_restored_tree_ok "$restore_root/letsencrypt" ||
    fail "A restored complete tree must pass verify_restored_tree."

# --- 3. every required directory is enforced --------------------------------
for missing in live archive renewal accounts; do
    pruned_parent="$work_directory/pruned-$missing"
    mkdir -p "$pruned_parent"
    cp -R "$fixture_parent/letsencrypt" "$pruned_parent/letsencrypt"
    rm -rf "$pruned_parent/letsencrypt/$missing"

    pruned_archive="$work_directory/pruned-$missing.tar.gz"
    archive_fixture "$pruned_parent" "$pruned_archive"

    if verify_archive_ok "$pruned_archive"; then
        fail "An archive without $missing/ must be rejected."
    fi
done

# --- 4. an empty archive is rejected ----------------------------------------
empty_parent="$work_directory/empty"
mkdir -p "$empty_parent/letsencrypt"
empty_archive="$work_directory/empty.tar.gz"
archive_fixture "$empty_parent" "$empty_archive"
if verify_archive_ok "$empty_archive"; then
    fail "An archive with no certbot state must be rejected."
fi

: >"$work_directory/zero.tar.gz"
if verify_archive_ok "$work_directory/zero.tar.gz"; then
    fail "A zero byte archive must be rejected."
fi

# --- 5. path traversal and absolute paths are rejected ----------------------
# The entry names are written with Python's tarfile so the case does not depend
# on whether the local tar normalises or refuses such names.
craft_archive_with_entry() {
    local output="$1"
    local entry_name="$2"
    local source_tree="$3"

    python3 - "$output" "$entry_name" "$source_tree" <<'CRAFT'
import io, sys, tarfile

output, entry_name, source_tree = sys.argv[1], sys.argv[2], sys.argv[3]
with tarfile.open(output, "w:gz") as archive:
    archive.add(source_tree, arcname="letsencrypt")
    payload = b"escaped\n"
    info = tarfile.TarInfo(entry_name)
    info.size = len(payload)
    archive.addfile(info, io.BytesIO(payload))
CRAFT
}

traversal_archive="$work_directory/traversal.tar.gz"
craft_archive_with_entry "$traversal_archive" "../escaped.txt" \
    "$fixture_parent/letsencrypt"
tar -tzf "$traversal_archive" 2>/dev/null | grep -qE '(^|/)\.\.(/|$)' ||
    fail "The traversal fixture does not actually contain a parent traversal entry."
if verify_archive_ok "$traversal_archive"; then
    fail "An archive containing a parent traversal entry must be rejected."
fi

absolute_archive="$work_directory/absolute.tar.gz"
craft_archive_with_entry "$absolute_archive" "/escaped.txt" \
    "$fixture_parent/letsencrypt"
tar -tzf "$absolute_archive" 2>/dev/null | grep -qE '^/' ||
    fail "The absolute-path fixture does not actually contain an absolute entry."
if verify_archive_ok "$absolute_archive"; then
    fail "An archive containing an absolute path entry must be rejected."
fi

# An entry outside letsencrypt/ must be rejected even without traversal.
stray_parent="$work_directory/stray"
mkdir -p "$stray_parent/letsencrypt" "$stray_parent/other"
cp -R "$fixture_parent/letsencrypt/." "$stray_parent/letsencrypt/"
printf 'stray\n' >"$stray_parent/other/stray.txt"
stray_archive="$work_directory/stray.tar.gz"
tar -czf "$stray_archive" -C "$stray_parent" letsencrypt other
if verify_archive_ok "$stray_archive"; then
    fail "An archive with entries outside letsencrypt/ must be rejected."
fi

# A traversal entry that still starts with letsencrypt/ passes the outside-root
# rule, so only the traversal rule can reject it. Without this fixture the
# traversal check is masked by the outside-root check.
nested_traversal_archive="$work_directory/nested-traversal.tar.gz"
craft_archive_with_entry "$nested_traversal_archive" "letsencrypt/../escaped.txt" \
    "$fixture_parent/letsencrypt"
tar -tzf "$nested_traversal_archive" 2>/dev/null | grep -qE '(^|/)\.\.(/|$)' ||
    fail "The nested traversal fixture does not contain a traversal entry."
if verify_archive_ok "$nested_traversal_archive"; then
    fail "An archive with a traversal entry under letsencrypt/ must be rejected."
fi

# --- 5b. a live symlink pointing outside archive/ is rejected ---------------
stray_link_root="$work_directory/stray-link/letsencrypt"
mkdir -p "$stray_link_root"
cp -R "$restore_root/letsencrypt/archive" "$stray_link_root/archive"
cp -R "$restore_root/letsencrypt/renewal" "$stray_link_root/renewal"
cp -R "$restore_root/letsencrypt/accounts" "$stray_link_root/accounts"
mkdir -p "$stray_link_root/live/$HOSTNAME_UNDER_TEST" "$stray_link_root/elsewhere"
cp -L "$restore_root/letsencrypt/live/$HOSTNAME_UNDER_TEST/privkey.pem" \
    "$stray_link_root/elsewhere/privkey.pem"
chmod 600 "$stray_link_root/elsewhere/privkey.pem"
for link_name in cert.pem chain.pem fullchain.pem; do
    ln -s "../../archive/$HOSTNAME_UNDER_TEST/${link_name%.pem}1.pem" \
        "$stray_link_root/live/$HOSTNAME_UNDER_TEST/$link_name"
done
ln -s "../../elsewhere/privkey.pem" \
    "$stray_link_root/live/$HOSTNAME_UNDER_TEST/privkey.pem"
if verify_restored_tree_ok "$stray_link_root"; then
    fail "A live symlink pointing outside archive/ must be rejected."
fi

# --- 5c. a group or world readable private key is rejected ------------------
loose_key_root="$work_directory/loose-key/letsencrypt"
mkdir -p "$(dirname "$loose_key_root")"
cp -R "$restore_root/letsencrypt" "$loose_key_root"
chmod 644 "$loose_key_root/archive/$HOSTNAME_UNDER_TEST/privkey1.pem"
if verify_restored_tree_ok "$loose_key_root"; then
    fail "A group or world readable private key must be rejected."
fi

# --- 6. a mismatched certificate and private key are rejected ---------------
mismatch_root="$work_directory/mismatch"
mkdir -p "$mismatch_root"
cp -R "$restore_root/letsencrypt" "$mismatch_root/letsencrypt"
mismatch_archive_dir="$mismatch_root/letsencrypt/archive/$HOSTNAME_UNDER_TEST"
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$mismatch_archive_dir/privkey1.pem" \
    -out "$work_directory/unused-cert.pem" \
    -days 1 -subj "/CN=$HOSTNAME_UNDER_TEST" >/dev/null 2>&1
chmod 600 "$mismatch_archive_dir/privkey1.pem"

if verify_restored_tree_ok "$mismatch_root/letsencrypt"; then
    fail "A certificate that does not match its private key must be rejected."
fi

# --- 7. a live/ of regular files instead of symlinks is rejected ------------
# This is what `aws s3 sync` would produce: it serves today and cannot renew.
# Everything else about the tree is deliberately kept valid -- matching key
# pair, 0600 private key, renewal config present -- so the symlink rule is the
# only thing that can reject it.
flattened_root="$work_directory/flattened/letsencrypt"
mkdir -p "$flattened_root"
cp -R "$restore_root/letsencrypt/archive" "$flattened_root/archive"
cp -R "$restore_root/letsencrypt/renewal" "$flattened_root/renewal"
cp -R "$restore_root/letsencrypt/accounts" "$flattened_root/accounts"
mkdir -p "$flattened_root/live/$HOSTNAME_UNDER_TEST"
for link_name in cert.pem chain.pem fullchain.pem privkey.pem; do
    cp -L "$restore_root/letsencrypt/live/$HOSTNAME_UNDER_TEST/$link_name" \
        "$flattened_root/live/$HOSTNAME_UNDER_TEST/$link_name"
done
chmod 600 "$flattened_root/live/$HOSTNAME_UNDER_TEST/privkey.pem"

[[ ! -L "$flattened_root/live/$HOSTNAME_UNDER_TEST/privkey.pem" ]] ||
    fail "The flattened fixture must contain regular files, not symlinks."
if verify_restored_tree_ok "$flattened_root"; then
    fail "A live/ directory of dereferenced copies must be rejected."
fi

# --- 8. a missing renewal configuration is rejected -------------------------
no_renewal_root="$work_directory/no-renewal"
mkdir -p "$no_renewal_root"
cp -R "$restore_root/letsencrypt" "$no_renewal_root/letsencrypt"
rm -f "$no_renewal_root/letsencrypt/renewal/$HOSTNAME_UNDER_TEST.conf"
if verify_restored_tree_ok "$no_renewal_root/letsencrypt"; then
    fail "A tree without a renewal configuration must be rejected."
fi

# --- 8b. hostile tar entries are refused before extraction ------------------
# Every fixture below carries a complete, valid-looking certbot tree, so it
# satisfies the name level checks: the only thing wrong with it is an entry
# whose *type* or *link target* escapes the tree. These are the cases a name
# listing cannot see, which is why the metadata check exists.
verify_staged_tree_safety_ok() {
    bash -c 'source "$1"; verify_staged_tree_safety "$2"' _ "$SYNC_SCRIPT" "$1" >/dev/null 2>&1
}

# Rebuilds the valid fixture and injects one hostile entry.
# $1 output archive, $2 injection kind
craft_hostile_archive() {
    python3 - "$1" "$2" "$fixture_parent" <<'PY'
import io
import os
import sys
import tarfile

output, kind, fixture_parent = sys.argv[1], sys.argv[2], sys.argv[3]
host = "origin-demo.yoonec.dev"

with tarfile.open(output, "w:gz") as tf:
    # The genuine tree first, so every name level check is satisfied.
    tf.add(os.path.join(fixture_parent, "letsencrypt"), arcname="letsencrypt")

    def add(name, entry_type, **kw):
        info = tarfile.TarInfo(name)
        info.type = entry_type
        for key, value in kw.items():
            setattr(info, key, value)
        if entry_type == tarfile.REGTYPE:
            payload = b"x\n"
            info.size = len(payload)
            tf.addfile(info, io.BytesIO(payload))
        else:
            tf.addfile(info)

    if kind == "symlink-absolute":
        add("letsencrypt/accounts/escape", tarfile.SYMTYPE, linkname="/etc/passwd")
    elif kind == "symlink-relative-escape":
        add("letsencrypt/accounts/escape", tarfile.SYMTYPE,
            linkname="../../../../../../etc/passwd")
    elif kind == "symlink-name-hides-target":
        add("letsencrypt/accounts/a -> safe", tarfile.SYMTYPE, linkname="/etc/passwd")
    elif kind == "hardlink-escape":
        add("letsencrypt/accounts/hard", tarfile.LNKTYPE,
            linkname="../../../../../../etc/passwd")
    elif kind == "chardev":
        add("letsencrypt/accounts/dev0", tarfile.CHRTYPE,
            mode=0o666, devmajor=1, devminor=3)
    elif kind == "blockdev":
        add("letsencrypt/accounts/blk0", tarfile.BLKTYPE,
            mode=0o660, devmajor=8, devminor=0)
    elif kind == "fifo":
        add("letsencrypt/accounts/pipe0", tarfile.FIFOTYPE, mode=0o644)
    elif kind == "setuid":
        add("letsencrypt/accounts/suid", tarfile.REGTYPE, mode=0o4755)
    elif kind == "unexpected-name-characters":
        # A plain regular file, so only the name check can reject it.
        add("letsencrypt/accounts/bad name.txt", tarfile.REGTYPE, mode=0o644)
    elif kind == "live-symlink-escape":
        # A live/ link whose target merely *contains* archive/<host>/.
        add("letsencrypt/live/%s/cert.pem" % host, tarfile.SYMTYPE,
            linkname="/tmp/evil/archive/%s/cert1.pem" % host)
    else:
        raise SystemExit("unknown kind: %s" % kind)
PY
}

for hostile_kind in \
    symlink-absolute \
    symlink-relative-escape \
    symlink-name-hides-target \
    hardlink-escape \
    chardev \
    blockdev \
    fifo \
    setuid \
    unexpected-name-characters \
    live-symlink-escape; do
    hostile_archive="$work_directory/hostile-$hostile_kind.tar.gz"
    craft_hostile_archive "$hostile_archive" "$hostile_kind" ||
        fail "Could not build the $hostile_kind fixture."

    # Guard against a fixture that silently failed to inject anything: it must
    # still be a readable archive carrying the genuine tree.
    tar -tzf "$hostile_archive" >/dev/null 2>&1 ||
        fail "The $hostile_kind fixture is not a readable archive."

    if verify_archive_ok "$hostile_archive"; then
        fail "A $hostile_kind entry must be rejected before extraction."
    fi
done

# --- 8c. the staged tree sweep catches what is already on disk --------------
# Belt and braces: even if an entry reached the filesystem, the tree must not be
# installed. Built with real filesystem calls, not tar, so it is independent of
# any tar behaviour.
sweep_root="$work_directory/sweep"
mkdir -p "$sweep_root"
cp -R "$restore_root/letsencrypt" "$sweep_root/letsencrypt"
verify_staged_tree_safety_ok "$sweep_root" ||
    fail "A clean staged tree must pass the safety sweep."

mkfifo "$sweep_root/letsencrypt/accounts/pipe0" 2>/dev/null ||
    fail "Could not create the FIFO fixture."
if verify_staged_tree_safety_ok "$sweep_root"; then
    fail "A FIFO in the staged tree must be rejected."
fi
rm -f "$sweep_root/letsencrypt/accounts/pipe0"

ln -s /etc/passwd "$sweep_root/letsencrypt/accounts/escape"
if verify_staged_tree_safety_ok "$sweep_root"; then
    fail "An absolute symlink in the staged tree must be rejected."
fi
rm -f "$sweep_root/letsencrypt/accounts/escape"

ln -s "../../../../../../etc/passwd" "$sweep_root/letsencrypt/accounts/escape"
if verify_staged_tree_safety_ok "$sweep_root"; then
    fail "A symlink leaving the staged tree must be rejected."
fi
rm -f "$sweep_root/letsencrypt/accounts/escape"

# An absolute link is refused even when it happens to point back inside the
# staging directory: the tree is moved to /etc/letsencrypt afterwards, so a link
# anchored to the scratch path would dangle the moment the restore completes.
ln -s "$sweep_root/letsencrypt/archive/$HOSTNAME_UNDER_TEST/cert1.pem" \
    "$sweep_root/letsencrypt/accounts/absolute-inside"
if verify_staged_tree_safety_ok "$sweep_root"; then
    fail "An absolute symlink must be rejected even when it resolves inside the tree."
fi
rm -f "$sweep_root/letsencrypt/accounts/absolute-inside"

verify_staged_tree_safety_ok "$sweep_root" ||
    fail "The staged tree must pass again once the hostile entries are removed."

# --- 8g. a padded archive cannot outrun the name checks ---------------------
# The attacker controls both the order and the number of entries. With the
# checks written as `printf ... | grep -q`, grep exits on the first match, the
# writer dies of SIGPIPE, and pipefail reports 141 - so a hostile entry placed
# first, in a listing larger than the pipe buffer, reads as "no violation".
# These fixtures are large enough to overflow that buffer.
craft_padded_archive() {
    python3 - "$1" "$2" "$fixture_parent/letsencrypt" <<'PY'
import io
import sys
import tarfile

output, hostile_name, source = sys.argv[1], sys.argv[2], sys.argv[3]

with tarfile.open(output, "w:gz") as tf:
    # The hostile entry goes first, so grep can match immediately.
    payload = b"escaped\n"
    info = tarfile.TarInfo(hostile_name)
    info.size = len(payload)
    tf.addfile(info, io.BytesIO(payload))

    tf.add(source, arcname="letsencrypt")

    # Pad well past a 64 KiB pipe buffer worth of listing.
    for index in range(20000):
        pad = tarfile.TarInfo("letsencrypt/archive/padding-%06d.pem" % index)
        pad.size = 0
        pad.mode = 0o644
        tf.addfile(pad)
PY
}

for padded_case in "../escaped.txt" "/escaped.txt" "letsencrypt/../escaped.txt"; do
    padded_archive="$work_directory/padded-$RANDOM.tar.gz"
    craft_padded_archive "$padded_archive" "$padded_case" ||
        fail "Could not build the padded fixture for $padded_case."

    padded_entries="$(tar -tzf "$padded_archive" | wc -l | tr -d ' ')"
    (( padded_entries > 20000 )) ||
        fail "The padded fixture is too small to exercise the buffer case."

    if verify_archive_ok "$padded_archive"; then
        fail "A padded archive hiding '$padded_case' must still be rejected."
    fi
done

# --- 8e. hostile ownership and modes are refused ----------------------------
# A private key at mode 0600 owned by uid 1000 satisfies "not group or world
# readable" while handing a local user ownership of the origin key. Ownership is
# therefore discarded at extraction and asserted afterwards.
# Asserted against the unpack_archive body with comments stripped: the flag is
# named in a nearby comment, so matching the whole file would pass even if the
# command itself had regressed.
unpack_body="$(sed -n '/^unpack_archive()/,/^}/p' "$SYNC_SCRIPT" |
    sed -e 's/[[:space:]]#.*$//' -e 's/^[[:space:]]*#.*$//')"
[[ -n "$unpack_body" ]] || fail "Unable to locate unpack_archive."
assert_contains "$unpack_body" "--no-same-owner" \
    "Extraction must discard archive ownership."
# Remove the legitimate flag first; any --same-owner left is the hostile form.
assert_absent "${unpack_body//--no-same-owner/}" "--same-owner" \
    "Extraction must not honour archive ownership."

# Rewrites the fixture archive with attacker chosen ownership or modes.
# $1 output archive, $2 hostile kind
craft_owner_mode_archive() {
    python3 - "$1" "$2" "$fixture_parent/letsencrypt" <<'PY'
import os
import sys
import tarfile

output, kind, source = sys.argv[1], sys.argv[2], sys.argv[3]

with tarfile.open(output, "w:gz") as tf:
    for directory, subdirectories, files in os.walk(source):
        for entry in sorted(subdirectories) + sorted(files):
            path = os.path.join(directory, entry)
            info = tf.gettarinfo(path, arcname="letsencrypt" + path[len(source):])
            # Normalise to root, then apply exactly one hostile property.
            info.uid = info.gid = 0
            info.uname = info.gname = "root"

            if kind == "foreign-uid" and entry == "privkey1.pem":
                info.uid = info.gid = 1000
                info.uname = info.gname = "ec2-user"
                info.mode = 0o600
            elif kind == "foreign-gid" and entry == "privkey1.pem":
                info.gid = 1000
                info.gname = "ec2-user"
                info.mode = 0o600
            elif kind == "key-group-readable" and entry == "privkey1.pem":
                info.mode = 0o640
            elif kind == "account-key-readable" and entry == "private_key.json":
                info.mode = 0o644
            elif kind == "world-writable" and entry == "cert1.pem":
                info.mode = 0o666
            elif kind == "group-writable" and entry == "fullchain1.pem":
                info.mode = 0o664

            if info.isreg():
                with open(path, "rb") as handle:
                    tf.addfile(info, handle)
            else:
                tf.addfile(info)
PY
}

# The sweep runs against an extracted tree, so ownership cases are asserted on
# the archive metadata the extraction is told to discard. Mode cases are driven
# all the way through extraction below.
for owner_kind in foreign-uid foreign-gid; do
    owner_archive="$work_directory/owner-$owner_kind.tar.gz"
    craft_owner_mode_archive "$owner_archive" "$owner_kind" ||
        fail "Could not build the $owner_kind fixture."
    tar -tvzf "$owner_archive" 2>/dev/null | grep -q "1000\|ec2-user" ||
        fail "The $owner_kind fixture does not actually carry a foreign owner."
done

for mode_kind in key-group-readable account-key-readable world-writable group-writable; do
    mode_archive="$work_directory/mode-$mode_kind.tar.gz"
    craft_owner_mode_archive "$mode_archive" "$mode_kind" ||
        fail "Could not build the $mode_kind fixture."

    mode_root="$work_directory/mode-root-$mode_kind"
    mkdir -p "$mode_root"
    tar -xzf "$mode_archive" -C "$mode_root" --no-same-owner -p 2>/dev/null ||
        fail "Could not extract the $mode_kind fixture."

    if verify_staged_tree_safety_ok "$mode_root"; then
        fail "A $mode_kind tree must be rejected."
    fi
done

# --- 8f. Certbot hook state is refused ---------------------------------------
# Certbot runs hooks as root, so a restored hook turns a backup into code.
hook_archive="$work_directory/hook-script.tar.gz"
hook_parent="$work_directory/hook-parent"
mkdir -p "$hook_parent"
cp -R "$fixture_parent/letsencrypt" "$hook_parent/letsencrypt"
printf '#!/bin/sh\nid > /tmp/pwned\n' >"$hook_parent/letsencrypt/renewal-hooks/deploy/evil.sh"
chmod 755 "$hook_parent/letsencrypt/renewal-hooks/deploy/evil.sh"
archive_fixture "$hook_parent" "$hook_archive"
if verify_archive_ok "$hook_archive"; then
    fail "An archive carrying a renewal-hooks script must be rejected."
fi

# A non-executable hook file is equally unacceptable: certbot does not require
# the executable bit to be set by the attacker, only by a later chmod.
nonexec_hook_parent="$work_directory/hook-parent-nonexec"
mkdir -p "$nonexec_hook_parent"
cp -R "$fixture_parent/letsencrypt" "$nonexec_hook_parent/letsencrypt"
printf 'id\n' >"$nonexec_hook_parent/letsencrypt/renewal-hooks/deploy/evil.sh"
chmod 644 "$nonexec_hook_parent/letsencrypt/renewal-hooks/deploy/evil.sh"
archive_fixture "$nonexec_hook_parent" "$work_directory/hook-nonexec.tar.gz"
if verify_archive_ok "$work_directory/hook-nonexec.tar.gz"; then
    fail "An archive carrying a non-executable renewal-hooks file must be rejected."
fi

# An empty hook directory is legitimate: certbot creates it.
verify_archive_ok "$good_archive" ||
    fail "An empty renewal-hooks directory must remain acceptable."

for hook_directive in deploy_hook renew_hook pre_hook post_hook; do
    directive_root="$work_directory/directive-$hook_directive"
    mkdir -p "$directive_root"
    cp -R "$restore_root/letsencrypt" "$directive_root/letsencrypt"
    printf '%s = /tmp/evil.sh\n' "$hook_directive" \
        >>"$directive_root/letsencrypt/renewal/$HOSTNAME_UNDER_TEST.conf"

    if verify_staged_tree_safety_ok "$directive_root"; then
        fail "A renewal configuration declaring $hook_directive must be rejected."
    fi
done

# Indented and spaced forms must not slip past.
for directive_form in '  deploy_hook=/tmp/evil.sh' 'post_hook   =   /tmp/evil.sh'; do
    spaced_root="$work_directory/directive-spaced-$RANDOM"
    mkdir -p "$spaced_root"
    cp -R "$restore_root/letsencrypt" "$spaced_root/letsencrypt"
    printf '%s\n' "$directive_form" \
        >>"$spaced_root/letsencrypt/renewal/$HOSTNAME_UNDER_TEST.conf"
    if verify_staged_tree_safety_ok "$spaced_root"; then
        fail "A hook directive written as '$directive_form' must be rejected."
    fi
done

# A hook script placed straight onto the staged tree must be refused too. The
# archive level check would already have rejected it, so this drives the
# post-extraction path directly and keeps both layers honest.
printf '#!/bin/sh\nid\n' >"$sweep_root/letsencrypt/renewal-hooks/deploy/evil.sh"
chmod 755 "$sweep_root/letsencrypt/renewal-hooks/deploy/evil.sh"
if verify_staged_tree_safety_ok "$sweep_root"; then
    fail "A hook script in the staged tree must be rejected."
fi
rm -f "$sweep_root/letsencrypt/renewal-hooks/deploy/evil.sh"

# A clean tree must still pass, so the hook checks are not rejecting everything.
verify_staged_tree_safety_ok "$sweep_root" ||
    fail "A clean tree must pass the hook and ownership checks."

# --- 8d. extraction is staged, never aimed at /etc/letsencrypt --------------
# The unpack target must be the scratch directory, and the install step must be
# guarded by a non-existence check, so no archive can overwrite a live tree.
script_body="$(cat "$SYNC_SCRIPT")"
assert_contains "$script_body" 'unpack_archive "$archive_file" "$staging_directory"' \
    "Extraction must target the staging directory."
printf '%s' "$script_body" | grep -Fq 'unpack_archive "$archive_file" "$LETSENCRYPT_DIRECTORY"' &&
    fail "Extraction must never target /etc/letsencrypt directly."
assert_contains "$script_body" '[[ ! -e "$LETSENCRYPT_DIRECTORY" ]] ||' \
    "Install must refuse when /etc/letsencrypt already exists."

# The safety sweep must run before the tree is judged usable, in both paths.
sweep_calls="$(printf '%s\n' "$script_body" | grep -c 'verify_staged_tree_safety "\$staging_directory"' || true)"
(( sweep_calls == 2 )) ||
    fail "Both restore and verify must sweep the staged tree (found $sweep_calls)."

# --- 8g. a Certbot global configuration is refused ---------------------------
# Certbot reads /etc/letsencrypt/cli.ini before any command-line flag, and a
# configuration file may declare pre-hook, post-hook and deploy-hook, which run
# as root. --no-directory-hooks does not cover this path: it disables
# renewal-hooks/ directories only. A restored cli.ini would therefore be root
# command execution that every other check in this suite lets through.

# A hostile one, carrying the hook that would run.
cli_hook_parent="$work_directory/cli-ini-hook"
mkdir -p "$cli_hook_parent"
cp -R "$fixture_parent/letsencrypt" "$cli_hook_parent/letsencrypt"
printf 'pre-hook = /tmp/evil.sh\n' >"$cli_hook_parent/letsencrypt/cli.ini"
archive_fixture "$cli_hook_parent" "$work_directory/cli-ini-hook.tar.gz"
if verify_archive_ok "$work_directory/cli-ini-hook.tar.gz"; then
    fail "An archive carrying a Certbot cli.ini with a hook must be rejected."
fi

# A benign one is refused just the same. The contract bans the file, not a list
# of directives: a filter that only caught hooks would still let cli.ini
# override --server, --authenticator or --config-dir.
cli_benign_parent="$work_directory/cli-ini-benign"
mkdir -p "$cli_benign_parent"
cp -R "$fixture_parent/letsencrypt" "$cli_benign_parent/letsencrypt"
printf 'rsa-key-size = 4096\n' >"$cli_benign_parent/letsencrypt/cli.ini"
archive_fixture "$cli_benign_parent" "$work_directory/cli-ini-benign.tar.gz"
if verify_archive_ok "$work_directory/cli-ini-benign.tar.gz"; then
    fail "An archive carrying any Certbot cli.ini must be rejected, hooks or not."
fi

# Defence in depth: the staged filesystem is checked too, so bypassing the
# metadata name check is not enough.
cli_staged_root="$work_directory/cli-ini-staged"
mkdir -p "$cli_staged_root"
cp -R "$restore_root/letsencrypt" "$cli_staged_root/letsencrypt"
printf 'pre-hook = /tmp/evil.sh\n' >"$cli_staged_root/letsencrypt/cli.ini"
if verify_staged_tree_safety_ok "$cli_staged_root"; then
    fail "A staged tree containing a Certbot cli.ini must be rejected."
fi

# A dangling symlink is still a path certbot would read once its target existed,
# so -e alone would not catch it.
cli_link_root="$work_directory/cli-ini-dangling"
mkdir -p "$cli_link_root"
cp -R "$restore_root/letsencrypt" "$cli_link_root/letsencrypt"
ln -s /tmp/does-not-exist-cli.ini "$cli_link_root/letsencrypt/cli.ini"
if verify_staged_tree_safety_ok "$cli_link_root"; then
    fail "A staged tree whose cli.ini is a dangling symlink must be rejected."
fi

# The valid fixture is unaffected by the new rule.
verify_archive_ok "$good_archive" ||
    fail "A tree with no cli.ini must remain acceptable."
verify_restored_tree_ok "$restore_root/letsencrypt" ||
    fail "A restored tree with no cli.ini must remain acceptable."

# --- 9. static contract: the script must not leak key material or delete ----
script_contents="$(cat "$SYNC_SCRIPT")"
for forbidden in "s3:DeleteObject" "rm -rf /etc" "cat \$key_file" "--recursive"; do
    assert_absent "$script_contents" "$forbidden" \
        "sync-origin-tls.sh must not reference: $forbidden"
done
assert_contains "$script_contents" "--sse AES256" \
    "The upload must request server side encryption explicitly."
assert_contains "$script_contents" "refusing to overwrite existing certbot state" \
    "Restore must refuse to overwrite an existing /etc/letsencrypt."

printf '[origin-tls-test] PASS\n'
