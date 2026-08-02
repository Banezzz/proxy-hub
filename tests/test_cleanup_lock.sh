#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_bwrap
require_command git

lock_tmp_base="$TEST_DIR/.tmp"
mkdir -p -- "$lock_tmp_base"
lock_tmp=$(mktemp -d "$lock_tmp_base/proxy-hub-test.cleanup-lock.XXXXXXXX")
register_cleanup_dir "$lock_tmp"
mkdir -p -- "$lock_tmp/tmp/tmp.foreign" "$lock_tmp/assets"
printf 'keep\n' >"$lock_tmp/tmp/tmp.foreign/keep"
cp -- "$REPO_ROOT/dist/proxy-hub.bundle.sh" "$lock_tmp/assets/proxy-hub.bundle.sh"
git -C "$REPO_ROOT" show "$LEGACY_BASELINE_COMMIT:proxy-hub.sh" >"$lock_tmp/assets/legacy-proxy-hub.sh"

lock_sandbox_base=(
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
    --bind "$lock_tmp" /srv
    --setenv TMPDIR /srv/tmp
    --setenv LANG en_US.UTF-8
)

run_lock_scenario() {
    local label="$1"
    local script="$2"
    if [[ -n "${PROXY_HUB_TEST_SCENARIO:-}" && "$label" != "$PROXY_HUB_TEST_SCENARIO" ]]; then
        return 0
    fi
    local stdout_file="$lock_tmp/${label}.out"
    local stderr_file="$lock_tmp/${label}.err"
    local rc=0
    "${lock_sandbox_base[@]}" -- bash -c "$script" >"$stdout_file" 2>"$stderr_file" || rc=$?
    if ((rc != 0)); then
        sed -n '1,200p' "$stderr_file" >&2
        fail "$label failed with status $rc"
    fi
    pass "$label"
}

run_lock_scenario mkdir-basic '
    set -euo pipefail
    source /mnt/lib/00_security_state.sh
    lock_acquire_smart
    [[ "$LOCK_HELD_METHOD" == mkdir ]]
    [[ "$LOCK_DIR" == /tmp/proxy-hub-"$EUID"/write.lock.d ]]
    [[ -f "$LOCK_OWNER_FILE" && -f "$PID_FILE" ]]
    printf "foreign\n" >"$LOCK_PARENT/foreign.keep"
    lock_release_smart
    [[ ! -d "$LOCK_DIR" ]]
    [[ -f "$LOCK_PARENT/foreign.keep" ]]
'

run_lock_scenario mkdir-contention '
    set -euo pipefail
    source /mnt/lib/00_security_state.sh
    lock_acquire_smart
    if TMPDIR=/srv/tmp bash -c "set -euo pipefail; source /mnt/lib/00_security_state.sh; lock_acquire_smart"; then
        echo "contender unexpectedly acquired mkdir lock" >&2
        exit 1
    fi
    lock_release_smart
    TMPDIR=/srv/tmp bash -c "set -euo pipefail; source /mnt/lib/00_security_state.sh; lock_acquire_smart; lock_release_smart"
'

run_lock_scenario failed-reacquire-preserves-owner '
    set -euo pipefail
    source /mnt/lib/00_security_state.sh
    lock_acquire_smart
    first_token="$LOCK_TOKEN"
    first_id="$LOCK_DIR_ID"
    if lock_acquire_smart; then
        echo "same process unexpectedly reacquired its lock" >&2
        exit 1
    fi
    [[ "$LOCK_TOKEN" == "$first_token" ]]
    [[ "$LOCK_DIR_ID" == "$first_id" ]]
    lock_release_smart
    [[ ! -d "$LOCK_DIR" ]]
'

run_lock_scenario signal-during-lock-publication '
    set -euo pipefail
    for stage in mkdir owner pid; do
        signal_rc=0
        PATH="/mnt/tests/fixtures/fake-bin:$PATH" FAKE_LOCK_SIGNAL_STAGE="$stage" \
            bash -c "set -euo pipefail; source /mnt/lib/00_security_state.sh; source /mnt/lib/10_runtime_platform_ui.sh; lock_acquire_smart; exit 99" \
            >/srv/lock-signal-"$stage".out 2>/srv/lock-signal-"$stage".err || signal_rc=$?
        [[ "$signal_rc" -eq 143 ]]
        [[ ! -d /tmp/proxy-hub-"$EUID"/write.lock.d ]]
        bash -c "set -euo pipefail; source /mnt/lib/00_security_state.sh; lock_acquire_smart; lock_release_smart"
    done
'

run_lock_scenario mkdir-owner-mismatch '
    set -euo pipefail
    source /mnt/lib/00_security_state.sh
    lock_acquire_smart
    printf "foreign-token\n%s\n" "$$" >"$LOCK_OWNER_FILE"
    lock_release_smart
    [[ -d "$LOCK_DIR" ]]
    [[ -f "$LOCK_OWNER_FILE" ]]
    rm -f -- "$PID_FILE" "$LOCK_OWNER_FILE"
    rmdir -- "$LOCK_DIR"
'

run_lock_scenario mkdir-inode-replacement '
    set -euo pipefail
    source /mnt/lib/00_security_state.sh
    lock_acquire_smart
    saved_dir="$LOCK_DIR"
    saved_owner="$LOCK_OWNER_FILE"
    saved_pid="$PID_FILE"
    mv -- "$saved_dir" "${saved_dir}.original"
    mkdir -m 700 -- "$saved_dir"
    printf "%s\n%s\n" "$LOCK_TOKEN" "$$" >"$saved_owner"
    printf "%s\n" "$$" >"$saved_pid"
    lock_release_smart
    [[ -d "$saved_dir" ]]
    [[ -f "$saved_owner" ]]
    rm -f -- "$saved_owner" "$saved_pid"
    rmdir -- "$saved_dir"
    rm -f -- "${saved_dir}.original/owner" "${saved_dir}.original/pid"
    rmdir -- "${saved_dir}.original"
'

run_lock_scenario acquisition-failure-keeps-unproven-replacement '
    set -euo pipefail
    source /mnt/lib/00_security_state.sh
    lock_dir_identity() {
        /usr/bin/mv -- "$1" "${1}.original"
        /usr/bin/mkdir -m 700 -- "$1"
        return 1
    }
    if lock_acquire_smart; then
        echo "identity-failing acquisition unexpectedly succeeded" >&2
        exit 1
    fi
    [[ -d /tmp/proxy-hub-"$EUID"/write.lock.d ]]
    [[ -d /tmp/proxy-hub-"$EUID"/write.lock.d.original ]]
    rmdir -- /tmp/proxy-hub-"$EUID"/write.lock.d
    rmdir -- /tmp/proxy-hub-"$EUID"/write.lock.d.original
'

run_lock_scenario compatibility-entrypoints-share-domain '
    set -euo pipefail
    source /mnt/lib/00_security_state.sh
    lock_acquire_flock
    [[ "$LOCK_HELD_METHOD" == mkdir ]]
    if bash -c "set -euo pipefail; source /mnt/lib/00_security_state.sh; lock_acquire_smart"; then
        echo "smart contender unexpectedly bypassed compatibility lock" >&2
        exit 1
    fi
    lock_release_flock
    bash -c "set -euo pipefail; source /mnt/lib/00_security_state.sh; lock_acquire_smart; lock_release_smart"
'

run_lock_scenario legacy-read-only-cleanup-cannot-delete-new-lock '
    set -euo pipefail
    source /mnt/lib/00_security_state.sh
    lock_acquire_smart
    bash /srv/assets/legacy-proxy-hub.sh help >/srv/legacy-help.out 2>/srv/legacy-help.err
    [[ -d "$LOCK_DIR" ]]
    if bash -c "set -euo pipefail; source /mnt/lib/00_security_state.sh; lock_acquire_smart"; then
        echo "new contender acquired after legacy read-only cleanup" >&2
        exit 1
    fi
    lock_release_smart
'

run_lock_scenario cleanup-foreign-temp '
    set -euo pipefail
    source /mnt/lib/00_security_state.sh
    source /mnt/lib/10_runtime_platform_ui.sh
    lock_acquire_smart
    cleanup
    [[ -f /srv/tmp/tmp.foreign/keep ]]
    [[ ! -d "$LOCK_DIR" ]]
'

run_lock_scenario signal-releases-owned-lock '
    set -euo pipefail
    rm -f -- /srv/lock.ready
    setsid bash -c '\''
        set -euo pipefail
        export TMPDIR=/srv/tmp
        source /mnt/lib/00_security_state.sh
        source /mnt/lib/10_runtime_platform_ui.sh
        lock_acquire_smart
        printf "%s\n" "$LOCK_DIR" > /srv/lock.ready
        while :; do sleep 0.1; done
    '\'' &
    child=$!
    for _ in $(seq 1 100); do
        [[ -s /srv/lock.ready ]] && break
        sleep 0.02
    done
    [[ -s /srv/lock.ready ]]
    lock_dir=$(cat /srv/lock.ready)
    kill -TERM -- "-$child"
    for _ in $(seq 1 100); do
        ! kill -0 "$child" 2>/dev/null && break
        sleep 0.02
    done
    ! kill -0 "$child" 2>/dev/null
    child_rc=0
    wait "$child" || child_rc=$?
    [[ "$child_rc" -eq 143 ]]
    [[ ! -d "$lock_dir" ]]
    [[ -f /srv/tmp/tmp.foreign/keep ]]
    bash -c "set -euo pipefail; source /mnt/lib/00_security_state.sh; lock_acquire_smart; lock_release_smart"
'

run_lock_scenario hup-releases-owned-lock '
    set -euo pipefail
    rm -f -- /srv/lock.ready
    setsid bash -c '\''
        set -euo pipefail
        export TMPDIR=/srv/tmp
        source /mnt/lib/00_security_state.sh
        source /mnt/lib/10_runtime_platform_ui.sh
        lock_acquire_smart
        printf "%s\n" "$LOCK_DIR" > /srv/lock.ready
        while :; do sleep 0.1; done
    '\'' &
    child=$!
    for _ in $(seq 1 100); do
        [[ -s /srv/lock.ready ]] && break
        sleep 0.02
    done
    [[ -s /srv/lock.ready ]]
    lock_dir=$(cat /srv/lock.ready)
    kill -HUP -- "-$child"
    for _ in $(seq 1 100); do
        ! kill -0 "$child" 2>/dev/null && break
        sleep 0.02
    done
    ! kill -0 "$child" 2>/dev/null
    child_rc=0
    wait "$child" || child_rc=$?
    [[ "$child_rc" -eq 129 ]]
    [[ ! -d "$lock_dir" ]]
    [[ -f /srv/tmp/tmp.foreign/keep ]]
    bash -c "set -euo pipefail; source /mnt/lib/00_security_state.sh; lock_acquire_smart; lock_release_smart"
'

run_lock_scenario stale-owner-diagnosed-not-reclaimed '
    set -euo pipefail
    source /mnt/lib/00_security_state.sh
    lock_acquire_smart

    # The recorded PID is this process and reads back as alive.
    [[ "$(lock_recorded_pid)" == "$$" ]]
    lock_pid_liveness "$$"

    # Owner identity is recorded next to the PID so a recycled PID cannot pass
    # as a live owner.
    [[ "$(lock_recorded_start)" == "$(lock_process_start_time "$$")" ]]
    [[ "$(lock_recorded_boot_id)" == "$(lock_boot_id)" ]]

    # A live PID whose recorded start time does not match was recycled by an
    # unrelated process: the lock is stale (1), not owned (0).
    liveness=0
    lock_pid_liveness 1 999999999 "$(lock_boot_id)" || liveness=$?
    [[ "$liveness" -eq 1 ]]

    # A lock carried across a reboot is stale even when the PID exists again.
    liveness=0
    lock_pid_liveness 1 "" "00000000-0000-0000-0000-000000000000" || liveness=$?
    [[ "$liveness" -eq 1 ]]

    # Locks written before this metadata existed keep PID-only classification.
    liveness=0
    lock_pid_liveness 1 "" "" || liveness=$?
    [[ "$liveness" -eq 0 ]]
    lock_pid_present 1

    # A provably-dead PID is classified stale (return 1) but the lock is left
    # intact: diagnostics never auto-reclaim (docs/audits.md).
    dead=4000000
    while [[ -e "/proc/$dead" ]]; do dead=$((dead + 1)); done
    printf "%s\n" "$dead" > "$PID_FILE"
    liveness=0
    lock_pid_liveness "$dead" || liveness=$?
    [[ "$liveness" -eq 1 ]]
    [[ "$(lock_recorded_pid)" == "$dead" ]]
    [[ -d "$LOCK_DIR" && -f "$PID_FILE" && -f "$LOCK_OWNER_FILE" ]]

    # Malformed metadata is rejected and unparseable PIDs are indeterminate (2).
    printf "not-a-pid\n" > "$PID_FILE"
    if lock_recorded_pid >/dev/null; then
        echo "malformed pid unexpectedly accepted" >&2
        exit 1
    fi
    liveness=0
    lock_pid_liveness "garbage" || liveness=$?
    [[ "$liveness" -eq 2 ]]

    # A symlinked PID file is refused even when its target is a live PID.
    rm -f -- "$PID_FILE"
    printf "%s\n" "$$" > /srv/real-pid
    ln -s /srv/real-pid "$PID_FILE"
    if lock_recorded_pid >/dev/null; then
        echo "symlinked pid file unexpectedly accepted" >&2
        exit 1
    fi

    # Restore well-formed metadata so the owner can release its own lock.
    rm -f -- "$PID_FILE"
    printf "%s\n" "$$" > "$PID_FILE"
    lock_release_smart
    [[ ! -d "$LOCK_DIR" ]]
'

run_lock_scenario parent-term-waits-for-resistant-writer '
    set -euo pipefail
    rm -f -- /srv/resistant.ready /srv/resistant.pid /srv/resistant.log
    setsid bash -c '\''
        set -euo pipefail
        source /mnt/lib/00_security_state.sh
        source /mnt/lib/10_runtime_platform_ui.sh
        lock_acquire_smart
        bash /mnt/tests/fixtures/resistant-writer.sh &
        printf "%s\n" "$LOCK_DIR" >/srv/resistant.ready
        while :; do sleep 0.1; done
    '\'' &
    parent=$!
    for _ in $(seq 1 100); do
        [[ -s /srv/resistant.ready && -s /srv/resistant.pid ]] && break
        sleep 0.02
    done
    [[ -s /srv/resistant.ready && -s /srv/resistant.pid ]]
    lock_dir=$(cat /srv/resistant.ready)
    writer=$(cat /srv/resistant.pid)
    kill -TERM "$parent"
    sleep 0.2
    kill -0 "$parent" 2>/dev/null
    kill -0 "$writer" 2>/dev/null
    [[ -d "$lock_dir" ]]
    if bash -c "set -euo pipefail; source /mnt/lib/00_security_state.sh; lock_acquire_smart"; then
        echo "second writer acquired before resistant child exited" >&2
        exit 1
    fi
    for _ in $(seq 1 250); do
        ! kill -0 "$parent" 2>/dev/null && break
        sleep 0.02
    done
    ! kill -0 "$parent" 2>/dev/null
    parent_rc=0
    wait "$parent" || parent_rc=$?
    [[ "$parent_rc" -eq 143 ]]
    ! kill -0 "$writer" 2>/dev/null
    [[ ! -d "$lock_dir" ]]
    bash -c "set -euo pipefail; source /mnt/lib/00_security_state.sh; lock_acquire_smart; lock_release_smart"
'

run_lock_scenario term-handler-fork-and-exit-cannot-escape-unlock '
    set -euo pipefail
    pid_is_running() {
        local pid="$1" stat_line rest
        [[ -r "/proc/$pid/stat" ]] || return 1
        IFS= read -r stat_line < "/proc/$pid/stat" || return 1
        rest="${stat_line##*) }"
        [[ "${rest%% *}" != Z && "${rest%% *}" != X ]]
    }
    rm -f -- /srv/late-exit.ready /srv/late-root.pid /srv/late-children.pids
    setsid bash -c '\''
        set -euo pipefail
        source /mnt/lib/00_security_state.sh
        source /mnt/lib/10_runtime_platform_ui.sh
        lock_acquire_smart
        bash /mnt/tests/fixtures/late-fork-root.sh &
        printf "%s\n" "$LOCK_DIR" >/srv/late-exit.ready
        while :; do sleep 0.1; done
    '\'' &
    parent=$!
    for _ in $(seq 1 100); do
        [[ -s /srv/late-exit.ready && -s /srv/late-root.pid ]] && break
        sleep 0.02
    done
    [[ -s /srv/late-exit.ready && -s /srv/late-root.pid ]]
    lock_dir=$(cat /srv/late-exit.ready)
    kill -TERM "$parent"
    for _ in $(seq 1 100); do
        [[ -s /srv/late-children.pids ]] && break
        sleep 0.02
    done
    [[ -s /srv/late-children.pids ]]
    escaped_child=$(tail -n 1 /srv/late-children.pids)
    pid_is_running "$escaped_child"
    kill -0 "$parent" 2>/dev/null
    [[ -d "$lock_dir" ]]
    if bash -c "set -euo pipefail; source /mnt/lib/00_security_state.sh; lock_acquire_smart"; then
        echo "second writer acquired while reparented child was alive" >&2
        exit 1
    fi
    for _ in $(seq 1 300); do
        ! kill -0 "$parent" 2>/dev/null && break
        sleep 0.02
    done
    ! kill -0 "$parent" 2>/dev/null
    parent_rc=0
    wait "$parent" || parent_rc=$?
    [[ "$parent_rc" -eq 143 ]]
    ! pid_is_running "$escaped_child"
    [[ ! -d "$lock_dir" ]]
    bash -c "set -euo pipefail; source /mnt/lib/00_security_state.sh; lock_acquire_smart; lock_release_smart"
'

run_lock_scenario pgid-reuse-is-fail-closed '
    set -euo pipefail
    source /mnt/lib/00_security_state.sh
    source /mnt/lib/10_runtime_platform_ui.sh
    trap - EXIT INT TERM

    reset_cleanup_model() {
        CLEANUP_TREE_PIDS=()
        CLEANUP_TREE_SEEN=()
        CLEANUP_TREE_IDENTITIES=()
        CLEANUP_TRACKED_GROUPS=()
        CLEANUP_GROUP_LEADER_IDENTITIES=()
        CLEANUP_HAS_UNBOUNDED_ROOTS=0
        FAKE_LEADER_READS=0
        FAKE_ROOT_READS=0
        FAKE_SIGNAL_COUNT=0
    }
    cleanup_list_process_ids() {
        printf "%s\n" 4242 4343
    }
    cleanup_send_signal() {
        FAKE_SIGNAL_COUNT=$((FAKE_SIGNAL_COUNT + 1))
    }

    # The root stat still matches the jobs snapshot, but the separate group
    # leader read sees the numeric PID after reuse.  The new leader identity
    # must never be saved as though it belonged to the registered job root.
    reset_cleanup_model
    CLEANUP_TREE_IDENTITIES[4242]=root-old
    cleanup_read_process_stat() {
        local pid="$1"
        CLEANUP_STAT_STATE=S
        if [[ "$pid" == 4242 ]]; then
            CLEANUP_STAT_GROUP=4242
            FAKE_ROOT_READS=$((FAKE_ROOT_READS + 1))
            if ((FAKE_ROOT_READS >= 2)); then
                CLEANUP_STAT_IDENTITY=root-new
            else
                CLEANUP_STAT_IDENTITY=root-old
            fi
        else
            CLEANUP_STAT_GROUP="$pid"
            CLEANUP_STAT_IDENTITY=shell-old
        fi
    }
    cleanup_track_process_group 4242
    [[ -z "${CLEANUP_TRACKED_GROUPS[4242]:-}" ]]
    [[ "$CLEANUP_HAS_UNBOUNDED_ROOTS" -eq 1 ]]

    # Reuse after the provisional member scan but before its post-scan leader
    # validation must absorb none of the scanned group.
    reset_cleanup_model
    CLEANUP_TRACKED_GROUPS[4242]=1
    CLEANUP_GROUP_LEADER_IDENTITIES[4242]=leader-old
    cleanup_read_process_stat() {
        local pid="$1"
        CLEANUP_STAT_STATE=S
        CLEANUP_STAT_GROUP=4242
        if [[ "$pid" == 4242 ]]; then
            FAKE_LEADER_READS=$((FAKE_LEADER_READS + 1))
            if ((FAKE_LEADER_READS >= 3)); then
                CLEANUP_STAT_IDENTITY=leader-new
            else
                CLEANUP_STAT_IDENTITY=leader-old
            fi
        else
            CLEANUP_STAT_IDENTITY=member-old
        fi
    }
    if cleanup_collect_process_group 4242; then
        echo "post-scan PGID reuse unexpectedly validated" >&2
        exit 1
    fi
    [[ "${#CLEANUP_TREE_PIDS[@]}" -eq 0 ]]
    [[ "$CLEANUP_HAS_UNBOUNDED_ROOTS" -eq 1 ]]

    # A reuse that occurs after a successful scan is caught again at the
    # signal gate.  No provisional or previously recorded PID may be signaled.
    reset_cleanup_model
    CLEANUP_TRACKED_GROUPS[4242]=1
    CLEANUP_GROUP_LEADER_IDENTITIES[4242]=leader-old
    FAKE_REUSED=0
    cleanup_read_process_stat() {
        local pid="$1"
        CLEANUP_STAT_STATE=S
        CLEANUP_STAT_GROUP=4242
        if [[ "$pid" == 4242 ]]; then
            if ((FAKE_REUSED)); then
                CLEANUP_STAT_IDENTITY=leader-new
            else
                CLEANUP_STAT_IDENTITY=leader-old
            fi
        else
            CLEANUP_STAT_IDENTITY=member-old
        fi
    }
    cleanup_collect_process_group 4242
    [[ "${#CLEANUP_TREE_PIDS[@]}" -eq 2 ]]
    FAKE_REUSED=1
    if cleanup_signal_original_processes TERM; then
        echo "reused PGID unexpectedly passed the signal gate" >&2
        exit 1
    fi
    [[ "$FAKE_SIGNAL_COUNT" -eq 0 ]]
    [[ "$CLEANUP_HAS_UNBOUNDED_ROOTS" -eq 1 ]]
'

run_lock_scenario signal-completes-tracked-ssh-rollback '
    set -euo pipefail
    printf "Port 22\n" >/srv/ssh.config
    rm -f -- /srv/ssh.ready /srv/ssh.timer.pid /srv/ssh.state
    setsid bash -c '\''
        set -euo pipefail
        source /mnt/lib/00_security_state.sh
        source /mnt/lib/10_runtime_platform_ui.sh
        source /mnt/lib/70_ports_logs.sh
        INIT_SYSTEM=systemd
        lock_acquire_smart
        ssh_rollback_prepare_state
        ssh_rollback_create_backup /srv/ssh.config
        printf "Port 2222\n" >/srv/ssh.config
        start_ssh_rollback_timer /srv/ssh.config "$SSH_ROLLBACK_BACKUP" 22 120 \
            "$SSH_ROLLBACK_STATE_DIR/confirmed"
        printf "%s\n" "$SSH_ROLLBACK_PID" >/srv/ssh.timer.pid
        printf "%s\n" "$SSH_ROLLBACK_STATE_DIR" >/srv/ssh.state
        printf "%s\n" "$LOCK_DIR" >/srv/ssh.ready
        while :; do sleep 0.1; done
    '\'' &
    parent=$!
    for _ in $(seq 1 100); do
        [[ -s /srv/ssh.ready && -s /srv/ssh.timer.pid ]] && break
        sleep 0.02
    done
    [[ -s /srv/ssh.ready && -s /srv/ssh.timer.pid ]]
    lock_dir=$(cat /srv/ssh.ready)
    timer_pid=$(cat /srv/ssh.timer.pid)
    state_dir=$(cat /srv/ssh.state)
    kill -TERM "$parent"
    for _ in $(seq 1 250); do
        ! kill -0 "$parent" 2>/dev/null && break
        sleep 0.02
    done
    ! kill -0 "$parent" 2>/dev/null
    parent_rc=0
    wait "$parent" || parent_rc=$?
    [[ "$parent_rc" -eq 143 ]]
    ! kill -0 "$timer_pid" 2>/dev/null
    [[ "$(cat /srv/ssh.config)" == "Port 22" ]]
    [[ ! -e "$state_dir" ]]
    [[ ! -d "$lock_dir" ]]
    bash -c "set -euo pipefail; source /mnt/lib/00_security_state.sh; lock_acquire_smart; lock_release_smart"
'

run_lock_scenario parent-claim-wins-before-timer-claim '
    set -euo pipefail
    printf "Port 22\n" >/srv/ssh.config
    rm -f -- /srv/ssh.worker-preclaim /srv/ssh.release-worker \
        /srv/ssh.rollback-count
    source /mnt/lib/00_security_state.sh
    source /mnt/lib/10_runtime_platform_ui.sh
    source /mnt/lib/70_ports_logs.sh
    INIT_SYSTEM=systemd

    # Hold only the timer subshell immediately before its claim.  Parent
    # cleanup remains free to claim rolling-back first.  Remap the losing
    # worker observation to status 2 to prove that a non-zero claim result is
    # not sufficient evidence of claimant ownership.
    eval "$(declare -f ssh_rollback_claim_phase | \
        sed '''1s/ssh_rollback_claim_phase/original_ssh_rollback_claim_phase/''')"
    ssh_rollback_claim_phase() {
        local target="$1" claim_status=0
        if [[ "$target" == "rolling-back" && "$BASHPID" != "$$" ]]; then
            printf "preclaim\n" >/srv/ssh.worker-preclaim
            while [[ ! -e /srv/ssh.release-worker ]]; do sleep 0.02; done
        fi
        original_ssh_rollback_claim_phase "$target" || claim_status=$?
        if [[ "$target" == "rolling-back" && "$BASHPID" != "$$" \
            && "$claim_status" -ne 0 \
            && "$(ssh_rollback_phase_current 2>/dev/null || true)" == "rolling-back" ]]; then
            SSH_ROLLBACK_CLAIM_RESULT=rolling-back
            return 2
        fi
        return "$claim_status"
    }

    eval "$(declare -f _ssh_rollback_claimed | \
        sed '''1s/_ssh_rollback_claimed/original_ssh_rollback_claimed/''')"
    _ssh_rollback_claimed() {
        printf "rollback\n" >>/srv/ssh.rollback-count
        original_ssh_rollback_claimed "$@"
    }

    lock_acquire_smart
    lock_dir=$LOCK_DIR
    ssh_rollback_prepare_state
    state_dir=$SSH_ROLLBACK_STATE_DIR
    ssh_rollback_create_backup /srv/ssh.config
    printf "Port 2222\n" >/srv/ssh.config
    start_ssh_rollback_timer /srv/ssh.config "$SSH_ROLLBACK_BACKUP" 22 0.05 \
        "$SSH_ROLLBACK_STATE_DIR/confirmed"
    timer_pid=$SSH_ROLLBACK_PID
    for _ in $(seq 1 250); do
        [[ -s /srv/ssh.worker-preclaim ]] && break
        sleep 0.02
    done
    [[ -s /srv/ssh.worker-preclaim ]]
    [[ "$(ssh_rollback_phase_current)" == "pending" ]]

    # Release the losing worker only after parent cleanup has atomically
    # published phase.rolling-back.  cleanup_pending_ssh_rollback blocks in
    # identity-bound stop/wait until that worker exits.
    (
        while [[ "$(ssh_rollback_phase_current 2>/dev/null || true)" != "rolling-back" ]]; do
            sleep 0.02
        done
        printf "release\n" >/srv/ssh.release-worker
    ) &
    releaser=$!
    cleanup_pending_ssh_rollback
    wait "$releaser"

    [[ "$(wc -l </srv/ssh.rollback-count)" -eq 1 ]]
    ! kill -0 "$timer_pid" 2>/dev/null
    [[ "$(cat /srv/ssh.config)" == "Port 22" ]]
    [[ ! -e "$state_dir" ]]
    [[ -z "$SSH_ROLLBACK_STATE_DIR" ]]
    lock_release_smart
    [[ ! -d "$lock_dir" ]]
    bash -c "set -euo pipefail; source /mnt/lib/00_security_state.sh; lock_acquire_smart; lock_release_smart"
'

run_lock_scenario signal-waits-for-claimed-ssh-rollback '
    set -euo pipefail
    printf "Port 22\n" >/srv/ssh.config
    run_claimed_group_signal_case() {
        local signal="$1" expected_status="$2" tag="${1,,}"
        local prefix="/srv/ssh.$tag"
        rm -f -- "$prefix.claimed" "$prefix.ready" "$prefix.release" \
            "$prefix.result-durable" "$prefix.state" "$prefix.timer.pid"
        SSH_SIGNAL_TAG="$tag" setsid bash -c '\''
            set -euo pipefail
            source /mnt/lib/00_security_state.sh
            source /mnt/lib/10_runtime_platform_ui.sh
            source /mnt/lib/70_ports_logs.sh
            INIT_SYSTEM=systemd
            prefix="/srv/ssh.$SSH_SIGNAL_TAG"

            # Pause after the timer has claimed rolling-back but before it
            # copies the backup over the live config.  The signal is then sent
            # to the entire PGID, not merely the parent.
            eval "$(declare -f _ssh_rollback_claimed | \
                sed '\''1s/_ssh_rollback_claimed/original_ssh_rollback_claimed/'\'')"
            _ssh_rollback_claimed() {
                [[ "$(ssh_rollback_phase_current)" == "rolling-back" ]]
                printf "claimed\n" >"$prefix.claimed"
                while [[ ! -e "$prefix.release" ]]; do sleep 0.02; done
                original_ssh_rollback_claimed "$@"
            }

            # Preserve evidence that the result was durable before completed
            # transaction state is removed by parent cleanup.
            eval "$(declare -f ssh_rollback_remove_backup | \
                sed '\''1s/ssh_rollback_remove_backup/original_ssh_rollback_remove_backup/'\'')"
            ssh_rollback_remove_backup() {
                ssh_rollback_result_is_valid
                command cat -- "$SSH_ROLLBACK_RESULT_FILE" >"$prefix.result-durable"
                original_ssh_rollback_remove_backup "$@"
            }

            lock_acquire_smart
            ssh_rollback_prepare_state
            ssh_rollback_create_backup /srv/ssh.config
            printf "Port 2222\n" >/srv/ssh.config
            start_ssh_rollback_timer /srv/ssh.config "$SSH_ROLLBACK_BACKUP" 22 1 \
                "$SSH_ROLLBACK_STATE_DIR/confirmed"
            printf "%s\n" "$SSH_ROLLBACK_PID" >"$prefix.timer.pid"
            printf "%s\n" "$SSH_ROLLBACK_STATE_DIR" >"$prefix.state"
            printf "%s\n" "$LOCK_DIR" >"$prefix.ready"
            while :; do sleep 0.1; done
        '\'' &
        local parent=$!
        for _ in $(seq 1 250); do
            [[ -s "$prefix.claimed" && -s "$prefix.ready" ]] && break
            sleep 0.02
        done
        [[ -s "$prefix.claimed" && -s "$prefix.ready" ]]
        local lock_dir timer_pid state_dir state_token parent_rc=0
        lock_dir=$(cat "$prefix.ready")
        timer_pid=$(cat "$prefix.timer.pid")
        state_dir=$(cat "$prefix.state")
        state_token=$(cat "$state_dir/token")
        [[ "$(cat "$state_dir/phase.rolling-back")" == "$state_token" ]]
        [[ "$(cat /srv/ssh.config)" == "Port 2222" ]]
        [[ -f "$state_dir/sshd_config.backup" && -d "$lock_dir" ]]

        kill -s "$signal" -- "-$parent"
        sleep 0.2
        kill -0 "$parent"
        kill -0 "$timer_pid"
        [[ "$(cat /srv/ssh.config)" == "Port 2222" ]]
        [[ -d "$state_dir" && ! -e "$state_dir/rolled-back" ]]

        printf "release\n" >"$prefix.release"
        for _ in $(seq 1 250); do
            ! kill -0 "$parent" 2>/dev/null && break
            sleep 0.02
        done
        ! kill -0 "$parent" 2>/dev/null
        wait "$parent" || parent_rc=$?
        [[ "$parent_rc" -eq "$expected_status" ]]
        ! kill -0 "$timer_pid" 2>/dev/null
        [[ "$(cat /srv/ssh.config)" == "Port 22" ]]
        [[ "$(cat "$prefix.result-durable")" == "$state_token:rolled-back" ]]
        [[ ! -e "$state_dir" ]]
        [[ ! -d "$lock_dir" ]]
        bash -c "set -euo pipefail; source /mnt/lib/00_security_state.sh; lock_acquire_smart; lock_release_smart"
    }

    run_claimed_group_signal_case TERM 143
    run_claimed_group_signal_case HUP 129
'

if [[ -n "${PROXY_HUB_TEST_SCENARIO:-}" ]]; then
    exit 0
fi

signal_case="$lock_tmp/bootstrap-signal"
mkdir -p -- "$signal_case/tmp/tmp.foreign" "$signal_case/assets"
printf 'keep\n' >"$signal_case/tmp/tmp.foreign/keep"
cp -- "$REPO_ROOT/dist/proxy-hub.bundle.sh" "$signal_case/assets/proxy-hub.bundle.sh"
signal_rc=0
bwrap \
    --ro-bind / / \
    --dev-bind /dev /dev \
    --proc /proc \
    --tmpfs /tmp \
    --tmpfs /root \
    --unshare-net \
    --die-with-parent \
    --ro-bind "$REPO_ROOT" /mnt \
    --bind "$signal_case" /srv \
    --setenv PATH "/mnt/tests/fixtures/fake-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    --setenv TMPDIR /srv/tmp \
    --setenv FAKE_CURL_MODE block \
    --setenv FAKE_CURL_ASSET_DIR /srv/assets \
    --setenv FAKE_CURL_READY_FILE /srv/curl.ready \
    -- bash -c '
        set -euo pipefail
        setsid bash -c "bash <(cat /mnt/proxy-hub.sh) help" >/srv/loader.out 2>/srv/loader.err &
        child=$!
        for _ in $(seq 1 100); do
            [[ -e /srv/curl.ready ]] && break
            sleep 0.02
        done
        [[ -e /srv/curl.ready ]]
        compgen -G "/srv/tmp/proxy-hub.bootstrap.*" >/dev/null
        kill -TERM -- "-$child"
        for _ in $(seq 1 100); do
            if ! compgen -G "/srv/tmp/proxy-hub.bootstrap.*" >/dev/null; then
                break
            fi
            sleep 0.02
        done
        ! compgen -G "/srv/tmp/proxy-hub.bootstrap.*" >/dev/null
        [[ -f /srv/tmp/tmp.foreign/keep ]]
        kill -KILL -- "-$child" 2>/dev/null || true
        wait "$child" 2>/dev/null || true
    ' >"$signal_case/controller.out" 2>"$signal_case/controller.err" || signal_rc=$?
if ((signal_rc != 0)); then
    sed -n '1,200p' "$signal_case/controller.err" >&2
    fail "bootstrap signal cleanup failed with status $signal_rc"
fi
pass "bootstrap signal cleanup removes only its process-owned temp directory"

publication_case="$lock_tmp/bootstrap-publication-signal"
mkdir -p -- "$publication_case/tmp" "$publication_case/assets"
cp -- "$REPO_ROOT/dist/proxy-hub.bundle.sh" "$publication_case/assets/proxy-hub.bundle.sh"
publication_rc=0
bwrap \
    --ro-bind / / \
    --dev-bind /dev /dev \
    --proc /proc \
    --tmpfs /tmp \
    --tmpfs /root \
    --unshare-net \
    --die-with-parent \
    --ro-bind "$REPO_ROOT" /mnt \
    --bind "$publication_case" /srv \
    --setenv PATH "/mnt/tests/fixtures/fake-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    --setenv TMPDIR /srv/tmp \
    --setenv FAKE_MKTEMP_SIGNAL 1 \
    --setenv FAKE_CURL_ASSET_DIR /srv/assets \
    -- bash -c '
        set -euo pipefail
        child_rc=0
        setsid bash -c "bash <(cat /mnt/proxy-hub.sh) help" >/srv/loader.out 2>/srv/loader.err || child_rc=$?
        [[ "$child_rc" -eq 143 ]]
        ! compgen -G "/srv/tmp/proxy-hub.bootstrap.*" >/dev/null
    ' >"$publication_case/controller.out" 2>"$publication_case/controller.err" || publication_rc=$?
if ((publication_rc != 0)); then
    sed -n '1,200p' "$publication_case/controller.err" >&2
    fail "bootstrap temp publication signal test failed with status $publication_rc"
fi
pass "bootstrap temp publication defers TERM until path identity is cleanup-visible"

replacement_case="$lock_tmp/bootstrap-replacement"
mkdir -p -- "$replacement_case/tmp" "$replacement_case/assets"
cp -- "$REPO_ROOT/dist/proxy-hub.bundle.sh" "$replacement_case/assets/proxy-hub.bundle.sh"
replacement_rc=0
bwrap \
    --ro-bind / / \
    --dev-bind /dev /dev \
    --proc /proc \
    --tmpfs /tmp \
    --tmpfs /root \
    --unshare-net \
    --die-with-parent \
    --ro-bind "$REPO_ROOT" /mnt \
    --bind "$replacement_case" /srv \
    --setenv PATH "/mnt/tests/fixtures/fake-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    --setenv TMPDIR /srv/tmp \
    --setenv FAKE_CURL_MODE block \
    --setenv FAKE_CURL_ASSET_DIR /srv/assets \
    --setenv FAKE_CURL_READY_FILE /srv/curl.ready \
    -- bash -c '
        set -euo pipefail
        setsid bash -c "bash <(cat /mnt/proxy-hub.sh) help" >/srv/loader.out 2>/srv/loader.err &
        child=$!
        for _ in $(seq 1 100); do
            [[ -e /srv/curl.ready ]] && break
            sleep 0.02
        done
        [[ -e /srv/curl.ready ]]
        bootstrap_path=$(compgen -G "/srv/tmp/proxy-hub.bootstrap.*" | head -n 1)
        [[ -n "$bootstrap_path" ]]
        mv -- "$bootstrap_path" "${bootstrap_path}.original"
        mkdir -m 700 -- "$bootstrap_path"
        printf "replacement\n" >"$bootstrap_path/keep"
        kill -TERM -- "-$child"
        wait "$child" 2>/dev/null || true
        [[ -f "$bootstrap_path/keep" ]]
        [[ -d "${bootstrap_path}.original" ]]
    ' >"$replacement_case/controller.out" 2>"$replacement_case/controller.err" || replacement_rc=$?
if ((replacement_rc != 0)); then
    sed -n '1,200p' "$replacement_case/controller.err" >&2
    fail "bootstrap replacement protection failed with status $replacement_rc"
fi
pass "bootstrap cleanup refuses a same-path directory replacement"

assert_file "$lock_tmp/tmp/tmp.foreign/keep"
