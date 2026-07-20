#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_bwrap
require_command git
require_command script

loader_tmp_base="$TEST_DIR/.tmp"
mkdir -p -- "$loader_tmp_base"
loader_tmp=$(mktemp -d "$loader_tmp_base/proxy-hub-test.loader.XXXXXXXX")
register_cleanup_dir "$loader_tmp"

mkdir -p -- \
    "$loader_tmp/origin" \
    "$loader_tmp/assets" \
    "$loader_tmp/work" \
    "$loader_tmp/repo with spaces/lib" \
    "$loader_tmp/standalone-empty/lib" \
    "$loader_tmp/standalone-foreign/lib"
git -C "$REPO_ROOT" show "$LEGACY_BASELINE_COMMIT:proxy-hub.sh" >"$loader_tmp/origin/proxy-hub.sh"
cp -- "$REPO_ROOT/proxy-hub.sh" "$loader_tmp/repo with spaces/proxy-hub.sh"
cp -- "$REPO_ROOT/proxy-hub.sh" "$loader_tmp/standalone-empty/proxy-hub.sh"
cp -- "$REPO_ROOT/proxy-hub.sh" "$loader_tmp/standalone-foreign/proxy-hub.sh"
printf 'unrelated\n' >"$loader_tmp/standalone-foreign/lib/README.txt"
cp -- "$REPO_ROOT/lib/manifest.sha256" "$loader_tmp/repo with spaces/lib/manifest.sha256"
cp -- "$REPO_ROOT"/lib/[0-9][0-9]_*.sh "$loader_tmp/repo with spaces/lib/"
cp -- "$REPO_ROOT/dist/proxy-hub.bundle.sh" "$loader_tmp/assets/proxy-hub.bundle.sh"
cp -- "$REPO_ROOT/proxy-hub.sh" "$loader_tmp/assets/proxy-hub.sh"
ln -s -- /mnt/proxy-hub.sh "$loader_tmp/proxy-hub-link.sh"

sandbox_base=(
    bwrap
    --ro-bind / /
    --dev-bind /dev /dev
    --proc /proc
    --tmpfs /tmp
    --tmpfs /root
    --unshare-net
    --die-with-parent
    --ro-bind "$REPO_ROOT" /mnt
    --bind "$loader_tmp" /srv
    --setenv LANG en_US.UTF-8
    --setenv TERM xterm
    --setenv CURRENT_LANG en
)

run_sandbox() {
    local stdout_file="$1"
    local stderr_file="$2"
    local cwd="$3"
    shift 3
    local rc=0

    "${sandbox_base[@]}" --chdir "$cwd" -- "$@" >"$stdout_file" 2>"$stderr_file" || rc=$?
    printf '%s\n' "$rc"
}

compare_result() {
    local expected_rc="$1"
    local actual_rc="$2"
    local expected_stdout="$3"
    local actual_stdout="$4"
    local expected_stderr="$5"
    local actual_stderr="$6"
    local label="$7"
    local expected_norm="$loader_tmp/${label//[^a-zA-Z0-9]/_}.expected.norm"
    local actual_norm="$loader_tmp/${label//[^a-zA-Z0-9]/_}.actual.norm"
    local expected_err_norm="$expected_norm.err"
    local actual_err_norm="$actual_norm.err"

    assert_eq "$expected_rc" "$actual_rc" "$label exit status"
    normalize_output "$expected_stdout" >"$expected_norm"
    normalize_output "$actual_stdout" >"$actual_norm"
    normalize_output "$expected_stderr" >"$expected_err_norm"
    normalize_output "$actual_stderr" >"$actual_err_norm"
    if ! cmp -s -- "$expected_norm" "$actual_norm"; then
        diff -u -- "$expected_norm" "$actual_norm" >&2 || true
        fail "$label stdout parity"
    fi
    if ! cmp -s -- "$expected_err_norm" "$actual_err_norm"; then
        diff -u -- "$expected_err_norm" "$actual_err_norm" >&2 || true
        fail "$label stderr parity"
    fi
}

case_index=0
for command_arg in help -h --help definitely-unknown; do
    ((case_index += 1))
    origin_out="$loader_tmp/origin.$case_index.out"
    origin_err="$loader_tmp/origin.$case_index.err"
    local_out="$loader_tmp/local.$case_index.out"
    local_err="$loader_tmp/local.$case_index.err"
    remote_out="$loader_tmp/remote.$case_index.out"
    remote_err="$loader_tmp/remote.$case_index.err"

    origin_rc=$(run_sandbox "$origin_out" "$origin_err" /tmp bash /srv/origin/proxy-hub.sh "$command_arg")
    local_rc=$(run_sandbox "$local_out" "$local_err" /tmp bash /mnt/proxy-hub.sh "$command_arg")

    remote_rc=0
    "${sandbox_base[@]}" \
        --setenv PATH "/mnt/tests/fixtures/fake-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        --setenv FAKE_CURL_ASSET_DIR /srv/assets \
        --setenv FAKE_CURL_LOG /srv/curl.log \
        --chdir /tmp \
        -- bash -c 'bash <(cat /mnt/proxy-hub.sh) "$1"' _ "$command_arg" \
        >"$remote_out" 2>"$remote_err" || remote_rc=$?

    compare_result "$origin_rc" "$local_rc" "$origin_out" "$local_out" "$origin_err" "$local_err" "local-$command_arg"
    compare_result "$origin_rc" "$remote_rc" "$origin_out" "$remote_out" "$origin_err" "$remote_err" "remote-$command_arg"
done
pass "help aliases and unknown-command behavior match the pinned historical baseline"

origin_out="$loader_tmp/origin.path.out"
origin_err="$loader_tmp/origin.path.err"
origin_rc=$(run_sandbox "$origin_out" "$origin_err" /tmp bash /srv/origin/proxy-hub.sh help)

for invocation in absolute space symlink; do
    actual_out="$loader_tmp/$invocation.out"
    actual_err="$loader_tmp/$invocation.err"
    case "$invocation" in
        absolute)
            actual_rc=$(run_sandbox "$actual_out" "$actual_err" /tmp bash /mnt/proxy-hub.sh help)
            ;;
        space)
            actual_rc=$(run_sandbox "$actual_out" "$actual_err" /tmp bash "/srv/repo with spaces/proxy-hub.sh" help)
            ;;
        symlink)
            actual_rc=$(run_sandbox "$actual_out" "$actual_err" /tmp bash /srv/proxy-hub-link.sh help)
            ;;
    esac
    compare_result "$origin_rc" "$actual_rc" "$origin_out" "$actual_out" "$origin_err" "$actual_err" "path-$invocation"
done
pass "local loader resolves modules from arbitrary cwd, space-containing paths, and symlinks"

for standalone_case in standalone-empty standalone-foreign; do
    standalone_out="$loader_tmp/$standalone_case.out"
    standalone_err="$loader_tmp/$standalone_case.err"
    standalone_rc=0
    "${sandbox_base[@]}" \
        --setenv PATH "/mnt/tests/fixtures/fake-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        --setenv FAKE_CURL_ASSET_DIR /srv/assets \
        --setenv FAKE_CURL_LOG "/srv/$standalone_case.curl.log" \
        --chdir /tmp \
        -- bash "/srv/$standalone_case/proxy-hub.sh" help \
        >"$standalone_out" 2>"$standalone_err" || standalone_rc=$?
    compare_result "$origin_rc" "$standalone_rc" \
        "$origin_out" "$standalone_out" "$origin_err" "$standalone_err" "path-$standalone_case"
    assert_file "$loader_tmp/$standalone_case.curl.log"
done
pass "empty or unrelated adjacent lib directories keep standalone loader remote mode"

source_state_out="$loader_tmp/source-state.out"
source_state_err="$loader_tmp/source-state.err"
source_state_rc=0
"${sandbox_base[@]}" --chdir /tmp -- bash -c '
    set -euo pipefail
    set -- alpha beta
    shopt -s nullglob dotglob
    trap "printf caller-hup >/srv/caller-hup" HUP
    before_hup=$(trap -p HUP)
    source /mnt/proxy-hub.sh help >/srv/source-help.out
    [[ "$#" -eq 2 && "$1" == alpha && "$2" == beta ]]
    shopt -q nullglob
    shopt -q dotglob
    [[ "$(trap -p HUP)" == "$before_hup" ]]
' >"$source_state_out" 2>"$source_state_err" || source_state_rc=$?
assert_eq "0" "$source_state_rc" "sourced loader caller-state preservation"
pass "sourced local loader preserves caller args, nullglob, dotglob, and HUP trap"

origin_zero_out="$loader_tmp/origin.zero.out"
origin_zero_err="$loader_tmp/origin.zero.err"
local_zero_out="$loader_tmp/local.zero.out"
local_zero_err="$loader_tmp/local.zero.err"
remote_zero_out="$loader_tmp/remote.zero.out"
remote_zero_err="$loader_tmp/remote.zero.err"
exact_curl_log="$loader_tmp/exact-curl.log"

origin_zero_rc=0
"${sandbox_base[@]}" --chdir /tmp -- bash -c 'printf "0\n" | bash /srv/origin/proxy-hub.sh' \
    >"$origin_zero_out" 2>"$origin_zero_err" || origin_zero_rc=$?
local_zero_rc=0
"${sandbox_base[@]}" --chdir /tmp -- bash -c 'printf "0\n" | bash /mnt/proxy-hub.sh' \
    >"$local_zero_out" 2>"$local_zero_err" || local_zero_rc=$?
remote_zero_rc=0
"${sandbox_base[@]}" \
    --setenv PATH "/mnt/tests/fixtures/fake-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    --setenv FAKE_CURL_ASSET_DIR /srv/assets \
    --setenv FAKE_CURL_LOG /srv/exact-curl.log \
    --chdir /tmp \
    -- bash -c 'printf "0\n" | bash <(curl -Ls https://raw.githubusercontent.com/Banezzz/proxy-hub/main/proxy-hub.sh)' \
    >"$remote_zero_out" 2>"$remote_zero_err" || remote_zero_rc=$?

compare_result "$origin_zero_rc" "$local_zero_rc" \
    "$origin_zero_out" "$local_zero_out" "$origin_zero_err" "$local_zero_err" "zero-arg-local"
compare_result "$origin_zero_rc" "$remote_zero_rc" \
    "$origin_zero_out" "$remote_zero_out" "$origin_zero_err" "$remote_zero_err" "zero-arg-remote"
pass "zero-argument local and exact documented remote commands enter and exit the interactive menu"

pty_local_out="$loader_tmp/local.pty.out"
pty_local_err="$loader_tmp/local.pty.err"
pty_remote_out="$loader_tmp/remote.pty.out"
pty_remote_err="$loader_tmp/remote.pty.err"
pty_local_command="bash -c '[[ -t 0 && -t 1 ]] || exit 88; exec bash /mnt/proxy-hub.sh'"
pty_remote_command="bash -c '[[ -t 0 && -t 1 ]] || exit 88; exec bash <(curl -Ls https://raw.githubusercontent.com/Banezzz/proxy-hub/main/proxy-hub.sh)'"

pty_local_rc=0
printf '0\n' | "${sandbox_base[@]}" --chdir /tmp -- \
    bash -c 'script -qefc "$1" /dev/null' _ "$pty_local_command" \
    >"$pty_local_out" 2>"$pty_local_err" || pty_local_rc=$?
assert_eq "0" "$pty_local_rc" "PTY-backed local zero-argument invocation"
assert_contains "$(<"$pty_local_out")" "VLESS TCP REALITY Vision" "PTY-backed local menu output"

pty_remote_rc=0
printf '0\n' | "${sandbox_base[@]}" \
    --setenv PATH "/mnt/tests/fixtures/fake-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    --setenv FAKE_CURL_ASSET_DIR /srv/assets \
    --setenv FAKE_CURL_LOG /srv/pty-curl.log \
    --chdir /tmp -- bash -c 'script -qefc "$1" /dev/null' _ "$pty_remote_command" \
    >"$pty_remote_out" 2>"$pty_remote_err" || pty_remote_rc=$?
assert_eq "0" "$pty_remote_rc" "PTY-backed exact remote zero-argument invocation"
assert_contains "$(<"$pty_remote_out")" "VLESS TCP REALITY Vision" "PTY-backed remote menu output"
pass "local and exact remote zero-argument invocations preserve terminal-backed stdin/stdout"

mapfile -t exact_curl_records <"$exact_curl_log"
assert_eq "2" "${#exact_curl_records[@]}" "exact remote command must fetch one loader and one bundle"
assert_contains "${exact_curl_records[0]}" \
    "curl -Ls https://raw.githubusercontent.com/Banezzz/proxy-hub/main/proxy-hub.sh" \
    "outer curl command shape"
[[ "${exact_curl_records[1]}" == "curl -q "* ]] || fail "inner bundle curl must put -q first"
for required_arg in --proto --proto-redir --tlsv1.2 --max-redirs --fail --silent --show-error --location; do
    assert_contains "${exact_curl_records[1]}" "$required_arg" "inner bundle curl policy"
done
assert_contains "${exact_curl_records[1]}" "/dist/proxy-hub.bundle.sh" "inner bundle URL"
pass "exact remote command and complete HTTPS-only inner curl policy are recorded"

curl_log=$(<"$loader_tmp/curl.log")
assert_contains "$curl_log" "https://raw.githubusercontent.com/Banezzz/proxy-hub/" "remote loader must use raw.githubusercontent.com over HTTPS"
assert_contains "$curl_log" "/dist/proxy-hub.bundle.sh" "remote loader must request the dist bundle"
assert_not_contains "$curl_log" " http://" "remote loader must not downgrade to HTTP"
pass "process-substitution mode fetched the dist bundle through fake curl without network access"
