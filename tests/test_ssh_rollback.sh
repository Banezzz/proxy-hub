#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_bwrap

test_base="$TEST_DIR/.tmp"
mkdir -p -- "$test_base"
test_tmp=$(mktemp -d "$test_base/proxy-hub-test.ssh-rollback.XXXXXXXX")
register_cleanup_dir "$test_tmp"

sandbox=(
    bwrap
    --ro-bind / /
    --dev-bind /dev /dev
    --proc /proc
    --tmpfs /tmp
    --tmpfs /root
    --tmpfs /run
    --unshare-net
    --die-with-parent
    --ro-bind "$REPO_ROOT" /mnt
    --bind "$test_tmp" /srv
    --setenv TMPDIR /srv/tmp
)
mkdir -p -- "$test_tmp/tmp"

run_scenario() {
    local label="$1" script="$2"
    local stdout_file="$test_tmp/$label.out" stderr_file="$test_tmp/$label.err"
    local rc=0
    "${sandbox[@]}" -- bash -c "$script" >"$stdout_file" 2>"$stderr_file" || rc=$?
    if ((rc != 0)); then
        sed -n '1,200p' "$stderr_file" >&2
        fail "$label failed with status $rc"
    fi
    pass "$label"
}

run_scenario successful-transactional-rollback '
    set -euo pipefail
    source /mnt/lib/00_security_state.sh
    source /mnt/lib/10_runtime_platform_ui.sh
    source /mnt/lib/70_ports_logs.sh
    INIT_SYSTEM=systemd
    printf "Port 22\n" >/srv/ssh.config
    lock_acquire_smart
    ssh_rollback_prepare_state
    state_dir=$SSH_ROLLBACK_STATE_DIR
    ssh_rollback_create_backup /srv/ssh.config
    printf "Port 2222\n" >/srv/ssh.config
    start_ssh_rollback_timer /srv/ssh.config "$SSH_ROLLBACK_BACKUP" 22 120 \
        "$SSH_ROLLBACK_STATE_DIR/confirmed"
    cleanup_pending_ssh_rollback
    [[ "$(cat /srv/ssh.config)" == "Port 22" ]]
    [[ ! -e "$state_dir" ]]
    [[ -z "$SSH_ROLLBACK_STATE_DIR" && -z "$SSH_ROLLBACK_BACKUP" ]]
    lock_release_smart
'

run_scenario direct-rollback-clears-state-and-allows-reuse '
    set -euo pipefail
    source /mnt/lib/00_security_state.sh
    source /mnt/lib/10_runtime_platform_ui.sh
    source /mnt/lib/70_ports_logs.sh
    INIT_SYSTEM=systemd
    printf "Port 22\n" >/srv/ssh.config
    lock_acquire_smart
    first_lock_dir=$LOCK_DIR
    ssh_rollback_prepare_state
    first_state_dir=$SSH_ROLLBACK_STATE_DIR
    ssh_rollback_create_backup /srv/ssh.config
    printf "Port 2222\n" >/srv/ssh.config
    _ssh_rollback /srv/ssh.config "$SSH_ROLLBACK_BACKUP" 22
    [[ "$(cat /srv/ssh.config)" == "Port 22" ]]
    [[ ! -e "$first_state_dir" ]]
    for rollback_var in \
        SSH_ROLLBACK_PID SSH_ROLLBACK_ID SSH_ROLLBACK_CONFIG \
        SSH_ROLLBACK_BACKUP SSH_ROLLBACK_BACKUP_ID SSH_ROLLBACK_ORIGINAL_PORT \
        SSH_ROLLBACK_MARKER SSH_ROLLBACK_MARKER_TOKEN SSH_ROLLBACK_RESULT_FILE \
        SSH_ROLLBACK_STATE_DIR SSH_ROLLBACK_STATE_ID SSH_ROLLBACK_STATE_TOKEN \
        SSH_ROLLBACK_TOKEN_FILE SSH_ROLLBACK_TOKEN_ID SSH_ROLLBACK_CLAIM_RESULT; do
        [[ -z "${!rollback_var}" ]]
    done
    cleanup
    [[ -z "$LOCK_HELD_METHOD" && ! -e "$first_lock_dir" ]]

    lock_acquire_smart
    second_lock_dir=$LOCK_DIR
    ssh_rollback_prepare_state
    second_state_dir=$SSH_ROLLBACK_STATE_DIR
    [[ "$second_state_dir" != "$first_state_dir" ]]
    ssh_rollback_create_backup /srv/ssh.config
    printf "Port 2200\n" >/srv/ssh.config
    _ssh_rollback /srv/ssh.config "$SSH_ROLLBACK_BACKUP" 22
    [[ "$(cat /srv/ssh.config)" == "Port 22" ]]
    [[ ! -e "$second_state_dir" && -z "$SSH_ROLLBACK_STATE_DIR" ]]
    cleanup
    [[ -z "$LOCK_HELD_METHOD" && ! -e "$second_lock_dir" ]]
'

run_scenario restart-failure-retains-state-and-lock '
    set -euo pipefail
    source /mnt/lib/00_security_state.sh
    source /mnt/lib/10_runtime_platform_ui.sh
    source /mnt/lib/70_ports_logs.sh
    INIT_SYSTEM=systemd
    printf "Port 22\n" >/srv/ssh.config
    lock_acquire_smart
    lock_dir=$LOCK_DIR
    ssh_rollback_prepare_state
    state_dir=$SSH_ROLLBACK_STATE_DIR
    ssh_rollback_create_backup /srv/ssh.config
    backup=$SSH_ROLLBACK_BACKUP
    printf "Port 2222\n" >/srv/ssh.config
    start_ssh_rollback_timer /srv/ssh.config "$backup" 22 120 \
        "$SSH_ROLLBACK_STATE_DIR/confirmed"
    ssh_rollback_validate_config() { return 0; }
    ssh_rollback_restart_service() { return 1; }
    cleanup
    [[ -d "$lock_dir" && -d "$state_dir" && -f "$backup" ]]
    [[ "$(cat /srv/ssh.config)" == "Port 22" ]]
    ssh_rollback_restart_service() { return 0; }
    cleanup_pending_ssh_rollback
    [[ ! -e "$state_dir" ]]
    clear_ssh_rollback_state
    CLEANUP_UNSAFE_TO_UNLOCK=0
    lock_release_smart
'

run_scenario failed-backup-creation-cleans-unstarted-state '
    set -euo pipefail
    source /mnt/lib/00_security_state.sh
    source /mnt/lib/10_runtime_platform_ui.sh
    source /mnt/lib/70_ports_logs.sh
    lock_acquire_smart
    ssh_rollback_prepare_state
    state_dir=$SSH_ROLLBACK_STATE_DIR
    if ssh_rollback_create_backup /srv/missing-sshd-config; then
        echo "missing source unexpectedly produced a backup" >&2
        exit 1
    fi
    cleanup_pending_ssh_rollback
    [[ ! -e "$state_dir" ]]
    [[ -z "$SSH_ROLLBACK_STATE_DIR" ]]
    lock_release_smart
'

run_scenario symlink-replacement-is-rejected '
    set -euo pipefail
    source /mnt/lib/00_security_state.sh
    source /mnt/lib/10_runtime_platform_ui.sh
    source /mnt/lib/70_ports_logs.sh
    printf "Port 22\n" >/srv/ssh.config
    printf "foreign\n" >/srv/foreign
    lock_acquire_smart
    ssh_rollback_prepare_state
    state_dir=$SSH_ROLLBACK_STATE_DIR
    ssh_rollback_create_backup /srv/ssh.config
    backup=$SSH_ROLLBACK_BACKUP
    start_ssh_rollback_timer /srv/ssh.config "$backup" 22 120 \
        "$SSH_ROLLBACK_STATE_DIR/confirmed"
    mv -- "$backup" "$state_dir/original.backup"
    ln -s /srv/foreign "$backup"
    if cleanup_pending_ssh_rollback; then
        echo "symlink replacement unexpectedly passed rollback validation" >&2
        exit 1
    fi
    [[ "$(cat /srv/foreign)" == "foreign" ]]
    [[ -d "$state_dir" && -L "$backup" ]]
    rm -- "$backup"
    mv -- "$state_dir/original.backup" "$backup"
    SSH_ROLLBACK_BACKUP_ID=$(ssh_rollback_file_identity "$backup")
    cleanup_pending_ssh_rollback
    [[ ! -e "$state_dir" ]]
    lock_release_smart
'

run_scenario late-confirmation-waits-for-claimed-rollback '
    set -euo pipefail
    source /mnt/lib/00_security_state.sh
    source /mnt/lib/10_runtime_platform_ui.sh
    source /mnt/lib/70_ports_logs.sh
    INIT_SYSTEM=systemd
    printf "Port 22\n" >/srv/ssh.config
    lock_acquire_smart
    ssh_rollback_prepare_state
    state_dir=$SSH_ROLLBACK_STATE_DIR
    ssh_rollback_create_backup /srv/ssh.config
    backup=$SSH_ROLLBACK_BACKUP
    printf "Port 2222\n" >/srv/ssh.config
    ssh_rollback_validate_config() {
        printf "reached\n" >/srv/rollback-restored
        while [[ ! -e /srv/release-rollback ]]; do sleep 0.02; done
    }
    ssh_rollback_restart_service() { return 0; }
    start_ssh_rollback_timer /srv/ssh.config "$backup" 22 1 \
        "$state_dir/confirmed"
    for _ in $(seq 1 200); do
        [[ -e /srv/rollback-restored ]] && break
        sleep 0.02
    done
    [[ -e /srv/rollback-restored ]]
    (
        [[ "$(cat /srv/ssh.config)" == "Port 22" ]]
        [[ -d "$state_dir" && -f "$backup" ]]
        [[ "$(ssh_rollback_phase_current)" == "rolling-back" ]]
        [[ ! -e "$state_dir/rolled-back" ]]
        printf "release\n" >/srv/release-rollback
    ) &
    observer_pid=$!
    confirm_status=0
    ssh_rollback_confirm >/srv/confirm.out 2>/srv/confirm.err || confirm_status=$?
    wait "$observer_pid"
    [[ "$confirm_status" -eq 2 ]]
    grep -q "确认输掉回滚竞态" /srv/confirm.err
    ! grep -q "SUCCESS" /srv/confirm.out
    [[ "$(cat /srv/ssh.config)" == "Port 22" ]]
    [[ ! -e "$backup" && ! -e "$state_dir" ]]
    [[ -z "$SSH_ROLLBACK_STATE_DIR" ]]
    lock_release_smart
'

run_scenario phase-claim-has-exactly-one-winner '
    set -euo pipefail
    source /mnt/lib/00_security_state.sh
    source /mnt/lib/10_runtime_platform_ui.sh
    source /mnt/lib/70_ports_logs.sh
    lock_acquire_smart
    ssh_rollback_prepare_state
    state_dir=$SSH_ROLLBACK_STATE_DIR
    (
        claim_status=0
        ssh_rollback_claim_phase confirmed || claim_status=$?
        printf "%s\n" "$claim_status" >/srv/confirmed.status
    ) &
    confirmed_pid=$!
    (
        claim_status=0
        ssh_rollback_claim_phase rolling-back || claim_status=$?
        printf "%s\n" "$claim_status" >/srv/rollback.status
    ) &
    rollback_pid=$!
    wait "$confirmed_pid"
    wait "$rollback_pid"
    confirmed_status=$(cat /srv/confirmed.status)
    rollback_status=$(cat /srv/rollback.status)
    if [[ "$confirmed_status" -eq 0 ]]; then
        [[ "$rollback_status" -ne 0 ]]
        [[ "$(ssh_rollback_phase_current)" == "confirmed" ]]
    else
        [[ "$rollback_status" -eq 0 ]]
        [[ "$(ssh_rollback_phase_current)" == "rolling-back" ]]
    fi
    [[ ! -e "$state_dir/phase.pending" ]]
    ssh_rollback_remove_state
    clear_ssh_rollback_state
    lock_release_smart
'

run_scenario rollback-durability-ordering '
    set -euo pipefail
    source /mnt/lib/00_security_state.sh
    source /mnt/lib/10_runtime_platform_ui.sh
    source /mnt/lib/70_ports_logs.sh
    INIT_SYSTEM=systemd
    printf "Port 22\n" >/srv/ssh.config
    lock_acquire_smart
    ssh_rollback_prepare_state
    state_dir=$SSH_ROLLBACK_STATE_DIR
    ssh_rollback_sync_path() { return 0; }
    ssh_rollback_create_backup /srv/ssh.config
    backup=$SSH_ROLLBACK_BACKUP
    printf "Port 2222\n" >/srv/ssh.config
    : >/srv/order.log
    ssh_rollback_sync_path() {
        local backup_state=absent
        [[ -e "$backup" ]] && backup_state=present
        printf "sync:%s:backup=%s\n" "$1" "$backup_state" >>/srv/order.log
    }
    ssh_rollback_validate_config() { printf "validate\n" >>/srv/order.log; }
    ssh_rollback_restart_service() { printf "restart\n" >>/srv/order.log; }
    SSH_ROLLBACK_CONFIG=/srv/ssh.config
    SSH_ROLLBACK_ORIGINAL_PORT=22
    SSH_ROLLBACK_RESULT_FILE="$state_dir/rolled-back"
    ssh_rollback_claim_phase rolling-back
    _ssh_rollback_claimed /srv/ssh.config "$backup" 22
    mapfile -t order </srv/order.log
    [[ "${order[0]}" == "sync:$state_dir:backup=present" ]]
    [[ "${order[1]}" == "sync:/srv/ssh.config:backup=present" ]]
    [[ "${order[2]}" == "validate" ]]
    [[ "${order[3]}" == "restart" ]]
    [[ "${order[4]}" == "sync:$state_dir/rolled-back:backup=present" ]]
    [[ "${order[5]}" == "sync:$state_dir:backup=present" ]]
    [[ "${order[6]}" == "sync:$state_dir:backup=absent" ]]
    [[ -f "$state_dir/rolled-back" && ! -e "$backup" ]]
    ssh_rollback_remove_state
    clear_ssh_rollback_state
    lock_release_smart
'

run_scenario sync-failures-retain-state-and-lock '
    set -euo pipefail
    source /mnt/lib/00_security_state.sh
    source /mnt/lib/10_runtime_platform_ui.sh
    source /mnt/lib/70_ports_logs.sh
    INIT_SYSTEM=systemd
    printf "Port 22\n" >/srv/ssh.config
    lock_acquire_smart
    lock_dir=$LOCK_DIR
    ssh_rollback_prepare_state
    state_dir=$SSH_ROLLBACK_STATE_DIR
    SSH_ROLLBACK_CONFIG=/srv/ssh.config
    SSH_ROLLBACK_ORIGINAL_PORT=22
    SSH_ROLLBACK_RESULT_FILE="$state_dir/rolled-back"
    ssh_rollback_sync_path() {
        [[ "$1" != "$SSH_ROLLBACK_STATE_DIR/sshd_config.backup" ]]
    }
    if ssh_rollback_create_backup /srv/ssh.config; then
        echo "backup sync failure unexpectedly succeeded" >&2
        exit 1
    fi
    backup=$SSH_ROLLBACK_BACKUP
    [[ -f "$backup" && -d "$state_dir" && -d "$lock_dir" ]]
    [[ "$(cat /srv/ssh.config)" == "Port 22" ]]
    ssh_rollback_sync_path() { return 0; }
    cleanup_pending_ssh_rollback
    [[ ! -e "$state_dir" ]]

    ssh_rollback_prepare_state
    state_dir=$SSH_ROLLBACK_STATE_DIR
    ssh_rollback_create_backup /srv/ssh.config
    backup=$SSH_ROLLBACK_BACKUP
    printf "Port 2222\n" >/srv/ssh.config
    SSH_ROLLBACK_CONFIG=/srv/ssh.config
    SSH_ROLLBACK_ORIGINAL_PORT=22
    SSH_ROLLBACK_RESULT_FILE="$state_dir/rolled-back"
    ssh_rollback_claim_phase rolling-back
    ssh_rollback_validate_config() { printf "validate\n" >/srv/unexpected-validate; }
    ssh_rollback_restart_service() { printf "restart\n" >/srv/unexpected-restart; }
    ssh_rollback_sync_path() { [[ "$1" != /srv/ssh.config ]]; }
    if _ssh_rollback_claimed /srv/ssh.config "$backup" 22; then
        echo "restore sync failure unexpectedly completed rollback" >&2
        exit 1
    fi
    [[ "$(cat /srv/ssh.config)" == "Port 22" ]]
    [[ ! -e /srv/unexpected-validate && ! -e /srv/unexpected-restart ]]
    [[ -f "$backup" && -d "$state_dir" && -d "$lock_dir" ]]
    ssh_rollback_sync_path() { return 0; }
    ssh_rollback_validate_config() { return 0; }
    ssh_rollback_restart_service() { return 0; }
    cleanup_pending_ssh_rollback
    [[ ! -e "$state_dir" ]]
    lock_release_smart
'

hup_rc=0
"${sandbox[@]}" \
    --setenv PATH "/mnt/tests/fixtures/fake-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    --setenv FAKE_MKTEMP_SIGNAL 1 \
    --setenv FAKE_MKTEMP_SIGNAL_NAME HUP \
    -- setsid bash -c '
        set -euo pipefail
        source /mnt/lib/00_security_state.sh
        source /mnt/lib/10_runtime_platform_ui.sh
        source /mnt/lib/70_ports_logs.sh
        lock_acquire_smart
        ssh_rollback_prepare_state
        exit 99
    ' >"$test_tmp/hup.out" 2>"$test_tmp/hup.err" || hup_rc=$?
[[ "$hup_rc" -eq 129 ]] || {
    sed -n '1,200p' "$test_tmp/hup.err" >&2
    fail "SSH rollback HUP publication exited with $hup_rc instead of 129"
}
if compgen -G "$test_tmp/tmp/proxy-hub-*/ssh-rollback.*" >/dev/null; then
    fail "SSH rollback state leaked after HUP publication"
fi
pass "HUP is deferred until SSH rollback state identity is published"
