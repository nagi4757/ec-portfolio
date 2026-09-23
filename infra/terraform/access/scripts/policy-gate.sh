#!/usr/bin/env bash

# Semantic comparison gate for Identity Center inline policies.
#
# The access root adopts inline policies that already exist and were written by
# hand in the console. Before the first plan is trusted, the policy Terraform
# renders has to be the same policy, not a similar one. Comparing bytes proves
# nothing either way: aws_iam_policy_document reorders keys, renders a
# one-element list as a string and pretty-prints. This script reduces a policy to
# a canonical form in which only differences that carry meaning survive, so two
# policies compare equal exactly when they grant the same thing.
#
# Canonical form of a statement:
#   - Sid is kept (an empty string when absent) and Effect is kept verbatim.
#   - Action, NotAction, Resource and NotResource become sorted lists with
#     duplicates collapsed. IAM evaluates them as sets, and the provider renders
#     them as sets, so order and repetition carry no meaning.
#   - Condition becomes operator -> key -> sorted, de-duplicated list of strings.
#     Booleans and numbers become their JSON text, which is how the provider
#     renders condition values.
#   - Any other key is refused rather than ignored, so nothing can drop out of
#     the comparison unnoticed.
# Statements are compared as a multiset. Version and Id are compared as-is; a
# missing Version is not the same policy as "2012-10-17".
#
# Nothing is case-folded. IAM action names are case-insensitive, but a changed
# case is still a change to the reviewed text and fails the gate.
#
# Commands:
#   canonical <policy.json>
#       Prints the SHA-256 of the canonical form.
#   compare <expected.json> <actual.json>
#       Exits 1 when the two policies differ, listing what differs.
#   verify-import-plan <plan.json> <address>=<policy.json> [...]
#       <plan.json> is the output of `terraform show -json <saved plan>`.
#       Exits 1 unless the plan imports exactly the given addresses, changes no
#       managed resource at all, and each imported policy matches its file.

set -euo pipefail

readonly LOG_PREFIX="[policy-gate]"

readonly CANONICAL_POLICY_FILTER='
def as_list: if type == "array" then . else [.] end;

def scalar:
  if type == "string" then .
  elif type == "boolean" or type == "number" then tojson
  else error("unsupported policy value of type \(type)")
  end;

def value_set: as_list | map(scalar) | unique;

def sorted_keys:
  if type == "object" then to_entries | sort_by(.key) | map(.value |= sorted_keys) | from_entries
  elif type == "array" then map(sorted_keys)
  else .
  end;

def canonical_statement:
  if type != "object" then error("a statement is not a JSON object") else . end
  | (keys - ["Sid", "Effect", "Action", "NotAction", "Resource", "NotResource", "Condition"]) as $unsupported
  | if ($unsupported | length) > 0 then error("unsupported statement keys: \($unsupported | join(", "))") else . end
  | {Sid: (.Sid // ""), Effect: .Effect}
    + with_entries(select(.key | IN("Action", "NotAction", "Resource", "NotResource")) | .value |= value_set)
    + (if has("Condition") then {Condition: (.Condition | map_values(map_values(value_set)))} else {} end)
  | sorted_keys;

def canonical_policy:
  if type != "object" then error("the policy is not a JSON object") else . end
  | (keys - ["Version", "Id", "Statement"]) as $unsupported
  | if ($unsupported | length) > 0 then error("unsupported policy keys: \($unsupported | join(", "))") else . end
  | {
      Version: (.Version // null),
      Id: (.Id // null),
      Statement: (.Statement | as_list | map(canonical_statement | tojson) | sort)
    };

canonical_policy
'

# Lists what separates two canonical policies. Statements are identified by Sid,
# Effect and their first actions only: resources can carry account IDs, and the
# point is to say which statement to look at, not to print the policy.
readonly DIFFERENCE_FILTER='
def statement_label:
  fromjson
  | "Effect=\(.Effect) Sid=\(if .Sid == "" then "(none)" else .Sid end) Action=\((.Action // .NotAction // [])[0:3] | join(","))";

(if $expected.Version != $actual.Version then "  Version differs: expected \($expected.Version) actual \($actual.Version)" else empty end),
(if $expected.Id != $actual.Id then "  Id differs" else empty end),
(if ($expected.Statement | length) != ($actual.Statement | length)
 then "  statement count differs: expected \($expected.Statement | length) actual \($actual.Statement | length)"
 else empty end),
(($expected.Statement - $actual.Statement)[] | "  missing statement: \(statement_label)"),
(($actual.Statement - $expected.Statement)[] | "  unexpected statement: \(statement_label)")
'

work_directory=""

cleanup() {
    if [[ -n "$work_directory" && -d "$work_directory" ]]; then
        rm -rf -- "$work_directory"
    fi
}

trap cleanup EXIT

fail() {
    printf '%s FAIL: %s\n' "$LOG_PREFIX" "$*" >&2
    exit 1
}

usage() {
    printf 'Usage:\n' >&2
    printf '  %s canonical <policy.json>\n' "$0" >&2
    printf '  %s compare <expected.json> <actual.json>\n' "$0" >&2
    printf '  %s verify-import-plan <plan.json> <address>=<policy.json> [...]\n' "$0" >&2
    exit 2
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command is not available: $1"
}

sha256_of_stdin() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | cut -d ' ' -f 1
    else
        shasum -a 256 | cut -d ' ' -f 1
    fi
}

canonical_policy_of() {
    local file="$1"
    [[ -f "$file" ]] || fail "Policy file not found: $file"
    jq -cS "$CANONICAL_POLICY_FILTER" "$file" || fail "Cannot canonicalize policy: $file"
}

# Returns 0 when the two policy files are semantically identical. Prints the
# canonical digest on a match and the differences otherwise.
policies_match() {
    local expected_file="$1" actual_file="$2"
    local expected actual

    # Explicit returns: callers use this in `||` lists, where errexit is off.
    expected="$(canonical_policy_of "$expected_file")" || return 1
    actual="$(canonical_policy_of "$actual_file")" || return 1

    if [[ "$expected" == "$actual" ]]; then
        printf '%s MATCH %s canonical sha256=%s\n' "$LOG_PREFIX" "$actual_file" \
            "$(printf '%s' "$actual" | sha256_of_stdin)"
        return 0
    fi

    printf '%s MISMATCH expected=%s actual=%s\n' "$LOG_PREFIX" "$expected_file" "$actual_file" >&2
    jq -nr --argjson expected "$expected" --argjson actual "$actual" "$DIFFERENCE_FILTER" >&2
    return 1
}

command_canonical() {
    [[ $# -eq 1 ]] || usage
    local canonical
    canonical="$(canonical_policy_of "$1")"
    printf '%s\n' "$(printf '%s' "$canonical" | sha256_of_stdin)"
}

command_compare() {
    [[ $# -eq 2 ]] || usage
    policies_match "$1" "$2"
}

command_verify_import_plan() {
    [[ $# -ge 2 ]] || usage
    local plan_file="$1"
    shift

    [[ -f "$plan_file" ]] || fail "Plan JSON not found: $plan_file"
    jq -e 'type == "object" and has("format_version")' "$plan_file" >/dev/null 2>&1 ||
        fail "Not the JSON form of a plan (terraform show -json <plan>): $plan_file"

    work_directory="$(mktemp -d)"
    local violations=0
    local expected_addresses="" pair address policy_file

    for pair in "$@"; do
        [[ "$pair" == *=* ]] || usage
        address="${pair%%=*}"
        policy_file="${pair#*=}"
        [[ -n "$address" && -f "$policy_file" ]] || fail "Invalid <address>=<policy.json> argument: $pair"
        expected_addresses+="$address"$'\n'
    done
    expected_addresses="$(printf '%s' "$expected_addresses" | LC_ALL=C sort)"

    if [[ "$(jq -r '.errored // false' "$plan_file")" != "false" ]]; then
        printf '%s the plan is marked as errored\n' "$LOG_PREFIX" >&2
        violations=$((violations + 1))
    fi

    # Any managed change other than a no-op is a mutation. Data source reads are
    # not managed resources and are ignored.
    local mutations
    mutations="$(jq -r '
        .resource_changes[]?
        | select(.mode == "managed")
        | select(.change.actions != ["no-op"])
        | "  \(.address): \(.change.actions | join(","))"
    ' "$plan_file")"
    if [[ -n "$mutations" ]]; then
        printf '%s the plan changes managed resources:\n%s\n' "$LOG_PREFIX" "$mutations" >&2
        violations=$((violations + 1))
    fi

    local imported_addresses managed_addresses
    imported_addresses="$(jq -r '
        .resource_changes[]? | select(.mode == "managed") | select(.change.importing != null) | .address
    ' "$plan_file" | LC_ALL=C sort)"
    managed_addresses="$(jq -r '
        .resource_changes[]? | select(.mode == "managed") | .address
    ' "$plan_file" | LC_ALL=C sort)"

    if [[ "$imported_addresses" != "$expected_addresses" ]]; then
        printf '%s imported addresses differ.\n  expected:\n%s\n  imported:\n%s\n' "$LOG_PREFIX" \
            "$(printf '%s' "$expected_addresses" | sed 's/^/    /')" \
            "$(printf '%s' "$imported_addresses" | sed 's/^/    /')" >&2
        violations=$((violations + 1))
    fi
    if [[ "$managed_addresses" != "$expected_addresses" ]]; then
        printf '%s the plan touches managed resources other than the expected imports:\n%s\n' "$LOG_PREFIX" \
            "$(printf '%s' "$managed_addresses" | sed 's/^/    /')" >&2
        violations=$((violations + 1))
    fi

    local index=0 rendered_file
    for pair in "$@"; do
        address="${pair%%=*}"
        policy_file="${pair#*=}"
        index=$((index + 1))
        rendered_file="$work_directory/rendered-$index.json"

        if ! jq -er --arg address "$address" '
            .resource_changes[]?
            | select(.address == $address)
            | .change.after.inline_policy
            | select(type == "string")
        ' "$plan_file" >"$rendered_file"; then
            printf '%s no planned inline_policy for %s\n' "$LOG_PREFIX" "$address" >&2
            violations=$((violations + 1))
            continue
        fi

        policies_match "$policy_file" "$rendered_file" || violations=$((violations + 1))
    done

    if ((violations > 0)); then
        fail "$violations gate violation(s); the plan must not be applied."
    fi
    printf '%s PASS import-only plan: %d import(s), no managed change, every policy matches its baseline\n' \
        "$LOG_PREFIX" "$#"
}

main() {
    require_command jq
    [[ $# -ge 1 ]] || usage

    local command="$1"
    shift
    case "$command" in
        canonical) command_canonical "$@" ;;
        compare) command_compare "$@" ;;
        verify-import-plan) command_verify_import_plan "$@" ;;
        *) usage ;;
    esac
}

main "$@"
