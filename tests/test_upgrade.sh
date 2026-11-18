#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# Contract tests for the upgrade path that brings nodes and cores created by an
# older script up to date: the offline scan, the apply engine with its snapshot
# and rollback, and the wizard that drives both.

require_bwrap
require_command jq
require_command openssl

test_base="$TEST_DIR/.tmp"
mkdir -p -- "$test_base"
test_tmp=$(mktemp -d "$test_base/proxy-hub-test.upgrade.XXXXXXXX")
register_cleanup_dir "$test_tmp"
mkdir -p -- "$test_tmp/tmp"

sandbox=(
    bwrap
    --ro-bind / /
    --dev-bind /dev /dev
    --proc /proc
    --tmpfs /tmp
    --tmpfs /root
    --tmpfs /run
    --tmpfs /usr/local/etc
    --unshare-net
    --die-with-parent
    --ro-bind "$REPO_ROOT" /mnt
    --bind "$test_tmp" /srv
    --setenv TMPDIR /srv/tmp
)

run_scenario() {
    local label="$1"
    if [[ -n "${UPGRADE_CASE:-}" && "$UPGRADE_CASE" != "$label" ]]; then
        cat >/dev/null
        return 0
    fi
    local scenario="$test_tmp/$label.sh"
    local stdout_file="$test_tmp/$label.out" stderr_file="$test_tmp/$label.err"
    local rc=0

    {
        cat <<'PRELUDE'
#!/usr/bin/env bash
set -euo pipefail

fail_case() {
    printf 'scenario failure: %s\n' "$*" >&2
    exit 1
}

assert_eq() {
    local expected="$1" actual="$2" context="$3"
    [[ "$expected" == "$actual" ]] || {
        printf 'expected: <%s>\nactual:   <%s>\n' "$expected" "$actual" >&2
        fail_case "$context"
    }
}

assert_contains() {
    local haystack="$1" needle="$2" context="$3"
    [[ "$haystack" == *"$needle"* ]] || fail_case "$context: $needle"
}

assert_not_contains() {
    local haystack="$1" needle="$2" context="$3"
    [[ "$haystack" != *"$needle"* ]] || fail_case "$context: $needle"
}

assert_fails() {
    local context="$1"
    shift
    if "$@"; then
        fail_case "$context"
    fi
}

strip_colors() { sed 's/\x1b\[[0-9;]*m//g'; }

# Fake cores that only report a version and a set of sub-commands.
set_xray() {
    local version="$1"
    shift
    {
        printf '%s\n' '#!/bin/sh' 'case "$1" in'
        printf '  version) echo "Xray %s (Xray, Penetrates Everything.) abc (go1.27 linux/amd64)" ;;\n' "$version"
        printf '%s\n' '  help) cat <<HELP' '	run       Run Xray'
        local cmd
        for cmd in "$@"; do printf '\t%s    capability\n' "$cmd"; done
        printf '%s\n' 'HELP' '  ;;'
        printf '%s\n' '  x25519) n=$(cat /srv/keycount 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" >/srv/keycount' \
            '    printf "PrivateKey: priv%s\nPassword (PublicKey): pub%s\n" "$n" "$n" ;;'
        printf '%s\n' '  vlessenc) cat <<OUT' 'Authentication: X25519, not Post-Quantum' \
            '"decryption": "mlkem768x25519plus.native.600s.EN5iuqWArcTGaz2Sgm5H7-n7TXD1am4vYKCQ9PraP3U"' \
            '"encryption": "mlkem768x25519plus.native.0rtt.ls4tO2BFOQS9z6pMkz4ty6LRj4GpYfUfQ0o8UKxxQRo"' 'OUT' '  ;;'
        printf '%s\n' '  *) exit 0 ;;' 'esac'
    } >"$XRAY_BIN"
    chmod 755 "$XRAY_BIN"
    XRAY_CAPS=""
}

set_singbox() {
    printf '#!/bin/sh\n[ "$1" = version ] && echo "sing-box version %s"\nexit 0\n' "$1" >"$SINGBOX_BIN"
    chmod 755 "$SINGBOX_BIN"
}

# Redirect every path the modules touch into the scenario's scratch area.
point_paths_at_scratch() {
    NETSTACK_FILE=/srv/netstack
    NODES_DIR=/srv/nodes
    XRAY_CONF=/srv/xray.json
    XRAY_BIN=/srv/bin/xray
    SINGBOX_DIR=/srv/sing-box
    SINGBOX_CONF=/srv/sing-box/config.json
    SINGBOX_CERT_DIR=/srv/sing-box/certs
    SINGBOX_BIN=/srv/bin/sing-box
    SYSTEMD_DROPIN_ROOT=/srv/state/systemd
    SERVICE_HARDENING_STATE_DIR=/srv/state/proxy-hub
    SYSCTL_TUNING_FILE=/srv/state/99-bbr.conf
    UPGRADE_STATE_FILE=/srv/state/upgrade.ack
    UPGRADE_BACKUP_ROOT=/srv/state/backups
    HY2_HOP_HELPER=/srv/state/libexec/proxy-hub-hy2-hop
    HY2_HOP_DROPIN=/srv/state/systemd/sing-box.service.d/20-proxy-hub-hy2-hop.conf
    GEODATA_HELPER=/srv/state/libexec/proxy-hub-geodata-update
    ENABLE_CONFIG_ENCRYPTION=false
    CURRENT_LANG=en
    INIT_SYSTEM=systemd
}

load_modules() {
    source /mnt/lib/00_security_state.sh
    source /mnt/lib/10_runtime_platform_ui.sh
    source /mnt/lib/15_xray_release.sh
    source /mnt/lib/20_installers_restart.sh
    source /mnt/lib/30_provision_network.sh
    source /mnt/lib/40_config_share.sh
    source /mnt/lib/50_node_commands.sh
    source /mnt/lib/60_system_tools.sh
    source /mnt/lib/70_ports_logs.sh
    source /mnt/lib/80_timesync.sh

    rm -rf -- /srv/nodes /srv/xray.json /srv/sing-box /srv/bin /srv/state /srv/netstack
    mkdir -p -- /srv/bin /srv/state
    point_paths_at_scratch
    mkdir -p -- "$NODES_DIR" "$SINGBOX_CERT_DIR"
    chmod 700 -- "$NODES_DIR"

    # A quiet, healthy, fully current host; scenarios turn individual knobs.
    check_warp_running() { return 1; }
    systemctl() { case "$1" in --version) echo "systemd 252 (252-1)" ;; esac; }
    systemd-detect-virt() { return 1; }
    ACTIVE_SERVICES=""
    service_is_active() { [[ " $ACTIVE_SERVICES " == *" $1 "* ]]; }
    crontab() { [[ "${1:-}" == "-l" ]] && cat /srv/crontab 2>/dev/null; return 0; }
    LISTENING=""
    ss() {
        printf 'State Recv-Q Send-Q Local Address:Port Peer Address:Port\n'
        local port
        for port in $LISTENING; do printf 'LISTEN 0 128 0.0.0.0:%s 0.0.0.0:*\n' "$port"; done
    }
    set_xray 26.11.9 mldsa65 mlkem768 vlessenc
    set_singbox 1.14.4
}

# A node file as an older script wrote it: no fields from the refresh work.
write_legacy_node() {
    local node_name="$1" protocol="$2"
    cat >"$NODES_DIR/${node_name}.env" <<ENV
NODE_NAME=$node_name
SERVER_IP=203.0.113.10
SERVER_IPV4=203.0.113.10
SERVER_IPV6=
PORT=31443
UUID=11111111-1111-4111-8111-111111111111
SNI=www.tesla.com
PUBLIC_KEY=LegacyPublicKey_1
PRIVATE_KEY=LegacyPrivateKey_1
SHORT_ID=0a1b2c3d
PROTOCOL_TYPE=$protocol
XHTTP_PORT=
XHTTP_PATH=
SS_METHOD=
SS_PASSWORD=
ANYTLS_PASSWORD=
ANYTLS_PADDING_B64=
HY2_PASSWORD=
ENV
    chmod 600 "$NODES_DIR/${node_name}.env"
}

set_node_field() {
    local key="$2" value="$3" file="$NODES_DIR/$1.env"
    if grep -q "^${key}=" "$file"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$file"
    else
        printf '%s=%s\n' "$key" "$value" >>"$file"
    fi
}

node_field() { safe_read_config_value "$NODES_DIR/$1.env" "$2"; }

remove_all_nodes() { find "${NODES_DIR:?}" -maxdepth 1 -name '*.env' -type f -delete; }

ids() { printf '%s\n' ${UPG_IDS[@]+"${UPG_IDS[@]}"}; }

class_of() {
    local index
    for index in "${!UPG_IDS[@]}"; do
        [[ "${UPG_IDS[$index]}" == "$1" ]] && { printf '%s' "${UPG_CLASS[$index]}"; return 0; }
    done
    return 1
}
PRELUDE
        cat
    } >"$scenario"

    "${sandbox[@]}" -- bash "/srv/$label.sh" >"$stdout_file" 2>"$stderr_file" || rc=$?
    if ((rc != 0)); then
        sed -n '1,240p' "$stdout_file" >&2
        sed -n '1,240p' "$stderr_file" >&2
        fail "$label failed with status $rc"
    fi
    pass "$label"
}

# The scan is offline and read-only, and classifies every finding by what it
# costs the operator: nothing for clients, a re-import, or just a note.
run_scenario upgrade-scan <<'SCENARIO'
load_modules

# A current host with no nodes has nothing to upgrade.
upgrade_scan
assert_eq "" "$(ids)" "a clean host must report nothing"
assert_fails "nothing found means nothing pending" upgrade_pending

# Outdated cores.
set_xray 25.9.11
set_singbox 1.13.15
upgrade_scan
assert_eq "core.xray
core.singbox" "$(ids)" "cores below their baselines are reported"
assert_eq "safe" "$(class_of core.xray)" "a core update needs nothing from clients"
set_xray 26.11.9 mldsa65 mlkem768 vlessenc
set_singbox 1.14.4

# A config rendered by the old script, on a core that understands target.
cat >"$XRAY_CONF" <<'JSON'
{"inbounds":[{"tag":"a_vision","streamSettings":{"realitySettings":{"dest":"www.tesla.com:443","fingerprint":"chrome"}}},
             {"tag":"s_ss","protocol":"shadowsocks"}]}
JSON
upgrade_scan
assert_eq "cfg.reality-fields" "$(ids)" "legacy REALITY fields are reported"
assert_eq "safe" "$(class_of cfg.reality-fields)" "re-rendering the config changes nothing for clients"
# An old core that will be updated in the same run still gets the item.
set_xray 25.9.11
upgrade_scan
assert_contains "$(ids)" "cfg.reality-fields" "the field rewrite is offered together with the core update"
# An old core that is not going to be updated cannot use the new field name.
real_gaps=$(declare -f core_baseline_gaps)
core_baseline_gaps() { :; }
upgrade_scan
assert_not_contains "$(ids)" "cfg.reality-fields" "no rewrite without a capable core"
eval "$real_gaps"
set_xray 26.11.9 mldsa65 mlkem768 vlessenc
# A config already in the current form is left alone.
printf '%s\n' '{"inbounds":[{"streamSettings":{"realitySettings":{"target":"www.tesla.com:443"}}}]}' >"$XRAY_CONF"
upgrade_scan
assert_eq "" "$(ids)" "a current config is not reported"
rm -f /srv/xray.json

# Service hardening: only for running services that are neither hardened nor skipped.
ACTIVE_SERVICES="xray sing-box"
upgrade_scan
assert_eq "svc.hardening" "$(ids)" "unhardened running services are reported"
assert_contains "${UPG_TITLE[0]}" "xray / sing-box" "the item names the affected services"
mkdir -p "$(dirname "$(service_hardening_dropin xray)")"
: >"$(service_hardening_dropin xray)"
mkdir -p "$SERVICE_HARDENING_STATE_DIR"
: >"$(service_hardening_skip_marker sing-box)"
upgrade_scan
assert_eq "" "$(ids)" "hardened or previously reverted services are not reported again"
ACTIVE_SERVICES=""

# Legacy cron and sysctl template.
printf '%s\n' "0 4 * * 0 curl -fsSL https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat -o /x/geoip.dat" >/srv/crontab
printf '%s\n' 'net.ipv4.tcp_low_latency = 1' >"$SYSCTL_TUNING_FILE"
upgrade_scan
assert_eq "geodata.cron
sysctl.template" "$(ids)" "unverified cron and the old sysctl template are reported"
rm -f /srv/crontab /srv/state/99-bbr.conf

# Nodes written by an older script.
write_legacy_node hk vision
write_legacy_node apple vision
set_node_field apple SNI www.icloud.com
write_legacy_node pair both
set_node_field pair XHTTP_PORT 32443
set_node_field pair XHTTP_PATH /p
write_legacy_node ar anytls_reality
set_node_field ar ANYTLS_PASSWORD SafeAnyTlsPassword
write_legacy_node hy hysteria2
set_node_field hy HY2_PASSWORD SafeHy2Password
write_legacy_node ss shadowsocks
set_node_field ss SS_METHOD 2022-blake3-aes-256-gcm
set_node_field ss SS_PASSWORD c2VjcmV0
write_legacy_node plain anytls
set_node_field plain ANYTLS_PASSWORD SafeAnyTlsPassword
upgrade_scan
found=$(ids)
assert_contains "$found" "node.apple.sni" "an Apple-family target is reported"
assert_not_contains "$found" "node.hk.sni" "an ordinary target is not reported"
assert_contains "$found" "node.pair.split" "a both node with shared credentials is reported"
assert_contains "$found" "node.hk.vlessenc" "VLESS nodes are offered VLESS Encryption"
assert_not_contains "$found" "node.ar.vlessenc" "AnyTLS has no VLESS Encryption"
assert_contains "$found" "node.hy.hy2obfs" "a plain Hysteria2 node is offered obfuscation"
assert_contains "$found" "node.ss.ss" "Shadowsocks nodes get a positioning note"
assert_contains "$found" "links.pin" "self-signed Hysteria2 links get the pin note"
assert_not_contains "$found" "node.plain" "plain AnyTLS has nothing to upgrade"
for id in node.apple.sni node.pair.split node.hk.vlessenc node.hy.hy2obfs; do
    assert_eq "relink" "$(class_of "$id")" "$id changes the share link"
done
assert_eq "info" "$(class_of node.ss.ss)" "the Shadowsocks note has no action"
assert_eq "info" "$(class_of links.pin)" "the pin note has no action"

# Exactly one node is offered port 443, and only while it is free and unclaimed.
assert_eq "1" "$(grep -c '\.port443$' <<<"$found")" "443 can be offered to one node only"
assert_contains "$found" "node.apple.port443" "the first REALITY node in order is offered 443"
LISTENING="443"
upgrade_scan
assert_not_contains "$(ids)" "port443" "a listening 443 is not offered"
LISTENING=""
set_node_field hk PORT 443
upgrade_scan
assert_not_contains "$(ids)" "port443" "a 443 already claimed by a node is not offered"
set_node_field hk PORT 31443

# Defaults: only client-neutral items are preselected.
ACTIVE_SERVICES="xray"
upgrade_scan
for index in "${!UPG_IDS[@]}"; do
    expected=0
    [[ "${UPG_CLASS[$index]}" == safe ]] && expected=1
    assert_eq "$expected" "${UPG_SEL[$index]}" "default selection of ${UPG_IDS[$index]}"
done
ACTIVE_SERVICES=""

# Already-upgraded nodes drop out of the scan.
set_node_field pair XHTTP_PUBLIC_KEY SplitPub
set_node_field hk VLESS_DECRYPTION mlkem768x25519plus.native.600s.Key
set_node_field hy HY2_OBFS_PASSWORD Obfs.Pass_12
set_node_field apple SNI www.tesla.com
upgrade_scan
found=$(ids)
for gone in node.pair.split node.hk.vlessenc node.hy.hy2obfs node.apple.sni; do
    assert_not_contains "$found" "$gone" "$gone must disappear once the node is upgraded"
done
# An ACME node has no pinned link and is not offered obfuscation by the scan.
set_node_field hy HY2_OBFS_PASSWORD ""
set_node_field hy HY2_DOMAIN hy.example.com
upgrade_scan
assert_not_contains "$(ids)" "node.hy.hy2obfs" "an ACME node is not offered obfuscation by the scan"
assert_not_contains "$(ids)" "links.pin" "an ACME node has no pinned link"

# A core without the capability does not offer VLESS Encryption.
set_xray 26.11.9 mldsa65
upgrade_scan
assert_not_contains "$(ids)" "vlessenc" "VLESS Encryption needs a capable core"
set_xray 26.11.9 mldsa65 mlkem768 vlessenc

# Legacy files without PROTOCOL_TYPE are classified by their ports.
write_legacy_node old both
sed -i '/^PROTOCOL_TYPE=/d' "$NODES_DIR/old.env"
set_node_field old XHTTP_PORT 33443
assert_eq "both" "$(upgrade_node_protocol "$NODES_DIR/old.env")" "two ports mean a both node"
upgrade_scan
assert_contains "$(ids)" "node.old.split" "a typeless legacy both node is still recognised"

# The scan changes nothing on disk.
before=$(cd /srv && find nodes state -type f -exec sha256sum {} + | sort)
upgrade_scan
cmd_upgrade_check >/dev/null
after=$(cd /srv && find nodes state -type f -exec sha256sum {} + | sort)
assert_eq "$before" "$after" "scanning and checking must not modify anything"

# Acknowledgement: the same findings do not prompt twice, new ones do.
upgrade_pending || fail_case "unseen findings must be pending"
upgrade_ack_save
assert_eq "600" "$(stat -c '%a' "$UPGRADE_STATE_FILE")" "the state file is private"
assert_fails "acknowledged findings are not pending" upgrade_pending
write_legacy_node newcomer hysteria2
set_node_field newcomer HY2_PASSWORD SafeHy2Password
upgrade_pending || fail_case "a new finding must be pending again"
printf 'garbage; $(touch /srv/injected)\n' >"$UPGRADE_STATE_FILE"
upgrade_pending || fail_case "a corrupt state file must not silence findings"
[[ ! -e /srv/injected ]] || fail_case "the state file must never be evaluated"
ln -sf /srv/elsewhere /srv/state/upgrade.ack
upgrade_pending || fail_case "a symlinked state file must not be trusted"
unlink /srv/state/upgrade.ack

# The read-only report groups findings and explains each one.
report=$(cmd_upgrade check | strip_colors)
assert_contains "$report" "Optional · clients must re-import the link" "the relink group is labelled"
assert_contains "$report" "Notes · no action needed" "the info group is labelled"
assert_contains "$report" "Clients must re-import this node's link" "relink items state their cost"
assert_contains "$report" "upgrade" "the report says how to open the wizard"
service_hardening_remove xray
ACTIVE_SERVICES="xray"
assert_contains "$(cmd_upgrade check | strip_colors)" "Recommended · nothing changes for clients" \
    "the safe group is labelled"
ACTIVE_SERVICES=""
remove_all_nodes
assert_contains "$(cmd_upgrade check | strip_colors)" "Nothing to upgrade" "a clean host says so"
SCENARIO

# Applying upgrades: one config rebuild for all node changes, a snapshot taken
# first, and a full restore when the new configuration does not come up.
run_scenario upgrade-apply <<'SCENARIO'
load_modules
sleep() { :; }
log_info() { :; }
log_warn() { printf 'warn: %s\n' "$*" >>/srv/apply.log; }
log_error() { printf 'error: %s\n' "$*" >>/srv/apply.log; }
: >/srv/apply.log
RESTART_OK=yes
service_restart() {
    printf 'restart:%s\n' "$1" >>/srv/service.calls
    [[ "$RESTART_OK" == yes ]] || return 1
    [[ " $ACTIVE_SERVICES " == *" $1 "* ]] || ACTIVE_SERVICES+=" $1"
}
service_enable() { :; }
service_stop() { ACTIVE_SERVICES="${ACTIVE_SERVICES// $1/}"; }
service_disable() { :; }
open_firewall_port() { printf '%s/%s\n' "$1" "$2" >>/srv/firewall.calls; }
: >/srv/service.calls; : >/srv/firewall.calls
snapshot_files() { (cd "$NODES_DIR" && sha256sum -- *.env); }

write_legacy_node hk vision
write_legacy_node pair both
set_node_field pair XHTTP_PORT 32443
set_node_field pair XHTTP_PATH /p
write_legacy_node hy hysteria2
set_node_field hy HY2_PASSWORD SafeHy2Password
set_node_field hy SNI www.bing.com
gen_selfsigned_cert hy www.bing.com
printf '%s\n' '{"inbounds":[{"streamSettings":{"realitySettings":{"dest":"www.tesla.com:443","fingerprint":"chrome"}}}]}' >"$XRAY_CONF"
ACTIVE_SERVICES="xray sing-box"
before=$(snapshot_files)

# Several node changes plus the config rewrite: one rebuild, everything recorded.
upgrade_scan
upgrade_apply node.pair.split node.hk.vlessenc node.hy.hy2obfs cfg.reality-fields || {
    cat /srv/apply.log >&2; fail_case "a healthy apply must succeed"; }
assert_eq "cfg.reality-fields node.hk.vlessenc node.hy.hy2obfs node.pair.split" \
    "$(printf '%s\n' "${UPG_DONE[@]}" | sort | tr '\n' ' ' | sed 's/ $//')" "every selected item is reported done"
assert_eq "0" "${#UPG_FAILED[@]}" "nothing failed"
assert_eq "hk hy pair" "$(printf '%s\n' "${UPG_RELINK_NODES[@]}" | sort | tr '\n' ' ' | sed 's/ $//')" \
    "nodes whose links changed are collected once each"
assert_eq "1" "$(grep -c '^restart:xray$' /srv/service.calls)" "all node changes share one Xray restart"

[[ -n "$(node_field pair XHTTP_PUBLIC_KEY)" && -n "$(node_field pair XHTTP_UUID)" ]] || fail_case "pair was not split"
assert_eq "LegacyPublicKey_1" "$(node_field pair PUBLIC_KEY)" "splitting must keep the Vision key"
assert_contains "$(node_field hk VLESS_DECRYPTION)" "mlkem768x25519plus." "hk gained VLESS Encryption"
[[ "$(node_field hy HY2_OBFS_PASSWORD)" =~ ^[0-9a-f]{32}$ ]] || fail_case "hy gained no obfs password"
assert_eq "true" "$(jq '[.inbounds[].streamSettings.realitySettings | has("target") and (has("dest") | not) and (has("fingerprint") | not)] | all' "$XRAY_CONF")" \
    "the config is re-rendered with current field names"
assert_eq "salamander" "$(jq -r '.inbounds[0].obfs.type' "$SINGBOX_CONF")" "sing-box picked up the obfuscation"

# The snapshot holds the nodes exactly as they were.
snap=$(ls -1d "$UPGRADE_BACKUP_ROOT"/*/ | head -n 1)
assert_eq "$before" "$(cd "$snap/nodes" && sha256sum -- *.env)" "the snapshot preserves the pre-upgrade nodes"
assert_eq "700" "$(stat -c '%a' "$snap")" "snapshots hold credentials and must be private"
[[ -f "$snap/xray-config.json" ]] || fail_case "the snapshot must include the Xray config"

# A typeless legacy node keeps its inferred type when it is rewritten.
write_legacy_node old both
sed -i '/^PROTOCOL_TYPE=/d' "$NODES_DIR/old.env"
set_node_field old PORT 34443
set_node_field old XHTTP_PORT 35443
set_node_field old XHTTP_PATH /o
upgrade_scan
upgrade_apply node.old.split || fail_case "splitting a typeless node failed"
assert_eq "both" "$(node_field old PROTOCOL_TYPE)" "an inferred both node must not be saved as vision"
assert_eq "2" "$(jq '[.inbounds[] | select(.tag | startswith("old_"))] | length' "$XRAY_CONF")" \
    "both inbounds of the typeless node survive"

# Moving to 443 updates the node and opens the port.
: >/srv/firewall.calls
upgrade_scan
assert_contains "$(ids)" "node.hk.port443" "hk is offered 443"
upgrade_apply node.hk.port443 || fail_case "moving to 443 failed"
assert_eq "443" "$(node_field hk PORT)" "the node moved to 443"
assert_eq "443/tcp" "$(cat /srv/firewall.calls)" "the new port is opened for its transport"
assert_eq "443" "$(jq -r '.inbounds[] | select(.tag == "hk_vision") | .port' "$XRAY_CONF")" "the inbound listens on 443"
# 443 is taken now, so a stale request for another node is refused, not forced.
rc=0
upgrade_apply node.pair.port443 || rc=$?
assert_eq "1" "$rc" "a second node cannot take 443"
assert_eq "node.pair.port443" "${UPG_FAILED[*]}" "the refused item is reported failed"
assert_eq "31443" "$(node_field pair PORT)" "the refused node keeps its port"

# Replacing an Apple target picks a new domain automatically.
set_node_field pair SNI www.icloud.com
upgrade_pick_sni() { printf '%s' www.example.org; }
upgrade_apply node.pair.sni || fail_case "replacing the target failed"
assert_eq "www.example.org" "$(node_field pair SNI)" "the node uses the picked target"
set_node_field pair SNI www.icloud.com
upgrade_pick_sni() { printf '%s' xp.apple.com; }
rc=0
upgrade_apply node.pair.sni || rc=$?
assert_eq "1/www.icloud.com" "$rc/$(node_field pair SNI)" "a discouraged pick is rejected and nothing is saved"
upgrade_pick_sni() { return 1; }
rc=0
upgrade_apply node.pair.sni || rc=$?
assert_eq "1" "$rc" "no reachable candidate fails the item"
set_node_field pair SNI www.tesla.com

# The real picker: fastest candidate after ranking.
eval "$(declare -f upgrade_pick_sni | sed 's/^upgrade_pick_sni/unused_picker/')"
source /mnt/lib/80_timesync.sh
point_paths_at_scratch
test_domains_parallel() { local -n out=$1; out=([slow.example]=80 [fast.example]=12); }
SNI_ASN_CHECK=0
assert_eq "fast.example" "$(upgrade_pick_sni)" "the picker returns the best-ranked candidate"
test_domains_parallel() { local -n out=$1; out=(); }
assert_fails "no reachable candidate yields no pick" upgrade_pick_sni

# Failure: the new configuration does not come up, so the nodes are restored.
write_legacy_node fresh both
set_node_field fresh PORT 36443
set_node_field fresh XHTTP_PORT 37443
set_node_field fresh XHTTP_PATH /f
before=$(snapshot_files)
: >/srv/service.calls; : >/srv/apply.log
RESTART_OK=no
rc=0
upgrade_apply node.fresh.split node.fresh.vlessenc || rc=$?
RESTART_OK=yes
assert_eq "1" "$rc" "a failed rebuild must fail the apply"
assert_eq "$before" "$(snapshot_files)" "every node file is restored byte for byte"
assert_eq "node.fresh.split node.fresh.vlessenc" "${UPG_FAILED[*]}" "both items are reported failed"
assert_eq "0" "${#UPG_DONE[@]}" "nothing is reported done after a restore"
assert_eq "0" "${#UPG_RELINK_NODES[@]}" "no link changed after a restore"
assert_contains "$(cat /srv/apply.log)" "restoring the nodes as they were" "the restore is announced"
(( $(grep -c '^restart:xray$' /srv/service.calls) >= 2 )) || fail_case "the restored configuration must be applied again"

# Cores: updates run first and a failed one does not block the rest.
cmd_xray_update() { printf 'xray:%s\n' "${XRAY_CHANNEL:-}" >>/srv/core.calls; return "${XRAY_UPDATE_RC:-0}"; }
singbox_install_release() { printf 'singbox:%s\n' "$1" >>/srv/core.calls; }
: >/srv/core.calls
XRAY_UPDATE_RC=1
rc=0
upgrade_apply core.xray core.singbox node.fresh.split || rc=$?
unset XRAY_UPDATE_RC
assert_eq "1" "$rc" "a failed core update fails the run"
assert_eq "xray:stable
singbox:update" "$(cat /srv/core.calls)" "both cores are updated through their verified paths"
assert_eq "core.xray" "${UPG_FAILED[*]}" "only the failed core is reported failed"
assert_contains " ${UPG_DONE[*]} " " core.singbox " "the other core still succeeds"
assert_contains " ${UPG_DONE[*]} " " node.fresh.split " "node changes still run after a core failure"

# System items.
service_hardening_ensure() { printf 'harden:%s:%s\n' "$1" "${2:-}" >>/srv/system.calls; return "${HARDEN_RC:-0}"; }
install_geodata_helper() { printf 'geodata-helper\n' >>/srv/system.calls; }
setup_geodata_cron() { printf 'geodata-cron\n' >>/srv/system.calls; : >/srv/crontab; }
sysctl_tuning_apply() { printf 'sysctl\n' >>/srv/system.calls; }
: >/srv/system.calls
upgrade_apply svc.hardening geodata.cron sysctl.template || fail_case "system items failed"
assert_eq "harden:xray:force
harden:sing-box:force
geodata-helper
geodata-cron
sysctl" "$(cat /srv/system.calls)" "system items run their own verified helpers"
assert_eq "3" "${#UPG_DONE[@]}" "all three system items are done"
HARDEN_RC=2
rc=0
upgrade_apply svc.hardening || rc=$?
unset HARDEN_RC
assert_eq "1/svc.hardening" "$rc/${UPG_FAILED[*]}" "reverted hardening is reported as not applied"

# Nothing selected is a successful no-op.
upgrade_apply || fail_case "applying nothing must succeed"
assert_eq "0/0" "${#UPG_DONE[@]}/${#UPG_FAILED[@]}" "nothing is reported for an empty run"
SCENARIO

# The non-interactive entry point: named selections, validated IDs, a printed
# result with fresh links, and an acknowledgement so the same set is not
# offered again.
run_scenario upgrade-apply-cli <<'SCENARIO'
load_modules
is_root() { return 0; }
write_legacy_node hk vision
write_legacy_node hy hysteria2
set_node_field hy HY2_PASSWORD SafeHy2Password
write_legacy_node ss shadowsocks
printf '%s\n' 'net.ipv4.tcp_low_latency = 1' >"$SYSCTL_TUNING_FILE"
ACTIVE_SERVICES="xray"
upgrade_apply() { printf '%s\n' "$*" >/srv/apply.args; UPG_DONE=("$@"); UPG_FAILED=(); UPG_RELINK_NODES=(); return "${APPLY_RC:-0}"; }
show_info() { printf 'INFO:%s\n' "$CURRENT_NODE_NAME"; }

cmd_upgrade apply >/srv/cli.out 2>&1 || fail_case "apply with the default selection failed"
assert_eq "svc.hardening sysctl.template" "$(cat /srv/apply.args)" "the default selection is the recommended set"
cmd_upgrade apply recommended >/dev/null 2>&1
assert_eq "svc.hardening sysctl.template" "$(cat /srv/apply.args)" "recommended selects only client-neutral items"
cmd_upgrade apply all >/dev/null 2>&1
all_args=$(cat /srv/apply.args)
assert_contains "$all_args" "node.hk.vlessenc" "all includes items that change links"
assert_contains "$all_args" "node.hy.hy2obfs" "all includes every actionable node item"
assert_not_contains "$all_args" "node.ss.ss" "notes are never applied"
assert_not_contains "$all_args" "links.pin" "notes are never applied"

cmd_upgrade apply node.hy.hy2obfs,sysctl.template >/dev/null 2>&1
assert_eq "node.hy.hy2obfs sysctl.template" "$(cat /srv/apply.args)" "an explicit list is honoured in order"
: >/srv/apply.args
for bad in node.nope.split node.ss.ss links.pin 'sysctl.template;id' ""; do
    rc=0
    cmd_upgrade apply "sysctl.template,$bad" >/srv/cli.out 2>&1 || rc=$?
    [[ -n "$bad" ]] || continue
    assert_eq "1" "$rc" "unknown or non-actionable item '$bad' must be rejected"
    assert_eq "" "$(cat /srv/apply.args)" "a rejected selection must apply nothing"
done

# A failing apply propagates, still prints the result and still acknowledges.
APPLY_RC=1
rc=0
cmd_upgrade apply recommended >/srv/cli.out 2>&1 || rc=$?
unset APPLY_RC
assert_eq "1" "$rc" "a failed apply must return non-zero"
assert_contains "$(strip_colors </srv/cli.out)" "Upgrade result" "the result is printed even on failure"
[[ -s "$UPGRADE_STATE_FILE" ]] || fail_case "the run must be acknowledged"

# The printed result lists outcomes and re-shows nodes whose links changed.
upgrade_scan
UPG_DONE=(sysctl.template node.hy.hy2obfs)
UPG_FAILED=(svc.hardening)
UPG_RELINK_NODES=(hy)
result=$(upgrade_print_result | strip_colors)
assert_contains "$result" "✓ Refresh the network tuning parameters" "done items are listed by title"
assert_contains "$result" "✗ Enable sandbox hardening" "failed items are listed by title"
assert_contains "$result" "the previous state was kept" "a failed item says nothing was broken"
assert_contains "$result" "import again" "the re-import instruction is shown"
assert_contains "$result" "INFO:hy" "the changed node is shown again with its new link"

# Unprivileged callers are refused before anything is scanned or applied.
is_root() { return 1; }
: >/srv/apply.args
assert_fails "apply needs root" cmd_upgrade apply all
assert_eq "" "$(cat /srv/apply.args)" "an unprivileged apply must do nothing"
is_root() { return 0; }

# Nothing to do.
remove_all_nodes
ACTIVE_SERVICES=""
: >"$SYSCTL_TUNING_FILE"
: >/srv/apply.args
cmd_upgrade apply all >/dev/null 2>&1 || fail_case "an empty selection must succeed"
assert_eq "" "$(cat /srv/apply.args)" "nothing is applied on a current host"
SCENARIO

printf '%s\n' "All upgrade contract tests passed."
