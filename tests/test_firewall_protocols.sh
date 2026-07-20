#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

RED=""
NC=""
# shellcheck source=../lib/70_ports_logs.sh
source "$REPO_ROOT/lib/70_ports_logs.sh"

test_tmp=$(new_test_dir firewall-protocols)

assert_line_count() {
    local expected="$1" needle="$2" file="$3" actual
    actual=$(grep -Fxc -- "$needle" "$file" 2>/dev/null || true)
    assert_eq "$expected" "$actual" "line count for: $needle"
}

make_netfilter_bin() {
    local bin_dir="$1"
    mkdir -p -- "$bin_dir"
    cat > "$bin_dir/iptables" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
backend=${0##*/}
state="$FAKE_FW_DIR/${backend}.rules"
log="$FAKE_FW_DIR/commands.log"
action="${1:-}"
shift || true
rule="$*"
printf '%s %s %s\n' "$backend" "$action" "$rule" >> "$log"
case "$action" in
    -C)
        grep -Fqx -- "$rule" "$state" 2>/dev/null
        ;;
    -I)
        if [[ "${FAKE_FAIL_BACKEND:-}" == "$backend" ]]; then
            exit 1
        fi
        grep -Fqx -- "$rule" "$state" 2>/dev/null || printf '%s\n' "$rule" >> "$state"
        ;;
    *) exit 2 ;;
esac
FAKE
    cp -- "$bin_dir/iptables" "$bin_dir/ip6tables"
    cat > "$bin_dir/netfilter-persistent" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf 'netfilter-persistent %s\n' "$*" >> "$FAKE_FW_DIR/commands.log"
[[ "${FAKE_FAIL_PERSIST:-0}" != 1 ]]
FAKE
    chmod 755 "$bin_dir/iptables" "$bin_dir/ip6tables" "$bin_dir/netfilter-persistent"
}

make_firewalld_bin() {
    local bin_dir="$1"
    mkdir -p -- "$bin_dir"
    cat > "$bin_dir/firewall-cmd" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
state="$FAKE_FW_DIR/firewalld.rules"
log="$FAKE_FW_DIR/commands.log"
printf 'firewall-cmd %s\n' "$*" >> "$log"
case "${1:-}" in
    --state)
        [[ "${FAKE_FIREWALLD_ACTIVE:-0}" == 1 ]]
        ;;
    --permanent)
        case "${2:-}" in
            --query-port=*)
                rule=${2#--query-port=}
                grep -Fqx -- "$rule" "$state" 2>/dev/null
                ;;
            --add-port=*)
                [[ "${FAKE_FAIL_FIREWALLD:-0}" != 1 ]] || exit 1
                rule=${2#--add-port=}
                grep -Fqx -- "$rule" "$state" 2>/dev/null || printf '%s\n' "$rule" >> "$state"
                ;;
            *) exit 2 ;;
        esac
        ;;
    --reload)
        [[ "${FAKE_FAIL_FIREWALLD_RELOAD:-0}" != 1 ]]
        ;;
    *) exit 2 ;;
esac
FAKE
    chmod 755 "$bin_dir/firewall-cmd"
}

make_ufw_bin() {
    local bin_dir="$1"
    mkdir -p -- "$bin_dir"
    cat > "$bin_dir/ufw" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
state="$FAKE_FW_DIR/ufw.rules"
log="$FAKE_FW_DIR/commands.log"
printf 'ufw %s\n' "$*" >> "$log"
case "${1:-}" in
    status)
        [[ "${FAKE_FAIL_UFW_STATUS:-0}" != 1 ]] || exit 1
        if [[ "${FAKE_UFW_ACTIVE:-0}" == 1 ]]; then
            printf 'Status: active\n'
        else
            printf 'Status: inactive\n'
        fi
        ;;
    allow)
        [[ "${FAKE_FAIL_UFW:-0}" != 1 ]] || exit 1
        rule="${2:-}"
        grep -Fqx -- "$rule" "$state" 2>/dev/null || printf '%s\n' "$rule" >> "$state"
        ;;
    *) exit 2 ;;
esac
FAKE
    chmod 755 "$bin_dir/ufw"
}

empty_bin="$test_tmp/empty-bin"
mkdir -p -- "$empty_bin"
if PATH="$empty_bin:/usr/bin:/bin" open_firewall_port invalid tcp >/dev/null 2>&1; then
    fail "non-numeric port unexpectedly succeeded"
fi
if PATH="$empty_bin:/usr/bin:/bin" open_firewall_port 65536 tcp >/dev/null 2>&1; then
    fail "out-of-range port unexpectedly succeeded"
fi
if PATH="$empty_bin:/usr/bin:/bin" open_firewall_port 443 sctp >/dev/null 2>&1; then
    fail "invalid transport unexpectedly succeeded"
fi
PATH="$empty_bin:/usr/bin:/bin" open_firewall_port 443 tcp
pass "invalid inputs fail and an absent firewall is a no-op success"

netfilter_bin="$test_tmp/netfilter-bin"
netfilter_state="$test_tmp/netfilter-state"
mkdir -p -- "$netfilter_state"
make_netfilter_bin "$netfilter_bin"
for spec in "41001 tcp" "41002 udp"; do
    read -r port transport <<< "$spec"
    PATH="$netfilter_bin:/usr/bin:/bin" FAKE_FW_DIR="$netfilter_state" \
        open_firewall_port "$port" "$transport"
    PATH="$netfilter_bin:/usr/bin:/bin" FAKE_FW_DIR="$netfilter_state" \
        open_firewall_port "$port" "$transport"
done
PATH="$netfilter_bin:/usr/bin:/bin" FAKE_FW_DIR="$netfilter_state" \
    open_firewall_port 41003
PATH="$netfilter_bin:/usr/bin:/bin" FAKE_FW_DIR="$netfilter_state" \
    open_firewall_port 41003
assert_line_count 1 "INPUT -p tcp --dport 41001 -j ACCEPT" "$netfilter_state/iptables.rules"
assert_line_count 0 "INPUT -p udp --dport 41001 -j ACCEPT" "$netfilter_state/iptables.rules"
assert_line_count 1 "INPUT -p udp --dport 41002 -j ACCEPT" "$netfilter_state/iptables.rules"
assert_line_count 0 "INPUT -p tcp --dport 41002 -j ACCEPT" "$netfilter_state/iptables.rules"
assert_line_count 1 "INPUT -p tcp --dport 41003 -j ACCEPT" "$netfilter_state/iptables.rules"
assert_line_count 1 "INPUT -p udp --dport 41003 -j ACCEPT" "$netfilter_state/iptables.rules"
assert_line_count 1 "iptables -I INPUT -p tcp --dport 41001 -j ACCEPT" "$netfilter_state/commands.log"
assert_line_count 1 "iptables -I INPUT -p udp --dport 41002 -j ACCEPT" "$netfilter_state/commands.log"
assert_line_count 3 "netfilter-persistent save" "$netfilter_state/commands.log"
if [[ -f /proc/net/if_inet6 ]]; then
    assert_line_count 1 "INPUT -p tcp --dport 41001 -j ACCEPT" "$netfilter_state/ip6tables.rules"
    assert_line_count 1 "INPUT -p udp --dport 41002 -j ACCEPT" "$netfilter_state/ip6tables.rules"
fi
pass "iptables and ip6tables honor tcp/udp/default-both and avoid duplicate inserts"

netfilter_fail_state="$test_tmp/netfilter-fail-state"
mkdir -p -- "$netfilter_fail_state"
if PATH="$netfilter_bin:/usr/bin:/bin" FAKE_FW_DIR="$netfilter_fail_state" \
    FAKE_FAIL_BACKEND=iptables open_firewall_port 42001 tcp; then
    fail "iptables insertion failure unexpectedly succeeded"
fi
persist_fail_state="$test_tmp/persist-fail-state"
mkdir -p -- "$persist_fail_state"
if PATH="$netfilter_bin:/usr/bin:/bin" FAKE_FW_DIR="$persist_fail_state" \
    FAKE_FAIL_PERSIST=1 open_firewall_port 42002 tcp; then
    fail "netfilter persistence failure unexpectedly succeeded"
fi
pass "active netfilter backend failures propagate"

firewalld_bin="$test_tmp/firewalld-bin"
firewalld_state="$test_tmp/firewalld-state"
mkdir -p -- "$firewalld_state"
make_firewalld_bin "$firewalld_bin"
PATH="$firewalld_bin:/usr/bin:/bin" FAKE_FW_DIR="$firewalld_state" \
    FAKE_FIREWALLD_ACTIVE=1 open_firewall_port 43001 udp
PATH="$firewalld_bin:/usr/bin:/bin" FAKE_FW_DIR="$firewalld_state" \
    FAKE_FIREWALLD_ACTIVE=1 open_firewall_port 43001 udp
assert_line_count 1 "43001/udp" "$firewalld_state/firewalld.rules"
assert_line_count 1 "firewall-cmd --permanent --add-port=43001/udp" "$firewalld_state/commands.log"
assert_line_count 1 "firewall-cmd --reload" "$firewalld_state/commands.log"
inactive_firewalld_state="$test_tmp/firewalld-inactive-state"
mkdir -p -- "$inactive_firewalld_state"
PATH="$firewalld_bin:/usr/bin:/bin" FAKE_FW_DIR="$inactive_firewalld_state" \
    FAKE_FIREWALLD_ACTIVE=0 open_firewall_port 43002 tcp
assert_not_exists "$inactive_firewalld_state/firewalld.rules"
failed_firewalld_state="$test_tmp/firewalld-fail-state"
mkdir -p -- "$failed_firewalld_state"
if PATH="$firewalld_bin:/usr/bin:/bin" FAKE_FW_DIR="$failed_firewalld_state" \
    FAKE_FIREWALLD_ACTIVE=1 FAKE_FAIL_FIREWALLD=1 open_firewall_port 43003 tcp; then
    fail "firewalld add failure unexpectedly succeeded"
fi
pass "firewalld queries before add, reloads only on change, and propagates active failures"

ufw_bin="$test_tmp/ufw-bin"
ufw_state="$test_tmp/ufw-state"
mkdir -p -- "$ufw_state"
make_ufw_bin "$ufw_bin"
PATH="$ufw_bin:/usr/bin:/bin" FAKE_FW_DIR="$ufw_state" FAKE_UFW_ACTIVE=1 \
    open_firewall_port 44001 both
PATH="$ufw_bin:/usr/bin:/bin" FAKE_FW_DIR="$ufw_state" FAKE_UFW_ACTIVE=1 \
    open_firewall_port 44001 both
assert_line_count 1 "44001/tcp" "$ufw_state/ufw.rules"
assert_line_count 1 "44001/udp" "$ufw_state/ufw.rules"
inactive_ufw_state="$test_tmp/ufw-inactive-state"
mkdir -p -- "$inactive_ufw_state"
PATH="$ufw_bin:/usr/bin:/bin" FAKE_FW_DIR="$inactive_ufw_state" FAKE_UFW_ACTIVE=0 \
    open_firewall_port 44002 tcp
assert_not_exists "$inactive_ufw_state/ufw.rules"
failed_ufw_state="$test_tmp/ufw-fail-state"
mkdir -p -- "$failed_ufw_state"
if PATH="$ufw_bin:/usr/bin:/bin" FAKE_FW_DIR="$failed_ufw_state" \
    FAKE_UFW_ACTIVE=1 FAKE_FAIL_UFW=1 open_firewall_port 44003 udp; then
    fail "ufw allow failure unexpectedly succeeded"
fi
if PATH="$ufw_bin:/usr/bin:/bin" FAKE_FW_DIR="$failed_ufw_state" \
    FAKE_FAIL_UFW_STATUS=1 open_firewall_port 44004 tcp; then
    fail "ufw status failure unexpectedly succeeded"
fi
pass "ufw applies exact transports, remains idempotent, and propagates active failures"
