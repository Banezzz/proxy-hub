#!/usr/bin/env bash

# Shared helpers for the proxy-hub shell test suite.  Test entrypoints must set
# `set -euo pipefail` before sourcing this file.

TEST_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
TEST_DIR="$(cd -- "$TEST_LIB_DIR/.." && pwd -P)"
REPO_ROOT="$(cd -- "$TEST_DIR/.." && pwd -P)"
readonly LEGACY_BASELINE_COMMIT="8ca0766e66278ce22377ce81040a98c8159d9c6e"

declare -a TEST_CLEANUP_PATHS=()

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}

pass() {
    printf 'ok - %s\n' "$*"
}

note() {
    printf '# %s\n' "$*"
}

register_cleanup_dir() {
    local path="$1"
    [[ -n "$path" && "$path" == /* ]] || fail "refusing non-absolute cleanup path: $path"
    case "$path" in
        /tmp/proxy-hub-test.*|/var/tmp/proxy-hub-test.*|"$REPO_ROOT"/tests/.tmp/proxy-hub-test.*)
            TEST_CLEANUP_PATHS+=("$path")
            ;;
        *)
            fail "refusing cleanup path outside the test namespace: $path"
            ;;
    esac
}

new_test_dir() {
    local topic="${1:-case}"
    local base="${TMPDIR:-/tmp}"
    local path

    mkdir -p -- "$base"
    path=$(mktemp -d "$base/proxy-hub-test.${topic}.XXXXXXXX")
    register_cleanup_dir "$path"
    printf '%s\n' "$path"
}

cleanup_test_dirs() {
    local i path
    for ((i=${#TEST_CLEANUP_PATHS[@]} - 1; i >= 0; i--)); do
        path="${TEST_CLEANUP_PATHS[$i]}"
        [[ -e "$path" || -L "$path" ]] || continue
        case "$path" in
            /tmp/proxy-hub-test.*|/var/tmp/proxy-hub-test.*|"$REPO_ROOT"/tests/.tmp/proxy-hub-test.*)
                rm -rf -- "$path"
                ;;
            *)
                printf 'refusing unsafe cleanup path during exit: %s\n' "$path" >&2
                ;;
        esac
    done
}

trap cleanup_test_dirs EXIT

assert_file() {
    [[ -f "$1" ]] || fail "expected file: $1"
}

assert_dir() {
    [[ -d "$1" ]] || fail "expected directory: $1"
}

assert_not_exists() {
    [[ ! -e "$1" && ! -L "$1" ]] || fail "path should not exist: $1"
}

assert_eq() {
    local expected="$1"
    local actual="$2"
    local context="${3:-values differ}"
    [[ "$expected" == "$actual" ]] || {
        printf 'expected: <%s>\nactual:   <%s>\n' "$expected" "$actual" >&2
        fail "$context"
    }
}

assert_ne() {
    local unexpected="$1"
    local actual="$2"
    local context="${3:-values unexpectedly equal}"
    [[ "$unexpected" != "$actual" ]] || fail "$context: $actual"
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local context="${3:-missing expected text}"
    [[ "$haystack" == *"$needle"* ]] || fail "$context: $needle"
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local context="${3:-found forbidden text}"
    [[ "$haystack" != *"$needle"* ]] || fail "$context: $needle"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

sha256_file() {
    sha256sum "$1" | awk '{print $1}'
}

run_capture() {
    local stdout_file="$1"
    local stderr_file="$2"
    shift 2
    local rc=0

    "$@" >"$stdout_file" 2>"$stderr_file" || rc=$?
    printf '%s\n' "$rc"
}

# Return a normalized rendering suitable for parity comparisons.  Only values
# known to vary by invocation mechanism are normalized; business output is not.
normalize_output() {
    sed -E \
        -e 's#/srv/repo with spaces/proxy-hub\.sh#<SCRIPT>#g' \
        -e 's#/srv/proxy-hub-link\.sh#<SCRIPT>#g' \
        -e 's#/srv/origin/proxy-hub\.sh#<SCRIPT>#g' \
        -e 's#/mnt/proxy-hub\.sh#<SCRIPT>#g' \
        -e 's#/dev/fd/[0-9]+#<SCRIPT>#g' \
        -e 's#bash /[^ ]*/proxy-hub(\.full|\.bundle)?\.sh#bash <SCRIPT>#g' \
        -e 's#bash [^ ]*proxy-hub\.sh#bash <SCRIPT>#g' \
        "$1"
}

require_bwrap() {
    require_command bwrap
    bwrap \
        --ro-bind / / \
        --dev-bind /dev /dev \
        --proc /proc \
        --tmpfs /tmp \
        --tmpfs /root \
        --unshare-net \
        --die-with-parent \
        -- bash -c ':' >/dev/null 2>&1 || fail "bwrap is installed but unusable"
}
