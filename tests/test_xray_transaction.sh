#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

if [[ "${PROXY_HUB_XRAY_TRANSACTION_SANDBOXED:-0}" != "1" ]]; then
    require_bwrap

    transaction_tmp_base="$TEST_DIR/.tmp"
    mkdir -p -- "$transaction_tmp_base"
    transaction_tmp=$(mktemp -d "$transaction_tmp_base/proxy-hub-test.xray-transaction.XXXXXXXX")
    register_cleanup_dir "$transaction_tmp"

    bwrap \
        --ro-bind / / \
        --dev-bind /dev /dev \
        --proc /proc \
        --tmpfs /tmp \
        --tmpfs /root \
        --tmpfs /run \
        --unshare-net \
        --die-with-parent \
        --ro-bind "$REPO_ROOT" /mnt \
        --bind "$transaction_tmp" /srv \
        --setenv PROXY_HUB_XRAY_TRANSACTION_SANDBOXED 1 \
        --setenv PROXY_HUB_TESTING 1 \
        --setenv CURRENT_LANG en \
        -- bash /mnt/tests/test_xray_transaction.sh
    pass "Xray transaction tests completed without network or host service access"
    exit 0
fi

assert_file /mnt/lib/15_xray_release.sh
assert_file /mnt/lib/20_installers_restart.sh

export PROXY_HUB_TESTING=1
export CURRENT_LANG=en
# shellcheck source=../lib/00_security_state.sh
source /mnt/lib/00_security_state.sh
# shellcheck source=../lib/10_runtime_platform_ui.sh
source /mnt/lib/10_runtime_platform_ui.sh
# shellcheck source=../lib/15_xray_release.sh
source /mnt/lib/15_xray_release.sh
# shellcheck source=../lib/20_installers_restart.sh
source /mnt/lib/20_installers_restart.sh

# The runtime module installs application-wide signal/exit traps.  Each update
# transaction installs its own scoped traps, so the test harness does not need
# the application traps after sourcing the functions under test.
trap - EXIT INT TERM HUP

write_fake_xray() {
    local path="$1" version="$2" config_ok="$3"
    {
        printf '%s\n' '#!/usr/bin/env bash'
        printf 'fake_version=%q\n' "$version"
        printf 'config_ok=%q\n' "$config_ok"
        cat <<'FAKE_XRAY'
case "${1:-}" in
    version|-version)
        printf 'Xray %s (transaction test fixture)\n' "$fake_version"
        ;;
    run)
        [[ "${2:-}" == -test && "$config_ok" == 1 ]]
        ;;
    -test)
        [[ "$config_ok" == 1 ]]
        ;;
    *)
        exit 64
        ;;
esac
FAKE_XRAY
    } > "$path"
    chmod 0755 "$path"
}

setup_transaction_case() {
    local case_name="$1" initially_active="$2"
    CASE_DIR="/srv/$case_name"
    mkdir -p "$CASE_DIR/bin" "$CASE_DIR/etc" "$CASE_DIR/state" "$CASE_DIR/run" "$CASE_DIR/tmp"

    XRAY_BIN="$CASE_DIR/bin/xray"
    XRAY_CONF="$CASE_DIR/etc/config.json"
    XRAY_UPDATE_STATE_FILE="$CASE_DIR/state/xray-update.state"
    XRAY_LIFECYCLE_LOCK="$CASE_DIR/run/xray-lifecycle.lock"
    TMPDIR="$CASE_DIR/tmp"
    SERVICE_STATE_FILE="$CASE_DIR/service.state"
    SERVICE_LOG_FILE="$CASE_DIR/service.log"
    MOCK_NEW_CONFIG_OK=1
    MOCK_ACTIVATION_FAIL=0
    MOCK_SYNC_FAIL_MATCH=""
    MOCK_SYNC_LOG=""
    MOCK_SIGNAL_AFTER_STOP=""
    MOCK_SIGNAL_ON_COMMIT_SYNC=""
    MOCK_STATE_SYNC_FAIL_PHASE=""
    MOCK_STATE_SYNC_FAIL_PATH=""
    MOCK_STATE_SYNC_FAILED=0
    MOCK_REPLACE_OLD_AFTER_DOWNLOAD=0
    MOCK_REPLACE_TMP_AFTER_DOWNLOAD=0
    MOCK_START_DURING_VALIDATION=0
    MOCK_REPLACE_OLD_BEFORE_ACTIVATION=0
    MOCK_STOP_IDENTITY_FAIL=0
    MOCK_EXTRA_PROCESS_AT_STOP=0
    MOCK_DOWNLOAD_COUNT=0
    MOCK_CAPTURE_BACKUP_IDS=0
    MOCK_REPLACE_STAGE_ON_COMMIT=0

    printf '%s\n' '{}' > "$XRAY_CONF"
    printf '%s\n' "$initially_active" > "$SERVICE_STATE_FILE"
    : > "$SERVICE_LOG_FILE"
    write_fake_xray "$XRAY_BIN" v1.2.3 1
}

# All externally coupled operations are replaced.  The transaction still uses
# its real same-directory staging, backup, state-journal, atomic mv and rollback
# functions against CASE_DIR.
_xray_release_capability_check() { return 0; }
_xray_check_disk_space() { return 0; }
_xray_sync_path() {
    [[ -z "$MOCK_SYNC_LOG" ]] || printf '%s\n' "$1" >> "$MOCK_SYNC_LOG"
    if [[ "$MOCK_STATE_SYNC_FAILED" == 0 && -n "$MOCK_STATE_SYNC_FAIL_PHASE" &&
          "$1" == "$MOCK_STATE_SYNC_FAIL_PATH" && -f "$XRAY_UPDATE_STATE_FILE" ]] &&
       grep -q "^phase=$MOCK_STATE_SYNC_FAIL_PHASE$" "$XRAY_UPDATE_STATE_FILE"; then
        MOCK_STATE_SYNC_FAILED=1
        return 1
    fi
    [[ -z "$MOCK_SYNC_FAIL_MATCH" || "$1" != *"$MOCK_SYNC_FAIL_MATCH"* ]] || return 1
    if [[ -n "$MOCK_SIGNAL_ON_COMMIT_SYNC" && "$1" == "$(dirname "$XRAY_UPDATE_STATE_FILE")" &&
          -f "$XRAY_UPDATE_STATE_FILE" ]] &&
       grep -q '^phase=committed$' "$XRAY_UPDATE_STATE_FILE"; then
        signal="$MOCK_SIGNAL_ON_COMMIT_SYNC"
        MOCK_SIGNAL_ON_COMMIT_SYNC=""
        kill -s "$signal" "$BASHPID"
    fi
    if [[ "$MOCK_REPLACE_STAGE_ON_COMMIT" == 1 && -f "$XRAY_UPDATE_STATE_FILE" ]] &&
       grep -q '^phase=committed$' "$XRAY_UPDATE_STATE_FILE"; then
        MOCK_REPLACE_STAGE_ON_COMMIT=0
        unlink "$XRAY_TXN_RESTORE_STAGE"
        ln -s "$CASE_DIR/external-stage" "$XRAY_TXN_RESTORE_STAGE"
    fi
}
map_xray_arch() { printf '%s\n' 64; }
xray_github_api() {
    printf 'unexpected GitHub API access in transaction test\n' >&2
    return 99
}
download_xray_release() {
    local _target="$1" _arch="$2" tmp_dir="$3" candidate="$3/mock-new-xray"
    ((++MOCK_DOWNLOAD_COUNT))
    : > "$CASE_DIR/download.called"
    write_fake_xray "$candidate" v2.0.0 "$MOCK_NEW_CONFIG_OK"
    if [[ "$MOCK_REPLACE_OLD_AFTER_DOWNLOAD" == 1 ]]; then
        write_fake_xray "$XRAY_BIN" v9.9.9 1
    fi
    if [[ "$MOCK_REPLACE_TMP_AFTER_DOWNLOAD" == 1 ]]; then
        mv "$tmp_dir" "${tmp_dir}.original"
        mkdir "$tmp_dir"
        printf '%s\n' replacement > "$tmp_dir/replacement-sentinel"
    fi
    printf '%s\n' "$candidate"
}
xray_process_exists() { return 1; }
xray_list_process_ids() {
    printf '%s\n' "$$"
    [[ ! -f "$CASE_DIR/extra-process.visible" ]] || printf '%s\n' 999999
}
service_is_active() { [[ "$(<"$SERVICE_STATE_FILE")" == active ]]; }
service_main_pid() { printf '%s\n' "$$"; }
xray_pid_uses_binary() { return 0; }
service_stop_strict() {
    printf '%s\n' stop >> "$SERVICE_LOG_FILE"
    printf '%s\n' inactive > "$SERVICE_STATE_FILE"
}
service_stop() {
    printf '%s\n' stop >> "$SERVICE_LOG_FILE"
    printf '%s\n' inactive > "$SERVICE_STATE_FILE"
}
service_start_strict() {
    printf '%s\n' start >> "$SERVICE_LOG_FILE"
    printf '%s\n' active > "$SERVICE_STATE_FILE"
}
xray_runtime_healthy() { return 0; }
_xray_stop_and_wait() {
    [[ "$MOCK_STOP_IDENTITY_FAIL" != 1 ]] || {
        XRAY_RECOVERY_EXTERNAL_CONFLICT=1
        return 1
    }
    [[ "$MOCK_EXTRA_PROCESS_AT_STOP" != 1 ]] || {
        : > "$CASE_DIR/extra-process.visible"
        XRAY_RECOVERY_EXTERNAL_CONFLICT=1
        return 1
    }
    service_stop_strict xray || return 1
    if [[ -n "$MOCK_SIGNAL_AFTER_STOP" ]]; then
        kill -s "$MOCK_SIGNAL_AFTER_STOP" "$BASHPID"
    fi
    ! service_is_active xray && ! xray_process_exists
}
_xray_start_and_verify() {
    service_start_strict xray || return 1
    [[ "$MOCK_ACTIVATION_FAIL" != 1 ]]
}
_xray_capture_restart_schedule() {
    XRAY_TXN_SCHEDULE_ENABLED=0
    XRAY_TXN_SCHEDULE_LABEL=""
    XRAY_TXN_SCHEDULE_CRON=""
    XRAY_TXN_SCHEDULE_CALENDAR=""
}
_xray_pause_restart_schedule() {
    if [[ "$MOCK_CAPTURE_BACKUP_IDS" == 1 ]]; then
        printf '%s\n%s\n' "$(stat -Lc '%d:%i' "$XRAY_TXN_RESTORE_STAGE")" \
            "$(stat -Lc '%d:%i' "$XRAY_TXN_BACKUP")" > "$CASE_DIR/backup.ids"
    fi
    [[ "$MOCK_START_DURING_VALIDATION" != 1 ]] || printf '%s\n' active > "$SERVICE_STATE_FILE"
    [[ "$MOCK_REPLACE_OLD_BEFORE_ACTIVATION" != 1 ]] || write_fake_xray "$XRAY_BIN" v9.9.9 1
}
_xray_restore_restart_schedule_values() { return 0; }

assert_binary_version() {
    local expected="$1" path="$2" context="$3"
    local actual
    actual=$(get_installed_xray_version "$path") || fail "$context: binary did not report a version"
    assert_eq "$expected" "$actual" "$context"
}

assert_no_transaction_residue() {
    local context="$1"
    assert_not_exists "$XRAY_UPDATE_STATE_FILE"
    if find "$CASE_DIR/bin" -maxdepth 1 -name '.xray.*' -print -quit | grep -q .; then
        fail "$context: same-directory transaction stage was not removed"
    fi
    if find "$TMPDIR" -maxdepth 1 -name 'proxy-hub-xray.*' -print -quit | grep -q .; then
        fail "$context: private download directory was not removed"
    fi
}

test_active_update_success() (
    setup_transaction_case active-success active
    MOCK_CAPTURE_BACKUP_IDS=1

    install_xray_release v2.0.0 fixed-update

    assert_binary_version v2.0.0 "$XRAY_BIN" "successful update activates the target binary"
    assert_eq active "$(<"$SERVICE_STATE_FILE")" "successful update restores active state"
    assert_eq $'stop\nstart' "$(<"$SERVICE_LOG_FILE")" "active update performs one stop/start cycle"
    backup=$(find "$CASE_DIR/bin" -maxdepth 1 -type f -name 'xray.bak-v1.2.3-*' -print -quit)
    [[ -n "$backup" ]] || fail "successful update keeps a managed backup"
    assert_binary_version v1.2.3 "$backup" "managed backup preserves the prior binary"
    mapfile -t backup_ids < "$CASE_DIR/backup.ids"
    assert_ne "${backup_ids[0]}" "${backup_ids[1]}" "named backup must be independent from restore stage"
    assert_no_transaction_residue "successful active update"
)

test_config_preflight_failure() (
    local rc=0
    setup_transaction_case config-preflight-failure active
    MOCK_NEW_CONFIG_OK=0

    install_xray_release v2.0.0 fixed-update || rc=$?

    assert_ne 0 "$rc" "invalid config must reject the candidate"
    assert_binary_version v1.2.3 "$XRAY_BIN" "config preflight failure leaves the old binary"
    assert_eq active "$(<"$SERVICE_STATE_FILE")" "config preflight failure leaves service state unchanged"
    assert_eq "" "$(<"$SERVICE_LOG_FILE")" "config preflight failure does not stop the service"
    backup_count=$(find "$CASE_DIR/bin" -maxdepth 1 -type f -name 'xray.bak-*' | wc -l)
    assert_eq 0 "$backup_count" "config preflight failure creates no backup or replacement"
    assert_no_transaction_residue "config preflight failure"
)

test_activation_health_failure_rolls_back() (
    local rc=0
    setup_transaction_case activation-health-failure active
    MOCK_ACTIVATION_FAIL=1

    install_xray_release v2.0.0 fixed-update || rc=$?

    assert_ne 0 "$rc" "failed post-activation health check must fail the update"
    assert_binary_version v1.2.3 "$XRAY_BIN" "health failure restores the prior binary"
    assert_eq active "$(<"$SERVICE_STATE_FILE")" "health failure restarts the prior active service"
    assert_eq $'stop\nstart\nstop\nstart' "$(<"$SERVICE_LOG_FILE")" \
        "health failure stops the candidate and restarts the prior binary"
    assert_no_transaction_residue "activation health rollback"
)

test_inactive_update_stays_inactive() (
    setup_transaction_case inactive-success inactive

    install_xray_release v2.0.0 fixed-update

    assert_binary_version v2.0.0 "$XRAY_BIN" "inactive update activates the target binary"
    assert_eq inactive "$(<"$SERVICE_STATE_FILE")" "inactive Xray remains stopped after update"
    assert_eq "" "$(<"$SERVICE_LOG_FILE")" "inactive update never calls service start or stop"
    assert_no_transaction_residue "successful inactive update"
)

test_persistent_activated_state_recovers() (
    setup_transaction_case persistent-activated-recovery inactive

    XRAY_TXN_TOKEN="persistent-recovery-1"
    XRAY_TXN_TARGET="v2.0.0"
    XRAY_TXN_NEW_DIGEST=""
    XRAY_TXN_OLD_EXISTS=1
    XRAY_TXN_OLD_DIGEST=$(_xray_sha256_file "$XRAY_BIN")
    XRAY_TXN_OLD_MODE=$(stat -c '%a' "$XRAY_BIN")
    XRAY_TXN_BACKUP="$CASE_DIR/bin/xray.bak-v1.2.3-20260721-120000"
    XRAY_TXN_RESTORE_STAGE="$CASE_DIR/bin/.xray.restore.$XRAY_TXN_TOKEN"
    XRAY_TXN_WAS_ACTIVE=1
    XRAY_TXN_SCHEDULE_ENABLED=0
    XRAY_TXN_SCHEDULE_LABEL=""
    XRAY_TXN_SCHEDULE_CRON=""
    XRAY_TXN_SCHEDULE_CALENDAR=""

    install -m 0755 "$XRAY_BIN" "$XRAY_TXN_BACKUP"
    install -m 0755 "$XRAY_BIN" "$XRAY_TXN_RESTORE_STAGE"
    write_fake_xray "$XRAY_BIN" v2.0.0 1
    XRAY_TXN_NEW_DIGEST=$(_xray_sha256_file "$XRAY_BIN")
    _xray_write_state activated

    recover_pending_xray_update_locked

    assert_binary_version v1.2.3 "$XRAY_BIN" "persistent activated journal restores the prior binary"
    assert_eq active "$(<"$SERVICE_STATE_FILE")" "persistent recovery restores the prior active state"
    assert_eq start "$(<"$SERVICE_LOG_FILE")" \
        "persistent recovery starts the prior binary when the candidate is already stopped"
    assert_file "$XRAY_TXN_BACKUP"
    assert_binary_version v1.2.3 "$XRAY_TXN_BACKUP" "persistent recovery retains the managed backup"
    assert_no_transaction_residue "persistent activated-state recovery"
)

test_term_after_stop_rolls_back() (
    local rc=0
    setup_transaction_case term-after-stop active
    MOCK_SIGNAL_AFTER_STOP=TERM

    install_xray_release v2.0.0 fixed-update || rc=$?

    assert_ne 0 "$rc" "TERM after stop must interrupt the update"
    assert_binary_version v1.2.3 "$XRAY_BIN" "TERM after stop preserves the prior binary"
    assert_eq active "$(<"$SERVICE_STATE_FILE")" "TERM rollback restores the prior active state"
    assert_eq $'stop\nstart' "$(<"$SERVICE_LOG_FILE")" \
        "TERM rollback restarts the service that the transaction stopped"
    assert_no_transaction_residue "TERM after stop rollback"
)

test_hardlink_sync_failure_is_safe() (
    local rc=0
    setup_transaction_case hardlink-sync-failure active
    MOCK_SYNC_FAIL_MATCH=.xray.restore.

    install_xray_release v2.0.0 fixed-update || rc=$?

    assert_ne 0 "$rc" "restore-link sync failure must fail the update"
    assert_binary_version v1.2.3 "$XRAY_BIN" "sync failure leaves the old binary active"
    assert_eq active "$(<"$SERVICE_STATE_FILE")" "sync failure preserves active state"
    assert_eq "" "$(<"$SERVICE_LOG_FILE")" "sync failure occurs before stop"
    assert_no_transaction_residue "hardlink sync failure"
)

test_committed_phase_does_not_roll_back() (
    setup_transaction_case committed-phase inactive
    write_fake_xray "$XRAY_BIN" v2.0.0 1
    XRAY_TXN_PREPARED=1
    XRAY_TXN_COMMITTED=0
    XRAY_TXN_PHASE=committed

    _xray_transaction_rollback

    assert_binary_version v2.0.0 "$XRAY_BIN" \
        "a signal after the durable commit point must not restore the old binary"
    assert_eq 1 "$XRAY_TXN_COMMITTED" "committed phase is recognized as terminal"
    assert_eq "" "$(<"$SERVICE_LOG_FILE")" "committed phase does not touch service state"
)

test_signal_during_commit_publication_is_terminal() (
    local rc=0
    setup_transaction_case signal-during-commit active
    MOCK_SIGNAL_ON_COMMIT_SYNC=TERM

    install_xray_release v2.0.0 fixed-update || rc=$?

    assert_eq 143 "$rc" "TERM during committed journal publication is replayed after commit"
    assert_binary_version v2.0.0 "$XRAY_BIN" "durably committed binary is not rolled back"
    assert_eq active "$(<"$SERVICE_STATE_FILE")" "committed service remains active"
    assert_eq $'stop\nstart' "$(<"$SERVICE_LOG_FILE")" "commit signal causes no rollback stop/start"
    assert_file "$XRAY_UPDATE_STATE_FILE"
    grep -q '^phase=committed$' "$XRAY_UPDATE_STATE_FILE" || fail "committed journal was not retained"

    recover_pending_xray_update_locked
    assert_no_transaction_residue "commit-signal terminal recovery"
)

test_committed_state_file_sync_failure_rolls_back() (
    local rc=0
    setup_transaction_case committed-file-sync-failure active
    MOCK_STATE_SYNC_FAIL_PHASE=committed
    MOCK_STATE_SYNC_FAIL_PATH="$XRAY_UPDATE_STATE_FILE"

    install_xray_release v2.0.0 fixed-update || rc=$?

    assert_ne 0 "$rc" "committed journal file sync failure must fail the update"
    assert_binary_version v1.2.3 "$XRAY_BIN" "file sync failure restores the old binary"
    assert_eq active "$(<"$SERVICE_STATE_FILE")" "file sync failure restores active state"
    assert_eq $'stop\nstart\nstop\nstart' "$(<"$SERVICE_LOG_FILE")" \
        "file sync failure performs the normal update and rollback cycles"
    assert_no_transaction_residue "committed file sync failure"
)

test_committed_state_directory_sync_failure_rolls_back() (
    local rc=0
    setup_transaction_case committed-directory-sync-failure active
    MOCK_STATE_SYNC_FAIL_PHASE=committed
    MOCK_STATE_SYNC_FAIL_PATH="$(dirname "$XRAY_UPDATE_STATE_FILE")"

    install_xray_release v2.0.0 fixed-update || rc=$?

    assert_ne 0 "$rc" "committed journal directory sync failure must fail the update"
    assert_binary_version v1.2.3 "$XRAY_BIN" "directory sync failure restores the old binary"
    assert_eq active "$(<"$SERVICE_STATE_FILE")" "directory sync failure restores active state"
    assert_no_transaction_residue "committed directory sync failure"
)

test_recovery_state_payload_failure_is_retryable() (
    local first_rc=0
    setup_transaction_case recovery-payload-retry inactive
    XRAY_TXN_TOKEN="recovery-payload-retry-1"
    XRAY_TXN_TARGET="v2.0.0"
    XRAY_TXN_OLD_EXISTS=1
    XRAY_TXN_OLD_DIGEST=$(_xray_sha256_file "$XRAY_BIN")
    XRAY_TXN_OLD_MODE=$(stat -c '%a' "$XRAY_BIN")
    XRAY_TXN_BACKUP="$CASE_DIR/bin/xray.bak-v1.2.3-20260721-121000"
    XRAY_TXN_RESTORE_STAGE="$CASE_DIR/bin/.xray.restore.$XRAY_TXN_TOKEN"
    XRAY_TXN_WAS_ACTIVE=0
    XRAY_TXN_SCHEDULE_ENABLED=0
    XRAY_TXN_SCHEDULE_LABEL="" XRAY_TXN_SCHEDULE_CRON="" XRAY_TXN_SCHEDULE_CALENDAR=""
    install -m 0755 "$XRAY_BIN" "$XRAY_TXN_BACKUP"
    install -m 0755 "$XRAY_BIN" "$XRAY_TXN_RESTORE_STAGE"
    write_fake_xray "$XRAY_BIN" v2.0.0 1
    XRAY_TXN_NEW_DIGEST=$(_xray_sha256_file "$XRAY_BIN")
    _xray_write_state activated
    _xray_sha256_file() {
        if [[ "$1" == *.payload.* && ! -e "$CASE_DIR/payload-failure.used" ]] &&
           grep -q '^phase=rolled-back$' "$1"; then
            : > "$CASE_DIR/payload-failure.used"
            return 1
        fi
        sha256sum "$1" | awk '{print $1}'
    }

    recover_pending_xray_update_locked || first_rc=$?

    assert_ne 0 "$first_rc" "a pre-rename rollback-journal failure must surface"
    assert_binary_version v1.2.3 "$XRAY_BIN" "the first recovery restores the old binary"
    assert_file "$XRAY_UPDATE_STATE_FILE"
    if find "$CASE_DIR/state" -maxdepth 1 -name '.xray-update-state.*.payload.*' -print -quit | grep -q .; then
        fail "failed state payload was not removed"
    fi

    recover_pending_xray_update_locked
    assert_no_transaction_residue "retry after state payload failure"
)

test_state_directory_creation_is_parent_synced() (
    setup_transaction_case state-parent-sync inactive
    rmdir "$CASE_DIR/state"
    MOCK_SYNC_LOG="$CASE_DIR/sync.log"
    : > "$MOCK_SYNC_LOG"

    install_xray_release v2.0.0 fixed-update

    grep -Fxq "$CASE_DIR/state" "$MOCK_SYNC_LOG" || fail "new state directory was not synchronized"
    grep -Fxq "$CASE_DIR" "$MOCK_SYNC_LOG" || fail "state directory parent was not synchronized"
)

test_old_binary_change_before_backup_is_rejected() (
    local rc=0
    setup_transaction_case old-binary-race active
    MOCK_REPLACE_OLD_AFTER_DOWNLOAD=1

    install_xray_release v2.0.0 fixed-update || rc=$?

    assert_ne 0 "$rc" "changed old binary must abort the update"
    assert_eq active "$(<"$SERVICE_STATE_FILE")" "old binary race does not stop the service"
    assert_eq "" "$(<"$SERVICE_LOG_FILE")" "old binary race is rejected before stop"
    assert_binary_version v9.9.9 "$XRAY_BIN" "old binary race preserves the external replacement"
    assert_file "$XRAY_UPDATE_STATE_FILE"
    find "$CASE_DIR/bin" -maxdepth 1 -type f -name '.xray.new.*' -print -quit | grep -q . || \
        fail "old binary race did not preserve transaction evidence"
)

test_stop_boundary_identity_failure_is_safe() (
    local rc=0
    setup_transaction_case stop-boundary-identity active
    MOCK_STOP_IDENTITY_FAIL=1

    install_xray_release v2.0.0 fixed-update || rc=$?

    assert_ne 0 "$rc" "stop-boundary identity mismatch must abort the update"
    assert_binary_version v1.2.3 "$XRAY_BIN" "stop-boundary failure keeps the old binary"
    assert_eq active "$(<"$SERVICE_STATE_FILE")" "stop-boundary failure keeps Xray active"
    assert_eq "" "$(<"$SERVICE_LOG_FILE")" "identity mismatch is rejected before service_stop"
    assert_file "$XRAY_UPDATE_STATE_FILE"
    find "$CASE_DIR/bin" -maxdepth 1 -type f -name '.xray.restore.*' -print -quit | grep -q . || \
        fail "stop-boundary conflict did not retain the restore stage"
)

test_untrusted_state_file_is_rejected_before_stop() (
    local rc=0
    setup_transaction_case untrusted-state active
    XRAY_TXN_TOKEN="untrusted-state-1"
    XRAY_TXN_TARGET="v2.0.0"
    XRAY_TXN_NEW_DIGEST=$(_xray_sha256_file "$XRAY_BIN")
    XRAY_TXN_OLD_EXISTS=1
    XRAY_TXN_OLD_DIGEST=$(_xray_sha256_file "$XRAY_BIN")
    XRAY_TXN_OLD_MODE=0755
    XRAY_TXN_BACKUP="$CASE_DIR/bin/xray.bak-v1.2.3-20260721-130000"
    XRAY_TXN_RESTORE_STAGE="$CASE_DIR/bin/.xray.restore.$XRAY_TXN_TOKEN"
    XRAY_TXN_WAS_ACTIVE=1
    XRAY_TXN_SCHEDULE_ENABLED=0
    XRAY_TXN_SCHEDULE_LABEL=""
    XRAY_TXN_SCHEDULE_CRON=""
    XRAY_TXN_SCHEDULE_CALENDAR=""
    _xray_write_state prepared
    chmod 0644 "$XRAY_UPDATE_STATE_FILE"

    recover_pending_xray_update_locked || rc=$?

    assert_ne 0 "$rc" "non-private persistent journal must be rejected"
    assert_eq active "$(<"$SERVICE_STATE_FILE")" "untrusted journal cannot stop Xray"
    assert_eq "" "$(<"$SERVICE_LOG_FILE")" "untrusted journal fails before service operations"
    assert_file "$XRAY_UPDATE_STATE_FILE"
)

test_unsafe_tmp_parent_is_rejected() (
    local rc=0
    setup_transaction_case unsafe-tmp-parent active
    chmod 0777 "$TMPDIR"

    install_xray_release v2.0.0 fixed-update || rc=$?

    assert_ne 0 "$rc" "group/world-writable non-sticky TMPDIR must be rejected"
    chmod 0700 "$TMPDIR"
    assert_binary_version v1.2.3 "$XRAY_BIN" "unsafe TMPDIR cannot change the binary"
    assert_eq active "$(<"$SERVICE_STATE_FILE")" "unsafe TMPDIR cannot stop Xray"
    assert_eq "" "$(<"$SERVICE_LOG_FILE")" "unsafe TMPDIR fails before service operations"
)

test_replaced_tmp_directory_is_preserved() (
    local rc=0 replacement original
    setup_transaction_case replaced-tmp-directory inactive
    MOCK_REPLACE_TMP_AFTER_DOWNLOAD=1

    install_xray_release v2.0.0 fixed-update || rc=$?

    assert_ne 0 "$rc" "temporary directory identity replacement must abort the update"
    replacement=$(find "$TMPDIR" -maxdepth 1 -type d -name 'proxy-hub-xray.*' ! -name '*.original' -print -quit)
    original=$(find "$TMPDIR" -maxdepth 1 -type d -name 'proxy-hub-xray.*.original' -print -quit)
    [[ -n "$replacement" && -n "$original" ]] || fail "replacement evidence was not preserved"
    assert_file "$replacement/replacement-sentinel"
    assert_binary_version v1.2.3 "$XRAY_BIN" "replaced temp directory cannot activate a binary"
)

test_inactive_service_start_during_validation_fails_closed() (
    local rc=0
    setup_transaction_case inactive-start-race inactive
    MOCK_START_DURING_VALIDATION=1

    install_xray_release v2.0.0 fixed-update || rc=$?

    assert_ne 0 "$rc" "inactive-to-active transition must abort before activation"
    assert_binary_version v1.2.3 "$XRAY_BIN" "runtime state transition keeps the old binary"
    assert_eq active "$(<"$SERVICE_STATE_FILE")" "externally started service is left untouched"
    assert_eq "" "$(<"$SERVICE_LOG_FILE")" "externally started service is not stopped"
    assert_file "$XRAY_UPDATE_STATE_FILE"
    find "$CASE_DIR/bin" -maxdepth 1 -type f -name '.xray.restore.*' -print -quit | grep -q . || \
        fail "runtime transition did not retain the restore stage"
)

test_unsafe_tmp_ancestor_is_rejected() (
    local rc=0 original_tmp
    setup_transaction_case unsafe-tmp-ancestor active
    original_tmp="$TMPDIR"
    mkdir -p "$CASE_DIR/attacker/private"
    chmod 0700 "$CASE_DIR/attacker/private"
    chown 65534:65534 "$CASE_DIR/attacker"
    TMPDIR="$CASE_DIR/attacker/private"

    install_xray_release v2.0.0 fixed-update || rc=$?

    assert_ne 0 "$rc" "private leaf under an unrelated-owner ancestor must be rejected"
    TMPDIR="$original_tmp"
    assert_binary_version v1.2.3 "$XRAY_BIN" "unsafe ancestor cannot change the binary"
    assert_eq "" "$(<"$SERVICE_LOG_FILE")" "unsafe ancestor fails before service operations"
)

test_binary_change_immediately_before_activation_is_preserved() (
    local rc=0
    setup_transaction_case pre-activation-binary-race inactive
    MOCK_REPLACE_OLD_BEFORE_ACTIVATION=1

    install_xray_release v2.0.0 fixed-update || rc=$?

    assert_ne 0 "$rc" "pre-activation binary replacement must abort the update"
    assert_binary_version v9.9.9 "$XRAY_BIN" "external replacement is preserved"
    assert_eq inactive "$(<"$SERVICE_STATE_FILE")" "inactive runtime remains inactive"
    assert_eq "" "$(<"$SERVICE_LOG_FILE")" "pre-activation replacement causes no service operation"
    assert_file "$XRAY_UPDATE_STATE_FILE"
    find "$CASE_DIR/bin" -maxdepth 1 -type f -name '.xray.displaced.*' -print -quit | grep -q . || \
        fail "cutover evidence was not retained after the external replacement"
)

test_fresh_install_target_appearance_is_preserved() (
    local rc=0
    setup_transaction_case fresh-target-appearance inactive
    unlink "$XRAY_BIN"
    MOCK_REPLACE_OLD_BEFORE_ACTIVATION=1

    install_xray_release v2.0.0 ordinary-install || rc=$?

    assert_ne 0 "$rc" "fresh install must not overwrite a binary that appears during validation"
    assert_binary_version v9.9.9 "$XRAY_BIN" "newly appeared fresh-install target is preserved"
    assert_eq "" "$(<"$SERVICE_LOG_FILE")" "fresh target conflict causes no service operation"
    assert_file "$XRAY_UPDATE_STATE_FILE"
)

test_recovery_preserves_unexpected_existing_update_target() (
    local rc=0 candidate
    setup_transaction_case recovery-external-update inactive
    XRAY_TXN_TOKEN="recovery-external-update-1"
    XRAY_TXN_TARGET="v2.0.0"
    XRAY_TXN_OLD_EXISTS=1
    XRAY_TXN_OLD_DIGEST=$(_xray_sha256_file "$XRAY_BIN")
    XRAY_TXN_OLD_MODE=$(stat -c '%a' "$XRAY_BIN")
    XRAY_TXN_BACKUP="$CASE_DIR/bin/xray.bak-v1.2.3-20260721-140000"
    XRAY_TXN_RESTORE_STAGE="$CASE_DIR/bin/.xray.restore.$XRAY_TXN_TOKEN"
    XRAY_TXN_WAS_ACTIVE=0
    XRAY_TXN_SCHEDULE_ENABLED=0
    XRAY_TXN_SCHEDULE_LABEL="" XRAY_TXN_SCHEDULE_CRON="" XRAY_TXN_SCHEDULE_CALENDAR=""
    ln "$XRAY_BIN" "$XRAY_TXN_BACKUP"
    ln "$XRAY_BIN" "$XRAY_TXN_RESTORE_STAGE"
    candidate="$CASE_DIR/candidate"
    write_fake_xray "$candidate" v2.0.0 1
    XRAY_TXN_NEW_DIGEST=$(_xray_sha256_file "$candidate")
    unlink "$candidate"
    write_fake_xray "$XRAY_BIN" v9.9.9 1
    _xray_write_state activated

    recover_pending_xray_update_locked || rc=$?

    assert_ne 0 "$rc" "recovery must reject a binary outside old/new journal digests"
    assert_binary_version v9.9.9 "$XRAY_BIN" "unexpected update target is preserved"
    assert_file "$XRAY_UPDATE_STATE_FILE"
    assert_eq "" "$(<"$SERVICE_LOG_FILE")" "unexpected recovery target fails before service operations"
)

test_recovery_preserves_unexpected_fresh_target() (
    local rc=0 candidate
    setup_transaction_case recovery-external-fresh inactive
    unlink "$XRAY_BIN"
    XRAY_TXN_TOKEN="recovery-external-fresh-1"
    XRAY_TXN_TARGET="v2.0.0"
    XRAY_TXN_OLD_EXISTS=0
    XRAY_TXN_OLD_DIGEST=""
    XRAY_TXN_OLD_MODE=0755
    XRAY_TXN_BACKUP="$CASE_DIR/bin/xray.bak-v0.0-absent-20260721-140100"
    XRAY_TXN_RESTORE_STAGE="$CASE_DIR/bin/.xray.restore.$XRAY_TXN_TOKEN"
    XRAY_TXN_WAS_ACTIVE=0
    XRAY_TXN_SCHEDULE_ENABLED=0
    XRAY_TXN_SCHEDULE_LABEL="" XRAY_TXN_SCHEDULE_CRON="" XRAY_TXN_SCHEDULE_CALENDAR=""
    candidate="$CASE_DIR/candidate"
    write_fake_xray "$candidate" v2.0.0 1
    XRAY_TXN_NEW_DIGEST=$(_xray_sha256_file "$candidate")
    unlink "$candidate"
    write_fake_xray "$XRAY_BIN" v9.9.9 1
    _xray_write_state activated

    recover_pending_xray_update_locked || rc=$?

    assert_ne 0 "$rc" "fresh recovery must not delete an external target"
    assert_binary_version v9.9.9 "$XRAY_BIN" "unexpected fresh-install target is preserved"
    assert_file "$XRAY_UPDATE_STATE_FILE"
    assert_eq "" "$(<"$SERVICE_LOG_FILE")" "fresh recovery conflict causes no service operation"
)

test_recovery_skips_corrupt_restore_source() (
    local backup_copy
    setup_transaction_case recovery-corrupt-restore inactive
    XRAY_TXN_TOKEN="recovery-corrupt-restore-1"
    XRAY_TXN_TARGET="v2.0.0"
    XRAY_TXN_OLD_EXISTS=1
    XRAY_TXN_OLD_DIGEST=$(_xray_sha256_file "$XRAY_BIN")
    XRAY_TXN_OLD_MODE=$(stat -c '%a' "$XRAY_BIN")
    XRAY_TXN_BACKUP="$CASE_DIR/bin/xray.bak-v1.2.3-20260721-141000"
    XRAY_TXN_RESTORE_STAGE="$CASE_DIR/bin/.xray.restore.$XRAY_TXN_TOKEN"
    XRAY_TXN_WAS_ACTIVE=0
    XRAY_TXN_SCHEDULE_ENABLED=0
    XRAY_TXN_SCHEDULE_LABEL="" XRAY_TXN_SCHEDULE_CRON="" XRAY_TXN_SCHEDULE_CALENDAR=""
    backup_copy="$CASE_DIR/bin/.xray.backup-copy.$XRAY_TXN_TOKEN"
    ln "$XRAY_BIN" "$XRAY_TXN_RESTORE_STAGE"
    xray_copy_verified_backup "$XRAY_BIN" "$backup_copy" "$XRAY_TXN_BACKUP" \
        "$XRAY_TXN_OLD_DIGEST" "$XRAY_TXN_OLD_MODE"
    assert_ne "$(stat -Lc '%d:%i' "$XRAY_TXN_RESTORE_STAGE")" \
        "$(stat -Lc '%d:%i' "$XRAY_TXN_BACKUP")" "production backup must use an independent inode"
    unlink "$XRAY_BIN"
    write_fake_xray "$XRAY_BIN" v2.0.0 1
    XRAY_TXN_NEW_DIGEST=$(_xray_sha256_file "$XRAY_BIN")
    _xray_write_state activated
    write_fake_xray "$XRAY_TXN_RESTORE_STAGE" v8.8.8 1

    recover_pending_xray_update_locked

    assert_binary_version v1.2.3 "$XRAY_BIN" "recovery skips a corrupt restore stage"
    assert_eq "$(stat -Lc '%d:%i' "$XRAY_TXN_BACKUP")" "$(stat -Lc '%d:%i' "$XRAY_BIN")" \
        "recovery falls back to the verified backup inode"
    assert_eq "" "$(<"$SERVICE_LOG_FILE")" "inactive fallback recovery performs no service operation"
    assert_no_transaction_residue "corrupt restore-stage fallback"
)

test_recovery_skips_nonexecutable_restore_source() (
    setup_transaction_case recovery-nonexecutable-restore inactive
    XRAY_TXN_TOKEN="recovery-nonexec-restore-1"
    XRAY_TXN_TARGET="v2.0.0"
    XRAY_TXN_OLD_EXISTS=1
    XRAY_TXN_OLD_DIGEST=$(_xray_sha256_file "$XRAY_BIN")
    XRAY_TXN_OLD_MODE=$(stat -c '%a' "$XRAY_BIN")
    XRAY_TXN_BACKUP="$CASE_DIR/bin/xray.bak-v1.2.3-20260721-141010"
    XRAY_TXN_RESTORE_STAGE="$CASE_DIR/bin/.xray.restore.$XRAY_TXN_TOKEN"
    XRAY_TXN_WAS_ACTIVE=0
    XRAY_TXN_SCHEDULE_ENABLED=0
    XRAY_TXN_SCHEDULE_LABEL="" XRAY_TXN_SCHEDULE_CRON="" XRAY_TXN_SCHEDULE_CALENDAR=""
    backup_copy="$CASE_DIR/bin/.xray.backup-copy.$XRAY_TXN_TOKEN"
    ln "$XRAY_BIN" "$XRAY_TXN_RESTORE_STAGE"
    xray_copy_verified_backup "$XRAY_BIN" "$backup_copy" "$XRAY_TXN_BACKUP" \
        "$XRAY_TXN_OLD_DIGEST" "$XRAY_TXN_OLD_MODE"
    unlink "$XRAY_BIN"
    write_fake_xray "$XRAY_BIN" v2.0.0 1
    XRAY_TXN_NEW_DIGEST=$(_xray_sha256_file "$XRAY_BIN")
    _xray_write_state activated
    chmod 0644 "$XRAY_TXN_RESTORE_STAGE"

    recover_pending_xray_update_locked

    assert_binary_version v1.2.3 "$XRAY_BIN" "recovery skips a nonexecutable restore source"
    assert_eq 755 "$(stat -c '%a' "$XRAY_BIN")" "recovery preserves the recorded executable mode"
    assert_eq "$(stat -Lc '%d:%i' "$XRAY_TXN_BACKUP")" "$(stat -Lc '%d:%i' "$XRAY_BIN")" \
        "recovery falls back to the metadata-verified independent backup"
    assert_no_transaction_residue "nonexecutable restore-stage fallback"
)

test_fresh_cutover_symlink_is_external_conflict() (
    local rc=0 output
    setup_transaction_case fresh-cutover-symlink inactive
    write_fake_xray "$CASE_DIR/external-xray" v9.9.9 1
    unlink "$XRAY_BIN"
    _xray_pause_restart_schedule() {
        ln -s "$CASE_DIR/external-xray" "$XRAY_BIN"
    }

    install_xray_release v2.0.0 ordinary-install 2>"$CASE_DIR/update.err" || rc=$?

    assert_ne 0 "$rc" "fresh cutover must reject a symlink target"
    [[ -L "$XRAY_BIN" ]] || fail "fresh cutover symlink was not preserved"
    assert_eq "$CASE_DIR/external-xray" "$(readlink "$XRAY_BIN")" "fresh cutover preserves symlink identity"
    assert_binary_version v9.9.9 "$CASE_DIR/external-xray" "fresh cutover preserves symlink content"
    assert_file "$XRAY_UPDATE_STATE_FILE"
    output=$(<"$CASE_DIR/update.err")
    assert_not_contains "$output" "Manual recovery: remove" "symlink conflict must not recommend deletion"
    assert_not_contains "$output" "Manual recovery: install" "symlink conflict must not recommend overwrite"
    assert_eq "" "$(<"$SERVICE_LOG_FILE")" "fresh symlink conflict causes no service operation"
)

test_update_recovery_directory_target_is_preserved() (
    local rc=0 output candidate
    setup_transaction_case recovery-directory-target inactive
    XRAY_TXN_TOKEN="recovery-directory-target-1"
    XRAY_TXN_TARGET="v2.0.0"
    XRAY_TXN_OLD_EXISTS=1
    XRAY_TXN_OLD_DIGEST=$(_xray_sha256_file "$XRAY_BIN")
    XRAY_TXN_OLD_MODE=$(stat -c '%a' "$XRAY_BIN")
    XRAY_TXN_BACKUP="$CASE_DIR/bin/xray.bak-v1.2.3-20260721-141100"
    XRAY_TXN_RESTORE_STAGE="$CASE_DIR/bin/.xray.restore.$XRAY_TXN_TOKEN"
    XRAY_TXN_WAS_ACTIVE=0
    XRAY_TXN_SCHEDULE_ENABLED=0
    XRAY_TXN_SCHEDULE_LABEL="" XRAY_TXN_SCHEDULE_CRON="" XRAY_TXN_SCHEDULE_CALENDAR=""
    install -m 0755 "$XRAY_BIN" "$XRAY_TXN_BACKUP"
    install -m 0755 "$XRAY_BIN" "$XRAY_TXN_RESTORE_STAGE"
    candidate="$CASE_DIR/candidate"
    write_fake_xray "$candidate" v2.0.0 1
    XRAY_TXN_NEW_DIGEST=$(_xray_sha256_file "$candidate")
    unlink "$candidate"
    unlink "$XRAY_BIN"
    mkdir "$XRAY_BIN"
    : > "$XRAY_BIN/preserve-me"
    _xray_write_state activated

    recover_pending_xray_update_locked 2>"$CASE_DIR/recovery.err" || rc=$?

    assert_ne 0 "$rc" "recovery must reject a directory at the canonical target"
    [[ -d "$XRAY_BIN" ]] || fail "unexpected target directory was removed"
    assert_file "$XRAY_BIN/preserve-me"
    assert_file "$XRAY_UPDATE_STATE_FILE"
    assert_file "$XRAY_TXN_RESTORE_STAGE"
    output=$(<"$CASE_DIR/recovery.err")
    assert_not_contains "$output" "Manual recovery: remove" "directory conflict must not recommend deletion"
    assert_not_contains "$output" "Manual recovery: install" "directory conflict must not recommend overwrite"
    assert_eq "" "$(<"$SERVICE_LOG_FILE")" "directory recovery conflict causes no service operation"
)

test_pending_terminal_journal_rejects_arithmetic_backup_keep() (
    local rc=0
    setup_transaction_case pending-backup-keep inactive
    XRAY_TXN_TOKEN="pending-backup-keep-1"
    XRAY_TXN_TARGET="v2.0.0"
    XRAY_TXN_OLD_EXISTS=1
    XRAY_TXN_OLD_DIGEST=$(_xray_sha256_file "$XRAY_BIN")
    XRAY_TXN_OLD_MODE=$(stat -c '%a' "$XRAY_BIN")
    XRAY_TXN_BACKUP="$CASE_DIR/bin/xray.bak-v1.2.3-20260721-141200"
    XRAY_TXN_RESTORE_STAGE="$CASE_DIR/bin/.xray.restore.$XRAY_TXN_TOKEN"
    XRAY_TXN_WAS_ACTIVE=0
    XRAY_TXN_SCHEDULE_ENABLED=0
    XRAY_TXN_SCHEDULE_LABEL="" XRAY_TXN_SCHEDULE_CRON="" XRAY_TXN_SCHEDULE_CALENDAR=""
    install -m 0755 "$XRAY_BIN" "$XRAY_TXN_BACKUP"
    install -m 0755 "$XRAY_BIN" "$XRAY_TXN_RESTORE_STAGE"
    write_fake_xray "$XRAY_BIN" v2.0.0 1
    XRAY_TXN_NEW_DIGEST=$(_xray_sha256_file "$XRAY_BIN")
    _xray_write_state committed
    PROBE=(0)
    XRAY_BACKUP_KEEP='PROBE[$(touch /srv/xray-backup-keep-injected)0]'

    recover_pending_xray_update_locked || rc=$?

    assert_ne 0 "$rc" "pending recovery must reject arithmetic-like backup retention"
    assert_not_exists /srv/xray-backup-keep-injected
    assert_file "$XRAY_UPDATE_STATE_FILE"
    assert_file "$XRAY_TXN_BACKUP"
    assert_file "$XRAY_TXN_RESTORE_STAGE"
    assert_binary_version v2.0.0 "$XRAY_BIN" "invalid retention leaves committed target unchanged"
    assert_eq "" "$(<"$SERVICE_LOG_FILE")" "invalid retention fails before service operations"
)

test_committed_terminal_preserves_external_target() (
    local rc=0 candidate
    setup_transaction_case committed-external-target inactive
    XRAY_TXN_TOKEN="committed-external-target-1"
    XRAY_TXN_TARGET="v2.0.0"
    XRAY_TXN_OLD_EXISTS=1
    XRAY_TXN_OLD_DIGEST=$(_xray_sha256_file "$XRAY_BIN")
    XRAY_TXN_OLD_MODE=$(stat -c '%a' "$XRAY_BIN")
    XRAY_TXN_BACKUP="$CASE_DIR/bin/xray.bak-v1.2.3-20260721-141300"
    XRAY_TXN_RESTORE_STAGE="$CASE_DIR/bin/.xray.restore.$XRAY_TXN_TOKEN"
    XRAY_TXN_WAS_ACTIVE=0
    XRAY_TXN_SCHEDULE_ENABLED=0
    XRAY_TXN_SCHEDULE_LABEL="" XRAY_TXN_SCHEDULE_CRON="" XRAY_TXN_SCHEDULE_CALENDAR=""
    install -m 0755 "$XRAY_BIN" "$XRAY_TXN_BACKUP"
    install -m 0755 "$XRAY_BIN" "$XRAY_TXN_RESTORE_STAGE"
    candidate="$CASE_DIR/bin/.xray.new.$XRAY_TXN_TOKEN"
    write_fake_xray "$candidate" v2.0.0 1
    XRAY_TXN_NEW_DIGEST=$(_xray_sha256_file "$candidate")
    _xray_write_state committed
    write_fake_xray "$XRAY_BIN" v9.9.9 1

    recover_pending_xray_update_locked || rc=$?

    assert_ne 0 "$rc" "committed recovery must reject an external canonical target"
    assert_binary_version v9.9.9 "$XRAY_BIN" "committed recovery preserves the external target"
    assert_file "$XRAY_UPDATE_STATE_FILE"
    assert_file "$XRAY_TXN_BACKUP"
    assert_file "$XRAY_TXN_RESTORE_STAGE"
    assert_file "$candidate"
    grep -q '^phase=committed$' "$XRAY_UPDATE_STATE_FILE" || fail "committed journal phase was lost"
    assert_eq "" "$(<"$SERVICE_LOG_FILE")" "terminal target conflict causes no service operation"
)

test_committed_terminal_rejects_nonexecutable_target() (
    local rc=0
    setup_transaction_case committed-nonexecutable-target inactive
    XRAY_TXN_TOKEN="committed-nonexec-target-1"
    XRAY_TXN_TARGET="v2.0.0"
    XRAY_TXN_OLD_EXISTS=1
    XRAY_TXN_OLD_DIGEST=$(_xray_sha256_file "$XRAY_BIN")
    XRAY_TXN_OLD_MODE=$(stat -c '%a' "$XRAY_BIN")
    XRAY_TXN_BACKUP="$CASE_DIR/bin/xray.bak-v1.2.3-20260721-141310"
    XRAY_TXN_RESTORE_STAGE="$CASE_DIR/bin/.xray.restore.$XRAY_TXN_TOKEN"
    XRAY_TXN_WAS_ACTIVE=0
    XRAY_TXN_SCHEDULE_ENABLED=0
    XRAY_TXN_SCHEDULE_LABEL="" XRAY_TXN_SCHEDULE_CRON="" XRAY_TXN_SCHEDULE_CALENDAR=""
    install -m 0755 "$XRAY_BIN" "$XRAY_TXN_BACKUP"
    install -m 0755 "$XRAY_BIN" "$XRAY_TXN_RESTORE_STAGE"
    write_fake_xray "$XRAY_BIN" v2.0.0 1
    XRAY_TXN_NEW_DIGEST=$(_xray_sha256_file "$XRAY_BIN")
    _xray_write_state committed
    chmod 0644 "$XRAY_BIN"

    recover_pending_xray_update_locked || rc=$?

    assert_ne 0 "$rc" "terminal recovery must reject a nonexecutable committed target"
    assert_eq 644 "$(stat -c '%a' "$XRAY_BIN")" "terminal recovery preserves the altered target"
    assert_file "$XRAY_UPDATE_STATE_FILE"
    assert_file "$XRAY_TXN_RESTORE_STAGE"
    assert_eq "" "$(<"$SERVICE_LOG_FILE")" "metadata conflict causes no service operation"
)

test_rolled_back_fresh_terminal_preserves_directory_target() (
    local rc=0 candidate
    setup_transaction_case rolled-back-fresh-directory inactive
    unlink "$XRAY_BIN"
    XRAY_TXN_TOKEN="rolled-back-fresh-directory-1"
    XRAY_TXN_TARGET="v2.0.0"
    XRAY_TXN_OLD_EXISTS=0
    XRAY_TXN_OLD_DIGEST=""
    XRAY_TXN_OLD_MODE=0755
    XRAY_TXN_BACKUP="$CASE_DIR/bin/xray.bak-v0.0-absent-20260721-141400"
    XRAY_TXN_RESTORE_STAGE="$CASE_DIR/bin/.xray.restore.$XRAY_TXN_TOKEN"
    XRAY_TXN_WAS_ACTIVE=0
    XRAY_TXN_SCHEDULE_ENABLED=0
    XRAY_TXN_SCHEDULE_LABEL="" XRAY_TXN_SCHEDULE_CRON="" XRAY_TXN_SCHEDULE_CALENDAR=""
    candidate="$CASE_DIR/bin/.xray.new.$XRAY_TXN_TOKEN"
    write_fake_xray "$candidate" v2.0.0 1
    XRAY_TXN_NEW_DIGEST=$(_xray_sha256_file "$candidate")
    _xray_write_state rolled-back
    mkdir "$XRAY_BIN"
    : > "$XRAY_BIN/preserve-me"

    recover_pending_xray_update_locked 2>"$CASE_DIR/recovery.err" || rc=$?

    assert_ne 0 "$rc" "rolled-back fresh journal must reject a directory target"
    assert_file "$XRAY_BIN/preserve-me"
    assert_file "$XRAY_UPDATE_STATE_FILE"
    assert_file "$candidate"
    assert_not_contains "$(<"$CASE_DIR/recovery.err")" \
        "Manual recovery for the interrupted fresh install: remove" \
        "terminal fresh conflict must not recommend deletion"
    assert_eq "" "$(<"$SERVICE_LOG_FILE")" "rolled-back fresh conflict causes no service operation"
)

test_locked_ordinary_install_preserves_existing_binary() (
    setup_transaction_case locked-ordinary-preserve inactive

    install_xray_release v2.0.0 ordinary-install

    assert_binary_version v1.2.3 "$XRAY_BIN" "locked ordinary install preserves a concurrent healthy binary"
    assert_not_exists "$CASE_DIR/download.called"
    assert_not_exists "$XRAY_UPDATE_STATE_FILE"
    assert_eq "" "$(<"$SERVICE_LOG_FILE")" "locked preserve performs no service operation"
)

test_locked_channel_update_refuses_downgrade() (
    setup_transaction_case locked-channel-refuse inactive
    write_fake_xray "$XRAY_BIN" v3.0.0 1

    install_xray_release v2.0.0 channel-update

    assert_binary_version v3.0.0 "$XRAY_BIN" "locked channel policy refuses downgrade"
    assert_not_exists "$CASE_DIR/download.called"
    assert_not_exists "$XRAY_UPDATE_STATE_FILE"
)

test_locked_fixed_update_allows_downgrade() (
    setup_transaction_case locked-fixed-downgrade inactive
    write_fake_xray "$XRAY_BIN" v3.0.0 1

    install_xray_release v2.0.0 fixed-update

    assert_binary_version v2.0.0 "$XRAY_BIN" "locked fixed-version policy permits explicit downgrade"
    assert_file "$CASE_DIR/download.called"
    assert_no_transaction_residue "locked fixed downgrade"
)

test_preserve_stage_late_arrival_is_not_clobbered() (
    local preserved
    setup_transaction_case preserve-stage-race inactive
    preserved="$CASE_DIR/bin/.xray.displaced.late-stage-race"
    XRAY_RECOVERY_EXTERNAL_CONFLICT=0
    mv() {
        printf '%s\n' external-stage > "$preserved"
        command mv "$@"
    }

    if xray_preserve_transaction_target "$XRAY_BIN" "$preserved" \
        "$(_xray_sha256_file "$XRAY_BIN")" "$(stat -c '%a' "$XRAY_BIN")"; then
        fail "late stage arrival must make no-clobber preserve fail"
    fi

    assert_binary_version v1.2.3 "$XRAY_BIN" "late stage arrival leaves canonical binary intact"
    assert_eq external-stage "$(<"$preserved")" "late stage arrival is not overwritten"
    assert_eq 1 "$XRAY_RECOVERY_EXTERNAL_CONFLICT" "late stage arrival is classified as conflict"
)

test_live_commit_stage_conflict_retains_journal() (
    local rc=0
    setup_transaction_case live-commit-stage-conflict inactive
    : > "$CASE_DIR/external-stage"
    MOCK_REPLACE_STAGE_ON_COMMIT=1

    install_xray_release v2.0.0 fixed-update || rc=$?

    assert_ne 0 "$rc" "committed transaction with a replaced stage must report failure"
    assert_binary_version v2.0.0 "$XRAY_BIN" "committed binary is not rolled back after finalizer conflict"
    assert_file "$XRAY_UPDATE_STATE_FILE"
    grep -q '^phase=committed$' "$XRAY_UPDATE_STATE_FILE" || fail "committed journal was not retained"
    find "$CASE_DIR/bin" -maxdepth 1 -type l -name '.xray.restore.*' -print -quit | grep -q . || \
        fail "replaced stage symlink was removed"
)

test_stage_cleanup_preflight_is_all_or_nothing() (
    local token="stage-preflight-1" restore
    setup_transaction_case stage-preflight inactive
    restore="$CASE_DIR/bin/.xray.restore.$token"
    : > "$CASE_DIR/bin/.xray.new.$token"
    ln -s "$CASE_DIR/missing-stage" "$restore"
    XRAY_RECOVERY_EXTERNAL_CONFLICT=0

    if _xray_cleanup_managed_stages "$CASE_DIR/bin" "$token" "$restore"; then
        fail "stage cleanup must reject a dangling symlink"
    fi

    assert_file "$CASE_DIR/bin/.xray.new.$token"
    [[ -L "$restore" ]] || fail "stage cleanup removed the conflicting symlink"
    assert_eq 1 "$XRAY_RECOVERY_EXTERNAL_CONFLICT" "stage cleanup records external conflict"
)

test_dangling_journal_symlink_is_preserved() (
    local rc=0
    setup_transaction_case dangling-journal inactive
    ln -s "$CASE_DIR/missing-journal" "$XRAY_UPDATE_STATE_FILE"

    install_xray_release v2.0.0 fixed-update || rc=$?

    assert_ne 0 "$rc" "dangling journal symlink must block a new transaction"
    [[ -L "$XRAY_UPDATE_STATE_FILE" ]] || fail "dangling journal symlink was overwritten"
    assert_not_exists "$CASE_DIR/download.called"
    assert_binary_version v1.2.3 "$XRAY_BIN" "dangling journal cannot change the binary"
)

test_active_runtime_identity_conflict_retains_evidence() (
    local rc=0
    setup_transaction_case recovery-runtime-conflict active
    XRAY_TXN_TOKEN="recovery-runtime-conflict-1"
    XRAY_TXN_TARGET="v2.0.0"
    XRAY_TXN_OLD_EXISTS=1
    XRAY_TXN_OLD_DIGEST=$(_xray_sha256_file "$XRAY_BIN")
    XRAY_TXN_OLD_MODE=$(stat -c '%a' "$XRAY_BIN")
    XRAY_TXN_BACKUP="$CASE_DIR/bin/xray.bak-v1.2.3-20260721-141500"
    XRAY_TXN_RESTORE_STAGE="$CASE_DIR/bin/.xray.restore.$XRAY_TXN_TOKEN"
    XRAY_TXN_WAS_ACTIVE=1
    XRAY_TXN_SCHEDULE_ENABLED=0
    XRAY_TXN_SCHEDULE_LABEL="" XRAY_TXN_SCHEDULE_CRON="" XRAY_TXN_SCHEDULE_CALENDAR=""
    install -m 0755 "$XRAY_BIN" "$XRAY_TXN_BACKUP"
    install -m 0755 "$XRAY_BIN" "$XRAY_TXN_RESTORE_STAGE"
    write_fake_xray "$XRAY_BIN" v2.0.0 1
    XRAY_TXN_NEW_DIGEST=$(_xray_sha256_file "$XRAY_BIN")
    _xray_write_state activated
    MOCK_STOP_IDENTITY_FAIL=1

    recover_pending_xray_update_locked 2>"$CASE_DIR/recovery.err" || rc=$?

    assert_ne 0 "$rc" "active wrong-identity recovery must fail closed"
    assert_binary_version v2.0.0 "$XRAY_BIN" "runtime identity conflict preserves canonical target"
    assert_file "$XRAY_UPDATE_STATE_FILE"
    assert_contains "$(<"$CASE_DIR/recovery.err")" "external Xray target or runtime state" \
        "runtime conflict uses identify-and-preserve guidance"
)

test_exact_process_set_rejects_additional_xray_pid() (
    setup_transaction_case exact-process-set inactive
    : > "$CASE_DIR/extra-process.visible"

    if xray_runtime_has_only_service_pid "$$"; then
        fail "a second Xray PID must invalidate the managed process set"
    fi
    unlink "$CASE_DIR/extra-process.visible"
    xray_runtime_has_only_service_pid "$$" || fail "the sole service PID should be accepted"
)

test_extra_process_at_stop_retains_recovery_evidence() (
    local rc=0 second_rc=0
    setup_transaction_case extra-process-at-stop active
    MOCK_EXTRA_PROCESS_AT_STOP=1

    install_xray_release v2.0.0 fixed-update 2>"$CASE_DIR/update.err" || rc=$?

    assert_ne 0 "$rc" "an additional Xray process at stop must fail the update"
    assert_binary_version v1.2.3 "$XRAY_BIN" "stop conflict preserves the old binary"
    assert_eq active "$(<"$SERVICE_STATE_FILE")" "stop conflict does not stop the managed service"
    assert_eq "" "$(<"$SERVICE_LOG_FILE")" "stop conflict performs no service operation"
    assert_file "$XRAY_UPDATE_STATE_FILE"
    find "$CASE_DIR/bin" -maxdepth 1 -type f -name '.xray.restore.*' -print -quit | grep -q . || \
        fail "stop conflict did not retain the restore stage"

    recover_pending_xray_update_locked 2>"$CASE_DIR/recovery.err" || second_rc=$?
    assert_ne 0 "$second_rc" "terminal recovery must still reject the additional Xray PID"
    assert_file "$XRAY_UPDATE_STATE_FILE"
    find "$CASE_DIR/bin" -maxdepth 1 -type f -name '.xray.restore.*' -print -quit | grep -q . || \
        fail "recovery conflict removed the restore stage"
    assert_contains "$(<"$CASE_DIR/recovery.err")" "external Xray target or runtime state" \
        "persistent process conflict retains identify-and-preserve guidance"
)

test_active_update_success
pass "successful update restores the original active service state"

test_config_preflight_failure
pass "invalid existing config rejects the candidate before binary replacement"

test_activation_health_failure_rolls_back
pass "failed activation health check restores and restarts the prior binary"

test_inactive_update_stays_inactive
pass "a previously stopped Xray remains stopped after a successful update"

test_persistent_activated_state_recovers
pass "an activated persistent journal recovers the prior binary and active state"

test_term_after_stop_rolls_back
pass "TERM between stop and activation rolls back cleanly"

test_hardlink_sync_failure_is_safe
pass "hardlink durability failure aborts before stopping the existing service"

test_committed_phase_does_not_roll_back
pass "durably committed updates are not misreported or rolled back"

test_signal_during_commit_publication_is_terminal
pass "signals in the durable commit publication window cannot trigger rollback"

test_committed_state_file_sync_failure_rolls_back
pass "committed journal file-sync failures retain identity and roll back"

test_committed_state_directory_sync_failure_rolls_back
pass "committed journal directory-sync failures retain identity and roll back"

test_recovery_state_payload_failure_is_retryable
pass "pre-rename journal failures leave no token-blocking payload residue"

test_state_directory_creation_is_parent_synced
pass "new persistent state directories are anchored by a parent-directory sync"

test_old_binary_change_before_backup_is_rejected
pass "old binary identity is revalidated after candidate preflight"

test_stop_boundary_identity_failure_is_safe
pass "service identity conflicts retain evidence at the exact stop boundary"

test_untrusted_state_file_is_rejected_before_stop
pass "persistent recovery rejects untrusted journal permissions before service changes"

test_unsafe_tmp_parent_is_rejected
pass "unsafe inherited temporary parents are rejected before artifact processing"

test_replaced_tmp_directory_is_preserved
pass "temporary directory identity replacement aborts without deleting the replacement"

test_inactive_service_start_during_validation_fails_closed
pass "runtime state transitions preserve recovery evidence before activation"

test_unsafe_tmp_ancestor_is_rejected
pass "temporary parent validation covers the complete canonical ancestor chain"

test_binary_change_immediately_before_activation_is_preserved
pass "old binary identity is unconditionally revalidated immediately before activation"

test_fresh_install_target_appearance_is_preserved
pass "fresh-install activation is atomic no-clobber"

test_recovery_preserves_unexpected_existing_update_target
pass "update recovery preserves binaries outside the journal state"

test_recovery_preserves_unexpected_fresh_target
pass "fresh-install recovery never deletes an unexpected external binary"

test_recovery_skips_corrupt_restore_source
pass "recovery skips corrupt sources and uses a verified fallback"

test_recovery_skips_nonexecutable_restore_source
pass "recovery rejects restore sources whose recorded mode changed"

test_fresh_cutover_symlink_is_external_conflict
pass "fresh cutover preserves an unexpected symlink target"

test_update_recovery_directory_target_is_preserved
pass "update recovery preserves an unexpected directory target"

test_pending_terminal_journal_rejects_arithmetic_backup_keep
pass "pending recovery rejects arithmetic backup retention before cleanup"

test_committed_terminal_preserves_external_target
pass "committed recovery preserves external targets and evidence"

test_committed_terminal_rejects_nonexecutable_target
pass "committed recovery verifies target mode before deleting evidence"

test_rolled_back_fresh_terminal_preserves_directory_target
pass "rolled-back fresh recovery preserves non-regular targets and evidence"

test_locked_ordinary_install_preserves_existing_binary
pass "locked ordinary-install policy preserves concurrent healthy Xray"

test_locked_channel_update_refuses_downgrade
pass "locked channel policy refuses concurrent downgrade"

test_locked_fixed_update_allows_downgrade
pass "locked fixed-version policy permits explicit downgrade"

test_preserve_stage_late_arrival_is_not_clobbered
pass "same-directory preserve does not clobber a late stage"

test_live_commit_stage_conflict_retains_journal
pass "live committed finalizer retains journal on stage conflict"

test_stage_cleanup_preflight_is_all_or_nothing
pass "managed-stage cleanup preflights every path before deletion"

test_dangling_journal_symlink_is_preserved
pass "dangling journal symlink blocks new transactions without overwrite"

test_active_runtime_identity_conflict_retains_evidence
pass "runtime identity conflicts retain recovery evidence and safe guidance"

test_exact_process_set_rejects_additional_xray_pid
pass "the managed service PID must be the only Xray process"

test_extra_process_at_stop_retains_recovery_evidence
pass "additional Xray processes block terminal cleanup and preserve evidence"

pass "Xray transaction rollback contract"
