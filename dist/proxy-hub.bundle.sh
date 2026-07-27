#!/usr/bin/env bash
set -euo pipefail
export LANG=en_US.UTF-8

# =========================
# VLESS TCP REALITY Vision 自动化脚本
# 增强版：XHTTP支持 + 双栈链接 + WARP分流 + 系统优化工具
# =========================

# Bash 版本检查 (需要 4.3+ 支持 nameref 和 wait -n)
if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3))); then
    echo "Error: This script requires bash 4.3 or newer (current: ${BASH_VERSION})"
    echo "Please upgrade bash or use a newer system"
    exit 1
fi

# ============== 单实例锁机制 ==============
LOCK_PARENT=""
LOCK_DIR=""
PID_FILE=""
LOCK_OWNER_FILE=""
LOCK_FILE=""
LOCK_FD=200
LOCK_HELD_METHOD=""
LOCK_TOKEN=""
LOCK_DIR_ID=""
LOCK_SIGNAL_PENDING=""

lock_prepare_parent() {
    local base_dir="/tmp" base_mode base_owner mode owner

    [[ -d "$base_dir" && ! -L "$base_dir" && -w "$base_dir" ]] || return 1
    base_owner=$(stat -c '%u' "$base_dir" 2>/dev/null) || return 1
    base_mode=$(stat -c '%a' "$base_dir" 2>/dev/null) || return 1
    [[ "$base_mode" =~ ^[0-7]+$ ]] || return 1
    if [[ "$base_owner" == "$EUID" ]] && (( (8#$base_mode & 022) == 0 )); then
        :
    elif [[ "$base_owner" == "0" ]] && (( (8#$base_mode & 01000) != 0 )); then
        :
    else
        return 1
    fi

    LOCK_PARENT="${base_dir%/}/proxy-hub-${EUID}"
    if [[ ! -e "$LOCK_PARENT" ]]; then
        (umask 077; mkdir -m 700 "$LOCK_PARENT") 2>/dev/null || return 1
    fi

    [[ -d "$LOCK_PARENT" && ! -L "$LOCK_PARENT" ]] || return 1
    owner=$(stat -c '%u' "$LOCK_PARENT" 2>/dev/null) || return 1
    mode=$(stat -c '%a' "$LOCK_PARENT" 2>/dev/null) || return 1
    [[ "$owner" == "$EUID" && "$mode" =~ ^[0-7]+$ ]] || return 1
    (( (8#$mode & 077) == 0 )) || return 1

    LOCK_DIR="$LOCK_PARENT/write.lock.d"
    PID_FILE="$LOCK_DIR/pid"
    LOCK_OWNER_FILE="$LOCK_DIR/owner"
    LOCK_FILE=""
}

lock_dir_identity() {
    stat -c '%d:%i' "$1" 2>/dev/null
}

lock_acquire() {
    local candidate_token dir_id="" pending_signal rc=1 saved_int saved_term

    [[ -z "$LOCK_HELD_METHOD" ]] || return 1
    lock_prepare_parent || return 1
    candidate_token="${EUID}-$$-${RANDOM}-${RANDOM}"

    LOCK_SIGNAL_PENDING=""
    saved_int=$(trap -p INT || true)
    saved_term=$(trap -p TERM || true)
    trap 'LOCK_SIGNAL_PENDING=INT' INT
    trap 'LOCK_SIGNAL_PENDING=TERM' TERM

    if dir_id=$(
        local owner_tmp="$LOCK_DIR/.owner-${candidate_token}"
        local pid_tmp="$LOCK_DIR/.pid-${candidate_token}"
        local candidate_id=""

        trap '' INT TERM
        umask 077

        cleanup_candidate() {
            if [[ -n "$candidate_id" && -d "$LOCK_DIR" && ! -L "$LOCK_DIR" ]] \
                && [[ "$(lock_dir_identity "$LOCK_DIR")" == "$candidate_id" ]]; then
                [[ -f "$owner_tmp" && ! -L "$owner_tmp" ]] && rm -f -- "$owner_tmp"
                [[ -f "$pid_tmp" && ! -L "$pid_tmp" ]] && rm -f -- "$pid_tmp"
                [[ -f "$LOCK_OWNER_FILE" && ! -L "$LOCK_OWNER_FILE" ]] && rm -f -- "$LOCK_OWNER_FILE"
                [[ -f "$PID_FILE" && ! -L "$PID_FILE" ]] && rm -f -- "$PID_FILE"
                rmdir "$LOCK_DIR" 2>/dev/null || true
            fi
        }

        mkdir "$LOCK_DIR" 2>/dev/null || exit 1
        candidate_id=$(lock_dir_identity "$LOCK_DIR") || {
            cleanup_candidate
            exit 1
        }
        printf '%s\n%s\n' "$candidate_token" "$$" > "$owner_tmp" || {
            cleanup_candidate
            exit 1
        }
        [[ -f "$owner_tmp" && ! -L "$owner_tmp" ]] || {
            cleanup_candidate
            exit 1
        }
        mv -- "$owner_tmp" "$LOCK_OWNER_FILE" || {
            cleanup_candidate
            exit 1
        }
        printf '%s\n' "$$" > "$pid_tmp" || {
            cleanup_candidate
            exit 1
        }
        [[ -f "$pid_tmp" && ! -L "$pid_tmp" ]] || {
            cleanup_candidate
            exit 1
        }
        mv -- "$pid_tmp" "$PID_FILE" || {
            cleanup_candidate
            exit 1
        }
        printf '%s\n' "$candidate_id"
    ); then
        LOCK_TOKEN="$candidate_token"
        LOCK_DIR_ID="$dir_id"
        LOCK_HELD_METHOD="mkdir"
        rc=0
    fi

    if [[ -n "$saved_int" ]]; then eval "$saved_int"; else trap - INT; fi
    if [[ -n "$saved_term" ]]; then eval "$saved_term"; else trap - TERM; fi
    pending_signal="$LOCK_SIGNAL_PENDING"
    LOCK_SIGNAL_PENDING=""
    if [[ -n "$pending_signal" ]]; then
        kill -s "$pending_signal" "$$" 2>/dev/null || true
    fi
    return "$rc"
}

lock_release() {
    local owner_token=""

    [[ "$LOCK_HELD_METHOD" == "mkdir" && -n "$LOCK_DIR_ID" && -n "$LOCK_TOKEN" ]] || return 0
    [[ -d "$LOCK_DIR" && ! -L "$LOCK_DIR" ]] || return 0
    [[ "$(lock_dir_identity "$LOCK_DIR")" == "$LOCK_DIR_ID" ]] || return 0
    [[ -f "$LOCK_OWNER_FILE" && ! -L "$LOCK_OWNER_FILE" ]] || return 0
    IFS= read -r owner_token < "$LOCK_OWNER_FILE" || return 0
    [[ "$owner_token" == "$LOCK_TOKEN" ]] || return 0

    [[ ! -e "$PID_FILE" || ( -f "$PID_FILE" && ! -L "$PID_FILE" ) ]] || return 0
    rm -f -- "$PID_FILE" "$LOCK_OWNER_FILE" 2>/dev/null || return 0
    rmdir "$LOCK_DIR" 2>/dev/null || true
    LOCK_HELD_METHOD=""
    LOCK_TOKEN=""
    LOCK_DIR_ID=""
}

# ---------------- Stale-lock diagnostics (read-only) ----------------
# These helpers never modify, remove, or steal the lock. Per docs/audits.md the
# lock is deliberately not auto-reclaimed from PID metadata (PID reuse / forged
# metadata risk); they only let a caller tell a human whether the recorded owner
# is still alive, so manual recovery becomes a single obvious command.

# Print the PID recorded in the current lock, or return non-zero when the lock
# metadata is missing, unreadable, a symlink, or malformed.
lock_recorded_pid() {
    local pid=""
    [[ -n "${PID_FILE:-}" && -f "$PID_FILE" && ! -L "$PID_FILE" ]] || return 1
    IFS= read -r pid < "$PID_FILE" 2>/dev/null || return 1
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    printf '%s\n' "$pid"
}

# Classify a recorded owner PID without touching the lock:
#   0 -> still alive (a real instance may be running)
#   1 -> provably gone (the lock is stale)
#   2 -> liveness cannot be determined; treat conservatively as maybe-alive
lock_pid_liveness() {
    local pid="${1:-}"
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 2
    [[ "$pid" == "$$" ]] && return 0
    if [[ -d /proc/self ]]; then
        [[ -e "/proc/$pid" ]] && return 0
        return 1
    fi
    kill -0 "$pid" 2>/dev/null && return 0
    return 2
}

# ============== Security Helper Functions ==============

# Compatibility names intentionally use the same mkdir exclusion domain. A
# separate flock file would allow mixed-mode processes to write concurrently.
lock_acquire_flock() {
    lock_acquire
}

lock_release_flock() {
    lock_release
}

# All current entry points acquire the same private mkdir lock.
lock_acquire_smart() {
    lock_acquire
}

lock_release_smart() {
    lock_release
}

# Secure curl wrapper with TLS enforcement and redirect limits
# Usage: secure_curl [curl_options] URL
secure_curl() {
    curl --proto '=https' --tlsv1.2 --max-redirs 3 -fsSL "$@"
}

# Safe download with optional SHA256 verification
# Usage: safe_download_and_verify URL DEST_FILE [EXPECTED_SHA256]
# Returns: 0 on success, 1 on download failure, 2 on checksum mismatch
safe_download_and_verify() {
    local url="$1"
    local dest="$2"
    local expected_sha="${3:-}"

    # Download file
    if ! secure_curl "$url" -o "$dest" 2>/dev/null; then
        return 1
    fi

    # Verify checksum if provided
    if [[ -n "$expected_sha" ]]; then
        local actual_sha
        actual_sha=$(sha256sum "$dest" 2>/dev/null | cut -d' ' -f1)
        if [[ "$actual_sha" != "$expected_sha" ]]; then
            log_warn "Checksum mismatch for $url"
            log_warn "Expected: $expected_sha"
            log_warn "Got: $actual_sha"
            return 2
        fi
    fi

    return 0
}

# Fetch GitHub release tag using jq instead of grep/cut
# Usage: fetch_github_release_tag REPO
fetch_github_release_tag() {
    local repo="$1"
    local api_url="https://api.github.com/repos/${repo}/releases/latest"
    local response

    response=$(secure_curl "$api_url" 2>/dev/null) || return 1

    # Use jq for safe JSON parsing
    if command -v jq &>/dev/null; then
        echo "$response" | jq -r '.tag_name // empty' 2>/dev/null
    else
        # Fallback: careful grep (less safe but functional)
        echo "$response" | grep -oP '"tag_name"\s*:\s*"\K[^"]+' | head -1
    fi
}

# Safe config value extraction (prevents command injection)
# Usage: safe_read_config_value FILE KEY
# Returns the value or empty string if not found/invalid
safe_read_config_value() {
    local file="$1"
    local key="$2"
    local value=""

    [[ ! -f "$file" ]] && return 1

    # Read line matching KEY= pattern
    # Note: Cannot use IFS='=' because values may contain '=' (e.g., base64 padding)
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Strip trailing CR (handles CRLF files / xray output with \r)
        line="${line%$'\r'}"

        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$line" ]] && continue

        # Extract key (everything before first '=')
        local k="${line%%=*}"
        # Extract value (everything after first '=')
        local v="${line#*=}"

        # Match exact key
        if [[ "$k" == "$key" ]]; then
            # Trim leading/trailing whitespace defensively
            v="${v#"${v%%[![:space:]]*}"}"
            v="${v%"${v##*[![:space:]]}"}"

            # Security: reject values containing dangerous characters
            # Allow: alphanumeric, dash, underscore, dot, slash, colon, equals, plus, at, brackets
            # Reject: backticks, $, ;, |, &, newlines, etc.
            # Note: In POSIX regex, ] must be first if included, - must be last or first
            if [[ "$v" =~ ^[]a-zA-Z0-9_./:=+@[-]*$ ]]; then
                value="$v"
            else
                # Log warning but don't fail (backward compat)
                log_warn "Potentially unsafe value for $key in $file, using empty"
                value=""
            fi
            break
        fi
    done < "$file"

    echo "$value"
}

# 节点作用域全局变量的唯一权威清单。
#
# 程序以 `set -u` 运行，因此任何一个未被赋值的变量在展开时都会立刻终止整个脚本。
# 各协议分支只会赋值它自己用得到的字段（例如 AnyTLS 不需要 UUID，Shadowsocks
# 不需要 REALITY 密钥），所以必须有一个统一的地方把全部字段都置为已定义状态，
# 否则某个协议路径漏掉一个字段就会在 save_env 等下游函数里炸掉。
#
# 同样重要的是：这些变量是进程级全局量。同一次菜单会话里连续安装两个节点时，
# 若不重置，第二个节点会继承第一个节点残留的密钥/端口，把不属于它的凭据写进
# 自己的 .env。因此 install_node 也必须在进入协议分支之前调用本函数。
# 注意：CURRENT_NODE_NAME 不在此列表内。它表示“当前选中的节点”，由 select_node /
# install_node 在读取配置之前设置，属于选择状态而非节点内容；清空它会让随后的
# save_env 回退到 ${CURRENT_NODE_NAME:-$PORT} 并写错文件。
reset_node_state() {
    NODE_NAME="" PORT="" UUID="" SNI=""
    PUBLIC_KEY="" PRIVATE_KEY="" SHORT_ID=""
    XHTTP_PORT="" XHTTP_PATH=""
    SERVER_IP="" SERVER_IPV4="" SERVER_IPV6=""
    SS_METHOD="" SS_PASSWORD=""
    ANYTLS_PASSWORD="" ANYTLS_PADDING_B64=""
    HY2_PASSWORD=""
    PROTOCOL_TYPE="vision"
}

# 在模块加载时就建立一次基线，使得任何代码路径（包括从未选择过协议的只读命令）
# 展开上述变量时都不会触发 unbound variable。
reset_node_state

# Safe load all config values from node file
# Usage: safe_load_node_config FILE
# Sets variables: NODE_NAME, PORT, UUID, SNI, PUBLIC_KEY, PRIVATE_KEY, SHORT_ID,
#                 PROTOCOL_TYPE, XHTTP_PORT, XHTTP_PATH, SERVER_IP, SERVER_IPV4, SERVER_IPV6,
#                 SS_METHOD, SS_PASSWORD, ANYTLS_PASSWORD, HY2_PASSWORD
safe_load_node_config() {
    local file="$1"

    [[ ! -f "$file" ]] && return 1

    # Reset all variables first
    reset_node_state
    # 本函数按文件内容重新填充；缺失的键保持空值，因此协议类型也从空开始判断。
    PROTOCOL_TYPE=""

    # Load each value safely
    NODE_NAME=$(safe_read_config_value "$file" "NODE_NAME")
    PORT=$(safe_read_config_value "$file" "PORT")
    UUID=$(safe_read_config_value "$file" "UUID")
    SNI=$(safe_read_config_value "$file" "SNI")
    PUBLIC_KEY=$(safe_read_config_value "$file" "PUBLIC_KEY")
    PRIVATE_KEY=$(safe_read_config_value "$file" "PRIVATE_KEY")
    SHORT_ID=$(safe_read_config_value "$file" "SHORT_ID")
    PROTOCOL_TYPE=$(safe_read_config_value "$file" "PROTOCOL_TYPE")
    XHTTP_PORT=$(safe_read_config_value "$file" "XHTTP_PORT")
    XHTTP_PATH=$(safe_read_config_value "$file" "XHTTP_PATH")
    SERVER_IP=$(safe_read_config_value "$file" "SERVER_IP")
    SERVER_IPV4=$(safe_read_config_value "$file" "SERVER_IPV4")
    SERVER_IPV6=$(safe_read_config_value "$file" "SERVER_IPV6")
    SS_METHOD=$(safe_read_config_value "$file" "SS_METHOD")
    SS_PASSWORD=$(safe_read_config_value "$file" "SS_PASSWORD")
    ANYTLS_PASSWORD=$(safe_read_config_value "$file" "ANYTLS_PASSWORD")
    HY2_PASSWORD=$(safe_read_config_value "$file" "HY2_PASSWORD")

    return 0
}

# Validate and extract port number (strips non-numeric, validates range)
# Usage: get_validated_port RAW_PORT [SILENT]
# Returns: validated port number or empty string
get_validated_port() {
    local raw_port="$1"
    local silent="${2:-false}"

    # Strip any non-numeric characters (security hardening)
    local port="${raw_port//[^0-9]/}"

    # Validate range
    if [[ -z "$port" ]] || [[ "$port" -lt 1 ]] || [[ "$port" -gt 65535 ]]; then
        [[ "$silent" != "true" ]] && log_error "Invalid port: $raw_port"
        return 1
    fi

    echo "$port"
}

# Build Vision inbound JSON using jq (prevents injection)
# Usage: build_vision_inbound NAME PORT UUID SNI PRIVATE_KEY SHORT_ID
build_vision_inbound() {
    local name="$1"
    local port="$2"
    local uuid="$3"
    local sni="$4"
    local private_key="$5"
    local short_id="$6"

    # Validate port
    port=$(get_validated_port "$port" true) || return 1

    jq -n \
        --arg tag "${name}_vision" \
        --argjson port "$port" \
        --arg uuid "$uuid" \
        --arg sni "$sni" \
        --arg private_key "$private_key" \
        --arg short_id "$short_id" \
        '{
            "tag": $tag,
            "listen": "0.0.0.0",
            "port": $port,
            "protocol": "vless",
            "settings": {
                "clients": [{"id": $uuid, "flow": "xtls-rprx-vision"}],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "dest": "\($sni):443",
                    "serverNames": [$sni],
                    "privateKey": $private_key,
                    "shortIds": [$short_id],
                    "fingerprint": "chrome"
                }
            },
            "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": true}
        }'
}

# Build XHTTP inbound JSON using jq (prevents injection)
# Usage: build_xhttp_inbound NAME PORT UUID SNI PRIVATE_KEY SHORT_ID PATH
build_xhttp_inbound() {
    local name="$1"
    local port="$2"
    local uuid="$3"
    local sni="$4"
    local private_key="$5"
    local short_id="$6"
    local xhttp_path="$7"

    # Validate port
    port=$(get_validated_port "$port" true) || return 1

    jq -n \
        --arg tag "${name}_xhttp" \
        --argjson port "$port" \
        --arg uuid "$uuid" \
        --arg sni "$sni" \
        --arg private_key "$private_key" \
        --arg short_id "$short_id" \
        --arg path "$xhttp_path" \
        '{
            "tag": $tag,
            "listen": "0.0.0.0",
            "port": $port,
            "protocol": "vless",
            "settings": {
                "clients": [{"id": $uuid, "flow": ""}],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "xhttp",
                "security": "reality",
                "xhttpSettings": {"path": $path},
                "realitySettings": {
                    "show": false,
                    "dest": "\($sni):443",
                    "serverNames": [$sni],
                    "privateKey": $private_key,
                    "shortIds": [$short_id],
                    "fingerprint": "chrome"
                }
            },
            "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": true}
        }'
}

# Build Shadowsocks inbound JSON using jq (prevents injection)
# Usage: build_shadowsocks_inbound NAME PORT METHOD PASSWORD
build_shadowsocks_inbound() {
    local name="$1"
    local port="$2"
    local method="$3"
    local password="$4"

    # Validate port
    port=$(get_validated_port "$port" true) || return 1

    jq -n \
        --arg tag "${name}_ss" \
        --argjson port "$port" \
        --arg method "$method" \
        --arg password "$password" \
        '{
            "tag": $tag,
            "listen": "0.0.0.0",
            "port": $port,
            "protocol": "shadowsocks",
            "settings": {
                "method": $method,
                "password": $password,
                "network": "tcp,udp"
            },
            "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": true}
        }'
}

# Build AnyTLS inbound JSON (sing-box) using jq (prevents injection)
# Usage: build_anytls_inbound NAME PORT PASSWORD PADDING MODE SNI PRIVKEY SHORTID CERT KEY
#   MODE = reality | tls
#   For MODE=reality: SNI/PRIVKEY/SHORTID required, CERT/KEY ignored
#   For MODE=tls:     SNI/CERT/KEY required (self-signed), PRIVKEY/SHORTID ignored
build_anytls_inbound() {
    local name="$1"
    local port="$2"
    local password="$3"
    local padding="$4"
    local mode="$5"
    local sni="$6"
    local privkey="$7"
    local shortid="$8"
    local cert="$9"
    local key="${10}"

    # Validate port
    port=$(get_validated_port "$port" true) || return 1

    # 构建 TLS 块（reality 伪装 或 自签名证书）
    local tls_json
    if [[ "$mode" == "reality" ]]; then
        tls_json=$(jq -n \
            --arg sni "$sni" \
            --arg priv "$privkey" \
            --arg sid "$shortid" \
            '{
                "enabled": true,
                "server_name": $sni,
                "reality": {
                    "enabled": true,
                    "handshake": {"server": $sni, "server_port": 443},
                    "private_key": $priv,
                    "short_id": [$sid]
                }
            }') || return 1
    else
        tls_json=$(jq -n \
            --arg sni "$sni" \
            --arg cert "$cert" \
            --arg key "$key" \
            '{
                "enabled": true,
                "server_name": $sni,
                "certificate_path": $cert,
                "key_path": $key
            }') || return 1
    fi

    # padding scheme 为字符串数组（每行一条规则）；服务端会在握手时
    # 通过 cmdUpdatePaddingScheme 自动下发给客户端，无需客户端额外配置。
    jq -n \
        --arg tag "${name}_anytls" \
        --argjson port "$port" \
        --arg name "$name" \
        --arg password "$password" \
        --arg padding "$padding" \
        --argjson tls "$tls_json" \
        '{
            "type": "anytls",
            "tag": $tag,
            "listen": "::",
            "listen_port": $port,
            "users": [{"name": $name, "password": $password}],
            "padding_scheme": ($padding | split("\n") | map(select(length > 0))),
            "tls": $tls
        }'
}

# Validate a TLS server name before it is written to JSON or a share URI.
# IPv4 literals are accepted; empty labels, URI delimiters, and overlong labels
# are rejected. Hysteria2 uses this value as TLS SNI, so IPv6 literals are not
# accepted here.
validate_tls_server_name() {
    local value="${1:-}"
    local label
    local -a labels=()

    [[ -n "$value" && ${#value} -le 253 ]] || return 1
    [[ "$value" =~ ^[a-zA-Z0-9.-]+$ ]] || return 1
    [[ "$value" != .* && "$value" != *. && "$value" != *..* ]] || return 1

    IFS='.' read -r -a labels <<<"$value"
    for label in "${labels[@]}"; do
        [[ -n "$label" && ${#label} -le 63 ]] || return 1
        [[ "$label" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] || return 1
    done
}

# Build a Hysteria2 inbound for sing-box using jq (prevents JSON injection).
# Usage: build_hysteria2_inbound NAME PORT PASSWORD SNI CERT KEY
build_hysteria2_inbound() {
    local name="$1"
    local port="$2"
    local password="$3"
    local sni="$4"
    local cert="$5"
    local key="$6"

    port=$(get_validated_port "$port" true) || return 1
    [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || return 1
    [[ "$password" =~ ^[a-zA-Z0-9._~-]{8,128}$ ]] || return 1
    validate_tls_server_name "$sni" || return 1
    [[ -n "$cert" && -n "$key" ]] || return 1

    jq -n \
        --arg tag "${name}_hysteria2" \
        --argjson port "$port" \
        --arg name "$name" \
        --arg password "$password" \
        --arg sni "$sni" \
        --arg cert "$cert" \
        --arg key "$key" \
        '{
            "type": "hysteria2",
            "tag": $tag,
            "listen": "::",
            "listen_port": $port,
            "users": [{"name": $name, "password": $password}],
            "tls": {
                "enabled": true,
                "server_name": $sni,
                "certificate_path": $cert,
                "key_path": $key
            },
            "masquerade": {
                "type": "proxy",
                "url": "https://www.bing.com",
                "rewrite_host": true
            }
        }'
}

# Optional encryption for sensitive config values
# Usage: encrypt_value PLAINTEXT
# Returns: base64-encoded encrypted value with "U2FsdGVk" prefix (OpenSSL magic)
ENCRYPTION_KEY_FILE="/root/.reality_vision_key"

setup_encryption_key() {
    if [[ ! -f "$ENCRYPTION_KEY_FILE" ]]; then
        # Generate random key on first use
        head -c 32 /dev/urandom | base64 > "$ENCRYPTION_KEY_FILE"
        chmod 600 "$ENCRYPTION_KEY_FILE"
    fi
}

encrypt_value() {
    local plaintext="$1"
    [[ -z "$plaintext" ]] && return 0

    setup_encryption_key
    local key
    key=$(cat "$ENCRYPTION_KEY_FILE")

    echo -n "$plaintext" | openssl enc -aes-256-cbc -pbkdf2 -a -pass "pass:$key" 2>/dev/null
}

decrypt_value() {
    local ciphertext="$1"
    [[ -z "$ciphertext" ]] && return 0

    # Check if value is encrypted (starts with U2FsdGVk after base64 decode)
    if [[ ! "$ciphertext" =~ ^U2FsdGVk ]]; then
        # Not encrypted, return as-is (backward compatibility)
        echo "$ciphertext"
        return 0
    fi

    [[ ! -f "$ENCRYPTION_KEY_FILE" ]] && { echo "$ciphertext"; return 0; }

    local key
    key=$(cat "$ENCRYPTION_KEY_FILE")

    echo "$ciphertext" | openssl enc -aes-256-cbc -pbkdf2 -d -a -pass "pass:$key" 2>/dev/null || echo "$ciphertext"
}

# Check if config encryption is enabled
is_encryption_enabled() {
    [[ -f "$ENCRYPTION_KEY_FILE" ]] && [[ "${ENABLE_CONFIG_ENCRYPTION:-false}" == "true" ]]
}

# 配置目录（支持多节点）
NODES_DIR="/root/reality_nodes"
LANG_FILE="/root/reality_vision.lang"
XRAY_BIN="/usr/local/bin/xray"
XRAY_CONF="/usr/local/etc/xray/config.json"
XRAY_GEODATA_DIR="/usr/local/share/xray"
SERVICE="xray"

# sing-box（用于 AnyTLS / AnyTLS + REALITY / Hysteria2）
SINGBOX_BIN="/usr/local/bin/sing-box"
SINGBOX_DIR="/usr/local/etc/sing-box"
SINGBOX_CONF="/usr/local/etc/sing-box/config.json"
SINGBOX_CERT_DIR="/usr/local/etc/sing-box/certs"
SINGBOX_SERVICE="sing-box"

# 缓存配置（放在 /root 下更安全）
CACHE_FILE="/root/.sni_latency_cache"
CACHE_TTL=3600  # 1小时

# 当前操作的节点名称
CURRENT_NODE_NAME=""

# 包管理器变量
PKG_MANAGER=""
PKG_UPDATE=""
PKG_INSTALL=""
PKG_CHECK=""

# 服务管理变量 (systemd 或 openrc)
INIT_SYSTEM=""

# WARP 配置
WARP_SOCKS_PORT=40000

PORT_MIN=10000
PORT_MAX=65535

# 语言设置 (zh/en)
CURRENT_LANG="${CURRENT_LANG:-}"

# Spinner 动画帧
SPINNER_FRAMES=('|' '/' '-' '\')

# SNI 域名列表（完整列表，用于延迟测试）
SNI_LIST=(
    "amd.com"
    "aws.com"
    "c.6sc.co"
    "j.6sc.co"
    "b.6sc.co"
    "intel.com"
    "r.bing.com"
    "th.bing.com"
    "www.amd.com"
    "www.aws.com"
    "ipv6.6sc.co"
    "www.xbox.com"
    "www.sony.com"
    "rum.hlx.page"
    "www.bing.com"
    "xp.apple.com"
    "www.wowt.com"
    "www.apple.com"
    "www.intel.com"
    "www.tesla.com"
    "www.xilinx.com"
    "www.oracle.com"
    "www.icloud.com"
    "apps.apple.com"
    "c.marsflag.com"
    "www.nvidia.com"
    "snap.licdn.com"
    "aws.amazon.com"
    "drivers.amd.com"
    "cdn.bizibly.com"
    "s.go-mpulse.net"
    "tags.tiqcdn.com"
    "cdn.bizible.com"
    "ocsp2.apple.com"
    "cdn.userway.org"
    "download.amd.com"
    "d1.awsstatic.com"
    "s0.awsstatic.com"
    "mscom.demdex.net"
    "a0.awsstatic.com"
    "go.microsoft.com"
    "apps.mzstatic.com"
    "sisu.xboxlive.com"
    "www.microsoft.com"
    "s.mp.marsflag.com"
    "images.nvidia.com"
    "vs.aws.amazon.com"
    "c.s-microsoft.com"
    "statici.icloud.com"
    "beacon.gtv-pub.com"
    "ts4.tc.mm.bing.net"
    "ts3.tc.mm.bing.net"
    "d2c.aws.amazon.com"
    "ts1.tc.mm.bing.net"
    "ce.mf.marsflag.com"
    "d0.m.awsstatic.com"
    "t0.m.awsstatic.com"
    "ts2.tc.mm.bing.net"
    "tag.demandbase.com"
    "assets-www.xbox.com"
    "logx.optimizely.com"
    "azure.microsoft.com"
    "aadcdn.msftauth.net"
    "d.oracleinfinity.io"
    "assets.adobedtm.com"
    "lpcdn.lpsnmedia.net"
    "res-1.cdn.office.net"
    "is1-ssl.mzstatic.com"
    "electronics.sony.com"
    "intelcorp.scene7.com"
    "acctcdn.msftauth.net"
    "cdnssl.clicktale.net"
    "catalog.gamepass.com"
    "consent.trustarc.com"
    "gsp-ssl.ls.apple.com"
    "munchkin.marketo.net"
    "s.company-target.com"
    "cdn77.api.userway.org"
    "cua-chat-ui.tesla.com"
    "assets-xbxweb.xbox.com"
    "ds-aksb-a.akamaihd.net"
    "static.cloud.coveo.com"
    "api.company-target.com"
    "devblogs.microsoft.com"
    "s7mbrstream.scene7.com"
    "fpinit.itunes.apple.com"
    "digitalassets.tesla.com"
    "d.impactradius-event.com"
    "downloadmirror.intel.com"
    "iosapps.itunes.apple.com"
    "se-edge.itunes.apple.com"
    "publisher.liveperson.net"
    "tag-logger.demandbase.com"
    "services.digitaleast.mobi"
    "configuration.ls.apple.com"
    "gray-wowt-prod.gtv-cdn.com"
    "visualstudio.microsoft.com"
    "prod.log.shortbread.aws.dev"
    "amp-api-edge.apps.apple.com"
    "store-images.s-microsoft.com"
    "cdn-dynmedia-1.microsoft.com"
    "github.gallerycdn.vsassets.io"
    "prod.pa.cdn.uis.awsstatic.com"
    "a.b.cdn.console.awsstatic.com"
    "d3agakyjgjv5i8.cloudfront.net"
    "vscjava.gallerycdn.vsassets.io"
    "location-services-prd.tesla.com"
    "ms-vscode.gallerycdn.vsassets.io"
    "ms-python.gallerycdn.vsassets.io"
    "gray-config-prod.api.arc-cdn.net"
    "i7158c100-ds-aksb-a.akamaihd.net"
    "downloaddispatch.itunes.apple.com"
    "res.public.onecdn.static.microsoft"
    "gray.video-player.arcpublishing.com"
    "gray-config-prod.api.cdn.arcpublishing.com"
    "img-prod-cms-rt-microsoft-com.akamaized.net"
    "prod.us-east-1.ui.gcr-chat.marketing.aws.dev"
)

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
GRAY='\033[0;90m'
NC='\033[0m' # No Color

# ============== 进程清理 ==============

declare -a CLEANUP_JOB_ROOTS=()
declare -a CLEANUP_TREE_PIDS=()
declare -A CLEANUP_TREE_SEEN=()
declare -A CLEANUP_TREE_IDENTITIES=()
declare -A CLEANUP_TRACKED_GROUPS=()
declare -A CLEANUP_GROUP_LEADER_IDENTITIES=()
CLEANUP_HAS_UNBOUNDED_ROOTS=0
CLEANUP_UNSAFE_TO_UNLOCK=0
CLEANUP_STAT_STATE=""
CLEANUP_STAT_GROUP=""
CLEANUP_STAT_IDENTITY=""

cleanup_read_process_stat() {
    local pid="$1" stat_line rest
    [[ "$pid" =~ ^[0-9]+$ && -r "/proc/$pid/stat" ]] || return 1
    IFS= read -r stat_line < "/proc/$pid/stat" || return 1
    rest="${stat_line##*) }"
    set -- $rest
    (($# >= 20)) || return 1
    CLEANUP_STAT_STATE="$1"
    CLEANUP_STAT_GROUP="$3"
    CLEANUP_STAT_IDENTITY="${20}"
}

cleanup_process_identity() {
    cleanup_read_process_stat "$1" || return 1
    printf '%s\n' "$CLEANUP_STAT_IDENTITY"
}

cleanup_pid_is_original() {
    local pid="$1"
    [[ -n "${CLEANUP_TREE_IDENTITIES[$pid]:-}" ]] || return 1
    cleanup_read_process_stat "$pid" || return 1
    [[ "$CLEANUP_STAT_IDENTITY" == "${CLEANUP_TREE_IDENTITIES[$pid]}" ]]
}

cleanup_pid_is_live_original() {
    cleanup_pid_is_original "$1" || return 1
    [[ "$CLEANUP_STAT_STATE" != Z && "$CLEANUP_STAT_STATE" != X ]]
}

cleanup_process_group() {
    cleanup_read_process_stat "$1" || return 1
    printf '%s\n' "$CLEANUP_STAT_GROUP"
}

cleanup_track_process_group() {
    local pid="$1" group_id own_group leader_identity registered_root_identity
    registered_root_identity="${CLEANUP_TREE_IDENTITIES[$pid]:-}"
    [[ -n "$registered_root_identity" ]] || {
        CLEANUP_HAS_UNBOUNDED_ROOTS=1
        return 0
    }
    cleanup_read_process_stat "$pid" || {
        CLEANUP_HAS_UNBOUNDED_ROOTS=1
        return 0
    }
    # The jobs snapshot and the group lookup are separate reads.  Refuse to
    # claim a numeric PID that was reused between them.
    [[ "$CLEANUP_STAT_IDENTITY" == "$registered_root_identity" ]] || {
        CLEANUP_HAS_UNBOUNDED_ROOTS=1
        return 0
    }
    group_id="$CLEANUP_STAT_GROUP"
    cleanup_read_process_stat "$$" || {
        CLEANUP_HAS_UNBOUNDED_ROOTS=1
        return 0
    }
    own_group="$CLEANUP_STAT_GROUP"

    # Claim only a group whose leader is the registered job root, or our own
    # group when this shell is its leader.  Merely being in a different group
    # does not prove ownership: a child can join an existing external group.
    if [[ "$group_id" == "$pid" ]] \
        || [[ "$group_id" == "$own_group" && "$own_group" == "$$" ]]; then
        cleanup_read_process_stat "$group_id" || {
            CLEANUP_HAS_UNBOUNDED_ROOTS=1
            return 0
        }
        leader_identity="$CLEANUP_STAT_IDENTITY"
        if [[ "$group_id" == "$pid" && "$leader_identity" != "$registered_root_identity" ]]; then
            CLEANUP_HAS_UNBOUNDED_ROOTS=1
            return 0
        fi
        CLEANUP_TRACKED_GROUPS[$group_id]=1
        CLEANUP_GROUP_LEADER_IDENTITIES[$group_id]="$leader_identity"
    else
        CLEANUP_HAS_UNBOUNDED_ROOTS=1
    fi
}

cleanup_list_process_ids() {
    local stat_path pid
    for stat_path in /proc/[0-9]*/stat; do
        [[ -r "$stat_path" ]] || continue
        pid="${stat_path#/proc/}"
        printf '%s\n' "${pid%/stat}"
    done
}

cleanup_group_leader_is_original() {
    local group_id="$1" expected_identity
    expected_identity="${CLEANUP_GROUP_LEADER_IDENTITIES[$group_id]:-}"
    [[ -n "$expected_identity" ]] || return 1
    cleanup_read_process_stat "$group_id" 2>/dev/null || return 1
    [[ "$CLEANUP_STAT_IDENTITY" == "$expected_identity" ]]
}

cleanup_validate_tracked_groups() {
    local group_id valid=0
    for group_id in "${!CLEANUP_TRACKED_GROUPS[@]}"; do
        if ! cleanup_group_leader_is_original "$group_id"; then
            CLEANUP_HAS_UNBOUNDED_ROOTS=1
            valid=1
        fi
    done
    return "$valid"
}

cleanup_collect_process_tree() {
    local pid="$1" identity children="" child
    [[ "$pid" =~ ^[0-9]+$ ]] || return 0

    cleanup_read_process_stat "$pid" || return 0
    identity="$CLEANUP_STAT_IDENTITY"
    if [[ -n "${CLEANUP_TREE_IDENTITIES[$pid]:-}" ]] \
        && [[ "${CLEANUP_TREE_IDENTITIES[$pid]}" != "$identity" ]]; then
        return 0
    fi
    if [[ -z "${CLEANUP_TREE_SEEN[$pid]:-}" ]]; then
        CLEANUP_TREE_SEEN[$pid]=1
        CLEANUP_TREE_IDENTITIES[$pid]="$identity"
        CLEANUP_TREE_PIDS+=("$pid")
    fi

    if [[ -r "/proc/$pid/task/$pid/children" ]]; then
        IFS= read -r children < "/proc/$pid/task/$pid/children" || true
        for child in $children; do
            cleanup_collect_process_tree "$child"
        done
    fi
}

cleanup_collect_process_group() {
    local group_id="$1" pid candidate_identity
    local -a candidate_pids=() candidate_identities=()
    local -a validated_pids=() validated_identities=()
    cleanup_group_leader_is_original "$group_id" || {
        CLEANUP_HAS_UNBOUNDED_ROOTS=1
        return 1
    }

    # Treat the whole /proc scan as provisional.  Nothing discovered here is
    # trusted until the leader identity is checked again after the scan.
    while IFS= read -r pid; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        [[ "$pid" != "$$" ]] || continue
        cleanup_read_process_stat "$pid" 2>/dev/null || continue
        [[ "$CLEANUP_STAT_GROUP" == "$group_id" ]] || continue
        candidate_pids+=("$pid")
        candidate_identities+=("$CLEANUP_STAT_IDENTITY")
    done < <(cleanup_list_process_ids)

    cleanup_group_leader_is_original "$group_id" || {
        CLEANUP_HAS_UNBOUNDED_ROOTS=1
        return 1
    }

    for ((pid = 0; pid < ${#candidate_pids[@]}; pid++)); do
        candidate_identity="${candidate_identities[$pid]}"
        cleanup_read_process_stat "${candidate_pids[$pid]}" 2>/dev/null || continue
        [[ "$CLEANUP_STAT_GROUP" == "$group_id" \
            && "$CLEANUP_STAT_IDENTITY" == "$candidate_identity" ]] || continue
        validated_pids+=("${candidate_pids[$pid]}")
        validated_identities+=("$candidate_identity")
    done

    # Keep even the revalidated members provisional until one final leader
    # check succeeds, so a scan-time reuse cannot contaminate the tracked tree.
    cleanup_group_leader_is_original "$group_id" || {
        CLEANUP_HAS_UNBOUNDED_ROOTS=1
        return 1
    }
    for ((pid = 0; pid < ${#validated_pids[@]}; pid++)); do
        if [[ -z "${CLEANUP_TREE_SEEN[${validated_pids[$pid]}]:-}" ]]; then
            CLEANUP_TREE_SEEN[${validated_pids[$pid]}]=1
            CLEANUP_TREE_IDENTITIES[${validated_pids[$pid]}]="${validated_identities[$pid]}"
            CLEANUP_TREE_PIDS+=("${validated_pids[$pid]}")
        fi
    done
}

cleanup_tree_has_live_processes() {
    local pid
    for pid in "${CLEANUP_TREE_PIDS[@]}"; do
        cleanup_pid_is_live_original "$pid" && return 0
    done
    return 1
}

cleanup_signal_original_processes() {
    local signal="$1" pid
    # Numeric PGIDs can be reused after collection.  Validate every leader
    # immediately before every STOP/TERM/KILL pass; on uncertainty signal
    # nothing and retain the writer lock.
    cleanup_validate_tracked_groups || return 1
    for pid in "${CLEANUP_TREE_PIDS[@]}"; do
        cleanup_pid_is_original "$pid" || continue
        cleanup_validate_tracked_groups || return 1
        cleanup_send_signal "$signal" "$pid" 2>/dev/null || true
    done
}

cleanup_send_signal() {
    kill -s "$1" "$2"
}

cleanup_refresh_process_tree() {
    local pid group_id
    for group_id in "${!CLEANUP_TRACKED_GROUPS[@]}"; do
        cleanup_collect_process_group "$group_id" || return 1
    done
    local -a known_pids=("${CLEANUP_TREE_PIDS[@]}")
    for pid in "${known_pids[@]}"; do
        cleanup_pid_is_original "$pid" || continue
        cleanup_collect_process_tree "$pid"
    done
}

cleanup_freeze_process_tree() {
    local attempt pid before_count after_count
    for attempt in $(seq 1 20); do
        before_count=${#CLEANUP_TREE_PIDS[@]}
        cleanup_signal_original_processes STOP || return 1
        cleanup_refresh_process_tree || return 1
        cleanup_signal_original_processes STOP || return 1
        after_count=${#CLEANUP_TREE_PIDS[@]}
        ((after_count == before_count)) && return 0
    done
    return 1
}

terminate_background_jobs() {
    local pid attempt
    CLEANUP_JOB_ROOTS=()
    CLEANUP_TREE_PIDS=()
    CLEANUP_TREE_SEEN=()
    CLEANUP_TREE_IDENTITIES=()
    CLEANUP_TRACKED_GROUPS=()
    CLEANUP_GROUP_LEADER_IDENTITIES=()
    CLEANUP_HAS_UNBOUNDED_ROOTS=0

    while IFS= read -r pid; do
        [[ "$pid" =~ ^[0-9]+$ ]] && CLEANUP_JOB_ROOTS+=("$pid")
    done < <(jobs -pr 2>/dev/null || true)
    ((${#CLEANUP_JOB_ROOTS[@]} > 0)) || return 0

    for pid in "${CLEANUP_JOB_ROOTS[@]}"; do
        cleanup_collect_process_tree "$pid"
        cleanup_track_process_group "$pid"
    done
    cleanup_refresh_process_tree || return 1
    cleanup_signal_original_processes TERM || return 1

    for attempt in $(seq 1 20); do
        cleanup_refresh_process_tree || return 1
        cleanup_tree_has_live_processes || break
        sleep 0.1
    done

    if cleanup_tree_has_live_processes; then
        cleanup_freeze_process_tree || {
            cleanup_signal_original_processes KILL || true
            return 1
        }
        cleanup_signal_original_processes KILL || return 1
    fi
    for pid in "${CLEANUP_JOB_ROOTS[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    for attempt in $(seq 1 20); do
        cleanup_refresh_process_tree || return 1
        if ! cleanup_tree_has_live_processes; then
            ((CLEANUP_HAS_UNBOUNDED_ROOTS == 0)) && return 0
            return 1
        fi
        sleep 0.05
    done
    return 1
}

# 清理函数，确保脚本退出时清理后台进程和临时文件
cleanup() {
    local jobs_stopped=0 rollback_safe=1
    # 恢复光标
    tput cnorm 2>/dev/null || true
    # SSH rollback is itself a tracked background job.  Let its identity-bound
    # recovery finish before the generic job-tree terminator runs; otherwise a
    # timer that already claimed rolling-back could be killed between restoring
    # the config and publishing its durable result.  Any uncertainty remains
    # fail-closed below and retains the writer lock.
    if declare -F cleanup_pending_ssh_rollback >/dev/null 2>&1; then
        cleanup_pending_ssh_rollback || rollback_safe=0
    fi
    # Terminate, wait for, and reap every remaining background process tree
    # before releasing the writer lock.  If SSH recovery could not be proven,
    # do not risk killing its timer through the generic path; retain the lock
    # and all ambiguous jobs instead.
    if ((rollback_safe)); then
        terminate_background_jobs || jobs_stopped=1
    else
        jobs_stopped=1
    fi
    ((jobs_stopped == 0)) || CLEANUP_UNSAFE_TO_UNLOCK=1
    if ((CLEANUP_UNSAFE_TO_UNLOCK == 0)); then
        lock_release_smart
    else
        printf 'proxy-hub: cleanup could not prove quiescence and rollback completion; retaining the write lock\n' >&2
    fi
}

cleanup_signal() {
    local signal="$1" fallback_status="$2"
    trap - EXIT INT TERM HUP
    cleanup
    kill -s "$signal" "$$" 2>/dev/null || exit "$fallback_status"
    exit "$fallback_status"
}

trap cleanup EXIT
trap 'cleanup_signal INT 130' INT
trap 'cleanup_signal TERM 143' TERM
# SIGHUP (SSH disconnect / terminal close) is catchable: release the write lock
# through the same cleanup path as INT/TERM instead of dying and orphaning it.
trap 'cleanup_signal HUP 129' HUP

# ============== Spinner 动画执行器 ==============

# 带 spinner 动画的任务执行器
# 用法: execute_task "命令" "描述" [max_retries]
execute_task() {
    local cmd="$1"
    local desc="$2"
    local max_retries="${3:-3}"
    local log_file="/tmp/xray_task_$$.log"
    local attempt=1
    local i=0

    while [[ $attempt -le $max_retries ]]; do
        echo "" > "$log_file"

        # 后台执行命令
        bash -c "$cmd" > "$log_file" 2>&1 &
        local pid=$!

        # 隐藏光标
        tput civis 2>/dev/null || true

        # 显示 spinner
        while kill -0 $pid 2>/dev/null; do
            local frame="${SPINNER_FRAMES[$((i % 4))]}"
            printf "\r  ${BLUE}[%s]${NC} %s..." "$frame" "$desc"
            ((i++))
            sleep 0.1
        done

        # 恢复光标
        tput cnorm 2>/dev/null || true

        wait $pid
        local status=$?

        # 清除当前行
        printf "\r\033[K"

        if [[ $status -eq 0 ]]; then
            echo -e "  ${GREEN}[OK]${NC}   $desc"
            rm -f "$log_file"
            return 0
        fi

        echo -e "  ${RED}[ERR]${NC}  $desc (attempt $attempt/$max_retries)"

        if [[ $attempt -ge $max_retries ]]; then
            echo -e "  ${RED}Error log:${NC}"
            tail -n 5 "$log_file" 2>/dev/null | sed 's/^/    /'
            rm -f "$log_file"
            return 1
        fi

        ((attempt++))
        sleep 2
    done

    rm -f "$log_file"
    return 1
}

# 简单的 spinner 显示（用于等待操作）
show_spinner() {
    local pid=$1
    local msg="$2"
    local i=0

    tput civis 2>/dev/null || true
    while kill -0 $pid 2>/dev/null; do
        local frame="${SPINNER_FRAMES[$((i % 4))]}"
        printf "\r  ${BLUE}[%s]${NC} %s..." "$frame" "$msg"
        ((i++))
        sleep 0.1
    done
    tput cnorm 2>/dev/null || true
    printf "\r\033[K"
}

# ============== 超时输入函数 ==============

# 交互超时设置
UI_TIMEOUT_SHORT=30   # 简单询问
UI_TIMEOUT_LONG=60    # 复杂操作

# 核心：统一倒计时交互函数
# 用法: read_with_timeout "提示语" "默认值" "超时时间"
# 返回值存储在 USER_INPUT 变量中
USER_INPUT=""

read_with_timeout() {
    local prompt="$1"
    local default="$2"
    local timeout="${3:-$UI_TIMEOUT_SHORT}"
    local input_char=""

    # 清空之前的输入残留 (防止幽灵回车导致秒过)
    while read -r -t 0 2>/dev/null; do read -r -n 1 2>/dev/null; done

    USER_INPUT=""

    # 设定截止时间戳
    local start_time end_time current_time remaining
    start_time=$(date +%s)
    end_time=$((start_time + timeout))

    while true; do
        current_time=$(date +%s)
        remaining=$((end_time - current_time))

        # 如果时间到了，退出循环
        if [[ "$remaining" -le 0 ]]; then
            break
        fi

        # 交互 UI： 提示语 [默认: X] [ 10s ] :
        printf "\r${YELLOW}%s [默认: %s] [ ${RED}%ds${YELLOW} ] : ${NC}" "$prompt" "$default" "$remaining"

        # -t 1 等待一秒，但我们只关心是否按键
        if read -t 1 -n 1 input_char 2>/dev/null; then
            # 用户按下了键
            echo "" # 换行
            if [[ -z "$input_char" ]]; then
                USER_INPUT="$default"
            else
                USER_INPUT="$input_char"
            fi
            return 0
        fi
    done

    # 超时处理
    echo ""
    echo -e "${BLUE}[INFO]${NC} 倒计时结束，使用默认值: ${default}"
    USER_INPUT="$default"
}

# ============== 包管理器状态检查 ==============

# 检查包管理器是否繁忙
is_pkg_manager_busy() {
    case "$PKG_MANAGER" in
        apt)
            pgrep -x apt >/dev/null 2>&1 || \
            pgrep -x apt-get >/dev/null 2>&1 || \
            pgrep -x dpkg >/dev/null 2>&1 || \
            pgrep -f "unattended-upgr" >/dev/null 2>&1
            ;;
        dnf|yum)
            pgrep -x dnf >/dev/null 2>&1 || \
            pgrep -x yum >/dev/null 2>&1 || \
            pgrep -x rpm >/dev/null 2>&1
            ;;
        apk)
            pgrep -x apk >/dev/null 2>&1
            ;;
        *)
            return 1
            ;;
    esac
}

# 检查 dpkg/rpm 数据库状态
check_pkg_db_status() {
    case "$PKG_MANAGER" in
        apt)
            if ! dpkg --audit >/dev/null 2>&1; then
                echo -e "${RED}[ERROR]${NC} 检测到 dpkg 数据库状态异常！"
                echo -e "${YELLOW}建议执行: 'dpkg --configure -a' 修复系统。${NC}"
                return 1
            fi
            ;;
        dnf|yum)
            if ! rpm --query --all >/dev/null 2>&1; then
                echo -e "${RED}[ERROR]${NC} 检测到 RPM 数据库状态异常！"
                echo -e "${YELLOW}建议执行: 'rpm --rebuilddb' 修复系统。${NC}"
                return 1
            fi
            ;;
    esac
    return 0
}

# 等待包管理器释放
wait_for_pkg_manager() {
    local max_wait=300  # 最长等待 5 分钟
    local waited=0
    local i=0

    if ! is_pkg_manager_busy; then
        return 0
    fi

    echo -e "${BLUE}[INFO]${NC} 检测到系统更新进程正在运行，正在等待释放..."
    tput civis 2>/dev/null || true

    while is_pkg_manager_busy; do
        if [[ $waited -ge $max_wait ]]; then
            tput cnorm 2>/dev/null || true
            echo ""
            echo -e "${YELLOW}[WARN]${NC} 等待超时！"
            echo -n "是否强制终止占用进程? (y/n) [n]: "
            read -r kill_choice
            if [[ "$kill_choice" == "y" || "$kill_choice" == "Y" ]]; then
                case "$PKG_MANAGER" in
                    apt)
                        killall apt apt-get dpkg 2>/dev/null || true
                        rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock* 2>/dev/null
                        ;;
                    dnf|yum)
                        killall dnf yum 2>/dev/null || true
                        rm -f /var/run/yum.pid /var/run/dnf.pid 2>/dev/null
                        ;;
                esac
                return 0
            else
                echo -e "${RED}[ERROR]${NC} 用户取消，安装终止。"
                return 1
            fi
        fi

        local frame="${SPINNER_FRAMES[$((i % 4))]}"
        printf "\r  ${BLUE}[%s]${NC} 等待包管理器释放... (%ds)" "$frame" "$waited"
        sleep 1
        ((waited++))
        ((i++))
    done

    tput cnorm 2>/dev/null || true
    printf "\r\033[K"
    echo -e "${GREEN}[OK]${NC} 包管理器已释放"
    return 0
}

# ============== IPv6 SSH 保护 ==============

# 检查当前 SSH 连接方式 (防自杀核心)
check_ssh_connection() {
    # 获取当前 SSH 连接的客户端 IP
    local client_ip="${SSH_CLIENT%% *}"
    if [[ -z "$client_ip" ]]; then
        echo "unknown"
    elif [[ "$client_ip" =~ : ]]; then
        echo "v6" # 当前是 IPv6 连接
    else
        echo "v4" # 当前是 IPv4 连接
    fi
}

# IPv6 操作前安全检查
check_ipv6_ssh_safety() {
    local action="$1"  # disable 或 其他操作

    if [[ "$action" == "disable" ]]; then
        if [[ "$(check_ssh_connection)" == "v6" ]]; then
            echo -e "${RED}═══════════════════════════════════════════════════════${NC}"
            echo -e "${RED}                 [危险操作拦截]                        ${NC}"
            echo -e "${RED}═══════════════════════════════════════════════════════${NC}"
            echo -e "${YELLOW}检测到您当前正在通过 IPv6 连接 SSH！${NC}"
            echo -e "${YELLOW}若此时禁用 IPv6，您将立即断开连接且无法重连！${NC}"
            echo -e "${RED}操作已取消。请切换到 IPv4 网络连接 SSH 后再试。${NC}"
            echo ""
            read -n 1 -s -r -p "按任意键返回..."
            return 1
        fi
    fi
    return 0
}

# ============== 包管理器检测 ==============

detect_pkg_manager() {
    if command -v apt-get &>/dev/null; then
        PKG_MANAGER="apt"
        PKG_UPDATE="apt-get update -y"
        PKG_INSTALL="apt-get install -y"
        PKG_CHECK="dpkg -s"
    elif command -v dnf &>/dev/null; then
        PKG_MANAGER="dnf"
        PKG_UPDATE="dnf check-update || true"
        PKG_INSTALL="dnf install -y"
        PKG_CHECK="rpm -q"
    elif command -v yum &>/dev/null; then
        PKG_MANAGER="yum"
        PKG_UPDATE="yum check-update || true"
        PKG_INSTALL="yum install -y"
        PKG_CHECK="rpm -q"
    elif command -v apk &>/dev/null; then
        PKG_MANAGER="apk"
        PKG_UPDATE="apk update"
        PKG_INSTALL="apk add --no-cache"
        PKG_CHECK="apk info -e"
    else
        echo -e "${RED}[ERROR]${NC} Unsupported package manager"
        echo "Please use Debian/Ubuntu, CentOS/RHEL/Fedora, or Alpine Linux"
        exit 1
    fi
}

# ============== init 系统检测 ==============

detect_init_system() {
    if command -v systemctl &>/dev/null && systemctl --version &>/dev/null 2>&1; then
        INIT_SYSTEM="systemd"
    elif command -v rc-service &>/dev/null; then
        INIT_SYSTEM="openrc"
    else
        # 默认尝试 systemd
        INIT_SYSTEM="systemd"
    fi
}

# ============== 服务管理抽象 ==============

# 启动服务
service_start() {
    local svc="$1"
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service "$svc" start
    else
        systemctl start "$svc"
    fi
}

# 停止服务
service_stop() {
    local svc="$1"
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service "$svc" stop 2>/dev/null || true
    else
        systemctl stop "$svc" 2>/dev/null || true
    fi
}

# Strict variants are used by transactional lifecycle operations that must
# distinguish a real service-manager failure from an already-stopped service.
service_start_strict() {
    local svc="$1"
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service "$svc" start
    else
        systemctl start "$svc"
    fi
}

service_stop_strict() {
    local svc="$1"
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service "$svc" stop
    else
        systemctl stop "$svc"
    fi
}

openrc_service_pidfile() {
    local svc="$1" script="${2:-/etc/init.d/$1}" line value="" count=0
    [[ -f "$script" && ! -L "$script" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^[[:space:]]*pidfile=(.*)$ ]]; then
            value="${BASH_REMATCH[1]}"
            ((++count))
        fi
    done < "$script"
    [[ "$count" == 1 ]] || return 1
    if [[ "$value" == \"*\" && "$value" == *\" ]]; then
        value="${value:1:${#value}-2}"
    elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
        value="${value:1:${#value}-2}"
    fi
    value="${value//'${RC_SVCNAME}'/$svc}"
    value="${value//'$RC_SVCNAME'/$svc}"
    [[ "$value" =~ ^/[A-Za-z0-9_./-]+$ && "$value" != *'..'* ]] || return 1
    printf '%s\n' "$value"
}

service_main_pid() {
    local svc="$1" pid pidfile
    local -a pids=()
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        pidfile=$(openrc_service_pidfile "$svc" 2>/dev/null || true)
        if [[ -n "$pidfile" && -f "$pidfile" && ! -L "$pidfile" ]]; then
            IFS= read -r pid < "$pidfile" || return 1
        else
            if [[ "$svc" == xray ]] && declare -F xray_list_process_ids >/dev/null; then
                mapfile -t pids < <(xray_list_process_ids)
            else
                mapfile -t pids < <(pgrep -x "$svc" 2>/dev/null || true)
            fi
            [[ ${#pids[@]} -eq 1 ]] || return 1
            pid="${pids[0]}"
        fi
    else
        pid=$(systemctl show --property MainPID --value "$svc" 2>/dev/null) || return 1
    fi
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    printf '%s\n' "$pid"
}

# 重启服务
service_restart() {
    local svc="$1"
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service "$svc" restart
    else
        systemctl restart "$svc"
    fi
}

# 设置开机启动
service_enable() {
    local svc="$1"
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-update add "$svc" default 2>/dev/null || true
    else
        systemctl enable "$svc" 2>/dev/null || true
    fi
}

# 取消开机启动
service_disable() {
    local svc="$1"
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-update del "$svc" default 2>/dev/null || true
    else
        systemctl disable "$svc" 2>/dev/null || true
    fi
}

# 检查服务是否运行
service_is_active() {
    local svc="$1"
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service "$svc" status &>/dev/null
    else
        systemctl is-active --quiet "$svc" 2>/dev/null
    fi
}

# 显示服务状态
service_status() {
    local svc="$1"
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service "$svc" status 2>/dev/null || echo "Service $svc is not running"
    else
        systemctl status "$svc" --no-pager 2>/dev/null | head -10 || true
    fi
}

# 初始化包管理器和 init 系统
detect_pkg_manager
detect_init_system

# ============== 多语言支持 ==============

# 获取翻译文本
msg() {
    local key="$1"
    if [[ "$CURRENT_LANG" == "en" ]]; then
        case "$key" in
            "menu_title") echo "VLESS TCP REALITY Vision Management" ;;
            "menu_install") echo "Install Node" ;;
            "menu_info") echo "View Node Info" ;;
            "menu_qr") echo "Show QR Code" ;;
            "menu_status") echo "Service Status" ;;
            "menu_health") echo "Health Check" ;;
            "menu_restart") echo "Restart Service" ;;
            "menu_test_sni") echo "Test SNI Latency" ;;
            "menu_uninstall") echo "Uninstall" ;;
            "menu_lang") echo "Switch Language" ;;
            "menu_exit") echo "Exit" ;;
            "menu_choice") echo "Please enter your choice" ;;
            "menu_invalid") echo "Invalid option, please try again" ;;
            "menu_press_enter") echo "Press Enter to continue..." ;;
            "lang_select") echo "Select Language / 选择语言" ;;
            "lang_zh") echo "Chinese (中文)" ;;
            "lang_en") echo "English" ;;
            "installing") echo "Installing VLESS TCP REALITY Vision..." ;;
            "install_deps") echo "Installing dependencies..." ;;
            "install_xray") echo "Installing Xray..." ;;
            "gen_keys") echo "Generating Reality keys..." ;;
            "testing_sni") echo "Testing all SNI domains for latency..." ;;
            "testing") echo "Testing..." ;;
            "test_progress") echo "Progress" ;;
            "current") echo "Current" ;;
            "sni_timeout") echo "All test domains timed out, using default SNI: www.tesla.com" ;;
            "sni_selected") echo "Selected optimal SNI" ;;
            "sni_multiple") echo "Multiple domains have the same lowest latency" ;;
            "sni_choose") echo "Please choose one" ;;
            "latency") echo "latency" ;;
            "install_complete") echo "Installation complete!" ;;
            "uninstalling") echo "Uninstalling..." ;;
            "uninstall_complete") echo "Uninstall complete" ;;
            "config_not_found") echo "Configuration not found, please install first" ;;
            "run_as_root") echo "Please run this script as root" ;;
            "node_info") echo "VLESS Reality Vision Node Info" ;;
            "node_info_suffix") echo "Node Info" ;;
            "server_addr") echo "Server Address" ;;
            "port") echo "Port" ;;
            "share_link") echo "Share Link" ;;
            "qr_title") echo "Node QR Code (Scan to Import)" ;;
            "qr_tip") echo "Tip: Run 'bash $0 qr' to regenerate QR code" ;;
            "common_cmds") echo "Common commands" ;;
            "view_info") echo "View node info" ;;
            "show_qr") echo "Show QR code" ;;
            "service_status") echo "Service Status" ;;
            "service_restarted") echo "Service restarted" ;;
            "test_complete") echo "Test complete" ;;
            "timeout") echo "timeout" ;;
            "using_sni") echo "Using specified SNI" ;;
            "installed") echo "Installed" ;;
            "not_installed") echo "Not Installed" ;;
            "total_domains") echo "Total domains" ;;
            "best_latency") echo "Best latency" ;;
            "health_check") echo "Health Check" ;;
            "connections") echo "Active Connections" ;;
            "sni_selection_title") echo "SNI Domain Selection" ;;
            "sni_top_results") echo "Top 5 Fastest Domains" ;;
            "sni_auto_select") echo "Auto select best" ;;
            "sni_manual_input") echo "Enter custom domain" ;;
            "sni_custom_test") echo "Test custom domains (comma-separated)" ;;
            "sni_custom_test_hint") echo "Enter domains to test, comma-separated (e.g. a.com,b.com,c.com)" ;;
            "sni_custom_test_done") echo "Custom domain test done, select from the results above" ;;
            "sni_choice_prompt") echo "Your choice" ;;
            "sni_no_results") echo "No test results available" ;;
            "sni_use_default") echo "Use default" ;;
            "sni_input_hint") echo "Enter domain (e.g. www.microsoft.com)" ;;
            "sni_empty_input") echo "Empty input" ;;
            "sni_custom_set") echo "Custom SNI set" ;;
            "sni_testing_custom") echo "Testing connectivity" ;;
            "sni_custom_ok") echo "Domain is reachable" ;;
            "sni_custom_unreachable") echo "Domain may be unreachable, but will use it anyway" ;;
            "sni_invalid_format") echo "Invalid domain format" ;;
            "anytls_sni_note") echo "Note: for plain AnyTLS the SNI is only TLS camouflage (self-signed cert, client uses insecure); latency results are for reference only." ;;
            # 新功能翻译
            "menu_tools") echo "System Tools" ;;
            "menu_warp") echo "WARP Routing" ;;
            "menu_bbr") echo "BBR Management" ;;
            "menu_swap") echo "Swap Management" ;;
            "menu_fail2ban") echo "Fail2ban Management" ;;
            "install_geodata") echo "Installing GeoIP/GeoSite databases..." ;;
            "geodata_updated") echo "GeoData databases updated" ;;
            "xhttp_port") echo "XHTTP Port" ;;
            "vision_port") echo "Vision Port" ;;
            "ipv4_links") echo "IPv4 Links" ;;
            "ipv6_links") echo "IPv6 Links" ;;
            "warp_status") echo "WARP Status" ;;
            "warp_running") echo "Running" ;;
            "warp_stopped") echo "Stopped" ;;
            "warp_install") echo "Install WARP" ;;
            "warp_uninstall") echo "Uninstall WARP" ;;
            "warp_netflix") echo "Netflix Routing" ;;
            "warp_ai") echo "AI Services Routing" ;;
            "bbr_enabled") echo "BBR Enabled" ;;
            "bbr_disabled") echo "BBR Disabled" ;;
            "swap_size") echo "Swap Size" ;;
            "fail2ban_status") echo "Fail2ban Status" ;;
            "script_running") echo "Script is already running!" ;;
            "lock_owner_alive") echo "Another instance appears to be running" ;;
            "lock_stale_hint") echo "The recorded owner process is gone; the lock looks stale (left over from an unclean exit)" ;;
            "lock_stale_action") echo "If no proxy-hub write operation is running, remove the stale lock with:" ;;
            "enable_xhttp") echo "Enable XHTTP protocol? (y/n)" ;;
            "xhttp_enabled") echo "XHTTP protocol enabled" ;;
            "detecting_ip") echo "Detecting server IP..." ;;
            "tools_menu") echo "System Optimization Tools" ;;
            "menu_timesync") echo "Time Sync" ;;
            "timesync_title") echo "System Time Sync" ;;
            "timesync_status") echo "Sync Status" ;;
            "timesync_current") echo "Current Time" ;;
            "timesync_timezone") echo "Timezone" ;;
            "timesync_install") echo "Install & Enable Time Sync" ;;
            "timesync_force") echo "Force Sync Now" ;;
            "timesync_uninstall") echo "Remove Time Sync" ;;
            "timesync_not_installed") echo "Not Installed" ;;
            "timesync_synced") echo "Synchronized" ;;
            "timesync_installing") echo "Installing time sync service..." ;;
            "timesync_installed") echo "Time sync service installed and enabled" ;;
            "timesync_forcing") echo "Forcing time synchronization..." ;;
            "timesync_forced") echo "Time synchronized successfully" ;;
            "timesync_removing") echo "Removing time sync service..." ;;
            "timesync_removed") echo "Time sync service removed" ;;
            "timesync_already") echo "Time sync service is already installed" ;;
            "timesync_ss2022_hint") echo "SS2022 requires accurate system time. Choose how to verify or enable synchronization." ;;
            "timesync_env") echo "Environment" ;;
            "timesync_container_warn") echo "Container environment detected - time sync may not work" ;;
            "timesync_container_type") echo "Container type" ;;
            "timesync_container_detail") echo "Containers share the host kernel clock. Time sync should run on the host." ;;
            "timesync_pve_title") echo "Proxmox VE / LXC solutions" ;;
            "timesync_pve_method1") echo "Method 1: Sync time on the PVE host (recommended)" ;;
            "timesync_pve_host_tip") echo "Run chrony/ntpdate on the PVE host, all containers will inherit the time." ;;
            "timesync_pve_method2") echo "Method 2: Grant SYS_TIME capability to this container" ;;
            "timesync_pve_cap_step1") echo "Edit the container config on the PVE host:" ;;
            "timesync_pve_cap_step2") echo "Add this line:" ;;
            "timesync_pve_cap_step3") echo "Then restart the container and try again." ;;
            "timesync_docker_tip") echo "Run the container with SYS_TIME capability:" ;;
            "timesync_try_anyway") echo "Try to install anyway?" ;;
            "timesync_start_failed") echo "Chrony service failed to start!" ;;
            "timesync_check_log") echo "Error log" ;;
            "timesync_check") echo "Check Time Accuracy (no privileges needed)" ;;
            "timesync_checking") echo "Checking time accuracy via HTTP..." ;;
            "timesync_offset") echo "Time offset" ;;
            "timesync_offset_ok") echo "Time is accurate. SS2022 will work normally." ;;
            "timesync_offset_warn") echo "Time offset is large! SS2022 connections may fail." ;;
            "timesync_offset_fail") echo "Failed to fetch remote time. Check network connectivity." ;;
            "timesync_container_no_host") echo "No host access? You can only verify time, not change it." ;;
            "timesync_seconds") echo "seconds" ;;
            "timesync_skip") echo "Skip" ;;
            "update_ip") echo "Update Node IP" ;;
            "update_ip_detecting") echo "Detecting current public IP..." ;;
            "update_ip_current") echo "Current IP" ;;
            "update_ip_stored") echo "Stored IP" ;;
            "update_ip_no_nodes") echo "No nodes configured" ;;
            "update_ip_no_change") echo "IP has not changed, no update needed" ;;
            "update_ip_changed") echo "IP change detected!" ;;
            "update_ip_updating") echo "Updating node configurations..." ;;
            "update_ip_node_updated") echo "Updated node" ;;
            "update_ip_done") echo "All node IPs updated successfully" ;;
            "update_ip_regen") echo "Regenerating Xray config..." ;;
            "update_ip_restarting") echo "Restarting Xray service..." ;;
            "update_ip_complete") echo "IP update complete! New share links will use the updated IP." ;;
            "update_ip_detect_fail") echo "Failed to detect current public IP" ;;
            # Xray 定时重启
            "xray_restart_title") echo "Proxy Service Periodic Restart" ;;
            "xray_restart_prompt") echo "Enable periodic restart of the proxy service(s)? (recommended for long-running stability)" ;;
            "xray_restart_choose") echo "Choose restart schedule" ;;
            "xray_restart_default") echo "default" ;;
            "xray_restart_daily") echo "Daily at 04:00" ;;
            "xray_restart_12h") echo "Every 12 hours" ;;
            "xray_restart_6h") echo "Every 6 hours" ;;
            "xray_restart_weekly") echo "Weekly (Sun 04:00)" ;;
            "xray_restart_custom") echo "Custom cron expression" ;;
            "xray_restart_cron_hint") echo "Format: 'minute hour day month weekday' (e.g. '0 3 * * *')" ;;
            "xray_restart_cron_prompt") echo "Enter cron expression" ;;
            "xray_restart_cron_invalid") echo "Invalid cron expression, falling back to daily" ;;
            "xray_restart_enabled") echo "Proxy service periodic restart enabled" ;;
            "xray_restart_disabled") echo "Proxy service periodic restart disabled" ;;
            "xray_restart_not_enabled") echo "Periodic restart is not currently enabled" ;;
            "xray_restart_already") echo "Periodic restart already enabled" ;;
            "xray_restart_setup_failed") echo "Failed to set up periodic restart (crontab or systemd unavailable)" ;;
            "xray_restart_status") echo "Status" ;;
            "xray_restart_status_on") echo "Enabled" ;;
            "xray_restart_status_off") echo "Disabled" ;;
            "xray_restart_current") echo "Current schedule" ;;
            "xray_restart_backend") echo "Backend" ;;
            "xray_restart_action_set") echo "Enable / Modify schedule" ;;
            "xray_restart_action_disable") echo "Disable periodic restart" ;;
            "xray_restart_back") echo "Back" ;;
            "xray_release_title") echo "Xray Version / Update" ;;
            "xray_release_show_status") echo "Show version status" ;;
            "xray_release_update_stable") echo "Update to latest stable" ;;
            "xray_release_update_latest") echo "Update to latest release including prerelease" ;;
            "xray_release_install_version") echo "Install specified version" ;;
            "xray_release_latest_stable") echo "Latest stable" ;;
            "xray_release_latest_all") echo "Latest release, including prerelease" ;;
            "xray_release_specify") echo "Specify version" ;;
            "xray_release_version_prompt") echo "Xray version (for example v26.7.11)" ;;
            "xray_release_cancel") echo "Cancel" ;;
            "xray_release_back") echo "Back" ;;
            *) echo "$key" ;;
        esac
    else
        case "$key" in
            "menu_title") echo "VLESS TCP REALITY Vision 管理面板" ;;
            "menu_install") echo "安装节点" ;;
            "menu_info") echo "查看节点信息" ;;
            "menu_qr") echo "显示二维码" ;;
            "menu_status") echo "服务状态" ;;
            "menu_health") echo "健康检查" ;;
            "menu_restart") echo "重启服务" ;;
            "menu_test_sni") echo "测试 SNI 延迟" ;;
            "menu_uninstall") echo "卸载节点" ;;
            "menu_lang") echo "切换语言" ;;
            "menu_exit") echo "退出" ;;
            "menu_choice") echo "请输入选项" ;;
            "menu_invalid") echo "无效选项，请重新输入" ;;
            "menu_press_enter") echo "按 Enter 键继续..." ;;
            "lang_select") echo "Select Language / 选择语言" ;;
            "lang_zh") echo "中文" ;;
            "lang_en") echo "English (英文)" ;;
            "installing") echo "开始安装 VLESS TCP REALITY Vision..." ;;
            "install_deps") echo "安装依赖..." ;;
            "install_xray") echo "安装 Xray..." ;;
            "gen_keys") echo "生成 Reality 密钥..." ;;
            "testing_sni") echo "测试所有 SNI 域名延迟..." ;;
            "testing") echo "测试中..." ;;
            "test_progress") echo "进度" ;;
            "current") echo "当前" ;;
            "sni_timeout") echo "所有测试域名均超时，使用默认 SNI: www.tesla.com" ;;
            "sni_selected") echo "选择最优 SNI" ;;
            "sni_multiple") echo "多个域名具有相同的最低延迟" ;;
            "sni_choose") echo "请选择一个" ;;
            "latency") echo "延迟" ;;
            "install_complete") echo "安装完成！" ;;
            "uninstalling") echo "开始卸载..." ;;
            "uninstall_complete") echo "卸载完成" ;;
            "config_not_found") echo "未找到配置文件，请先运行安装" ;;
            "run_as_root") echo "请使用 root 用户运行此脚本" ;;
            "node_info") echo "VLESS Reality Vision 节点信息" ;;
            "node_info_suffix") echo "节点信息" ;;
            "server_addr") echo "服务器地址" ;;
            "port") echo "端口" ;;
            "share_link") echo "分享链接" ;;
            "qr_title") echo "节点二维码（扫码导入）" ;;
            "qr_tip") echo "提示: 可运行 'bash $0 qr' 重新生成二维码" ;;
            "common_cmds") echo "常用命令" ;;
            "view_info") echo "查看节点信息" ;;
            "show_qr") echo "显示二维码" ;;
            "service_status") echo "服务状态" ;;
            "service_restarted") echo "服务已重启" ;;
            "test_complete") echo "测试完成" ;;
            "timeout") echo "超时" ;;
            "using_sni") echo "使用指定 SNI" ;;
            "installed") echo "已安装" ;;
            "not_installed") echo "未安装" ;;
            "total_domains") echo "域名总数" ;;
            "best_latency") echo "最低延迟" ;;
            "health_check") echo "健康检查" ;;
            "connections") echo "当前连接数" ;;
            "sni_selection_title") echo "SNI 域名选择" ;;
            "sni_top_results") echo "延迟最低的 5 个域名" ;;
            "sni_auto_select") echo "自动选择最佳" ;;
            "sni_manual_input") echo "输入自定义域名" ;;
            "sni_custom_test") echo "测试自定义域名（逗号分隔多个）" ;;
            "sni_custom_test_hint") echo "输入要测试的域名，用逗号分隔（如 a.com,b.com,c.com）" ;;
            "sni_custom_test_done") echo "自定义域名测试完成，请从上方结果中选择" ;;
            "sni_choice_prompt") echo "请选择" ;;
            "sni_no_results") echo "没有可用的测试结果" ;;
            "sni_use_default") echo "使用默认" ;;
            "sni_input_hint") echo "输入域名 (例如 www.microsoft.com)" ;;
            "sni_empty_input") echo "输入为空" ;;
            "sni_custom_set") echo "已设置自定义 SNI" ;;
            "sni_testing_custom") echo "测试连通性" ;;
            "sni_custom_ok") echo "域名可访问" ;;
            "sni_custom_unreachable") echo "域名可能无法访问，但仍会使用" ;;
            "sni_invalid_format") echo "域名格式无效" ;;
            "anytls_sni_note") echo "提示：单独 AnyTLS 的 SNI 仅作 TLS 伪装（自签证书，客户端用 insecure），测速结果仅供参考。" ;;
            # 新功能翻译
            "menu_tools") echo "系统工具" ;;
            "menu_warp") echo "WARP 分流" ;;
            "menu_bbr") echo "BBR 管理" ;;
            "menu_swap") echo "Swap 管理" ;;
            "menu_fail2ban") echo "Fail2ban 管理" ;;
            "install_geodata") echo "安装 GeoIP/GeoSite 数据库..." ;;
            "geodata_updated") echo "GeoData 数据库已更新" ;;
            "xhttp_port") echo "XHTTP 端口" ;;
            "vision_port") echo "Vision 端口" ;;
            "ipv4_links") echo "IPv4 链接" ;;
            "ipv6_links") echo "IPv6 链接" ;;
            "warp_status") echo "WARP 状态" ;;
            "warp_running") echo "运行中" ;;
            "warp_stopped") echo "已停止" ;;
            "warp_install") echo "安装 WARP" ;;
            "warp_uninstall") echo "卸载 WARP" ;;
            "warp_netflix") echo "Netflix 分流" ;;
            "warp_ai") echo "AI 服务分流" ;;
            "bbr_enabled") echo "BBR 已启用" ;;
            "bbr_disabled") echo "BBR 未启用" ;;
            "swap_size") echo "Swap 大小" ;;
            "fail2ban_status") echo "Fail2ban 状态" ;;
            "script_running") echo "脚本已在运行中！" ;;
            "lock_owner_alive") echo "检测到另一个实例正在运行" ;;
            "lock_stale_hint") echo "锁记录的进程已不存在，可能是上次异常退出残留的锁" ;;
            "lock_stale_action") echo "确认没有 proxy-hub 写操作在运行后，可用以下命令清理残留锁：" ;;
            "enable_xhttp") echo "是否启用 XHTTP 协议？(y/n)" ;;
            "xhttp_enabled") echo "XHTTP 协议已启用" ;;
            "detecting_ip") echo "检测服务器 IP..." ;;
            "tools_menu") echo "系统优化工具" ;;
            "menu_timesync") echo "时间同步" ;;
            "timesync_title") echo "系统时间同步" ;;
            "timesync_status") echo "同步状态" ;;
            "timesync_current") echo "当前时间" ;;
            "timesync_timezone") echo "时区" ;;
            "timesync_install") echo "安装并启用时间同步" ;;
            "timesync_force") echo "立即强制同步" ;;
            "timesync_uninstall") echo "卸载时间同步" ;;
            "timesync_not_installed") echo "未安装" ;;
            "timesync_synced") echo "已同步" ;;
            "timesync_installing") echo "正在安装时间同步服务..." ;;
            "timesync_installed") echo "时间同步服务已安装并启用" ;;
            "timesync_forcing") echo "正在强制同步时间..." ;;
            "timesync_forced") echo "时间同步成功" ;;
            "timesync_removing") echo "正在卸载时间同步服务..." ;;
            "timesync_removed") echo "时间同步服务已卸载" ;;
            "timesync_already") echo "时间同步服务已安装" ;;
            "timesync_ss2022_hint") echo "SS2022 需要精确的系统时间，请选择校验或启用时间同步。" ;;
            "timesync_env") echo "运行环境" ;;
            "timesync_container_warn") echo "检测到容器环境 - 时间同步可能无法工作" ;;
            "timesync_container_type") echo "容器类型" ;;
            "timesync_container_detail") echo "容器与宿主机共享内核时钟，时间同步应在宿主机上进行。" ;;
            "timesync_pve_title") echo "Proxmox VE / LXC 解决方案" ;;
            "timesync_pve_method1") echo "方法一: 在 PVE 宿主机上同步时间 (推荐)" ;;
            "timesync_pve_host_tip") echo "在 PVE 宿主机运行 chrony/ntpdate，所有容器自动继承。" ;;
            "timesync_pve_method2") echo "方法二: 给此容器授权 SYS_TIME 能力" ;;
            "timesync_pve_cap_step1") echo "在 PVE 宿主机上编辑容器配置:" ;;
            "timesync_pve_cap_step2") echo "添加以下行:" ;;
            "timesync_pve_cap_step3") echo "然后重启容器，再次尝试安装。" ;;
            "timesync_docker_tip") echo "使用 SYS_TIME 能力运行容器:" ;;
            "timesync_try_anyway") echo "仍然尝试安装？" ;;
            "timesync_start_failed") echo "Chrony 服务启动失败！" ;;
            "timesync_check_log") echo "错误日志" ;;
            "timesync_check") echo "检查时间准确度 (无需特权)" ;;
            "timesync_checking") echo "正在通过 HTTP 校验时间..." ;;
            "timesync_offset") echo "时间偏差" ;;
            "timesync_offset_ok") echo "时间准确，SS2022 可正常工作。" ;;
            "timesync_offset_warn") echo "时间偏差较大！SS2022 连接可能失败。" ;;
            "timesync_offset_fail") echo "无法获取远程时间，请检查网络连接。" ;;
            "timesync_container_no_host") echo "没有宿主机权限？只能校验时间，无法修改。" ;;
            "timesync_seconds") echo "秒" ;;
            "timesync_skip") echo "跳过" ;;
            "update_ip") echo "更新节点 IP" ;;
            "update_ip_detecting") echo "正在检测当前公网 IP..." ;;
            "update_ip_current") echo "当前 IP" ;;
            "update_ip_stored") echo "已存储 IP" ;;
            "update_ip_no_nodes") echo "未配置任何节点" ;;
            "update_ip_no_change") echo "IP 未变更，无需更新" ;;
            "update_ip_changed") echo "检测到 IP 变更！" ;;
            "update_ip_updating") echo "正在更新节点配置..." ;;
            "update_ip_node_updated") echo "已更新节点" ;;
            "update_ip_done") echo "所有节点 IP 已更新完成" ;;
            "update_ip_regen") echo "正在重新生成 Xray 配置..." ;;
            "update_ip_restarting") echo "正在重启 Xray 服务..." ;;
            "update_ip_complete") echo "IP 更新完成！分享链接将使用新的 IP 地址。" ;;
            "update_ip_detect_fail") echo "无法检测当前公网 IP" ;;
            # Xray 定时重启
            "xray_restart_title") echo "代理服务定时重启" ;;
            "xray_restart_prompt") echo "是否启用代理服务定时重启？（长期运行建议启用）" ;;
            "xray_restart_choose") echo "请选择重启频率" ;;
            "xray_restart_default") echo "默认" ;;
            "xray_restart_daily") echo "每日一次 (04:00)" ;;
            "xray_restart_12h") echo "每 12 小时一次" ;;
            "xray_restart_6h") echo "每 6 小时一次" ;;
            "xray_restart_weekly") echo "每周一次 (周日 04:00)" ;;
            "xray_restart_custom") echo "自定义 cron 表达式" ;;
            "xray_restart_cron_hint") echo "格式: '分 时 日 月 周'（例如 '0 3 * * *' 表示每日 03:00）" ;;
            "xray_restart_cron_prompt") echo "请输入 cron 表达式" ;;
            "xray_restart_cron_invalid") echo "cron 表达式无效，已回退到默认（每日）" ;;
            "xray_restart_enabled") echo "已启用代理服务定时重启" ;;
            "xray_restart_disabled") echo "已禁用代理服务定时重启" ;;
            "xray_restart_not_enabled") echo "当前未启用定时重启" ;;
            "xray_restart_already") echo "已启用定时重启" ;;
            "xray_restart_setup_failed") echo "定时重启配置失败（crontab 或 systemd 不可用）" ;;
            "xray_restart_status") echo "状态" ;;
            "xray_restart_status_on") echo "已启用" ;;
            "xray_restart_status_off") echo "未启用" ;;
            "xray_restart_current") echo "当前计划" ;;
            "xray_restart_backend") echo "后端" ;;
            "xray_restart_action_set") echo "启用 / 修改计划" ;;
            "xray_restart_action_disable") echo "禁用定时重启" ;;
            "xray_restart_back") echo "返回" ;;
            "xray_release_title") echo "Xray 版本 / 更新" ;;
            "xray_release_show_status") echo "显示版本状态" ;;
            "xray_release_update_stable") echo "更新到最新稳定版" ;;
            "xray_release_update_latest") echo "更新到最新版本（含预发布版）" ;;
            "xray_release_install_version") echo "安装指定版本" ;;
            "xray_release_latest_stable") echo "最新稳定版" ;;
            "xray_release_latest_all") echo "最新版本（含预发布版）" ;;
            "xray_release_specify") echo "指定版本" ;;
            "xray_release_version_prompt") echo "Xray 版本（例如 v26.7.11）" ;;
            "xray_release_cancel") echo "取消" ;;
            "xray_release_back") echo "返回" ;;
            *) echo "$key" ;;
        esac
    fi
}

log_info() { echo -e "${GREEN}[INFO]${NC} $1" >&2; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

is_root() { [[ "${EUID}" -eq 0 ]]; }

is_port_free() {
    local port="$1"
    local transport="${2:-tcp}"
    local tcp_busy=false udp_busy=false

    [[ "$port" =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535)) || return 1
    case "$transport" in
        tcp|udp|both) ;;
        *) return 1 ;;
    esac

    # 更精确的端口匹配：检查 :port 结尾，避免 80 匹配 8080。
    if [[ "$transport" == "tcp" || "$transport" == "both" ]]; then
        ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE ":${port}$" && tcp_busy=true
    fi
    if [[ "$transport" == "udp" || "$transport" == "both" ]]; then
        ss -lnu 2>/dev/null | awk '{print $4}' | grep -qE ":${port}$" && udp_busy=true
    fi

    ! $tcp_busy && ! $udp_busy
}

# ============== 多节点管理 ==============

# 初始化节点目录
init_nodes_dir() {
    mkdir -p "$NODES_DIR"
    chmod 700 "$NODES_DIR"
}

# 获取节点配置文件路径
get_node_file() {
    local node_name="$1"
    echo "${NODES_DIR}/${node_name}.env"
}

# 列出所有节点
list_nodes() {
    local nodes=()
    if [[ -d "$NODES_DIR" ]]; then
        for f in "$NODES_DIR"/*.env; do
            [[ -f "$f" ]] || continue
            local name
            name=$(basename "$f" .env)
            nodes+=("$name")
        done
    fi
    echo "${nodes[@]}"
}

# 获取节点数量
count_nodes() {
    local count=0
    if [[ -d "$NODES_DIR" ]]; then
        count=$(find "$NODES_DIR" -maxdepth 1 -name "*.env" 2>/dev/null | wc -l)
    fi
    echo "$count"
}

# 检查节点是否存在
node_exists() {
    local node_name="$1"
    [[ -f "$(get_node_file "$node_name")" ]]
}

# 生成随机节点名称
generate_random_name() {
    echo "node_$(openssl rand -hex 4)"
}

# 交互式输入节点名称
prompt_node_name() {
    local default_name
    default_name=$(generate_random_name)

    echo "" >/dev/tty
    echo -e "${CYAN}Enter node name (press Enter for random):${NC}" >/dev/tty
    echo -e "${CYAN}输入节点名称（直接回车使用随机名称）:${NC}" >/dev/tty
    echo -n "  [$default_name]: " >/dev/tty
    read -r input_name </dev/tty

    local node_name="${input_name:-$default_name}"

    # 清理非法字符，只保留字母、数字、下划线、短横线
    node_name=$(echo "$node_name" | tr -cd 'a-zA-Z0-9_-')

    # 如果名称已存在，添加后缀
    local base_name="$node_name"
    local counter=1
    while node_exists "$node_name"; do
        node_name="${base_name}_${counter}"
        ((counter++))
    done

    echo "$node_name"
}

# 选择节点（交互式）
select_node() {
    local nodes
    read -ra nodes <<< "$(list_nodes)"
    local count=${#nodes[@]}

    if [[ $count -eq 0 ]]; then
        log_error "$(msg config_not_found)"
        return 1
    fi

    if [[ $count -eq 1 ]]; then
        CURRENT_NODE_NAME="${nodes[0]}"
        return 0
    fi

    echo "" >/dev/tty
    echo -e "${CYAN}Available nodes / 可用节点:${NC}" >/dev/tty
    echo "" >/dev/tty

    local i=1
    for node in "${nodes[@]}"; do
        local node_file
        node_file=$(get_node_file "$node")
        # 使用安全的配置加载（防止命令注入）
        safe_load_node_config "$node_file"
        # 根据协议类型显示对应的端口
        local display_port=""
        local proto="${PROTOCOL_TYPE:-vision}"
        local display_info=""
        if [[ "$proto" == "shadowsocks" ]]; then
            display_port="${PORT:-N/A}"
            display_info="Method: ${SS_METHOD:-N/A}"
        elif [[ "$proto" == "hysteria2" ]]; then
            display_port="${PORT:-N/A} (UDP)"
            display_info="Hysteria2"
        elif [[ "$proto" == "xhttp" ]]; then
            display_port="${XHTTP_PORT:-N/A}"
            display_info="SNI: $SNI"
        elif [[ "$proto" == "both" ]]; then
            display_port="${PORT:-}/${XHTTP_PORT:-}"
            display_info="SNI: $SNI"
        else
            display_port="${PORT:-N/A}"
            display_info="SNI: $SNI"
        fi
        echo -e "  ${GREEN}$i.${NC} $node (Port: $display_port, $display_info)" >/dev/tty
        ((i++))
    done

    echo "" >/dev/tty
    echo -n "  Select node / 选择节点 [1-$count]: " >/dev/tty
    read -r choice </dev/tty

    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le $count ]]; then
        CURRENT_NODE_NAME="${nodes[$((choice - 1))]}"
    else
        CURRENT_NODE_NAME="${nodes[0]}"
    fi

    return 0
}

# 加载语言设置
load_lang() {
    if [[ -f "$LANG_FILE" ]]; then
        CURRENT_LANG=$(cat "$LANG_FILE")
    fi
}

# 保存语言设置
save_lang() {
    echo "$CURRENT_LANG" > "$LANG_FILE"
    chmod 600 "$LANG_FILE"
}

# 语言选择界面
select_language() {
    clear
    {
    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}           ${YELLOW}Select Language / 选择语言${NC}                        ${CYAN}║${NC}"
    echo -e "${CYAN}╠═══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC}                                                               ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   ${GREEN}1.${NC} 中文 (Chinese)                                         ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   ${GREEN}2.${NC} English                                                ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}                                                               ${CYAN}║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -n "   请选择 / Please choose [1-2]: "
    } >/dev/tty
    read -r lang_choice </dev/tty

    case "$lang_choice" in
        1)
            CURRENT_LANG="zh"
            ;;
        2)
            CURRENT_LANG="en"
            ;;
        *)
            CURRENT_LANG="zh"
            ;;
    esac
    save_lang
}

# Resolve a temporary parent that cannot be renamed by an unrelated user:
# either a private directory owned by this process UID or a root-owned sticky
# directory such as /tmp.
secure_resolve_tmp_parent() {
    local candidate="${1:-${TMPDIR:-/tmp}}" resolved current owner mode
    [[ "$candidate" != *$'\n'* && "$candidate" != *$'\r'* &&
       -d "$candidate" && ! -L "$candidate" && -w "$candidate" ]] || return 1
    resolved=$(cd -P -- "$candidate" 2>/dev/null && pwd) || return 1
    current="$resolved"
    while :; do
        [[ -d "$current" && ! -L "$current" ]] || return 1
        owner=$(stat -c '%u' "$current" 2>/dev/null) || return 1
        mode=$(stat -c '%a' "$current" 2>/dev/null) || return 1
        [[ "$mode" =~ ^[0-7]+$ ]] || return 1
        if [[ "$owner" == "$EUID" || "$owner" == 0 ]] && (((8#$mode & 022) == 0)); then
            :
        elif [[ "$owner" == 0 ]] && (((8#$mode & 01000) != 0)); then
            :
        else
            return 1
        fi
        [[ "$current" == / ]] && break
        current=$(dirname "$current") || return 1
    done
    SECURE_TMP_PARENT="$resolved"
}

identity_bound_tmp_create() {
    local parent="$1" prefix="$2" path owner identity
    [[ "$prefix" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    secure_resolve_tmp_parent "$parent" || return 1
    parent="$SECURE_TMP_PARENT"
    path=$(mktemp -d "${parent%/}/${prefix}XXXXXXXX") || return 1
    [[ -d "$path" && ! -L "$path" ]] || { rmdir -- "$path" 2>/dev/null || true; return 1; }
    owner=$(stat -c '%u' "$path" 2>/dev/null) || { rmdir -- "$path"; return 1; }
    [[ "$owner" == "$EUID" ]] || { rmdir -- "$path"; return 1; }
    chmod 0700 "$path" || { rmdir -- "$path"; return 1; }
    identity=$(stat -c '%d:%i' "$path" 2>/dev/null) || { rmdir -- "$path"; return 1; }
    IDENTITY_TMP_PATH="$path"
    IDENTITY_TMP_ID="$identity"
    IDENTITY_TMP_PARENT="$parent"
}

identity_bound_tmp_intact() {
    local path="$1" expected_id="$2" parent="$3" prefix="$4" owner current_id
    [[ "$path" == "${parent%/}/${prefix}"* && -d "$path" && ! -L "$path" ]] || return 1
    owner=$(stat -c '%u' "$path" 2>/dev/null) || return 1
    current_id=$(stat -c '%d:%i' "$path" 2>/dev/null) || return 1
    [[ "$owner" == "$EUID" && "$current_id" == "$expected_id" ]]
}

identity_bound_tmp_cleanup() {
    local path="$1" expected_id="$2" parent="$3" prefix="$4"
    [[ -n "$path" ]] || return 0
    identity_bound_tmp_intact "$path" "$expected_id" "$parent" "$prefix" || return 1
    rm -rf -- "$path"
}

# ============== Xray release management ==============

XRAY_REPO="XTLS/Xray-core"
XRAY_RELEASE_API="https://api.github.com/repos/${XRAY_REPO}/releases"
XRAY_BACKUP_KEEP="${XRAY_BACKUP_KEEP:-3}"
XRAY_MAX_RELEASE_BYTES=$((128 * 1024 * 1024))
XRAY_MAX_ARCHIVE_MEMBERS=256
# Production paths ignore inherited values; isolated tests may reassign them after sourcing.
XRAY_LIFECYCLE_LOCK="/run/proxy-hub-xray-lifecycle.lock"
XRAY_UPDATE_STATE_FILE="/var/lib/proxy-hub/xray-update.state"
XRAY_PRODUCTION_LIFECYCLE_LOCK="/run/proxy-hub-xray-lifecycle.lock"
XRAY_PRODUCTION_UPDATE_STATE_FILE="/var/lib/proxy-hub/xray-update.state"
XRAY_REQUEST_OVERRIDE_SET=0
XRAY_REQUEST_VERSION_OVERRIDE=""
XRAY_REQUEST_CHANNEL_OVERRIDE=""
xray_requested_version() {
    if ((XRAY_REQUEST_OVERRIDE_SET)); then
        printf '%s\n' "$XRAY_REQUEST_VERSION_OVERRIDE"
    elif [[ -n "${XRAY_VERSION:-}" ]]; then
        printf '%s\n' "$XRAY_VERSION"
    elif [[ -n "${xray_version:-}" ]]; then
        printf '%s\n' "$xray_version"
    fi
}
xray_requested_channel() {
    if ((XRAY_REQUEST_OVERRIDE_SET)); then
        printf '%s\n' "$XRAY_REQUEST_CHANNEL_OVERRIDE"
    elif [[ -n "${XRAY_CHANNEL:-}" ]]; then
        printf '%s\n' "$XRAY_CHANNEL"
    elif [[ -n "${xray_channel:-}" ]]; then
        printf '%s\n' "$xray_channel"
    fi
}
normalize_xray_version() {
    local raw="${1:-}"
    [[ "$raw" =~ ^v?[0-9]+(\.[0-9]+){1,3}([.-][A-Za-z0-9._-]+)?$ ]] || return 1
    [[ "$raw" == v* ]] || raw="v$raw"
    printf '%s\n' "$raw"
}
_xray_parse_version() {
    local normalized body
    normalized=$(normalize_xray_version "${1:-}") || return 1
    body="${normalized#v}"
    XRAY_PARSED_SUFFIX=""
    if [[ "$body" =~ ^([0-9]+(\.[0-9]+){1,3})([.-][A-Za-z0-9._-]+)?$ ]]; then
        XRAY_PARSED_CORE="${BASH_REMATCH[1]}"
        XRAY_PARSED_SUFFIX="${BASH_REMATCH[3]:-}"
        return 0
    fi
    return 1
}
_xray_trim_numeric() {
    local value="${1:-0}"
    while [[ ${#value} -gt 1 && "$value" == 0* ]]; do
        value="${value#0}"
    done
    printf '%s\n' "$value"
}
_xray_compare_numeric_string() {
    local left right
    left=$(_xray_trim_numeric "$1")
    right=$(_xray_trim_numeric "$2")
    if ((${#left} < ${#right})); then
        printf '%s\n' -1
    elif ((${#left} > ${#right})); then
        printf '%s\n' 1
    elif [[ "$left" == "$right" ]]; then
        printf '%s\n' 0
    elif [[ "$left" < "$right" ]]; then
        printf '%s\n' -1
    else
        printf '%s\n' 1
    fi
}
_xray_take_natural_run() {
    local value="$1" run
    if [[ "$value" =~ ^([0-9]+) ]]; then
        run="${BASH_REMATCH[1]}"
        XRAY_NATURAL_KIND="number"
    elif [[ "$value" =~ ^([^0-9]+) ]]; then
        run="${BASH_REMATCH[1]}"
        XRAY_NATURAL_KIND="text"
    else
        return 1
    fi
    XRAY_NATURAL_RUN="$run"
    XRAY_NATURAL_REST="${value:${#run}}"
}
_xray_compare_suffixes() {
    local left="${1#[-.]}" right="${2#[-.]}" left_kind left_run cmp
    while [[ -n "$left" || -n "$right" ]]; do
        [[ -n "$left" ]] || { printf '%s\n' -1; return 0; }
        [[ -n "$right" ]] || { printf '%s\n' 1; return 0; }
        _xray_take_natural_run "$left" || return 1
        left_kind="$XRAY_NATURAL_KIND"
        left_run="$XRAY_NATURAL_RUN"
        left="$XRAY_NATURAL_REST"
        _xray_take_natural_run "$right" || return 1
        if [[ "$left_kind" != "$XRAY_NATURAL_KIND" ]]; then
            [[ "$left_kind" == "number" ]] && printf '%s\n' -1 || printf '%s\n' 1
            return 0
        fi
        if [[ "$left_kind" == "number" ]]; then
            cmp=$(_xray_compare_numeric_string "$left_run" "$XRAY_NATURAL_RUN") || return 1
        elif [[ "$left_run" == "$XRAY_NATURAL_RUN" ]]; then
            cmp=0
        elif [[ "$left_run" < "$XRAY_NATURAL_RUN" ]]; then
            cmp=-1
        else
            cmp=1
        fi
        [[ "$cmp" == 0 ]] || { printf '%s\n' "$cmp"; return 0; }
        right="$XRAY_NATURAL_REST"
    done
    printf '%s\n' 0
}
xray_compare_versions() {
    local left right left_core left_suffix right_core right_suffix cmp i sorted_first
    local -a left_parts right_parts
    left=$(normalize_xray_version "$1") || return 1
    right=$(normalize_xray_version "$2") || return 1
    _xray_parse_version "$left" || return 1
    left_core="$XRAY_PARSED_CORE"
    left_suffix="$XRAY_PARSED_SUFFIX"
    _xray_parse_version "$right" || return 1
    right_core="$XRAY_PARSED_CORE"
    right_suffix="$XRAY_PARSED_SUFFIX"
    if [[ -z "$left_suffix" && -z "$right_suffix" ]] && sort -V </dev/null >/dev/null 2>&1; then
        if [[ "$left" == "$right" ]]; then
            printf '%s\n' 0
            return 0
        fi
        sorted_first=$(printf '%s\n%s\n' "$left" "$right" | LC_ALL=C sort -V | head -n 1) || return 1
        [[ "$sorted_first" == "$left" ]] && printf '%s\n' -1 || printf '%s\n' 1
        return 0
    fi
    IFS=. read -r -a left_parts <<< "$left_core"
    IFS=. read -r -a right_parts <<< "$right_core"
    for i in 0 1 2 3; do
        cmp=$(_xray_compare_numeric_string "${left_parts[$i]:-0}" "${right_parts[$i]:-0}") || return 1
        [[ "$cmp" == 0 ]] || { printf '%s\n' "$cmp"; return 0; }
    done
    if [[ -z "$left_suffix" && -z "$right_suffix" ]]; then
        printf '%s\n' 0
    elif [[ -z "$left_suffix" ]]; then
        printf '%s\n' 1
    elif [[ -z "$right_suffix" ]]; then
        printf '%s\n' -1
    else
        _xray_compare_suffixes "$left_suffix" "$right_suffix"
    fi
}
compare_xray_versions() {
    xray_compare_versions "$@"
}
map_xray_arch() {
    local arch="${1:-}"
    [[ -n "$arch" ]] || arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) printf '%s\n' 64 ;;
        aarch64|arm64) printf '%s\n' arm64-v8a ;;
        armv7l|armv7) printf '%s\n' arm32-v7a ;;
        i386|i486|i586|i686|386) printf '%s\n' 32 ;;
        armv5*|arm32-v5) printf '%s\n' arm32-v5 ;;
        armv6*|arm32-v6) printf '%s\n' arm32-v6 ;;
        riscv64|s390x|ppc64le) printf '%s\n' "$arch" ;;
        *)
            log_error "Unsupported Xray architecture: $arch"
            return 1
            ;;
    esac
}

xray_github_api() {
    local url="$1"
    secure_curl --connect-timeout 10 --max-time 30 \
        -H 'Accept: application/vnd.github+json' \
        -H 'X-GitHub-Api-Version: 2022-11-28' "$url"
}

_xray_require_jq() {
    command -v jq >/dev/null 2>&1 || {
        log_error "jq is required to parse GitHub release metadata safely"
        return 1
    }
}

get_xray_stable_version() {
    local response tag normalized
    _xray_require_jq || return 1
    if ! response=$(xray_github_api "$XRAY_RELEASE_API/latest" 2>/dev/null); then
        log_error "GitHub API request for the latest stable Xray release failed (network or rate limit)"
        return 1
    fi
    if ! jq -e 'type == "object" and .draft == false and .prerelease == false and
        (.tag_name | type == "string") and (.published_at | type == "string")' \
        >/dev/null 2>&1 <<< "$response"; then
        log_error "GitHub returned incomplete stable Xray release metadata"
        return 1
    fi
    tag=$(jq -r '.tag_name' <<< "$response") || return 1
    normalized=$(normalize_xray_version "$tag") || {
        log_error "GitHub returned an invalid stable Xray tag"
        return 1
    }
    printf '%s\n' "$normalized"
}

get_xray_latest_version() {
    local page response count published tag normalized best_date="" best_tag="" line
    _xray_require_jq || return 1
    for page in 1 2 3; do
        if ! response=$(xray_github_api "$XRAY_RELEASE_API?per_page=100&page=$page" 2>/dev/null); then
            log_error "GitHub API request for Xray releases page $page failed (network or rate limit)"
            return 1
        fi
        jq -e 'type == "array"' >/dev/null 2>&1 <<< "$response" || {
            log_error "GitHub returned malformed Xray release-list metadata"
            return 1
        }
        count=$(jq 'length' <<< "$response") || return 1
        while IFS=$'\t' read -r published tag; do
            [[ -n "$published" && -n "$tag" ]] || continue
            [[ "$published" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.+-]+Z$ ]] || continue
            normalized=$(normalize_xray_version "$tag") || continue
            if [[ -z "$best_date" || "$published" > "$best_date" || \
                  ( "$published" == "$best_date" && "$normalized" > "$best_tag" ) ]]; then
                best_date="$published"
                best_tag="$normalized"
            fi
        done < <(jq -r '.[] | select(.draft == false and (.published_at | type == "string") and
            (.tag_name | type == "string")) | [.published_at, .tag_name] | @tsv' <<< "$response")
        ((count < 100)) && break
        if ((page == 3)); then
            log_error "Xray release pagination exceeded the safe lookup bound"
            return 1
        fi
    done
    [[ -n "$best_tag" ]] || {
        log_error "No published non-draft Xray release was found"
        return 1
    }
    printf '%s\n' "$best_tag"
}

resolve_xray_target_version() {
    local requested channel
    requested=$(xray_requested_version)
    channel=$(xray_requested_channel)
    if [[ -n "$requested" ]]; then
        normalize_xray_version "$requested" || {
            log_error "Invalid XRAY_VERSION: $requested"
            return 1
        }
        return 0
    fi
    channel="${channel:-stable}"
    case "$channel" in
        stable) get_xray_stable_version ;;
        prerelease) get_xray_latest_version ;;
        *)
            log_error "Invalid XRAY_CHANNEL: $channel (expected stable or prerelease)"
            return 1
            ;;
    esac
}

_xray_run_bounded() {
    local output_file output_size probe_parent rc=0
    command -v timeout >/dev/null 2>&1 && command -v head >/dev/null 2>&1 || return 1
    if [[ -n "${XRAY_TXN_TMP_DIR:-}" ]]; then
        identity_bound_tmp_intact "$XRAY_TXN_TMP_DIR" "$XRAY_TXN_TMP_ID" \
            "$XRAY_TXN_TMP_PARENT" proxy-hub-xray. || return 1
        probe_parent="$XRAY_TXN_TMP_DIR"
    else
        secure_resolve_tmp_parent "${TMPDIR:-/tmp}" || return 1
        probe_parent="$SECURE_TMP_PARENT"
    fi
    output_file=$(mktemp "${probe_parent%/}/proxy-hub-xray-probe.XXXXXX") || return 1
    chmod 0600 "$output_file" || {
        rm -f -- "$output_file"
        return 1
    }
    # Limit the regular-file output as well as wall time so an untrusted
    # candidate cannot consume unbounded memory or temporary storage.
    (ulimit -f 130; timeout --signal=TERM --kill-after=2s 15s "$@") >"$output_file" 2>&1 || rc=$?
    output_size=$(wc -c < "$output_file") || {
        rm -f -- "$output_file"
        return 1
    }
    if ((output_size > 65536)); then
        rm -f -- "$output_file"
        log_error "Xray probe exceeded the output limit"
        return 1
    fi
    if ((rc == 124 || rc == 137)); then
        rm -f -- "$output_file"
        log_error "Xray probe timed out"
        return 1
    fi
    output=$(head -c 65536 "$output_file")
    rm -f -- "$output_file"
    printf '%s\n' "$output"
    return "$rc"
}

get_installed_xray_version() {
    local binary="${1:-$XRAY_BIN}" output line token_pattern
    [[ -x "$binary" && ! -d "$binary" ]] || return 1
    if ! output=$(_xray_run_bounded "$binary" version); then
        output=$(_xray_run_bounded "$binary" -version) || return 1
    fi
    token_pattern='v?[0-9]+(\.[0-9]+){1,3}([.-][A-Za-z0-9._-]+)?'
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        if [[ "$line" =~ [Xx]ray[[:space:]]+($token_pattern) ]]; then
            normalize_xray_version "${BASH_REMATCH[1]}" && return 0
        fi
    done <<< "$output"
    return 1
}

xray_update_decision() {
    local current target source="${3:-channel}" cmp
    current=$(normalize_xray_version "$1") || return 1
    target=$(normalize_xray_version "$2") || return 1
    cmp=$(xray_compare_versions "$current" "$target") || return 1
    if [[ "$cmp" == 0 ]]; then
        [[ "$source" == "version" ]] && printf '%s\n' reinstall || printf '%s\n' noop
    elif [[ "$cmp" == -1 ]]; then
        printf '%s\n' upgrade
    elif [[ "$source" == "version" ]]; then
        printf '%s\n' downgrade
    else
        printf '%s\n' refuse
    fi
}

_xray_release_asset_metadata() {
    local target="$1" arch="$2" response zip_name digest_name expected_zip expected_digest
    local zip_count digest_count zip_url digest_url digest
    target=$(normalize_xray_version "$target") || return 1
    [[ "$arch" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    _xray_require_jq || return 1
    if ! response=$(xray_github_api "$XRAY_RELEASE_API/tags/$target" 2>/dev/null); then
        log_error "GitHub API request for Xray $target failed"
        return 1
    fi
    jq -e --arg tag "$target" 'type == "object" and .draft == false and .tag_name == $tag and
        (.assets | type == "array")' >/dev/null 2>&1 <<< "$response" || {
        log_error "GitHub returned incomplete release metadata for Xray $target"
        return 1
    }
    zip_name="Xray-linux-${arch}.zip"
    digest_name="${zip_name}.dgst"
    zip_count=$(jq --arg name "$zip_name" '[.assets[] | select(.name == $name)] | length' <<< "$response")
    digest_count=$(jq --arg name "$digest_name" '[.assets[] | select(.name == $name)] | length' <<< "$response")
    [[ "$zip_count" == 1 && "$digest_count" == 1 ]] || {
        log_error "Xray $target does not expose one unambiguous archive and digest for $arch"
        return 1
    }
    zip_url=$(jq -r --arg name "$zip_name" '.assets[] | select(.name == $name) | .browser_download_url' <<< "$response")
    digest_url=$(jq -r --arg name "$digest_name" '.assets[] | select(.name == $name) | .browser_download_url' <<< "$response")
    digest=$(jq -r --arg name "$zip_name" '.assets[] | select(.name == $name) | (.digest // "")' <<< "$response")
    expected_zip="https://github.com/$XRAY_REPO/releases/download/$target/$zip_name"
    expected_digest="${expected_zip}.dgst"
    [[ "$zip_url" == "$expected_zip" && "$digest_url" == "$expected_digest" ]] || {
        log_error "GitHub returned an unexpected Xray asset URL"
        return 1
    }
    printf '%s\n%s\n%s\n' "$zip_url" "$digest_url" "$digest"
}

_xray_parse_digest_file() {
    local file="$1" line digest="" count=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        if [[ "$line" =~ ^SHA2-256=[[:space:]]([0-9A-Fa-f]{64})$ ]]; then
            digest="${BASH_REMATCH[1],,}"
            ((++count))
        fi
    done < "$file"
    [[ "$count" == 1 ]] || return 1
    printf '%s\n' "$digest"
}

_xray_download_file() {
    local url="$1" destination="$2" max_bytes="$3" expected_sha="${4:-}" size actual_sha
    [[ "$max_bytes" =~ ^[1-9][0-9]*$ ]] || return 1
    if ! secure_curl --connect-timeout 10 --max-time 300 --speed-limit 1024 --speed-time 30 \
        --max-filesize "$max_bytes" "$url" -o "$destination" 2>/dev/null; then
        rm -f -- "$destination"
        return 1
    fi
    size=$(stat -c '%s' "$destination" 2>/dev/null) || return 1
    ((size > 0 && size <= max_bytes)) || return 1
    if [[ -n "$expected_sha" ]]; then
        actual_sha=$(_xray_sha256_file "$destination") || return 1
        [[ "$actual_sha" == "$expected_sha" ]] || {
            log_error "SHA256 mismatch for the downloaded Xray release asset"
            return 1
        }
    fi
}

download_xray_release() {
    local target="$1" arch="$2" tmp_dir="$3" expected_sha digest_value size member entry_size xray_count=0
    local archive_listing archive_metadata member_count=0
    local zip_file="$tmp_dir/xray.zip" digest_file="$tmp_dir/xray.zip.dgst" candidate="$tmp_dir/xray"
    local -a metadata
    identity_bound_tmp_intact "$tmp_dir" "$XRAY_TXN_TMP_ID" "$XRAY_TXN_TMP_PARENT" proxy-hub-xray. || return 1
    mapfile -t metadata < <(_xray_release_asset_metadata "$target" "$arch") || return 1
    [[ ${#metadata[@]} -eq 3 ]] || return 1
    digest_value="${metadata[2]}"
    if [[ "$digest_value" =~ ^sha256:([0-9A-Fa-f]{64})$ ]]; then
        expected_sha="${BASH_REMATCH[1],,}"
    else
        if ! _xray_download_file "${metadata[1]}" "$digest_file" 4096; then
            log_error "Failed to download the official Xray digest for $target"
            return 1
        fi
        expected_sha=$(_xray_parse_digest_file "$digest_file") || {
            log_error "The official Xray digest for $target is malformed"
            return 1
        }
    fi
    _xray_check_disk_space "$tmp_dir" "$XRAY_MAX_RELEASE_BYTES" || return 1
    if ! _xray_download_file "${metadata[0]}" "$zip_file" "$XRAY_MAX_RELEASE_BYTES" "$expected_sha"; then
        log_error "Xray archive download or SHA256 verification failed"
        return 1
    fi
    size=$(stat -c '%s' "$zip_file" 2>/dev/null) || return 1
    ((size > 0 && size <= XRAY_MAX_RELEASE_BYTES)) || {
        log_error "Xray archive exceeds the safe size limit"
        return 1
    }
    archive_listing=$(_xray_run_bounded unzip -Z1 "$zip_file") || {
        log_error "Xray archive member listing failed or exceeded its safety bound"
        return 1
    }
    while IFS= read -r member || [[ -n "$member" ]]; do
        [[ -n "$member" ]] || continue
        ((++member_count))
        ((member_count <= XRAY_MAX_ARCHIVE_MEMBERS)) || {
            log_error "Xray archive contains too many members"
            return 1
        }
        [[ "$member" != /* && "$member" != *'\'* && "$member" != *$'\r'* &&
           "$member" != ".." && "$member" != ../* && "$member" != */../* && "$member" != */.. ]] || {
            log_error "Unsafe path in Xray release archive"
            return 1
        }
        [[ "$member" == xray ]] && ((++xray_count))
    done <<< "$archive_listing"
    [[ "$xray_count" == 1 ]] || {
        log_error "Xray archive must contain exactly one top-level xray binary"
        return 1
    }
    archive_metadata=$(_xray_run_bounded unzip -Z -l "$zip_file" xray) || {
        log_error "Xray archive metadata lookup failed or exceeded its safety bound"
        return 1
    }
    entry_size=$(awk '$NF == "xray" {print $4}' <<< "$archive_metadata") || return 1
    [[ "$entry_size" =~ ^[1-9][0-9]*$ ]] && ((entry_size <= XRAY_MAX_RELEASE_BYTES)) || {
        log_error "Xray archive entry exceeds the safe uncompressed-size limit"
        return 1
    }
    # The downloaded archive is still present, so check the remaining space for
    # the separate extracted candidate plus the normal safety margin.
    _xray_check_disk_space "$tmp_dir" "$entry_size" || return 1
    timeout --signal=TERM --kill-after=2s 60s unzip -tq "$zip_file" xray >/dev/null 2>&1 || {
        log_error "Xray archive integrity test failed"
        return 1
    }
    (umask 077; ulimit -f 262144; timeout --signal=TERM --kill-after=2s 60s \
        unzip -p "$zip_file" xray > "$candidate") || {
        log_error "Failed to extract the Xray binary safely"
        return 1
    }
    [[ -f "$candidate" && ! -L "$candidate" ]] || return 1
    size=$(stat -c '%s' "$candidate" 2>/dev/null) || return 1
    ((size > 0 && size <= XRAY_MAX_RELEASE_BYTES)) || return 1
    chmod 0755 "$candidate" || return 1
    printf '%s\n' "$candidate"
}

_xray_sha256_file() {
    local file="$1" output
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        output=$(openssl dgst -sha256 "$file") || return 1
        printf '%s\n' "${output##*= }"
    else
        return 1
    fi
}

validate_xray_binary() {
    local binary="$1" target="$2" mode="${3:-update}" reported cmp modern_error legacy_error
    [[ -f "$binary" && ! -L "$binary" && -x "$binary" ]] || {
        log_error "The downloaded Xray binary is not a regular executable"
        return 1
    }
    reported=$(get_installed_xray_version "$binary") || {
        log_error "The downloaded Xray binary cannot report its version"
        return 1
    }
    cmp=$(xray_compare_versions "$reported" "$target") || return 1
    [[ "$cmp" == 0 ]] || {
        log_error "Downloaded Xray version mismatch: expected $target, got $reported"
        return 1
    }

    if [[ -f "$XRAY_CONF" ]]; then
        if modern_error=$(_xray_run_bounded "$binary" run -test -config "$XRAY_CONF"); then
            return 0
        fi
        if legacy_error=$(_xray_run_bounded "$binary" -test -config "$XRAY_CONF"); then
            return 0
        fi
        log_error "New Xray rejected the existing config (modern: ${modern_error:-failed}; legacy: ${legacy_error:-failed})"
        return 1
    fi
    if [[ "$mode" == "update" && -e "$XRAY_BIN" ]]; then
        log_error "Refusing to update an existing Xray without config: $XRAY_CONF"
        return 1
    fi
    log_warn "Xray config does not exist yet; binary config test skipped for fresh installation"
}

_xray_validate_backup_keep() {
    local keep="${XRAY_BACKUP_KEEP:-}"
    [[ "$keep" =~ ^[1-9][0-9]{0,3}$ ]] && ((10#$keep <= 1000)) || {
        log_error "XRAY_BACKUP_KEEP must be an integer between 1 and 1000"
        return 1
    }
}

_xray_release_capability_check() {
    local command_name
    for command_name in curl jq unzip stat install mv ln unlink cat df date chmod flock awk sed readlink sync sha256sum timeout head mktemp wc; do
        command -v "$command_name" >/dev/null 2>&1 || {
            log_error "Xray update requires command: $command_name"
            return 1
        }
    done
    _xray_sha256_file "${BASH_SOURCE[0]}" >/dev/null 2>&1 || {
        log_error "Xray update requires a working SHA256 implementation"
        return 1
    }
    _xray_validate_backup_keep
}

xray_runtime_healthy() {
    local expected_binary="${1:-$XRAY_BIN}" attempt pid expected_id actual_id consecutive=0
    expected_id=$(stat -Lc '%d:%i' "$expected_binary" 2>/dev/null) || return 1
    for attempt in {1..12}; do
        pid=""
        actual_id=""
        if service_is_active xray &&
           pid=$(service_main_pid xray 2>/dev/null) &&
        [[ "$pid" =~ ^[1-9][0-9]*$ && -r "/proc/$pid/exe" ]] &&
           actual_id=$(stat -Lc '%d:%i' "/proc/$pid/exe" 2>/dev/null) &&
           [[ "$actual_id" == "$expected_id" ]] &&
           xray_runtime_has_only_service_pid "$pid"; then
            ((++consecutive))
            ((consecutive >= 3)) && return 0
        else
            consecutive=0
        fi
        sleep 1
    done
    if service_is_active xray; then
        pid=$(service_main_pid xray 2>/dev/null || true)
        [[ -n "$pid" ]] && xray_pid_uses_binary "$pid" "$expected_binary" &&
            xray_runtime_has_only_service_pid "$pid" || \
            XRAY_RECOVERY_EXTERNAL_CONFLICT=1
    elif xray_process_exists; then
        XRAY_RECOVERY_EXTERNAL_CONFLICT=1
    fi
    log_error "Xray service did not stay healthy on the activated binary"
    return 1
}

_xray_stop_and_wait() {
    local expected_binary="${1:-$XRAY_BIN}" expected_digest="${2:-}" attempt pid actual_digest
    if service_is_active xray; then
        pid=$(service_main_pid xray 2>/dev/null) || {
            XRAY_RECOVERY_EXTERNAL_CONFLICT=1
            log_error "Xray is active but its main process cannot be identified at the stop boundary"
            return 1
        }
        xray_pid_uses_binary "$pid" "$expected_binary" || {
            XRAY_RECOVERY_EXTERNAL_CONFLICT=1
            log_error "Refusing to stop Xray because its process no longer matches the expected binary"
            return 1
        }
        xray_runtime_has_only_service_pid "$pid" || {
            XRAY_RECOVERY_EXTERNAL_CONFLICT=1
            log_error "Refusing to stop Xray while another Xray process exists"
            return 1
        }
        if [[ -n "$expected_digest" ]]; then
            actual_digest=$(_xray_sha256_file "$expected_binary" 2>/dev/null) || {
                XRAY_RECOVERY_EXTERNAL_CONFLICT=1
                return 1
            }
            [[ "$actual_digest" == "$expected_digest" ]] || {
                XRAY_RECOVERY_EXTERNAL_CONFLICT=1
                log_error "Refusing to stop Xray because its binary changed during the update"
                return 1
            }
        fi
    elif xray_process_exists; then
        XRAY_RECOVERY_EXTERNAL_CONFLICT=1
        log_error "Refusing to stop an unmanaged or stale Xray process"
        return 1
    else
        return 0
    fi
    service_stop_strict xray || {
        XRAY_RECOVERY_EXTERNAL_CONFLICT=1
        return 1
    }
    for attempt in {1..20}; do
        if ! service_is_active xray && ! xray_process_exists; then
            return 0
        fi
        sleep 0.25
    done
    XRAY_RECOVERY_EXTERNAL_CONFLICT=1
    log_error "Xray did not stop cleanly"
    return 1
}

_xray_start_and_verify() {
    service_start_strict xray || {
        ! service_is_active xray && ! xray_process_exists || XRAY_RECOVERY_EXTERNAL_CONFLICT=1
        return 1
    }
    xray_runtime_healthy "$XRAY_BIN"
}

_xray_sync_path() {
    local path="$1"
    sync -f "$path" >/dev/null 2>&1
}

_xray_prepare_managed_file_parent() {
    local file="$1" private_parent="${2:-0}" parent grandparent owner mode created=0
    parent=$(dirname "$file") || return 1
    if [[ ! -e "$parent" ]]; then
        grandparent=$(dirname "$parent") || return 1
        [[ -d "$grandparent" && ! -L "$grandparent" ]] || return 1
        mkdir "$parent" || return 1
        created=1
    fi
    [[ -d "$parent" && ! -L "$parent" ]] || return 1
    owner=$(stat -c '%u' "$parent" 2>/dev/null) || return 1
    [[ "$owner" == "$EUID" ]] || return 1
    [[ ( ! -e "$file" && ! -L "$file" ) || ( -f "$file" && ! -L "$file" ) ]] || return 1
    if [[ -e "$file" || -L "$file" ]]; then
        owner=$(stat -c '%u' "$file" 2>/dev/null) || return 1
        [[ "$owner" == "$EUID" ]] || return 1
    fi
    if [[ "$private_parent" == 1 ]]; then
        mode=$(stat -c '%a' "$parent" 2>/dev/null) || return 1
        if [[ "$mode" != 700 ]]; then
            chmod 0700 "$parent" || return 1
            _xray_sync_path "$parent" || return 1
        fi
    fi
    if ((created)); then
        _xray_sync_path "$parent" || return 1
        _xray_sync_path "$(dirname "$parent")" || return 1
    fi
}

_xray_state_storage_trusted() {
    local require_file="${1:-0}" state_dir owner mode links size ancestor
    state_dir=$(dirname "$XRAY_UPDATE_STATE_FILE") || return 1
    [[ -d "$state_dir" && ! -L "$state_dir" ]] || return 1
    owner=$(stat -c '%u' "$state_dir" 2>/dev/null) || return 1
    mode=$(stat -c '%a' "$state_dir" 2>/dev/null) || return 1
    [[ "$owner" == "$EUID" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (((8#$mode & 077) == 0)) || return 1
    if [[ "$XRAY_UPDATE_STATE_FILE" == "$XRAY_PRODUCTION_UPDATE_STATE_FILE" ]]; then
        for ancestor in /var /var/lib; do
            [[ -d "$ancestor" && ! -L "$ancestor" ]] || return 1
            owner=$(stat -c '%u' "$ancestor" 2>/dev/null) || return 1
            mode=$(stat -c '%a' "$ancestor" 2>/dev/null) || return 1
            [[ "$owner" == 0 && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
            (((8#$mode & 022) == 0)) || return 1
        done
    fi
    [[ "$require_file" == 1 ]] || return 0
    [[ -f "$XRAY_UPDATE_STATE_FILE" && ! -L "$XRAY_UPDATE_STATE_FILE" ]] || return 1
    IFS=: read -r owner mode links size < <(stat -c '%u:%a:%h:%s' "$XRAY_UPDATE_STATE_FILE" 2>/dev/null) || return 1
    [[ "$owner" == "$EUID" && "$mode" == 600 && "$links" == 1 &&
       "$size" =~ ^[1-9][0-9]*$ && "$size" -le 16384 ]]
}

_xray_write_state() {
    local phase="$1" state_dir payload_file payload_id checksum prior_id="" published_id owner mode links
    state_dir=$(dirname "$XRAY_UPDATE_STATE_FILE")
    _xray_prepare_managed_file_parent "$XRAY_UPDATE_STATE_FILE" 1 || return 1
    if [[ -e "$XRAY_UPDATE_STATE_FILE" || -L "$XRAY_UPDATE_STATE_FILE" ]]; then
        [[ -f "$XRAY_UPDATE_STATE_FILE" && ! -L "$XRAY_UPDATE_STATE_FILE" ]] || return 1
        prior_id=$(stat -Lc '%d:%i' "$XRAY_UPDATE_STATE_FILE" 2>/dev/null) || return 1
        [[ -n "${XRAY_TXN_STATE_ID:-}" && "$prior_id" == "$XRAY_TXN_STATE_ID" ]] || return 1
    else
        [[ -z "${XRAY_TXN_STATE_ID:-}" ]] || return 1
    fi
    payload_file=$(mktemp "$state_dir/.xray-update-state.${XRAY_TXN_TOKEN}.payload.XXXXXXXX") || return 1
    payload_id=$(stat -Lc '%d:%i' "$payload_file" 2>/dev/null) || return 1
    IFS=: read -r owner mode links < <(stat -c '%u:%a:%h' "$payload_file" 2>/dev/null) || return 1
    [[ -f "$payload_file" && ! -L "$payload_file" && "$owner" == "$EUID" &&
       "$mode" == 600 && "$links" == 1 ]] || { _xray_discard_state_payload "$payload_file" "$payload_id" >/dev/null 2>&1 || true; return 1; }
    [[ "$XRAY_TXN_BACKUP" != *$'\n'* && "$XRAY_TXN_RESTORE_STAGE" != *$'\n'* &&
       "$XRAY_TXN_SCHEDULE_LABEL" != *$'\n'* && "$XRAY_TXN_SCHEDULE_CRON" != *$'\n'* &&
       "$XRAY_TXN_SCHEDULE_CALENDAR" != *$'\n'* ]] || { _xray_discard_state_payload "$payload_file" "$payload_id" >/dev/null 2>&1 || true; return 1; }
    (umask 077; {
        printf 'format=proxy-hub-xray-update-v1\n'
        printf 'phase=%s\n' "$phase"
        printf 'token=%s\n' "$XRAY_TXN_TOKEN"
        printf 'target=%s\n' "$XRAY_TXN_TARGET"
        printf 'new_digest=%s\n' "$XRAY_TXN_NEW_DIGEST"
        printf 'old_exists=%s\n' "$XRAY_TXN_OLD_EXISTS"
        printf 'old_digest=%s\n' "$XRAY_TXN_OLD_DIGEST"
        printf 'old_mode=%s\n' "$XRAY_TXN_OLD_MODE"
        printf 'backup=%s\n' "$XRAY_TXN_BACKUP"
        printf 'restore_stage=%s\n' "$XRAY_TXN_RESTORE_STAGE"
        printf 'was_active=%s\n' "$XRAY_TXN_WAS_ACTIVE"
        printf 'schedule_enabled=%s\n' "$XRAY_TXN_SCHEDULE_ENABLED"
        printf 'schedule_label=%s\n' "$XRAY_TXN_SCHEDULE_LABEL"
        printf 'schedule_cron=%s\n' "$XRAY_TXN_SCHEDULE_CRON"
        printf 'schedule_calendar=%s\n' "$XRAY_TXN_SCHEDULE_CALENDAR"
    } > "$payload_file") || { _xray_discard_state_payload "$payload_file" "$payload_id" >/dev/null 2>&1 || true; return 1; }
    checksum=$(_xray_sha256_file "$payload_file") || { _xray_discard_state_payload "$payload_file" "$payload_id" >/dev/null 2>&1 || true; return 1; }
    printf 'checksum=%s\n' "$checksum" >> "$payload_file" || { _xray_discard_state_payload "$payload_file" "$payload_id" >/dev/null 2>&1 || true; return 1; }
    chmod 0600 "$payload_file" || { _xray_discard_state_payload "$payload_file" "$payload_id" >/dev/null 2>&1 || true; return 1; }
    if [[ -n "$prior_id" ]]; then
        [[ "$(stat -Lc '%d:%i' "$XRAY_UPDATE_STATE_FILE" 2>/dev/null)" == "$prior_id" ]] || { _xray_discard_state_payload "$payload_file" "$payload_id" >/dev/null 2>&1 || true; return 1; }
        mv -f -- "$payload_file" "$XRAY_UPDATE_STATE_FILE" || { _xray_discard_state_payload "$payload_file" "$payload_id" >/dev/null 2>&1 || true; return 1; }
    else
        mv -n -T -- "$payload_file" "$XRAY_UPDATE_STATE_FILE" || { _xray_discard_state_payload "$payload_file" "$payload_id" >/dev/null 2>&1 || true; return 1; }
        [[ ! -e "$payload_file" && ! -L "$payload_file" ]] || { _xray_discard_state_payload "$payload_file" "$payload_id" >/dev/null 2>&1 || true; return 1; }
    fi
    [[ -f "$XRAY_UPDATE_STATE_FILE" && ! -L "$XRAY_UPDATE_STATE_FILE" ]] || return 1
    published_id=$(stat -Lc '%d:%i' "$XRAY_UPDATE_STATE_FILE" 2>/dev/null) || return 1
    XRAY_TXN_STATE_ID="$published_id"
    _xray_sync_path "$XRAY_UPDATE_STATE_FILE" || return 1
    _xray_sync_path "$state_dir" || return 1
    [[ "$phase" != prepared ]] || XRAY_TXN_PREPARED=1
    XRAY_TXN_PHASE="$phase"
}

_xray_load_state() {
    local key value expected_checksum actual_checksum payload loaded_id final_id
    _xray_state_storage_trusted 1 || return 1
    loaded_id=$(stat -Lc '%d:%i' "$XRAY_UPDATE_STATE_FILE" 2>/dev/null) || return 1
    XRAY_STATE_FORMAT="" XRAY_STATE_PHASE="" XRAY_STATE_TOKEN="" XRAY_STATE_TARGET=""
    XRAY_STATE_NEW_DIGEST=""
    XRAY_STATE_OLD_EXISTS="" XRAY_STATE_OLD_DIGEST="" XRAY_STATE_OLD_MODE=""
    XRAY_STATE_BACKUP="" XRAY_STATE_RESTORE_STAGE="" XRAY_STATE_WAS_ACTIVE=""
    XRAY_STATE_SCHEDULE_ENABLED="" XRAY_STATE_SCHEDULE_LABEL=""
    XRAY_STATE_SCHEDULE_CRON="" XRAY_STATE_SCHEDULE_CALENDAR=""
    expected_checksum=""
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        case "$key" in
            format) XRAY_STATE_FORMAT="$value" ;;
            phase) XRAY_STATE_PHASE="$value" ;;
            token) XRAY_STATE_TOKEN="$value" ;;
            target) XRAY_STATE_TARGET="$value" ;;
            new_digest) XRAY_STATE_NEW_DIGEST="$value" ;;
            old_exists) XRAY_STATE_OLD_EXISTS="$value" ;;
            old_digest) XRAY_STATE_OLD_DIGEST="$value" ;;
            old_mode) XRAY_STATE_OLD_MODE="$value" ;;
            backup) XRAY_STATE_BACKUP="$value" ;;
            restore_stage) XRAY_STATE_RESTORE_STAGE="$value" ;;
            was_active) XRAY_STATE_WAS_ACTIVE="$value" ;;
            schedule_enabled) XRAY_STATE_SCHEDULE_ENABLED="$value" ;;
            schedule_label) XRAY_STATE_SCHEDULE_LABEL="$value" ;;
            schedule_cron) XRAY_STATE_SCHEDULE_CRON="$value" ;;
            schedule_calendar) XRAY_STATE_SCHEDULE_CALENDAR="$value" ;;
            checksum) expected_checksum="$value" ;;
            *) return 1 ;;
        esac
    done < "$XRAY_UPDATE_STATE_FILE"
    [[ "$expected_checksum" =~ ^[0-9a-f]{64}$ ]] || return 1
    payload=$(sed '$d' "$XRAY_UPDATE_STATE_FILE") || return 1
    actual_checksum=$(_xray_sha256_file <(printf '%s\n' "$payload")) || return 1
    [[ "$actual_checksum" == "$expected_checksum" ]] || return 1
    [[ "$XRAY_STATE_FORMAT" == proxy-hub-xray-update-v1 &&
       "$XRAY_STATE_TOKEN" =~ ^[A-Za-z0-9._-]+$ &&
       "$XRAY_STATE_NEW_DIGEST" =~ ^[0-9a-f]{64}$ &&
       "$XRAY_STATE_OLD_EXISTS" =~ ^[01]$ && "$XRAY_STATE_WAS_ACTIVE" =~ ^[01]$ &&
       "$XRAY_STATE_SCHEDULE_ENABLED" =~ ^[01]$ &&
       "$XRAY_STATE_OLD_MODE" =~ ^[0-7]{3,4}$ ]] || return 1
    [[ "$(normalize_xray_version "$XRAY_STATE_TARGET" 2>/dev/null || true)" == "$XRAY_STATE_TARGET" ]] || return 1
    if [[ "$XRAY_STATE_OLD_EXISTS" == 1 ]]; then
        [[ "$XRAY_STATE_OLD_DIGEST" =~ ^[0-9a-f]{64}$ ]] || return 1
    else
        [[ -z "$XRAY_STATE_OLD_DIGEST" ]] || return 1
    fi
    if [[ "$XRAY_STATE_SCHEDULE_ENABLED" == 1 ]]; then
        [[ "$XRAY_STATE_SCHEDULE_LABEL" =~ ^[A-Za-z0-9_-]+$ &&
           "$XRAY_STATE_SCHEDULE_CRON" =~ ^[0-9*/?,[:space:]-]+$ &&
           "$XRAY_STATE_SCHEDULE_CALENDAR" =~ ^[A-Za-z0-9*/?,:.*[:space:]-]*$ &&
           "$(awk '{print NF}' <<< "$XRAY_STATE_SCHEDULE_CRON")" == 5 ]] || return 1
    else
        [[ -z "$XRAY_STATE_SCHEDULE_LABEL" && -z "$XRAY_STATE_SCHEDULE_CRON" &&
           -z "$XRAY_STATE_SCHEDULE_CALENDAR" ]] || return 1
    fi
    case "$XRAY_STATE_PHASE" in
        prepared|schedule-paused|stopped|displaced|activated|committed|rolled-back) ;;
        *) return 1 ;;
    esac
    final_id=$(stat -Lc '%d:%i' "$XRAY_UPDATE_STATE_FILE" 2>/dev/null) || return 1
    [[ "$final_id" == "$loaded_id" ]] || return 1
    XRAY_STATE_FILE_ID="$loaded_id"
}

_xray_read_restart_config_value() {
    local file="$1" wanted="$2" line key value found=0
    [[ -f "$file" && ! -L "$file" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == *=* ]] || continue
        key="${line%%=*}"
        [[ "$key" == "$wanted" ]] || continue
        value="${line#*=}"
        ((++found))
    done < "$file"
    [[ "$found" == 1 ]] || return 1
    if [[ "$value" == \"*\" && "$value" == *\" ]]; then
        value="${value:1:${#value}-2}"
    elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
        value="${value:1:${#value}-2}"
    fi
    [[ "$value" != *$'\r'* && "$value" != *$'\n'* ]] || return 1
    printf '%s\n' "$value"
}

_xray_capture_restart_schedule() {
    local restart_conf="${XRAY_RESTART_CONF:-/etc/proxy-hub/xray-restart.conf}" enabled fields
    XRAY_TXN_SCHEDULE_ENABLED=0
    XRAY_TXN_SCHEDULE_LABEL=""
    XRAY_TXN_SCHEDULE_CRON=""
    XRAY_TXN_SCHEDULE_CALENDAR=""
    [[ -f "$restart_conf" ]] || return 0
    enabled=$(_xray_read_restart_config_value "$restart_conf" RESTART_ENABLED) || return 1
    [[ "$enabled" == yes ]] || return 0
    XRAY_TXN_SCHEDULE_LABEL=$(_xray_read_restart_config_value "$restart_conf" RESTART_LABEL) || return 1
    XRAY_TXN_SCHEDULE_CRON=$(_xray_read_restart_config_value "$restart_conf" RESTART_CRON) || return 1
    XRAY_TXN_SCHEDULE_CALENDAR=$(_xray_read_restart_config_value "$restart_conf" RESTART_SYSTEMD_CALENDAR) || return 1
    [[ "$XRAY_TXN_SCHEDULE_LABEL" =~ ^[A-Za-z0-9_-]+$ &&
       "$XRAY_TXN_SCHEDULE_CRON" =~ ^[0-9*/?,[:space:]-]+$ &&
       "$XRAY_TXN_SCHEDULE_CALENDAR" =~ ^[A-Za-z0-9*/?,:.*[:space:]-]*$ ]] || {
        log_error "Xray restart schedule contains unsupported characters"
        return 1
    }
    fields=$(awk '{print NF}' <<< "$XRAY_TXN_SCHEDULE_CRON") || return 1
    [[ "$fields" == 5 ]] || return 1
    XRAY_TXN_SCHEDULE_ENABLED=1
}

_xray_pause_restart_schedule() {
    [[ "$XRAY_TXN_SCHEDULE_ENABLED" == 1 ]] || return 0
    remove_xray_restart_schedule
}

_xray_restore_restart_schedule_values() {
    local enabled="$1" label="$2" cron="$3" calendar="$4"
    [[ "$enabled" == 1 ]] || return 0
    setup_xray_restart_schedule "$label" "$cron" "$calendar"
}

_xray_cleanup_managed_stages() {
    local bin_dir="$1" token="$2" restore_stage="$3" new_stage displaced failed backup_copy stage owner
    local -a stages
    [[ "$token" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    [[ "$restore_stage" == "$bin_dir/.xray.restore.$token" ]] || return 1
    new_stage="$bin_dir/.xray.new.$token"
    displaced="$bin_dir/.xray.displaced.$token"
    failed="$bin_dir/.xray.failed.$token"
    backup_copy="$bin_dir/.xray.backup-copy.$token"
    stages=("$new_stage" "$restore_stage" "$displaced" "$failed" "$backup_copy")
    for stage in "${stages[@]}"; do
        [[ ! -e "$stage" && ! -L "$stage" ]] && continue
        if [[ ! -f "$stage" || -L "$stage" ]]; then
            XRAY_RECOVERY_EXTERNAL_CONFLICT=1
            log_error "Refusing to remove an unclassifiable Xray transaction stage: $stage"
            return 1
        fi
        owner=$(stat -c '%u' "$stage" 2>/dev/null) || return 1
        [[ "$owner" == "$EUID" ]] || {
            XRAY_RECOVERY_EXTERNAL_CONFLICT=1
            return 1
        }
    done
    for stage in "${stages[@]}"; do
        [[ ! -e "$stage" && ! -L "$stage" ]] || unlink "$stage" || return 1
    done
    _xray_sync_path "$bin_dir"
}

recover_pending_xray_update() {
    local bin_dir backup_base restore_id backup_id recovery_ok=1
    XRAY_RECOVERY_EXTERNAL_CONFLICT=0
    [[ -e "$XRAY_UPDATE_STATE_FILE" || -L "$XRAY_UPDATE_STATE_FILE" ]] || return 0
    if ! _xray_load_state; then
        log_error "Xray update recovery state is malformed: $XRAY_UPDATE_STATE_FILE"
        return 1
    fi
    bin_dir=$(dirname "$XRAY_BIN")
    backup_base=$(basename "$XRAY_STATE_BACKUP")
    [[ "$XRAY_STATE_BACKUP" == "$bin_dir/$backup_base" &&
       "$backup_base" =~ ^xray\.bak-v[0-9]+(\.[0-9]+){1,3}([.-][A-Za-z0-9._-]+)?-[0-9]{8}-[0-9]{6}$ &&
       "$XRAY_STATE_RESTORE_STAGE" == "$bin_dir/.xray.restore.$XRAY_STATE_TOKEN" ]] || {
        log_error "Xray recovery paths are outside the managed namespace"
        return 1
    }
    _xray_validate_backup_keep || return 1
    case "$XRAY_STATE_PHASE" in
        committed|rolled-back)
            if ! xray_finalize_transaction_evidence "$XRAY_STATE_PHASE" \
                "$XRAY_STATE_OLD_EXISTS" "$XRAY_STATE_OLD_DIGEST" "$XRAY_STATE_OLD_MODE" \
                "$XRAY_STATE_NEW_DIGEST" "$XRAY_STATE_WAS_ACTIVE" "$bin_dir" \
                "$XRAY_STATE_TOKEN" "$XRAY_STATE_RESTORE_STAGE" "$XRAY_STATE_FILE_ID"; then
                log_error "Terminal Xray recovery evidence was preserved at '$XRAY_UPDATE_STATE_FILE'."
                log_error "Do not overwrite or remove '$XRAY_BIN' until its owner and purpose are identified."
                if [[ "$XRAY_STATE_OLD_EXISTS" == 1 && -f "$XRAY_STATE_BACKUP" && ! -L "$XRAY_STATE_BACKUP" ]]; then
                    log_error "After preserving the target elsewhere, verify SHA-256 '$XRAY_STATE_OLD_DIGEST' and restore from '$XRAY_STATE_BACKUP'."
                fi
                return 1
            fi
            _xray_prune_backups || log_warn "Could not prune managed Xray backups after recovery"
            return 0
            ;;
    esac
    log_warn "Recovering an interrupted Xray update (${XRAY_STATE_PHASE})"
    xray_restore_transaction_binary "$XRAY_STATE_OLD_EXISTS" "$XRAY_STATE_OLD_DIGEST" \
        "$XRAY_STATE_OLD_MODE" "$XRAY_STATE_NEW_DIGEST" "$XRAY_STATE_RESTORE_STAGE" "$XRAY_STATE_BACKUP" \
        "$XRAY_STATE_WAS_ACTIVE" "$XRAY_STATE_TOKEN" || recovery_ok=0
    if ((recovery_ok)) && [[ "$XRAY_STATE_WAS_ACTIVE" == 1 ]]; then
        service_start_strict xray || recovery_ok=0
        ((recovery_ok)) && xray_runtime_healthy "$XRAY_BIN" || recovery_ok=0
    fi
    if ((recovery_ok)); then
        _xray_restore_restart_schedule_values \
            "$XRAY_STATE_SCHEDULE_ENABLED" "$XRAY_STATE_SCHEDULE_LABEL" \
            "$XRAY_STATE_SCHEDULE_CRON" "$XRAY_STATE_SCHEDULE_CALENDAR" || recovery_ok=0
    fi
    if ((recovery_ok)); then
        xray_adopt_loaded_transaction_state
        _xray_write_state rolled-back || recovery_ok=0
        ((recovery_ok)) && xray_finalize_transaction_evidence rolled-back \
            "$XRAY_TXN_OLD_EXISTS" "$XRAY_TXN_OLD_DIGEST" "$XRAY_TXN_OLD_MODE" \
            "$XRAY_TXN_NEW_DIGEST" "$XRAY_TXN_WAS_ACTIVE" "$bin_dir" \
            "$XRAY_TXN_TOKEN" "$XRAY_TXN_RESTORE_STAGE" "$XRAY_TXN_STATE_ID" || recovery_ok=0
    fi
    if ((recovery_ok)); then
        _xray_prune_backups || log_warn "Could not prune managed Xray backups after recovery"
        log_info "Interrupted Xray update recovered successfully"
        return 0
    fi
    restore_id=$(stat -Lc '%d:%i' "$XRAY_STATE_RESTORE_STAGE" 2>/dev/null || true)
    backup_id=$(stat -Lc '%d:%i' "$XRAY_STATE_BACKUP" 2>/dev/null || true)
    log_error "AUTOMATIC XRAY ROLLBACK FAILED (restore=$restore_id backup=$backup_id)"
    if [[ "$XRAY_RECOVERY_EXTERNAL_CONFLICT" == 1 ]]; then
        log_error "An external Xray target or runtime state was preserved at '$XRAY_BIN'; do not overwrite or remove it until its owner and purpose are identified."
        if [[ "$XRAY_STATE_OLD_EXISTS" == 1 && -f "$XRAY_STATE_BACKUP" && ! -L "$XRAY_STATE_BACKUP" ]]; then
            log_error "After preserving the external target elsewhere, verify SHA-256 '$XRAY_STATE_OLD_DIGEST', then restore with: install -m ${XRAY_STATE_OLD_MODE:-0755} '$XRAY_STATE_BACKUP' '$XRAY_BIN'"
        else
            log_error "Inspect '$XRAY_UPDATE_STATE_FILE' and the managed staged binaries before choosing which binary to keep."
        fi
    elif [[ "$XRAY_STATE_OLD_EXISTS" == 1 && -f "$XRAY_STATE_BACKUP" && ! -L "$XRAY_STATE_BACKUP" ]]; then
        log_error "Manual recovery: install -m ${XRAY_STATE_OLD_MODE:-0755} '$XRAY_STATE_BACKUP' '$XRAY_BIN'"
    elif [[ "$XRAY_STATE_OLD_EXISTS" == 1 ]]; then
        log_error "The recorded old-binary backup is missing; inspect '$XRAY_STATE_RESTORE_STAGE' before manual recovery."
    else
        log_error "Manual recovery for the interrupted fresh install: remove '$XRAY_BIN' after confirming Xray is stopped."
    fi
    [[ "$XRAY_STATE_WAS_ACTIVE" == 1 ]] && log_error "Then restart Xray with your system service manager."
    return 1
}

recover_pending_xray_update_locked() {
    [[ -e "$XRAY_UPDATE_STATE_FILE" || -L "$XRAY_UPDATE_STATE_FILE" ]] || return 0
    command -v flock >/dev/null 2>&1 || {
        log_error "Cannot recover the pending Xray update because flock is unavailable"
        return 1
    }
    _xray_prepare_managed_file_parent "$XRAY_LIFECYCLE_LOCK" || return 1
    (
        exec 8>>"$XRAY_LIFECYCLE_LOCK" || exit 1
        flock -n 8 || {
            log_error "Another Xray lifecycle operation is already running"
            exit 1
        }
        recover_pending_xray_update
    )
}

_xray_prune_backups() {
    local bin_dir backup base timestamp remove_count i removed=0 backup_keep
    local -a backups=()
    _xray_validate_backup_keep || return 1
    backup_keep=$((10#$XRAY_BACKUP_KEEP))
    bin_dir=$(dirname "$XRAY_BIN")
    while IFS= read -r backup; do
        base=$(basename "$backup")
        [[ "$base" =~ ^xray\.bak-v[0-9]+(\.[0-9]+){1,3}([.-][A-Za-z0-9._-]+)?-[0-9]{8}-[0-9]{6}$ ]] || continue
        [[ -f "$backup" && ! -L "$backup" ]] || continue
        timestamp="${base: -15}"
        backups+=("$timestamp|$backup")
    done < <(find "$bin_dir" -maxdepth 1 -type f -name 'xray.bak-v*-????????-??????' -print 2>/dev/null)
    mapfile -t backups < <(printf '%s\n' "${backups[@]}" | LC_ALL=C sort)
    remove_count=$((${#backups[@]} - backup_keep))
    ((remove_count > 0)) || return 0
    for ((i = 0; i < remove_count; i++)); do
        backup="${backups[$i]#*|}"
        rm -f -- "$backup" || return 1
        removed=1
    done
    ((removed == 0)) || _xray_sync_path "$bin_dir"
}

_xray_cleanup_private_tmp() {
    local tmp_dir="${XRAY_TXN_TMP_DIR:-}"
    [[ -n "$tmp_dir" ]] || return 0
    identity_bound_tmp_cleanup "$tmp_dir" "$XRAY_TXN_TMP_ID" \
        "$XRAY_TXN_TMP_PARENT" proxy-hub-xray. || {
        log_error "Refusing to remove an unexpected Xray temporary path: $tmp_dir"
        return 1
    }
    XRAY_TXN_TMP_DIR=""
    XRAY_TXN_TMP_ID=""
}

_xray_transaction_rollback() {
    local rollback_ok=1 bin_dir
    [[ "${XRAY_TXN_COMMITTED:-0}" == 0 ]] || return 0
    [[ "${XRAY_TXN_PREPARED:-0}" == 1 ]] || return 0
    if [[ "$XRAY_TXN_PHASE" == committed ]]; then
        log_warn "Xray update had already reached its durable commit point"
        XRAY_TXN_COMMITTED=1
        return 0
    fi
    log_warn "Xray update failed; restoring the previous state"
    bin_dir=$(dirname "$XRAY_BIN")
    [[ "$XRAY_RECOVERY_EXTERNAL_CONFLICT" != 1 ]] || rollback_ok=0

    if ((rollback_ok)) && [[ "$XRAY_TXN_PHASE" == displaced || "$XRAY_TXN_PHASE" == activated ]]; then
        xray_restore_transaction_binary "$XRAY_TXN_OLD_EXISTS" "$XRAY_TXN_OLD_DIGEST" \
            "$XRAY_TXN_OLD_MODE" "$XRAY_TXN_NEW_DIGEST" "$XRAY_TXN_RESTORE_STAGE" "$XRAY_TXN_BACKUP" \
            "$XRAY_TXN_WAS_ACTIVE" "$XRAY_TXN_TOKEN" || rollback_ok=0
    fi

    if ((rollback_ok)) && [[ "$XRAY_TXN_WAS_ACTIVE" == 1 ]]; then
        if ! service_is_active xray; then
            service_start_strict xray || rollback_ok=0
        fi
        ((rollback_ok)) && xray_runtime_healthy "$XRAY_BIN" || rollback_ok=0
    fi
    if ((rollback_ok)) && [[ "$XRAY_TXN_PHASE" != prepared ]]; then
        _xray_restore_restart_schedule_values \
            "$XRAY_TXN_SCHEDULE_ENABLED" "$XRAY_TXN_SCHEDULE_LABEL" \
            "$XRAY_TXN_SCHEDULE_CRON" "$XRAY_TXN_SCHEDULE_CALENDAR" || rollback_ok=0
    fi
    if ((rollback_ok)); then
        _xray_write_state rolled-back >/dev/null 2>&1 || rollback_ok=0
        ((rollback_ok)) && xray_finalize_transaction_evidence rolled-back \
            "$XRAY_TXN_OLD_EXISTS" "$XRAY_TXN_OLD_DIGEST" "$XRAY_TXN_OLD_MODE" \
            "$XRAY_TXN_NEW_DIGEST" "$XRAY_TXN_WAS_ACTIVE" "$bin_dir" \
            "$XRAY_TXN_TOKEN" "$XRAY_TXN_RESTORE_STAGE" "$XRAY_TXN_STATE_ID" || rollback_ok=0
    fi
    if ((rollback_ok)); then
        _xray_prune_backups || log_warn "Could not prune managed Xray backups after rollback"
        log_info "Previous Xray state restored"
        return 0
    fi

    log_error "AUTOMATIC XRAY ROLLBACK FAILED"
    if [[ "$XRAY_RECOVERY_EXTERNAL_CONFLICT" == 1 ]]; then
        log_error "An external Xray target or runtime state was preserved at '$XRAY_BIN'; do not overwrite or remove it until its owner and purpose are identified."
        if [[ "$XRAY_TXN_OLD_EXISTS" == 1 && -f "$XRAY_TXN_BACKUP" && ! -L "$XRAY_TXN_BACKUP" ]]; then
            log_error "After preserving the external target elsewhere, verify SHA-256 '$XRAY_TXN_OLD_DIGEST', then restore with: install -m $XRAY_TXN_OLD_MODE '$XRAY_TXN_BACKUP' '$XRAY_BIN'"
        else
            log_error "Inspect '$XRAY_UPDATE_STATE_FILE' and the managed staged binaries before choosing which binary to keep."
        fi
    elif [[ "$XRAY_TXN_OLD_EXISTS" == 1 ]]; then
        log_error "Manual recovery: install -m $XRAY_TXN_OLD_MODE '$XRAY_TXN_BACKUP' '$XRAY_BIN'"
    else
        log_error "Manual recovery: remove the incomplete binary '$XRAY_BIN'"
    fi
    [[ "$XRAY_TXN_WAS_ACTIVE" == 1 ]] && log_error "Then restart Xray with your system service manager."
    return 1
}

_xray_transaction_exit() {
    local original_status="$1" final_status="$1" rollback_ok=1 bin_dir
    trap - EXIT INT TERM HUP
    if [[ "${XRAY_TXN_COMMITTED:-0}" != 1 ]]; then
        _xray_transaction_rollback || { final_status=1; rollback_ok=0; }
        if ((rollback_ok)) && [[ "${XRAY_TXN_PREPARED:-0}" != 1 ]]; then
            bin_dir=$(dirname "$XRAY_BIN")
            [[ -z "${XRAY_TXN_TOKEN:-}" || -z "${XRAY_TXN_RESTORE_STAGE:-}" ]] || \
                _xray_cleanup_managed_stages "$bin_dir" "$XRAY_TXN_TOKEN" \
                    "$XRAY_TXN_RESTORE_STAGE" >/dev/null 2>&1 || final_status=1
        fi
    fi
    _xray_cleanup_private_tmp || final_status=1
    exit "$final_status"
}

_xray_transaction_signal() {
    local signal="$1" status="$2"
    if [[ "${XRAY_TXN_COMMIT_PUBLISHING:-0}" == 1 ]]; then
        [[ "${XRAY_TXN_PENDING_SIGNAL_STATUS:-0}" != 0 ]] || XRAY_TXN_PENDING_SIGNAL_STATUS="$status"
        log_warn "Received $signal while publishing the durable Xray commit; deferring termination"
        return 0
    fi
    log_warn "Received $signal during Xray update; rolling back"
    exit "$status"
}
install_xray_release() (
    set +e
    local requested_target="${1:-}" intent="${2:-fixed-update}" arch candidate reported current_label
    local bin_dir stage_size old_size=0 timestamp active_pid current_id current_digest backup_copy intent_rc=0
    XRAY_TXN_COMMITTED=0
    XRAY_TXN_COMMIT_PUBLISHING=0
    XRAY_TXN_PENDING_SIGNAL_STATUS=0
    XRAY_TXN_STATE_ID=""
    XRAY_RECOVERY_EXTERNAL_CONFLICT=0
    XRAY_TXN_PREPARED=0
    XRAY_TXN_PHASE="initial"
    XRAY_TXN_TMP_DIR=""
    XRAY_TXN_TMP_ID=""
    XRAY_TXN_TMP_PARENT=""
    XRAY_TXN_BACKUP=""
    XRAY_TXN_RESTORE_STAGE=""
    XRAY_TXN_OLD_EXISTS=0
    XRAY_TXN_OLD_DIGEST=""
    XRAY_TXN_OLD_ID=""
    XRAY_TXN_NEW_DIGEST=""
    XRAY_TXN_OLD_MODE="0755"
    XRAY_TXN_WAS_ACTIVE=0
    XRAY_TXN_SCHEDULE_ENABLED=0
    XRAY_TXN_SCHEDULE_LABEL=""
    XRAY_TXN_SCHEDULE_CRON=""
    XRAY_TXN_SCHEDULE_CALENDAR=""
    XRAY_TXN_TOKEN="$(date +%s)-$$-${RANDOM}-${RANDOM}"
    XRAY_TXN_TARGET=$(normalize_xray_version "$requested_target") || {
        log_error "Invalid Xray target version: $requested_target"
        return 1
    }
    case "$intent" in ordinary-install|channel-update|fixed-update) ;; *) return 1 ;; esac
    trap '_xray_transaction_exit $?' EXIT
    trap '_xray_transaction_signal INT 130' INT
    trap '_xray_transaction_signal TERM 143' TERM
    trap '_xray_transaction_signal HUP 129' HUP

    _xray_release_capability_check || return 1
    _xray_prepare_managed_file_parent "$XRAY_LIFECYCLE_LOCK" || return 1
    exec 9>>"$XRAY_LIFECYCLE_LOCK" || return 1
    flock -n 9 || {
        log_error "Another Xray lifecycle operation is already running"
        return 1
    }
    recover_pending_xray_update || return 1
    xray_revalidate_release_request "$intent" "$XRAY_TXN_TARGET" || intent_rc=$?
    case "$intent_rc" in
        0) ;;
        10) XRAY_TXN_COMMITTED=1; return 0 ;;
        *) return 1 ;;
    esac

    bin_dir=$(dirname "$XRAY_BIN")
    mkdir -p "$bin_dir" "$(dirname "$XRAY_CONF")" || return 1
    if [[ -L "$XRAY_BIN" ]]; then
        log_error "Refusing to replace a symlinked Xray binary: $XRAY_BIN"
        return 1
    fi
    if [[ -e "$XRAY_BIN" ]]; then
        [[ -f "$XRAY_BIN" ]] || {
            log_error "Existing Xray path is not a regular file: $XRAY_BIN"
            return 1
        }
        XRAY_TXN_OLD_EXISTS=1
        XRAY_TXN_OLD_MODE=$(stat -c '%a' "$XRAY_BIN" 2>/dev/null) || return 1
        [[ "$XRAY_TXN_OLD_MODE" =~ ^[0-7]{3,4}$ ]] || return 1
        XRAY_TXN_OLD_DIGEST=$(_xray_sha256_file "$XRAY_BIN") || return 1
        _xray_binary_matches "$XRAY_BIN" "$XRAY_TXN_OLD_DIGEST" "$XRAY_TXN_OLD_MODE" || return 1
        XRAY_TXN_OLD_ID=$(stat -Lc '%d:%i' "$XRAY_BIN" 2>/dev/null) || return 1
        old_size=$(stat -c '%s' "$XRAY_BIN" 2>/dev/null) || return 1
    fi
    service_is_active xray && XRAY_TXN_WAS_ACTIVE=1
    if [[ "$XRAY_TXN_WAS_ACTIVE" == 1 ]]; then
        active_pid=$(service_main_pid xray 2>/dev/null) || {
            log_error "Xray is active but its main process cannot be identified safely"
            return 1
        }
        xray_pid_uses_binary "$active_pid" "$XRAY_BIN" || {
            log_error "Xray service PID does not execute the managed Xray binary"
            return 1
        }
        xray_runtime_has_only_service_pid "$active_pid" || {
            log_error "Another managed or unmanaged Xray process is running"
            return 1
        }
    elif xray_process_exists; then
        log_error "An unmanaged or stale Xray process exists; stop it before updating"
        return 1
    fi

    identity_bound_tmp_create "${TMPDIR:-/tmp}" proxy-hub-xray. || return 1
    XRAY_TXN_TMP_DIR="$IDENTITY_TMP_PATH"
    XRAY_TXN_TMP_ID="$IDENTITY_TMP_ID"
    XRAY_TXN_TMP_PARENT="$IDENTITY_TMP_PARENT"
    arch=$(map_xray_arch) || return 1
    candidate=$(download_xray_release "$XRAY_TXN_TARGET" "$arch" "$XRAY_TXN_TMP_DIR") || return 1
    identity_bound_tmp_intact "$XRAY_TXN_TMP_DIR" "$XRAY_TXN_TMP_ID" \
        "$XRAY_TXN_TMP_PARENT" proxy-hub-xray. || return 1
    validate_xray_binary "$candidate" "$XRAY_TXN_TARGET" "$XRAY_TXN_VALIDATION_MODE" || return 1
    XRAY_TXN_NEW_DIGEST=$(_xray_sha256_file "$candidate") || return 1
    reported=$(get_installed_xray_version "$candidate") || return 1
    log_info "Validated Xray release $reported ($arch)"

    stage_size=$(stat -c '%s' "$candidate" 2>/dev/null) || return 1
    _xray_check_disk_space "$bin_dir" "$((stage_size + old_size))" || return 1
    timestamp=$(date '+%Y%m%d-%H%M%S') || return 1
    if [[ "$XRAY_TXN_OLD_EXISTS" == 1 ]]; then
        current_label=$(get_installed_xray_version "$XRAY_BIN" 2>/dev/null || printf '%s\n' v0.0-unknown)
    else
        current_label="v0.0-absent"
    fi
    XRAY_TXN_BACKUP="$bin_dir/xray.bak-${current_label}-${timestamp}"
    XRAY_TXN_RESTORE_STAGE="$bin_dir/.xray.restore.${XRAY_TXN_TOKEN}"
    backup_copy="$bin_dir/.xray.backup-copy.${XRAY_TXN_TOKEN}"
    [[ ! -e "$XRAY_TXN_BACKUP" && ! -L "$XRAY_TXN_BACKUP" &&
       ! -e "$XRAY_TXN_RESTORE_STAGE" && ! -L "$XRAY_TXN_RESTORE_STAGE" &&
       ! -e "$backup_copy" && ! -L "$backup_copy" ]] || {
        log_error "Xray backup name collision; retry the update"
        return 1
    }

    _xray_capture_restart_schedule || return 1
    _xray_write_state prepared || return 1
    install -m 0755 "$candidate" "$bin_dir/.xray.new.${XRAY_TXN_TOKEN}" || return 1
    _xray_sync_path "$bin_dir/.xray.new.${XRAY_TXN_TOKEN}" || return 1
    if [[ "$XRAY_TXN_OLD_EXISTS" == 1 ]]; then
        current_id=$(stat -Lc '%d:%i' "$XRAY_BIN" 2>/dev/null) || return 1
        current_digest=$(_xray_sha256_file "$XRAY_BIN") || return 1
        [[ "$current_id" == "$XRAY_TXN_OLD_ID" && "$current_digest" == "$XRAY_TXN_OLD_DIGEST" ]] &&
            _xray_binary_metadata_matches "$XRAY_BIN" "$XRAY_TXN_OLD_MODE" || {
            log_error "Existing Xray binary changed during candidate validation"
            return 1
        }
        ln "$XRAY_BIN" "$XRAY_TXN_RESTORE_STAGE" || return 1
        [[ "$(stat -Lc '%d:%i' "$XRAY_TXN_RESTORE_STAGE" 2>/dev/null)" == "$XRAY_TXN_OLD_ID" ]] || return 1
        _xray_sync_path "$XRAY_TXN_RESTORE_STAGE" || return 1
        xray_copy_verified_backup "$XRAY_BIN" "$backup_copy" "$XRAY_TXN_BACKUP" \
            "$XRAY_TXN_OLD_DIGEST" "$XRAY_TXN_OLD_MODE" || return 1
    fi
    _xray_sync_path "$bin_dir" || return 1

    XRAY_TXN_PHASE=schedule-paused
    _xray_pause_restart_schedule || return 1
    _xray_write_state schedule-paused || return 1
    if [[ "$XRAY_TXN_WAS_ACTIVE" == 1 ]]; then
        XRAY_TXN_PHASE=stopped
        _xray_stop_and_wait "$XRAY_BIN" "$XRAY_TXN_OLD_DIGEST" || return 1
    elif service_is_active xray || xray_process_exists; then
        XRAY_RECOVERY_EXTERNAL_CONFLICT=1
        log_error "Xray runtime state changed during candidate validation; retry the update"
        return 1
    fi
    _xray_write_state stopped || return 1

    if service_is_active xray || xray_process_exists; then
        XRAY_RECOVERY_EXTERNAL_CONFLICT=1
        log_error "Xray runtime reappeared before binary activation"
        return 1
    fi

    _xray_write_state displaced || return 1
    xray_activate_transaction_binary "$XRAY_TXN_OLD_EXISTS" "$XRAY_TXN_OLD_DIGEST" "$XRAY_TXN_OLD_MODE" \
        "$bin_dir/.xray.new.${XRAY_TXN_TOKEN}" "$XRAY_TXN_NEW_DIGEST" "$XRAY_TXN_TOKEN" || return 1
    _xray_write_state activated || return 1

    if [[ "$XRAY_TXN_WAS_ACTIVE" == 1 ]]; then
        _xray_start_and_verify || return 1
    fi
    _xray_restore_restart_schedule_values \
        "$XRAY_TXN_SCHEDULE_ENABLED" "$XRAY_TXN_SCHEDULE_LABEL" \
        "$XRAY_TXN_SCHEDULE_CRON" "$XRAY_TXN_SCHEDULE_CALENDAR" || return 1
    XRAY_TXN_COMMIT_PUBLISHING=1
    if ! _xray_write_state committed; then
        XRAY_TXN_COMMIT_PUBLISHING=0
        return 1
    fi
    XRAY_TXN_COMMITTED=1
    XRAY_TXN_COMMIT_PUBLISHING=0
    if [[ "$XRAY_TXN_PENDING_SIGNAL_STATUS" != 0 ]]; then
        return "$XRAY_TXN_PENDING_SIGNAL_STATUS"
    fi
    xray_finalize_transaction_evidence committed "$XRAY_TXN_OLD_EXISTS" \
        "$XRAY_TXN_OLD_DIGEST" "$XRAY_TXN_OLD_MODE" "$XRAY_TXN_NEW_DIGEST" \
        "$XRAY_TXN_WAS_ACTIVE" "$bin_dir" "$XRAY_TXN_TOKEN" \
        "$XRAY_TXN_RESTORE_STAGE" "$XRAY_TXN_STATE_ID" || {
        log_error "Committed Xray evidence could not be finalized safely; journal retained"
        return 1
    }
    _xray_prune_backups || log_warn "Could not prune older managed Xray backups"
    log_info "Xray $XRAY_TXN_TARGET installed successfully"
    return 0
)

install_xray_fresh() {
    local target
    target=$(resolve_xray_target_version) || return 1
    install_xray_release "$target" ordinary-install
}

_xray_configured_channel_label() {
    local requested_version requested_channel
    requested_version=$(xray_requested_version)
    requested_channel=$(xray_requested_channel)
    if [[ -n "$requested_version" ]]; then
        requested_version=$(normalize_xray_version "$requested_version" 2>/dev/null || printf '%s' invalid)
        printf 'pinned (%s)\n' "$requested_version"
    else
        printf '%s\n' "${requested_channel:-stable}"
    fi
}

_xray_version_relation() {
    local current="$1" remote="$2" label="$3" cmp
    [[ -n "$remote" ]] || {
        printf '%s unavailable' "$label"
        return 0
    }
    cmp=$(xray_compare_versions "$current" "$remote") || {
        printf 'comparison unavailable'
        return 0
    }
    case "$cmp" in
        0) printf 'up to date with %s' "$label" ;;
        -1) printf 'behind %s' "$label" ;;
        1) printf 'newer than %s' "$label" ;;
    esac
}

cmd_xray_version() {
    local current="" stable="" latest="" channel stable_status latest_status
    current=$(get_installed_xray_version "$XRAY_BIN" 2>/dev/null || true)
    stable=$(get_xray_stable_version || true)
    latest=$(get_xray_latest_version || true)
    channel=$(_xray_configured_channel_label)

    printf '%-25s %s\n' 'Current installed:' "${current:-Not installed}"
    printf '%-25s %s\n' 'Latest stable:' "${stable:-Unavailable}"
    printf '%-25s %s\n' 'Latest incl. prerelease:' "${latest:-Unavailable}"
    printf '%-25s %s\n' 'Configured channel:' "$channel"
    if [[ -z "$current" ]]; then
        printf '%-25s %s\n' 'Status:' 'Not installed'
        return 0
    fi
    stable_status=$(_xray_version_relation "$current" "$stable" stable)
    latest_status=$(_xray_version_relation "$current" "$latest" 'latest release')
    printf '%-25s %s; %s\n' 'Status:' "$stable_status" "$latest_status"
}

_xray_set_request_override() {
    XRAY_REQUEST_OVERRIDE_SET=1
    XRAY_REQUEST_VERSION_OVERRIDE="${1:-}"
    XRAY_REQUEST_CHANNEL_OVERRIDE="${2:-}"
}

_xray_clear_request_override() {
    XRAY_REQUEST_OVERRIDE_SET=0
    XRAY_REQUEST_VERSION_OVERRIDE=""
    XRAY_REQUEST_CHANNEL_OVERRIDE=""
}

_xray_prompt_update_target() {
    local choice specified
    echo ""
    echo "1. $(msg xray_release_latest_stable)"
    echo "2. $(msg xray_release_latest_all)"
    echo "3. $(msg xray_release_specify)"
    echo "0. $(msg xray_release_cancel)"
    printf '%s [0-3]: ' "$(msg menu_choice)"
    read -r choice
    case "$choice" in
        1) _xray_set_request_override "" stable ;;
        2) _xray_set_request_override "" prerelease ;;
        3)
            printf '%s: ' "$(msg xray_release_version_prompt)"
            read -r specified
            normalize_xray_version "$specified" >/dev/null || {
                log_error "Invalid Xray version: $specified"
                return 1
            }
            _xray_set_request_override "$specified" ""
            ;;
        0) return 2 ;;
        *) log_error "$(msg menu_invalid)"; return 1 ;;
    esac
}

cmd_xray_update() {
    local requested_version requested_channel source target intent prompt_rc=0
    if ! is_root; then
        log_error "$(msg run_as_root)"
        return 1
    fi
    recover_pending_xray_update_locked || return 1
    requested_version=$(xray_requested_version)
    requested_channel=$(xray_requested_channel)
    if [[ -z "$requested_version" && -z "$requested_channel" && -t 0 && -t 1 ]]; then
        _xray_prompt_update_target || prompt_rc=$?
        case "$prompt_rc" in
            0) ;;
            2) return 0 ;;
            *) return 1 ;;
        esac
        requested_version=$(xray_requested_version)
        requested_channel=$(xray_requested_channel)
    fi
    source=channel
    [[ -n "$requested_version" ]] && source=version
    target=$(resolve_xray_target_version) || return 1
    intent=channel-update
    [[ "$source" != version ]] || intent=fixed-update
    install_xray_release "$target" "$intent" || return 1
    ensure_xray_service_definition
}

cmd_xray_release_menu() {
    local choice specified rc
    while true; do
        clear
        echo ""
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}                    $(msg xray_release_title)${NC}"
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        cmd_xray_version
        echo ""
        echo "1. $(msg xray_release_show_status)"
        echo "2. $(msg xray_release_update_stable)"
        echo "3. $(msg xray_release_update_latest)"
        echo "4. $(msg xray_release_install_version)"
        echo "0. $(msg xray_release_back)"
        printf '%s [0-4]: ' "$(msg menu_choice)"
        read -r choice
        case "$choice" in
            1) cmd_xray_version ;;
            2)
                _xray_set_request_override "" stable
                rc=0
                cmd_xray_update || rc=$?
                _xray_clear_request_override
                ((rc == 0)) || log_error "Xray update failed"
                ;;
            3)
                _xray_set_request_override "" prerelease
                rc=0
                cmd_xray_update || rc=$?
                _xray_clear_request_override
                ((rc == 0)) || log_error "Xray update failed"
                ;;
            4)
                printf '%s: ' "$(msg xray_release_version_prompt)"
                read -r specified
                if normalize_xray_version "$specified" >/dev/null; then
                    _xray_set_request_override "$specified" ""
                    rc=0
                    cmd_xray_update || rc=$?
                    _xray_clear_request_override
                    ((rc == 0)) || log_error "Xray update failed"
                else
                    log_error "Invalid Xray version: $specified"
                fi
                ;;
            0) return 0 ;;
            *) log_error "$(msg menu_invalid)" ;;
        esac
        echo ""
        read -rp "$(msg menu_press_enter)"
    done
}

install_deps() {
    log_info "$(msg install_deps)"

    # 根据包管理器设置包名
    local required_packages
    case "$PKG_MANAGER" in
        apt)
            required_packages=(curl unzip tar openssl ca-certificates iproute2 qrencode jq cron util-linux)
            ;;
        dnf|yum)
            required_packages=(curl unzip tar openssl ca-certificates iproute qrencode jq cronie util-linux)
            ;;
        apk)
            # Alpine Linux 特殊包名
            # libqrencode-tools 提供 qrencode 命令
            required_packages=(curl unzip tar openssl ca-certificates iproute2 libqrencode-tools bash coreutils jq flock)
            ;;
        *)
            required_packages=(curl unzip tar openssl ca-certificates iproute qrencode jq util-linux)
            ;;
    esac

    local missing_packages=()

    # 检查哪些包未安装
    for pkg in "${required_packages[@]}"; do
        if ! $PKG_CHECK "$pkg" >/dev/null 2>&1; then
            missing_packages+=("$pkg")
        fi
    done

    # 如果所有包都已安装，跳过
    if [[ ${#missing_packages[@]} -eq 0 ]]; then
        log_info "All dependencies already installed, skipping..."
        return
    fi

    # 只安装缺失的包
    log_info "Installing: ${missing_packages[*]}"
    $PKG_UPDATE >/dev/null 2>&1 || true
    if ! $PKG_INSTALL "${missing_packages[@]}" >/dev/null 2>&1; then
        log_error "Failed to install dependencies"
        return 1
    fi
}

xray_list_process_ids() {
    local proc pid comm verify_comm
    for proc in /proc/[0-9]*; do
        [[ -d "$proc" && -r "$proc/comm" ]] || continue
        IFS= read -r comm < "$proc/comm" 2>/dev/null || continue
        [[ "$comm" == xray ]] || continue
        pid="${proc##*/}"
        [[ "$pid" =~ ^[1-9][0-9]*$ ]] || continue
        IFS= read -r verify_comm < "$proc/comm" 2>/dev/null || continue
        [[ "$verify_comm" == xray ]] && printf '%s\n' "$pid"
    done
}

xray_process_exists() {
    [[ -n "$(xray_list_process_ids)" ]]
}

xray_runtime_has_only_service_pid() {
    local expected_pid="$1" pid count=0
    [[ "$expected_pid" =~ ^[1-9][0-9]*$ ]] || return 1
    while IFS= read -r pid; do
        [[ -n "$pid" ]] || continue
        [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
        ((++count))
        [[ "$pid" == "$expected_pid" ]] || return 1
    done < <(xray_list_process_ids)
    ((count == 1))
}

xray_pid_uses_binary() {
    local pid="$1" binary="$2" expected_id actual_id
    [[ "$pid" =~ ^[1-9][0-9]*$ && -r "/proc/$pid/exe" ]] || return 1
    expected_id=$(stat -Lc '%d:%i' "$binary" 2>/dev/null) || return 1
    actual_id=$(stat -Lc '%d:%i' "/proc/$pid/exe" 2>/dev/null) || return 1
    [[ "$actual_id" == "$expected_id" ]]
}

_xray_binary_metadata_matches() {
    local path="$1" expected_mode="$2" owner mode
    [[ -f "$path" && ! -L "$path" && "$expected_mode" =~ ^[0-7]{3,4}$ ]] || return 1
    IFS=: read -r owner mode < <(stat -c '%u:%a' "$path" 2>/dev/null) || return 1
    [[ "$owner" == "$EUID" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    ((8#$mode == 8#$expected_mode))
}

_xray_binary_matches() {
    local path="$1" expected_digest="$2" expected_mode="$3" actual_digest
    _xray_binary_metadata_matches "$path" "$expected_mode" || return 1
    actual_digest=$(_xray_sha256_file "$path" 2>/dev/null) || return 1
    [[ "$actual_digest" == "$expected_digest" ]]
}

_xray_discard_state_payload() {
    local payload="$1" expected_id="$2" actual_id owner links
    [[ ! -e "$payload" && ! -L "$payload" ]] && return 0
    [[ -f "$payload" && ! -L "$payload" ]] || return 1
    actual_id=$(stat -Lc '%d:%i' "$payload" 2>/dev/null) || return 1
    IFS=: read -r owner links < <(stat -c '%u:%h' "$payload" 2>/dev/null) || return 1
    [[ "$actual_id" == "$expected_id" && "$owner" == "$EUID" && "$links" == 1 ]] || return 1
    unlink "$payload" || return 1
    _xray_sync_path "$(dirname "$payload")"
}

_xray_check_disk_space() {
    local directory="$1" required="$2" available_kb
    available_kb=$(df -Pk "$directory" 2>/dev/null | awk 'NR == 2 {print $4}') || return 1
    [[ "$available_kb" =~ ^[0-9]+$ ]] || return 1
    ((available_kb * 1024 >= required + 1048576)) || {
        log_error "Not enough free space in $directory for the Xray update"
        return 1
    }
}

xray_preserve_transaction_target() {
    local target="$1" preserved="$2" expected_digest="$3" expected_mode="$4" actual_digest
    if ! _xray_binary_metadata_matches "$target" "$expected_mode"; then
        [[ ! -e "$target" && ! -L "$target" ]] || XRAY_RECOVERY_EXTERNAL_CONFLICT=1
        log_error "Refusing to move an unclassifiable Xray transaction target: $target"
        return 1
    fi
    if [[ -e "$preserved" || -L "$preserved" ]]; then
        XRAY_RECOVERY_EXTERNAL_CONFLICT=1
        log_error "Refusing to overwrite an existing Xray transaction stage: $preserved"
        return 1
    fi
    mv -n -T -- "$target" "$preserved" || return 1
    if [[ -e "$target" || -L "$target" ]]; then
        XRAY_RECOVERY_EXTERNAL_CONFLICT=1
        log_error "No-clobber Xray staging did not move the canonical target"
        return 1
    fi
    _xray_binary_metadata_matches "$preserved" "$expected_mode" || {
        XRAY_RECOVERY_EXTERNAL_CONFLICT=1
        return 1
    }
    _xray_sync_path "$preserved" || return 1
    _xray_sync_path "$(dirname "$target")" || return 1
    actual_digest=$(_xray_sha256_file "$preserved" 2>/dev/null) || {
        XRAY_RECOVERY_EXTERNAL_CONFLICT=1
        return 1
    }
    if [[ "$actual_digest" != "$expected_digest" ]]; then
        XRAY_RECOVERY_EXTERNAL_CONFLICT=1
        log_error "Xray target changed at the transaction cutover; preserving it at $preserved"
        if [[ ! -e "$target" && ! -L "$target" ]]; then
            ln "$preserved" "$target" 2>/dev/null && _xray_sync_path "$(dirname "$target")" || true
        fi
        return 1
    fi
}

xray_copy_verified_backup() {
    local source="$1" copy_stage="$2" backup="$3" expected_digest="$4" mode="$5"
    local copy_id source_id backup_id
    _xray_binary_matches "$source" "$expected_digest" "$mode" || return 1
    [[ ! -e "$copy_stage" && ! -L "$copy_stage" && ! -e "$backup" && ! -L "$backup" ]] || return 1
    (umask 077; set -o noclobber; command cat -- "$source" > "$copy_stage") 2>/dev/null || return 1
    chmod "$mode" "$copy_stage" || return 1
    _xray_sync_path "$copy_stage" || return 1
    source_id=$(stat -Lc '%d:%i' "$source" 2>/dev/null) || return 1
    copy_id=$(stat -Lc '%d:%i' "$copy_stage" 2>/dev/null) || return 1
    [[ "$copy_id" != "$source_id" ]] || return 1
    _xray_binary_matches "$copy_stage" "$expected_digest" "$mode" || return 1
    ln "$copy_stage" "$backup" || return 1
    backup_id=$(stat -Lc '%d:%i' "$backup" 2>/dev/null) || return 1
    [[ "$backup_id" == "$copy_id" ]] || return 1
    _xray_sync_path "$backup" || return 1
    _xray_sync_path "$(dirname "$backup")"
}

xray_link_transaction_target() {
    local source="$1" target="$2" expected_digest="$3" expected_mode="$4"
    _xray_binary_matches "$source" "$expected_digest" "$expected_mode" || return 1
    if [[ -e "$target" || -L "$target" ]]; then
        XRAY_RECOVERY_EXTERNAL_CONFLICT=1
        return 1
    fi
    ln "$source" "$target" || {
        [[ ! -e "$target" && ! -L "$target" ]] || XRAY_RECOVERY_EXTERNAL_CONFLICT=1
        return 1
    }
    _xray_sync_path "$target" || return 1
    _xray_sync_path "$(dirname "$target")" || return 1
    _xray_binary_matches "$target" "$expected_digest" "$expected_mode" || {
        XRAY_RECOVERY_EXTERNAL_CONFLICT=1
        return 1
    }
}

xray_activate_transaction_binary() {
    local old_exists="$1" old_digest="$2" old_mode="$3" new_stage="$4" new_digest="$5" token="$6"
    local bin_dir displaced
    bin_dir=$(dirname "$XRAY_BIN")
    displaced="$bin_dir/.xray.displaced.$token"
    if [[ "$old_exists" == 1 ]]; then
        xray_preserve_transaction_target "$XRAY_BIN" "$displaced" "$old_digest" "$old_mode" || return 1
    elif [[ -e "$XRAY_BIN" || -L "$XRAY_BIN" ]]; then
        XRAY_RECOVERY_EXTERNAL_CONFLICT=1
        log_error "An Xray binary appeared during fresh-install validation; preserving it"
        return 1
    fi
    xray_link_transaction_target "$new_stage" "$XRAY_BIN" "$new_digest" 0755 || {
        log_error "Xray activation target appeared or changed; no existing target was overwritten"
        return 1
    }
}

xray_terminal_target_matches_state() {
    local phase="$1" old_exists="$2" old_digest="$3" old_mode="$4" new_digest="$5"
    local expected_digest="$new_digest" expected_mode=0755
    if [[ "$phase" == rolled-back && "$old_exists" == 0 ]]; then
        if [[ -e "$XRAY_BIN" || -L "$XRAY_BIN" ]]; then
            XRAY_RECOVERY_EXTERNAL_CONFLICT=1
            log_error "Fresh-install rollback journal conflicts with an existing Xray target"
            return 1
        fi
        return 0
    fi
    if [[ "$phase" == rolled-back ]]; then
        expected_digest="$old_digest"
        expected_mode="$old_mode"
    fi
    _xray_binary_matches "$XRAY_BIN" "$expected_digest" "$expected_mode" || {
        XRAY_RECOVERY_EXTERNAL_CONFLICT=1
        log_error "Terminal Xray journal does not match the current target content or metadata"
        return 1
    }
}

xray_terminal_runtime_matches_state() {
    local was_active="$1" pid
    if [[ "$was_active" == 1 ]]; then
        service_is_active xray && pid=$(service_main_pid xray 2>/dev/null) &&
            xray_pid_uses_binary "$pid" "$XRAY_BIN" &&
            xray_runtime_has_only_service_pid "$pid" || {
                XRAY_RECOVERY_EXTERNAL_CONFLICT=1
                log_error "Terminal Xray journal conflicts with the current service process set"
                return 1
            }
    elif [[ "$was_active" == 0 ]]; then
        if service_is_active xray || xray_process_exists; then
            XRAY_RECOVERY_EXTERNAL_CONFLICT=1
            log_error "Terminal inactive Xray journal conflicts with a running process"
            return 1
        fi
    else
        return 1
    fi
}

xray_finalize_transaction_evidence() {
    local phase="$1" old_exists="$2" old_digest="$3" old_mode="$4" new_digest="$5"
    local was_active="$6" bin_dir="$7" token="$8" restore_stage="$9" expected_state_id="${10}" state_id
    [[ "${XRAY_RECOVERY_EXTERNAL_CONFLICT:-0}" != 1 ]] || return 1
    state_id=$(stat -Lc '%d:%i' "$XRAY_UPDATE_STATE_FILE" 2>/dev/null) || return 1
    [[ "$state_id" == "$expected_state_id" ]] || {
        XRAY_RECOVERY_EXTERNAL_CONFLICT=1
        return 1
    }
    grep -Fxq "phase=$phase" "$XRAY_UPDATE_STATE_FILE" 2>/dev/null || return 1
    xray_terminal_target_matches_state "$phase" "$old_exists" "$old_digest" "$old_mode" "$new_digest" || return 1
    xray_terminal_runtime_matches_state "$was_active" || return 1
    _xray_cleanup_managed_stages "$bin_dir" "$token" "$restore_stage" || return 1
    xray_terminal_target_matches_state "$phase" "$old_exists" "$old_digest" "$old_mode" "$new_digest" || return 1
    xray_terminal_runtime_matches_state "$was_active" || return 1
    state_id=$(stat -Lc '%d:%i' "$XRAY_UPDATE_STATE_FILE" 2>/dev/null) || return 1
    [[ "$state_id" == "$expected_state_id" ]] || {
        XRAY_RECOVERY_EXTERNAL_CONFLICT=1
        return 1
    }
    [[ "${XRAY_RECOVERY_EXTERNAL_CONFLICT:-0}" != 1 ]] || return 1
    unlink "$XRAY_UPDATE_STATE_FILE" || return 1
    _xray_sync_path "$(dirname "$XRAY_UPDATE_STATE_FILE")"
}

xray_adopt_loaded_transaction_state() {
    XRAY_TXN_TOKEN="$XRAY_STATE_TOKEN"
    XRAY_TXN_TARGET="$XRAY_STATE_TARGET"
    XRAY_TXN_NEW_DIGEST="$XRAY_STATE_NEW_DIGEST"
    XRAY_TXN_OLD_EXISTS="$XRAY_STATE_OLD_EXISTS"
    XRAY_TXN_OLD_DIGEST="$XRAY_STATE_OLD_DIGEST"
    XRAY_TXN_OLD_MODE="$XRAY_STATE_OLD_MODE"
    XRAY_TXN_BACKUP="$XRAY_STATE_BACKUP"
    XRAY_TXN_RESTORE_STAGE="$XRAY_STATE_RESTORE_STAGE"
    XRAY_TXN_WAS_ACTIVE="$XRAY_STATE_WAS_ACTIVE"
    XRAY_TXN_SCHEDULE_ENABLED="$XRAY_STATE_SCHEDULE_ENABLED"
    XRAY_TXN_SCHEDULE_LABEL="$XRAY_STATE_SCHEDULE_LABEL"
    XRAY_TXN_SCHEDULE_CRON="$XRAY_STATE_SCHEDULE_CRON"
    XRAY_TXN_SCHEDULE_CALENDAR="$XRAY_STATE_SCHEDULE_CALENDAR"
    XRAY_TXN_STATE_ID="$XRAY_STATE_FILE_ID"
    XRAY_TXN_PREPARED=1
}

xray_revalidate_release_request() {
    local intent="$1" target="$2" current="" decision
    case "$intent" in
        ordinary-install|channel-update|fixed-update) ;;
        *) return 1 ;;
    esac
    XRAY_TXN_VALIDATION_MODE=install
    XRAY_TXN_LOCKED_ACTION=install
    if [[ -e "$XRAY_BIN" || -L "$XRAY_BIN" ]]; then
        [[ -f "$XRAY_BIN" && ! -L "$XRAY_BIN" ]] || {
            log_error "Existing Xray target is not a regular file"
            return 1
        }
        current=$(get_installed_xray_version "$XRAY_BIN" 2>/dev/null || true)
        if [[ -z "$current" ]]; then
            [[ "$intent" == fixed-update ]] || {
                log_error "Only a fixed version may repair an unidentifiable Xray binary"
                return 1
            }
            XRAY_TXN_VALIDATION_MODE=update
            XRAY_TXN_LOCKED_ACTION=repair
            return 0
        fi
        if [[ "$intent" == ordinary-install ]]; then
            log_info "Xray already installed: $current (leaving it unchanged)"
            return 10
        fi
        XRAY_TXN_VALIDATION_MODE=update
        if [[ "$intent" == channel-update ]]; then
            decision=$(xray_update_decision "$current" "$target" channel) || return 1
        else
            decision=$(xray_update_decision "$current" "$target" version) || return 1
        fi
        XRAY_TXN_LOCKED_ACTION="$decision"
        log_info "Current Xray: $current; target: $target"
        case "$decision" in
            noop) log_info "Xray is already at the selected channel target; no changes made"; return 10 ;;
            refuse) log_warn "Installed Xray $current is newer than channel target $target; refusing automatic downgrade"; return 10 ;;
            reinstall) log_warn "Explicit version request will reinstall $target" ;;
            downgrade) log_warn "Explicit version request will downgrade Xray to $target" ;;
        esac
    fi
}

xray_restore_transaction_binary() {
    local old_exists="$1" old_digest="$2" old_mode="$3" new_digest="$4" restore_stage="$5"
    local backup="$6" was_active="$7" token="$8" bin_dir current_digest="" source failed displaced
    bin_dir=$(dirname "$XRAY_BIN")
    failed="$bin_dir/.xray.failed.$token"
    displaced="$bin_dir/.xray.displaced.$token"
    [[ "${XRAY_RECOVERY_EXTERNAL_CONFLICT:-0}" != 1 ]] || return 1
    if [[ -e "$XRAY_BIN" || -L "$XRAY_BIN" ]]; then
        if [[ ! -f "$XRAY_BIN" || -L "$XRAY_BIN" ]]; then
            XRAY_RECOVERY_EXTERNAL_CONFLICT=1
            log_error "Refusing recovery because the current Xray target is unclassifiable"
            return 1
        fi
        current_digest=$(_xray_sha256_file "$XRAY_BIN" 2>/dev/null) || {
            XRAY_RECOVERY_EXTERNAL_CONFLICT=1
            return 1
        }
        if [[ "$old_exists" == 1 && "$current_digest" == "$old_digest" ]] &&
           _xray_binary_metadata_matches "$XRAY_BIN" "$old_mode"; then
            if [[ "$was_active" == 0 ]] && (service_is_active xray || xray_process_exists); then
                XRAY_RECOVERY_EXTERNAL_CONFLICT=1
                log_error "Refusing recovery because Xray became active outside the transaction"
                return 1
            fi
            return 0
        fi
        [[ "$current_digest" == "$new_digest" ]] &&
            _xray_binary_metadata_matches "$XRAY_BIN" 0755 || {
            XRAY_RECOVERY_EXTERNAL_CONFLICT=1
            log_error "Refusing recovery because the current Xray binary is external to the journal"
            return 1
        }
        if service_is_active xray || xray_process_exists; then
            _xray_stop_and_wait "$XRAY_BIN" "$new_digest" || return 1
        fi
        xray_preserve_transaction_target "$XRAY_BIN" "$failed" "$new_digest" 0755 || return 1
    elif service_is_active xray || xray_process_exists; then
        XRAY_RECOVERY_EXTERNAL_CONFLICT=1
        log_error "Refusing recovery while an unidentifiable Xray process exists"
        return 1
    fi
    [[ "$old_exists" == 1 ]] || return 0
    for source in "$restore_stage" "$displaced" "$backup"; do
        [[ -f "$source" && ! -L "$source" ]] || continue
        xray_link_transaction_target "$source" "$XRAY_BIN" "$old_digest" "$old_mode" && return 0
        [[ ! -e "$XRAY_BIN" && ! -L "$XRAY_BIN" ]] || return 1
    done
    log_error "No verified old Xray binary is available for recovery"
    return 1
}

install_xray() {
    local current
    recover_pending_xray_update_locked || return 1
    if current=$(get_installed_xray_version "$XRAY_BIN" 2>/dev/null); then
        # Creating a node must never silently replace or downgrade an existing
        # healthy Xray, even when a channel/version environment variable exists.
        ensure_xray_service_definition || return 1
        log_info "Xray already installed: $current (leaving it unchanged)"
        return 0
    fi
    if [[ -e "$XRAY_BIN" || -L "$XRAY_BIN" ]]; then
        log_error "An existing Xray binary cannot report a valid version; repair it with XRAY_VERSION=... xray-update"
        return 1
    fi
    log_info "$(msg install_xray)"
    install_xray_fresh || return 1
    ensure_xray_service_definition || return 1
    log_info "Xray installed successfully"
}

# Backward-compatible internal entry point.
install_xray_alpine() {
    install_xray_fresh && ensure_xray_service_definition
}

_xray_definition_should_publish() {
    local target="$1" legacy="$3" marker='# proxy-hub-managed: xray-service-v1' size
    [[ ! -e "$target" && ! -L "$target" ]] && return 0
    [[ -f "$target" && ! -L "$target" ]] || return 1
    grep -Fxq "$marker" "$target" 2>/dev/null && return 0
    size=$(stat -c '%s' "$target" 2>/dev/null) || return 1
    [[ "$size" =~ ^[0-9]+$ && "$size" -le "$(stat -c '%s' "$legacy")" ]] || return 1
    cmp -n "$size" "$target" "$legacy" >/dev/null 2>&1
}

_xray_publish_managed_definition() {
    local source="$1" target="$2" mode="$3"
    _xray_prepare_managed_file_parent "$target" || return 1
    chmod "$mode" "$source" || return 1
    _xray_sync_path "$source" || return 1
    mv -f -T -- "$source" "$target" || return 1
    _xray_sync_path "$target" || return 1
    _xray_sync_path "$(dirname "$target")"
}

# 创建 Xray OpenRC 服务脚本
create_xray_openrc_service() {
    local target=/etc/init.d/xray tmp legacy
    _xray_prepare_managed_file_parent "$target" || return 1
    mkdir -p /var/log/xray
    tmp=$(mktemp /etc/init.d/.xray.proxy-hub.XXXXXXXX) || return 1
    legacy="${tmp}.legacy"
    cat > "$tmp" <<'OPENRC_SERVICE'
#!/sbin/openrc-run
# proxy-hub-managed: xray-service-v1

name="xray"
description="Xray - A platform for building proxies"

command="/usr/local/bin/xray"
command_args="run -config /usr/local/etc/xray/config.json"
command_background="yes"
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/xray/access.log"
error_log="/var/log/xray/error.log"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath --directory --owner root:root --mode 0755 /var/log/xray
}
OPENRC_SERVICE
    grep -Fv '# proxy-hub-managed: xray-service-v1' "$tmp" > "$legacy" || {
        rm -f -- "$tmp" "$legacy"
        return 1
    }
    if ! _xray_definition_should_publish "$target" "$tmp" "$legacy"; then
        rm -f -- "$tmp" "$legacy"
        return 0
    fi
    bash -n "$tmp" || {
        rm -f -- "$tmp" "$legacy"
        return 1
    }
    rm -f -- "$legacy"
    _xray_publish_managed_definition "$tmp" "$target" 0755 || {
        rm -f -- "$tmp"
        return 1
    }
}

create_xray_systemd_service() {
    local unit_path=/etc/systemd/system/xray.service tmp legacy
    if [[ ! -e "$unit_path" && ! -L "$unit_path" ]] && systemctl cat xray.service >/dev/null 2>&1; then
        return 0
    fi
    _xray_prepare_managed_file_parent "$unit_path" || return 1
    mkdir -p /var/log/xray
    tmp=$(mktemp /etc/systemd/system/.xray.service.proxy-hub.XXXXXXXX) || return 1
    legacy="${tmp}.legacy"
    cat > "$tmp" <<'UNIT'
# proxy-hub-managed: xray-service-v1
[Unit]
Description=Xray Service
Documentation=https://github.com/XTLS/Xray-core
After=network.target nss-lookup.target

[Service]
Type=simple
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
UNIT
    grep -Fv '# proxy-hub-managed: xray-service-v1' "$tmp" > "$legacy" || {
        rm -f -- "$tmp" "$legacy"
        return 1
    }
    if ! _xray_definition_should_publish "$unit_path" "$tmp" "$legacy"; then
        rm -f -- "$tmp" "$legacy"
        return 0
    fi
    grep -Fxq 'ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json' "$tmp" || {
        rm -f -- "$tmp" "$legacy"
        return 1
    }
    rm -f -- "$legacy"
    _xray_publish_managed_definition "$tmp" "$unit_path" 0644 || {
        rm -f -- "$tmp"
        return 1
    }
    systemctl daemon-reload
}

ensure_xray_service_definition() {
    if [[ "$INIT_SYSTEM" == openrc ]]; then
        create_xray_openrc_service
    else
        create_xray_systemd_service
    fi
}

# ============== sing-box 安装（AnyTLS / Hysteria2 支持） ==============

# 创建 sing-box systemd 服务
create_singbox_systemd_service() {
    cat > /etc/systemd/system/sing-box.service <<'UNIT'
[Unit]
Description=sing-box service (AnyTLS / Hysteria2)
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c /usr/local/etc/sing-box/config.json
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload 2>/dev/null || true
}

# 创建 sing-box OpenRC 服务（Alpine）
create_singbox_openrc_service() {
    cat > /etc/init.d/sing-box <<'OPENRC_SERVICE'
#!/sbin/openrc-run

name="sing-box"
description="sing-box service (AnyTLS / Hysteria2)"

command="/usr/local/bin/sing-box"
command_args="run -c /usr/local/etc/sing-box/config.json"
command_background="yes"
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.log"

depend() {
    need net
    after firewall
}
OPENRC_SERVICE
    chmod 755 /etc/init.d/sing-box
}

# 安装 sing-box（下载官方预编译二进制，适用于所有发行版包括 Alpine）
# AnyTLS 协议需要 sing-box >= 1.12.0；同一内核也承载 Hysteria2。
install_singbox() {
    if [[ -f "$SINGBOX_BIN" ]] && "$SINGBOX_BIN" version &>/dev/null; then
        log_info "sing-box already installed, skipping..."
        return 0
    fi

    log_info "Installing sing-box (required for AnyTLS / Hysteria2)..."

    local arch sb_arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)   sb_arch="amd64" ;;
        aarch64|arm64)  sb_arch="arm64" ;;
        armv7l|armv7)   sb_arch="armv7" ;;
        i686|i386)      sb_arch="386" ;;
        *)
            log_error "Unsupported architecture for sing-box: $arch"
            return 1
            ;;
    esac

    # 获取最新版本号（安全的 API 解析）
    local tag version
    tag=$(fetch_github_release_tag "SagerNet/sing-box")
    if [[ -z "$tag" ]]; then
        log_error "Failed to get sing-box latest version"
        return 1
    fi
    version="${tag#v}"

    log_info "Installing sing-box ${tag} (${sb_arch})..."

    local download_url="https://github.com/SagerNet/sing-box/releases/download/${tag}/sing-box-${version}-linux-${sb_arch}.tar.gz"
    local tmp_dir
    tmp_dir=$(mktemp -d)

    if ! secure_curl "$download_url" -o "${tmp_dir}/sing-box.tar.gz"; then
        log_error "Failed to download sing-box from $download_url"
        rm -rf "$tmp_dir"
        return 1
    fi

    if ! tar -xzf "${tmp_dir}/sing-box.tar.gz" -C "$tmp_dir" 2>/dev/null; then
        log_error "Failed to extract sing-box archive"
        rm -rf "$tmp_dir"
        return 1
    fi

    local extracted_bin
    extracted_bin=$(find "$tmp_dir" -type f -name sing-box 2>/dev/null | head -1)
    if [[ -z "$extracted_bin" ]]; then
        log_error "sing-box binary not found in archive"
        rm -rf "$tmp_dir"
        return 1
    fi

    mkdir -p "$SINGBOX_DIR" /usr/local/bin
    install -m 755 "$extracted_bin" "$SINGBOX_BIN"
    rm -rf "$tmp_dir"

    # 创建服务（systemd 或 OpenRC）
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        create_singbox_openrc_service
    else
        create_singbox_systemd_service
    fi

    log_info "sing-box ${tag} installed successfully"
    return 0
}

# ============== GeoData 安装 ==============

# 按需确保 GeoIP/GeoSite 数据库存在（仅 WARP 分流的 geosite 规则需要）。
# 已存在则跳过，避免无谓的重复下载。
ensure_geodata() {
    if [[ -f "$XRAY_GEODATA_DIR/geoip.dat" ]] && [[ -f "$XRAY_GEODATA_DIR/geosite.dat" ]]; then
        return 0
    fi
    install_geodata
}

install_geodata() {
    log_info "$(msg install_geodata)"

    mkdir -p "$XRAY_GEODATA_DIR"

    local geoip_url="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
    local geosite_url="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"

    # 下载 geoip.dat（使用安全的 curl 选项，内联因为 execute_task 在子 shell 运行）
    if execute_task "curl --proto '=https' --tlsv1.2 -fsSL '$geoip_url' -o '$XRAY_GEODATA_DIR/geoip.dat'" "Downloading geoip.dat"; then
        # 创建软链接到 /usr/local/bin (Xray 查找位置)
        ln -sf "$XRAY_GEODATA_DIR/geoip.dat" /usr/local/bin/geoip.dat 2>/dev/null || true
    fi

    # 下载 geosite.dat
    if execute_task "curl --proto '=https' --tlsv1.2 -fsSL '$geosite_url' -o '$XRAY_GEODATA_DIR/geosite.dat'" "Downloading geosite.dat"; then
        ln -sf "$XRAY_GEODATA_DIR/geosite.dat" /usr/local/bin/geosite.dat 2>/dev/null || true
    fi

    # 设置自动更新定时任务（每周日 4:00）
    setup_geodata_cron

    log_info "$(msg geodata_updated)"
}

setup_geodata_cron() {
    # Use secure curl options in cron job (--proto, --tlsv1.2)
    local cron_cmd="curl --proto '=https' --tlsv1.2 -fsSL https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat -o $XRAY_GEODATA_DIR/geoip.dat && curl --proto '=https' --tlsv1.2 -fsSL https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat -o $XRAY_GEODATA_DIR/geosite.dat"
    local cron_job="0 4 * * 0 $cron_cmd >/dev/null 2>&1"

    # 检查 crontab 命令是否存在
    if ! command -v crontab &>/dev/null; then
        return 0
    fi

    # 添加定时任务（先删除旧的）
    (crontab -l 2>/dev/null | grep -v 'geoip.dat' | grep -v 'geosite.dat'; echo "$cron_job") | crontab - 2>/dev/null || true
}

# ============== Xray 定时重启 ==============

XRAY_RESTART_CONF="/etc/proxy-hub/xray-restart.conf"
XRAY_RESTART_NAME="xray-restart"
XRAY_RESTART_SYSTEMD_SERVICE="/etc/systemd/system/${XRAY_RESTART_NAME}.service"
XRAY_RESTART_SYSTEMD_TIMER="/etc/systemd/system/${XRAY_RESTART_NAME}.timer"
XRAY_RESTART_CRON_MARKER="# proxy-hub-xray-restart"
XRAY_RESTART_HELPER="/usr/local/libexec/proxy-hub-xray-restart"

# 调度选择的全局返回值
XRAY_RESTART_LABEL=""
XRAY_RESTART_CRON=""
XRAY_RESTART_CALENDAR=""

is_xray_restart_enabled() {
    [[ -f "$XRAY_RESTART_CONF" ]] && grep -q "^RESTART_ENABLED=yes" "$XRAY_RESTART_CONF" 2>/dev/null
}

get_xray_restart_label() {
    [[ -f "$XRAY_RESTART_CONF" ]] || return 0
    grep "^RESTART_LABEL=" "$XRAY_RESTART_CONF" 2>/dev/null | cut -d'=' -f2- | tr -d '"'
}

get_xray_restart_backend() {
    [[ -f "$XRAY_RESTART_CONF" ]] || return 0
    grep "^RESTART_BACKEND=" "$XRAY_RESTART_CONF" 2>/dev/null | cut -d'=' -f2- | tr -d '"'
}

# 将标签翻译为人类可读字符串
xray_restart_describe_label() {
    case "$1" in
        daily)  msg xray_restart_daily ;;
        12h)    msg xray_restart_12h ;;
        6h)     msg xray_restart_6h ;;
        weekly) msg xray_restart_weekly ;;
        custom) msg xray_restart_custom ;;
        *)      echo "$1" ;;
    esac
}

save_xray_restart_config() {
    local label="$1" cron_expr="$2" systemd_cal="$3" backend="$4"
    mkdir -p "$(dirname "$XRAY_RESTART_CONF")"
    cat > "$XRAY_RESTART_CONF" <<EOF
# Xray periodic restart config - managed by proxy-hub
RESTART_ENABLED=yes
RESTART_LABEL="$label"
RESTART_CRON="$cron_expr"
RESTART_SYSTEMD_CALENDAR="$systemd_cal"
RESTART_BACKEND="$backend"
EOF
    chmod 600 "$XRAY_RESTART_CONF"
}

install_xray_restart_helper() {
    local target="$XRAY_RESTART_HELPER" tmp marker='# proxy-hub-managed: xray-restart-helper-v1'
    [[ "$target" == /usr/local/libexec/proxy-hub-xray-restart ]] || return 1
    _xray_prepare_managed_file_parent "$target" || return 1
    if [[ -e "$target" || -L "$target" ]]; then
        [[ -f "$target" && ! -L "$target" ]] || return 1
        grep -Fxq "$marker" "$target" 2>/dev/null || {
            log_error "Refusing to overwrite an unmanaged restart helper: $target"
            return 1
        }
    fi
    tmp=$(mktemp /usr/local/libexec/.proxy-hub-xray-restart.XXXXXXXX) || return 1
    cat > "$tmp" <<'RESTART_HELPER'
#!/usr/bin/env bash
# proxy-hub-managed: xray-restart-helper-v1
set -u
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
lock=/run/proxy-hub-xray-lifecycle.lock

[[ "${EUID:-$(id -u)}" == 0 ]] || exit 1
[[ -d /run && ! -L /run && "$(stat -c '%u' /run 2>/dev/null)" == 0 ]] || exit 1
run_mode=$(stat -c '%a' /run 2>/dev/null) || exit 1
[[ "$run_mode" =~ ^[0-7]{3,4}$ ]] || exit 1
(((8#$run_mode & 022) == 0)) || exit 1
if [[ -e "$lock" || -L "$lock" ]]; then
    [[ -f "$lock" && ! -L "$lock" && "$(stat -c '%u' "$lock" 2>/dev/null)" == 0 ]] || exit 1
    lock_mode=$(stat -c '%a' "$lock" 2>/dev/null) || exit 1
    [[ "$lock_mode" =~ ^[0-7]{3,4}$ ]] || exit 1
    (((8#$lock_mode & 022) == 0)) || exit 1
fi
umask 077
exec 9>>"$lock" || exit 1
[[ -f "$lock" && ! -L "$lock" && "$(stat -c '%u' "$lock" 2>/dev/null)" == 0 ]] || exit 1
path_id=$(stat -Lc '%d:%i' "$lock" 2>/dev/null) || exit 1
fd_id=$(stat -Lc '%d:%i' "/proc/$$/fd/9" 2>/dev/null) || exit 1
[[ "$path_id" == "$fd_id" ]] || exit 1
flock -n 9 || exit 0

status=0
if command -v systemctl >/dev/null 2>&1; then
    for unit in xray sing-box; do
        systemctl is-active --quiet "$unit.service" 2>/dev/null || continue
        systemctl restart "$unit.service" >/dev/null 2>&1 || status=1
    done
elif command -v rc-service >/dev/null 2>&1; then
    for service in xray sing-box; do
        [[ -e "/etc/init.d/$service" ]] || continue
        rc-service "$service" status >/dev/null 2>&1 || continue
        rc-service "$service" restart >/dev/null 2>&1 || status=1
    done
fi
exit "$status"
RESTART_HELPER
    bash -n "$tmp" || {
        rm -f -- "$tmp"
        return 1
    }
    _xray_publish_managed_definition "$tmp" "$target" 0755 || {
        rm -f -- "$tmp"
        return 1
    }
}

# 通过 systemd timer + service 安装（Ubuntu/Debian/CentOS 等）
install_xray_restart_systemd() {
    local systemd_cal="$1"
    [[ "$XRAY_LIFECYCLE_LOCK" == "$XRAY_PRODUCTION_LIFECYCLE_LOCK" ]] || return 1
    install_xray_restart_helper || return 1

    cat > "$XRAY_RESTART_SYSTEMD_SERVICE" <<EOF
[Unit]
Description=Restart proxy cores (proxy-hub)
After=xray.service sing-box.service

[Service]
Type=oneshot
ExecStart=$XRAY_RESTART_HELPER
EOF

    cat > "$XRAY_RESTART_SYSTEMD_TIMER" <<EOF
[Unit]
Description=Periodic restart for Xray (proxy-hub)

[Timer]
OnCalendar=$systemd_cal
Persistent=true
Unit=${XRAY_RESTART_NAME}.service

[Install]
WantedBy=timers.target
EOF

    chmod 644 "$XRAY_RESTART_SYSTEMD_SERVICE" "$XRAY_RESTART_SYSTEMD_TIMER"

    systemctl daemon-reload 2>/dev/null || return 1
    systemctl enable --now "${XRAY_RESTART_NAME}.timer" >/dev/null 2>&1 || return 1
    return 0
}

# 通过 crontab 安装（Alpine/OpenRC，以及自定义 cron 表达式场景）
install_xray_restart_cron() {
    local cron_expr="$1"
    [[ "$XRAY_LIFECYCLE_LOCK" == "$XRAY_PRODUCTION_LIFECYCLE_LOCK" ]] || return 1

    if ! command -v crontab &>/dev/null; then
        log_warn "crontab not available; cannot schedule Xray restart"
        return 1
    fi

    install_xray_restart_helper || return 1
    local cron_line="$cron_expr $XRAY_RESTART_HELPER >/dev/null 2>&1 $XRAY_RESTART_CRON_MARKER"

    if ! (crontab -l 2>/dev/null | grep -v "$XRAY_RESTART_CRON_MARKER"; echo "$cron_line") | crontab - 2>/dev/null; then
        log_warn "Failed to write crontab for Xray restart"
        return 1
    fi

    # Alpine / OpenRC：确保 crond 已启用并运行
    if [[ "$INIT_SYSTEM" == "openrc" ]] && command -v rc-service &>/dev/null; then
        rc-service crond status &>/dev/null || rc-service crond start &>/dev/null || true
        rc-update show default 2>/dev/null | grep -q crond || rc-update add crond default &>/dev/null || true
    fi

    return 0
}

remove_xray_restart_systemd() {
    if command -v systemctl &>/dev/null && [[ -f "$XRAY_RESTART_SYSTEMD_TIMER" ]]; then
        systemctl disable --now "${XRAY_RESTART_NAME}.timer" >/dev/null 2>&1 || true
    fi
    rm -f "$XRAY_RESTART_SYSTEMD_SERVICE" "$XRAY_RESTART_SYSTEMD_TIMER"
    if command -v systemctl &>/dev/null; then
        systemctl daemon-reload 2>/dev/null || true
    fi
}

remove_xray_restart_cron() {
    if command -v crontab &>/dev/null; then
        crontab -l 2>/dev/null | grep -v "$XRAY_RESTART_CRON_MARKER" | crontab - 2>/dev/null || true
    fi
}

remove_xray_restart_schedule() {
    remove_xray_restart_systemd
    remove_xray_restart_cron
    rm -f "$XRAY_RESTART_CONF"
}

# 统一安装入口
# $1 label  $2 cron expr  $3 systemd OnCalendar (可为空)
setup_xray_restart_schedule() {
    local label="$1" cron_expr="$2" systemd_cal="$3"

    # Publish the validated fixed-path lock helper before disturbing an existing
    # schedule, so helper creation failure leaves the current schedule intact.
    install_xray_restart_helper || return 1

    # 清理旧的
    remove_xray_restart_systemd
    remove_xray_restart_cron

    local backend=""
    if [[ "$INIT_SYSTEM" == "systemd" ]] && command -v systemctl &>/dev/null && [[ -n "$systemd_cal" ]]; then
        if install_xray_restart_systemd "$systemd_cal"; then
            backend="systemd-timer"
        else
            log_warn "systemd timer setup failed, falling back to cron"
            if install_xray_restart_cron "$cron_expr"; then
                backend="cron"
            fi
        fi
    else
        if install_xray_restart_cron "$cron_expr"; then
            backend="cron"
        fi
    fi

    if [[ -z "$backend" ]]; then
        return 1
    fi

    save_xray_restart_config "$label" "$cron_expr" "$systemd_cal" "$backend"
    return 0
}

# 让用户选择一个预设调度或输入 cron 表达式
# 结果写入 XRAY_RESTART_LABEL / XRAY_RESTART_CRON / XRAY_RESTART_CALENDAR
prompt_xray_restart_choose_schedule() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}                  $(msg xray_restart_choose)${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${GREEN}1.${NC} $(msg xray_restart_daily) [${YELLOW}$(msg xray_restart_default)${NC}]"
    echo -e "  ${GREEN}2.${NC} $(msg xray_restart_12h)"
    echo -e "  ${GREEN}3.${NC} $(msg xray_restart_6h)"
    echo -e "  ${GREEN}4.${NC} $(msg xray_restart_weekly)"
    echo -e "  ${GREEN}5.${NC} $(msg xray_restart_custom)"
    echo ""
    echo -n "  $(msg menu_choice) [1-5]: "
    read -r choice
    case "$choice" in
        2)
            XRAY_RESTART_LABEL="12h"
            XRAY_RESTART_CRON="0 */12 * * *"
            XRAY_RESTART_CALENDAR="*-*-* 00/12:00:00"
            ;;
        3)
            XRAY_RESTART_LABEL="6h"
            XRAY_RESTART_CRON="0 */6 * * *"
            XRAY_RESTART_CALENDAR="*-*-* 00/6:00:00"
            ;;
        4)
            XRAY_RESTART_LABEL="weekly"
            XRAY_RESTART_CRON="0 4 * * 0"
            XRAY_RESTART_CALENDAR="Sun *-*-* 04:00:00"
            ;;
        5)
            echo ""
            echo -e "  $(msg xray_restart_cron_hint)"
            echo -n "  $(msg xray_restart_cron_prompt): "
            local custom_cron
            read -r custom_cron
            # 简单验证：5 个字段
            if [[ -z "$custom_cron" || ! "$custom_cron" =~ ^[0-9*/?,[:space:]-]+$ ]] \
                || [[ $(awk '{print NF}' <<< "$custom_cron") -ne 5 ]]; then
                log_warn "$(msg xray_restart_cron_invalid)"
                XRAY_RESTART_LABEL="daily"
                XRAY_RESTART_CRON="0 4 * * *"
                XRAY_RESTART_CALENDAR="*-*-* 04:00:00"
            else
                XRAY_RESTART_LABEL="custom"
                XRAY_RESTART_CRON="$custom_cron"
                # 自定义 cron 强制走 crontab 后端
                XRAY_RESTART_CALENDAR=""
            fi
            ;;
        *)
            XRAY_RESTART_LABEL="daily"
            XRAY_RESTART_CRON="0 4 * * *"
            XRAY_RESTART_CALENDAR="*-*-* 04:00:00"
            ;;
    esac
}

# 创建节点时询问是否启用定时重启
prompt_xray_restart_on_install() {
    # 已配置过则仅提示当前状态
    if is_xray_restart_enabled; then
        local cur
        cur=$(xray_restart_describe_label "$(get_xray_restart_label)")
        log_info "$(msg xray_restart_already): $cur"
        return 0
    fi

    # 支持环境变量自动选择
    if [[ -n "${restart:-}" ]]; then
        case "$restart" in
            no|false|0|n)
                return 0
                ;;
            daily|yes|true|1|y)
                XRAY_RESTART_LABEL="daily"
                XRAY_RESTART_CRON="0 4 * * *"
                XRAY_RESTART_CALENDAR="*-*-* 04:00:00"
                ;;
            12h)
                XRAY_RESTART_LABEL="12h"
                XRAY_RESTART_CRON="0 */12 * * *"
                XRAY_RESTART_CALENDAR="*-*-* 00/12:00:00"
                ;;
            6h)
                XRAY_RESTART_LABEL="6h"
                XRAY_RESTART_CRON="0 */6 * * *"
                XRAY_RESTART_CALENDAR="*-*-* 00/6:00:00"
                ;;
            weekly)
                XRAY_RESTART_LABEL="weekly"
                XRAY_RESTART_CRON="0 4 * * 0"
                XRAY_RESTART_CALENDAR="Sun *-*-* 04:00:00"
                ;;
            *)
                log_warn "Unknown restart value: $restart (use: daily/12h/6h/weekly/no)"
                return 0
                ;;
        esac
        if setup_xray_restart_schedule "$XRAY_RESTART_LABEL" "$XRAY_RESTART_CRON" "$XRAY_RESTART_CALENDAR"; then
            log_info "$(msg xray_restart_enabled): $(xray_restart_describe_label "$XRAY_RESTART_LABEL")"
        else
            log_warn "$(msg xray_restart_setup_failed)"
        fi
        return 0
    fi

    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${YELLOW}⏰${NC}  $(msg xray_restart_prompt)"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -n "  [y/N]: "
    local answer
    read -r answer
    [[ ! "$answer" =~ ^[Yy]$ ]] && return 0

    prompt_xray_restart_choose_schedule

    if setup_xray_restart_schedule "$XRAY_RESTART_LABEL" "$XRAY_RESTART_CRON" "$XRAY_RESTART_CALENDAR"; then
        log_info "$(msg xray_restart_enabled): $(xray_restart_describe_label "$XRAY_RESTART_LABEL")"
    else
        log_warn "$(msg xray_restart_setup_failed)"
    fi
}

# 工具菜单入口：显示当前状态并允许修改/禁用
cmd_xray_restart() {
    while true; do
        clear
        echo ""
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}                  $(msg xray_restart_title)${NC}"
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo ""
        if is_xray_restart_enabled; then
            local cur backend
            cur=$(xray_restart_describe_label "$(get_xray_restart_label)")
            backend=$(get_xray_restart_backend)
            echo -e "  $(msg xray_restart_status): ${GREEN}$(msg xray_restart_status_on)${NC}"
            echo -e "  $(msg xray_restart_current): ${YELLOW}$cur${NC}"
            echo -e "  $(msg xray_restart_backend): ${BLUE}$backend${NC}"
        else
            echo -e "  $(msg xray_restart_status): ${RED}$(msg xray_restart_status_off)${NC}"
        fi
        echo ""
        echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
        echo -e "  ${GREEN}1.${NC} $(msg xray_restart_action_set)"
        echo -e "  ${GREEN}2.${NC} $(msg xray_restart_action_disable)"
        echo -e "  ${RED}0.${NC} $(msg xray_restart_back)"
        echo ""
        echo -n "  $(msg menu_choice) [0-2]: "
        local choice
        read -r choice
        case "$choice" in
            1)
                prompt_xray_restart_choose_schedule
                if setup_xray_restart_schedule "$XRAY_RESTART_LABEL" "$XRAY_RESTART_CRON" "$XRAY_RESTART_CALENDAR"; then
                    log_info "$(msg xray_restart_enabled): $(xray_restart_describe_label "$XRAY_RESTART_LABEL")"
                else
                    log_warn "$(msg xray_restart_setup_failed)"
                fi
                echo ""
                read -rp "$(msg menu_press_enter)"
                ;;
            2)
                if is_xray_restart_enabled; then
                    remove_xray_restart_schedule
                    log_info "$(msg xray_restart_disabled)"
                else
                    log_info "$(msg xray_restart_not_enabled)"
                fi
                echo ""
                read -rp "$(msg menu_press_enter)"
                ;;
            0) return ;;
            *) ;;
        esac
    done
}

# ============== 协议类型选择 ==============

# 协议类型: vision, xhttp, both, shadowsocks, anytls, anytls_reality, hysteria2
#
# 节点作用域变量（PROTOCOL_TYPE / UUID / SNI / REALITY 密钥 / 各协议密码等）的默认值
# 统一在 lib/00_security_state.sh 的 reset_node_state() 中定义，并在该模块加载时执行一次。
# 此处曾经维护一份平行的默认值清单，但它只覆盖了部分字段（缺少 UUID / SNI / REALITY 密钥），
# 导致 anytls_reality 这类不赋值 UUID 的协议分支在 `set -u` 下于 save_env 处崩溃。
# 因此不要在这里重新引入清单——新增字段请只改 reset_node_state()。

# Shadowsocks 支持的加密方式
SS_METHODS_2022=(
    "2022-blake3-aes-256-gcm"
    "2022-blake3-chacha20-poly1305"
)
SS_METHODS_LEGACY=(
    "chacha20-ietf-poly1305"
    "aes-256-gcm"
)

# 选择协议类型
prompt_protocol_type() {
    {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}                     选择节点协议类型${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${GREEN}1.${NC} VLESS + Vision + REALITY  ${GRAY}(TCP 传输, 推荐)${NC}"
    echo -e "  ${GREEN}2.${NC} VLESS + XHTTP + REALITY   ${GRAY}(XHTTP 传输)${NC}"
    echo -e "  ${GREEN}3.${NC} 两个都安装               ${GRAY}(生成两个端口)${NC}"
    echo -e "  ${GREEN}4.${NC} Shadowsocks 2022         ${GRAY}(SS 协议, 高性能)${NC}"
    echo -e "  ${GREEN}5.${NC} AnyTLS                   ${GRAY}(sing-box, 自签名证书)${NC}"
    echo -e "  ${GREEN}6.${NC} AnyTLS + REALITY         ${GRAY}(sing-box, 抗封锁, 推荐)${NC}"
    echo -e "  ${GREEN}7.${NC} Hysteria2                ${GRAY}(sing-box, QUIC/UDP)${NC}"
    echo ""
    echo -n "  请选择 [1-7] (默认 1): "
    } >/dev/tty

    local choice
    read -r choice </dev/tty

    case "$choice" in
        2)
            PROTOCOL_TYPE="xhttp"
            log_info "已选择: VLESS + XHTTP + REALITY"
            ;;
        3)
            PROTOCOL_TYPE="both"
            log_info "已选择: Vision + XHTTP 双协议"
            ;;
        4)
            PROTOCOL_TYPE="shadowsocks"
            log_info "已选择: Shadowsocks 2022"
            ;;
        5)
            PROTOCOL_TYPE="anytls"
            log_info "已选择: AnyTLS"
            ;;
        6)
            PROTOCOL_TYPE="anytls_reality"
            log_info "已选择: AnyTLS + REALITY"
            ;;
        7)
            PROTOCOL_TYPE="hysteria2"
            log_info "已选择: Hysteria2"
            ;;
        *)
            PROTOCOL_TYPE="vision"
            log_info "已选择: VLESS + Vision + REALITY"
            ;;
    esac
}

# 选择 Shadowsocks 加密方式
prompt_ss_method() {
    {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}                  Shadowsocks 加密方式${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${YELLOW}推荐 (2022 协议, 更安全):${NC}"
    echo -e "  ${GREEN}1.${NC} 2022-blake3-aes-256-gcm      ${GRAY}(推荐, 硬件加速)${NC}"
    echo -e "  ${GREEN}2.${NC} 2022-blake3-chacha20-poly1305 ${GRAY}(移动设备优化)${NC}"
    echo ""
    echo -e "  ${YELLOW}传统方式 (兼容性更好):${NC}"
    echo -e "  ${GREEN}3.${NC} chacha20-ietf-poly1305       ${GRAY}(广泛支持)${NC}"
    echo -e "  ${GREEN}4.${NC} aes-256-gcm                  ${GRAY}(经典加密)${NC}"
    echo ""
    echo -n "  请选择 [1-4] (默认 1): "
    } >/dev/tty

    local choice
    read -r choice </dev/tty

    case "$choice" in
        2)
            SS_METHOD="2022-blake3-chacha20-poly1305"
            ;;
        3)
            SS_METHOD="chacha20-ietf-poly1305"
            ;;
        4)
            SS_METHOD="aes-256-gcm"
            ;;
        *)
            SS_METHOD="2022-blake3-aes-256-gcm"
            ;;
    esac
    log_info "加密方式: $SS_METHOD"
}

# 生成 Shadowsocks 密码/密钥
gen_ss_password() {
    # 2022 协议需要 base64 编码的预共享密钥
    # 2022-blake3-aes-256-gcm 和 2022-blake3-chacha20-poly1305 需要 32 字节
    # 传统方式使用随机字符串密码
    case "$SS_METHOD" in
        2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305)
            SS_PASSWORD=$(openssl rand -base64 32)
            ;;
        2022-blake3-aes-128-gcm)
            SS_PASSWORD=$(openssl rand -base64 16)
            ;;
        *)
            # 传统方式：生成 16 字符随机密码
            SS_PASSWORD=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
            ;;
    esac
    log_info "密码已生成"
}

# Hysteria2 authentication is embedded in config and URI output. Restrict it
# to the URI-unreserved subset so user input cannot alter either structure.
validate_hy2_password() {
    [[ "$1" =~ ^[a-zA-Z0-9._~-]{8,128}$ ]]
}

gen_hy2_password() {
    local candidate="${hy2pwd:-$(openssl rand -hex 24)}"
    if ! validate_hy2_password "$candidate"; then
        log_error "Hysteria2 password must be 8-128 URI-safe characters (A-Z, a-z, 0-9, . _ ~ -)"
        return 1
    fi
    HY2_PASSWORD="$candidate"
    log_info "Hysteria2 密码已生成"
}

gen_uuid() {
    UUID="${uuid:-$(cat /proc/sys/kernel/random/uuid)}"
}

# 生成一个可用的随机端口
gen_random_free_port() {
    local exclude_port="${1:-0}"
    local transport="${2:-tcp}"
    local port
    while true; do
        port="$(shuf -i ${PORT_MIN}-${PORT_MAX} -n 1)"
        if is_port_free "$port" "$transport" && [[ "$port" != "$exclude_port" ]]; then
            echo "$port"
            return 0
        fi
    done
}

# 交互式选择端口
# Usage: prompt_port "提示信息" "默认端口" "排除端口(可选)"
prompt_port() {
    local prompt_msg="$1"
    local default_port="$2"
    local exclude_port="${3:-0}"
    local transport="${4:-tcp}"
    local user_port

    while true; do
        echo -n "  $prompt_msg [默认: $default_port]: " >/dev/tty
        read -r user_port </dev/tty

        # 用户直接回车，使用默认端口
        if [[ -z "$user_port" ]]; then
            echo "$default_port"
            return 0
        fi

        # 验证端口格式
        if ! [[ "$user_port" =~ ^[0-9]+$ ]]; then
            echo -e "  ${RED}端口必须是数字${NC}" >/dev/tty
            continue
        fi

        # 验证端口范围
        if [[ "$user_port" -lt 1 || "$user_port" -gt 65535 ]]; then
            echo -e "  ${RED}端口必须在 1-65535 之间${NC}" >/dev/tty
            continue
        fi

        # 检查是否与排除端口冲突
        if [[ "$user_port" == "$exclude_port" ]]; then
            echo -e "  ${RED}端口不能与其他服务端口相同${NC}" >/dev/tty
            continue
        fi

        # 检查端口是否被占用
        if ! is_port_free "$user_port" "$transport"; then
            echo -e "  ${YELLOW}端口 $user_port 已被占用，是否仍然使用? [y/N]: ${NC}" >/dev/tty
            read -r confirm </dev/tty
            if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                echo "$user_port"
                return 0
            fi
            continue
        fi

        echo "$user_port"
        return 0
    done
}

# 选择端口（根据协议类型）
choose_ports() {
    {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}                     端口配置${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    } >/dev/tty

    # Shadowsocks 端口
    if [[ "$PROTOCOL_TYPE" == "shadowsocks" ]]; then
        if [[ -n "${sspt:-}" ]]; then
            # 环境变量指定
            PORT="$sspt"
        elif [[ -n "${vlpt:-}" ]]; then
            # 兼容 vlpt 变量
            PORT="$vlpt"
        else
            # 交互式选择
            local default_ss_port
            default_ss_port=$(gen_random_free_port)
            PORT=$(prompt_port "Shadowsocks 端口" "$default_ss_port")
        fi
        log_info "Shadowsocks 端口: $PORT"
        XHTTP_PORT=""
        XHTTP_PATH=""
        echo "" >/dev/tty
        return 0
    fi

    # AnyTLS 端口
    if [[ "$PROTOCOL_TYPE" == "anytls" || "$PROTOCOL_TYPE" == "anytls_reality" ]]; then
        if [[ -n "${atpt:-}" ]]; then
            PORT="$atpt"
        elif [[ -n "${vlpt:-}" ]]; then
            PORT="$vlpt"
        else
            local default_at_port
            default_at_port=$(gen_random_free_port)
            PORT=$(prompt_port "AnyTLS 端口" "$default_at_port")
        fi
        log_info "AnyTLS 端口: $PORT"
        XHTTP_PORT=""
        XHTTP_PATH=""
        echo "" >/dev/tty
        return 0
    fi

    # Hysteria2 使用 QUIC/UDP，端口占用检查必须查询 UDP socket。
    if [[ "$PROTOCOL_TYPE" == "hysteria2" ]]; then
        if [[ -n "${hy2pt:-}" ]]; then
            PORT="$hy2pt"
        elif [[ -n "${vlpt:-}" ]]; then
            PORT="$vlpt"
        else
            local default_hy2_port
            default_hy2_port=$(gen_random_free_port 0 udp)
            PORT=$(prompt_port "Hysteria2 端口 (UDP)" "$default_hy2_port" 0 udp)
        fi
        PORT=$(get_validated_port "$PORT") || return 1
        log_info "Hysteria2 端口: $PORT (UDP)"
        XHTTP_PORT=""
        XHTTP_PATH=""
        echo "" >/dev/tty
        return 0
    fi

    # Vision 端口（如果需要）
    if [[ "$PROTOCOL_TYPE" == "vision" || "$PROTOCOL_TYPE" == "both" ]]; then
        if [[ -n "${vlpt:-}" ]]; then
            # 环境变量指定，直接使用
            PORT="$vlpt"
        else
            # 交互式选择
            local default_vision_port
            default_vision_port=$(gen_random_free_port)
            PORT=$(prompt_port "Vision 端口" "$default_vision_port")
        fi
        log_info "Vision 端口: $PORT"
    else
        PORT=""
    fi

    # XHTTP 端口（如果需要）
    if [[ "$PROTOCOL_TYPE" == "xhttp" || "$PROTOCOL_TYPE" == "both" ]]; then
        if [[ -n "${xhpt:-}" ]]; then
            # 环境变量指定，直接使用
            XHTTP_PORT="$xhpt"
        else
            # 交互式选择（排除 Vision 端口）
            local default_xhttp_port
            default_xhttp_port=$(gen_random_free_port "${PORT:-0}")
            XHTTP_PORT=$(prompt_port "XHTTP 端口" "$default_xhttp_port" "${PORT:-0}")
        fi
        XHTTP_PATH="/$(openssl rand -hex 4)"
        log_info "XHTTP 端口: $XHTTP_PORT, 路径: $XHTTP_PATH"
    else
        XHTTP_PORT=""
        XHTTP_PATH=""
    fi

    echo "" >/dev/tty
}

gen_reality_keys() {
    log_info "$(msg gen_keys)"
    local KEYS
    # tr -d '\r' 防止部分内核输出 CRLF 行尾导致密钥末尾混入 \r,
    # 进而被 safe_read_config_value 的字符白名单判定为 "unsafe value".
    # 优先使用已安装的 xray (x25519)，否则回退到 sing-box (generate reality-keypair)。
    # 两者输出的 X25519 密钥格式互相兼容，AnyTLS 节点因此无需安装 xray。
    if [[ -x "$XRAY_BIN" ]]; then
        KEYS="$("$XRAY_BIN" x25519 | tr -d '\r')"
    elif [[ -x "$SINGBOX_BIN" ]]; then
        KEYS="$("$SINGBOX_BIN" generate reality-keypair | tr -d '\r')"
    else
        log_error "需要 xray 或 sing-box 来生成 REALITY 密钥"
        return 1
    fi

    # 提取私钥. 兼容多种 xray 版本输出标签:
    #   "PrivateKey: xxx"          (现代版本)
    #   "Private key: xxx"         (旧版本)
    #   "PrivateKey (Private): xxx" (新版本带括号备注)
    # 不依赖字段切分, 直接取第一个 ':' 之后的内容并裁剪空白.
    PRIVATE_KEY="$(echo "$KEYS" | awk '
        /^(PrivateKey|Private[[:space:]]+key)([[:space:]]*\([^)]*\))?[[:space:]]*:/ {
            idx = index($0, ":")
            val = substr($0, idx + 1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
            print val
            exit
        }
    ')"

    # 提取公钥. 兼容多种 xray 版本输出标签:
    #   "Password: xxx"            (中期版本)
    #   "PublicKey: xxx"           (现代版本)
    #   "Public key: xxx"          (旧版本)
    #   "Password (PublicKey): xxx" (最新版本带括号备注)
    PUBLIC_KEY="$(echo "$KEYS" | awk '
        /^(Password|PublicKey|Public[[:space:]]+key)([[:space:]]*\([^)]*\))?[[:space:]]*:/ {
            idx = index($0, ":")
            val = substr($0, idx + 1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
            print val
            exit
        }
    ')"

    SHORT_ID="$(openssl rand -hex 4)"

    # 验证密钥
    if [[ -z "$PRIVATE_KEY" ]]; then
        log_error "Failed to extract private key"
        log_error "Xray output: $KEYS"
        return 1
    fi

    if [[ -z "$PUBLIC_KEY" ]]; then
        log_error "Failed to extract public key"
        log_error "Xray output: $KEYS"
        return 1
    fi

    log_info "Keys generated successfully"
}

# 生成 AnyTLS 密码（32 个十六进制字符 = 128-bit，URI 安全，无需百分号编码）
gen_anytls_password() {
    ANYTLS_PASSWORD="${atpwd:-$(openssl rand -hex 16)}"
    log_info "AnyTLS 密码已生成"
}

# 生成随机化的 AnyTLS padding scheme（多行字符串，仅输出到 stdout）
#
# AnyTLS 通过 padding scheme 在协议层随机化数据包长度，以对抗基于
# 包长度分布的被动流量识别。官方默认方案是公开且固定的（容易被指纹库收录），
# 因此这里为每个节点生成独立、随机的方案。服务端方案会在握手时通过
# cmdUpdatePaddingScheme 自动下发给客户端（当客户端 padding-md5 不一致时），
# 所以无需客户端做任何额外配置即可生效。
#
# 格式: 第一行 stop=N 表示对前 N 个包（0..N-1）应用 padding；
#       随后每行 idx=seg[,seg...]，seg 为 "min-max"（区间随机长度）或 "c"（checkpoint）。
gen_anytls_padding() {
    local stop=$(( RANDOM % 5 + 4 ))   # stop ∈ [4,8]
    local -a lines
    lines+=("stop=${stop}")

    # 包 0 为认证包，使用较小的固定长度（模拟 TLS 握手记录）
    local p0=$(( RANDOM % 70 + 30 ))   # 30..99
    lines+=("0=${p0}-${p0}")

    local i s segs lo span hi line
    for (( i = 1; i < stop; i++ )); do
        segs=$(( RANDOM % 4 + 1 ))     # 每个包 1..4 个分段
        line="${i}="
        for (( s = 0; s < segs; s++ )); do
            lo=$(( RANDOM % 500 + 100 ))   # 100..599
            span=$(( RANDOM % 700 + 200 )) # 200..899
            hi=$(( lo + span ))
            (( hi > 1400 )) && hi=1400     # 控制在 ~MTU 以内，更贴近真实流量
            if (( s == 0 )); then
                line+="${lo}-${hi}"
            elif (( RANDOM % 2 == 0 )); then
                line+=",c,${lo}-${hi}"     # 以一定概率插入 checkpoint
            else
                line+=",${lo}-${hi}"
            fi
        done
        lines+=("$line")
    done

    printf '%s\n' "${lines[@]}"
}

# 为 plain AnyTLS 生成自签名证书（客户端使用 insecure=1 连接）
# Usage: gen_selfsigned_cert NAME CN
gen_selfsigned_cert() {
    local name="$1"
    local cn="${2:-www.bing.com}"
    mkdir -p "$SINGBOX_CERT_DIR"
    chmod 700 "$SINGBOX_CERT_DIR"
    local cert_path="$SINGBOX_CERT_DIR/${name}.crt"
    local key_path="$SINGBOX_CERT_DIR/${name}.key"

    openssl ecparam -genkey -name prime256v1 -out "$key_path" 2>/dev/null
    openssl req -new -x509 -days 3650 -key "$key_path" -out "$cert_path" \
        -subj "/CN=${cn}" 2>/dev/null
    chmod 600 "$key_path" "$cert_path"
}

# 统计 AnyTLS 节点数量
anytls_node_count() {
    local count=0 f t
    for f in "$NODES_DIR"/*.env; do
        [[ -f "$f" ]] || continue
        t=$(safe_read_config_value "$f" "PROTOCOL_TYPE")
        [[ "$t" == "anytls" || "$t" == "anytls_reality" ]] && ((count++))
    done
    echo "$count"
}

# 统计由 sing-box 承载的节点数量（AnyTLS 与 Hysteria2）。
singbox_node_count() {
    local count=0 f t
    for f in "$NODES_DIR"/*.env; do
        [[ -f "$f" ]] || continue
        t=$(safe_read_config_value "$f" "PROTOCOL_TYPE")
        case "$t" in
            anytls|anytls_reality|hysteria2) ((count++)) ;;
        esac
    done
    echo "$count"
}

# 统计由 Xray 承载的节点数量；未使用的内核不应影响健康状态。
xray_node_count() {
    local count=0 f t
    for f in "$NODES_DIR"/*.env; do
        [[ -f "$f" ]] || continue
        t=$(safe_read_config_value "$f" "PROTOCOL_TYPE")
        case "$t" in
            anytls|anytls_reality|hysteria2) ;;
            *) ((count++)) ;;
        esac
    done
    echo "$count"
}

# 验证 IPv4 地址格式
is_valid_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS='.'
    read -ra octets <<< "$ip"
    for octet in "${octets[@]}"; do
        [[ "$octet" -le 255 ]] || return 1
    done
    return 0
}

# 验证 IPv6 地址格式
is_valid_ipv6() {
    local ip="$1"
    # 简单验证：包含冒号且不包含非法字符
    [[ "$ip" =~ ^[0-9a-fA-F:]+$ ]] && [[ "$ip" == *:* ]]
}

# 全局 IP 变量（SERVER_IP / SERVER_IPV4 / SERVER_IPV6）统一由
# lib/00_security_state.sh 的 reset_node_state() 初始化。此处曾只声明 IPv4/IPv6
# 两个而漏掉旧字段 SERVER_IP，导致 IPv6 Only 主机在 save_env 处触发 unbound variable。

# 获取 IPv4 地址
get_ipv4() {
    local ip
    ip=$(curl -s4 --max-time 3 https://api.ipify.org 2>/dev/null | tr -d '[:space:]')
    if is_valid_ipv4 "$ip"; then
        echo "$ip"
        return 0
    fi
    ip=$(curl -s4 --max-time 3 https://ifconfig.me 2>/dev/null | tr -d '[:space:]')
    if is_valid_ipv4 "$ip"; then
        echo "$ip"
        return 0
    fi
    echo ""
}

# 获取 IPv6 地址
get_ipv6() {
    local ip
    ip=$(curl -s6 --max-time 3 https://api64.ipify.org 2>/dev/null | tr -d '[:space:]')
    if is_valid_ipv6 "$ip"; then
        echo "$ip"
        return 0
    fi
    ip=$(curl -s6 --max-time 3 https://ifconfig.me 2>/dev/null | tr -d '[:space:]')
    if is_valid_ipv6 "$ip"; then
        echo "$ip"
        return 0
    fi
    echo ""
}

# 检测网络栈类型
detect_network_stack() {
    log_info "$(msg detecting_ip)"

    SERVER_IPV4=$(get_ipv4)
    SERVER_IPV6=$(get_ipv6)

    if [[ -n "$SERVER_IPV4" ]] && [[ -n "$SERVER_IPV6" ]]; then
        log_info "Dual-Stack detected: IPv4=$SERVER_IPV4, IPv6=$SERVER_IPV6"
    elif [[ -n "$SERVER_IPV4" ]]; then
        log_info "IPv4 Only: $SERVER_IPV4"
    elif [[ -n "$SERVER_IPV6" ]]; then
        log_info "IPv6 Only: $SERVER_IPV6"
    else
        log_warn "Could not detect server IP automatically"
        SERVER_IPV4="YOUR_SERVER_IP"
    fi
}

# 并行获取服务器 IP 地址 (向后兼容)
get_server_ip_parallel() {
    local result_file pids=()
    result_file=$(mktemp)

    # IP 检测 API 列表
    local apis=(
        "https://api.ipify.org"
        "https://ifconfig.me"
        "https://icanhazip.com"
        "https://ipinfo.io/ip"
    )

    # 并行请求所有 API
    for api in "${apis[@]}"; do
        (
            ip=$(curl -s --max-time 5 "$api" 2>/dev/null | tr -d '[:space:]')
            if is_valid_ipv4 "$ip"; then
                echo "$ip" >> "$result_file"
            fi
        ) &
        pids+=($!)
    done

    # 等待第一个有效结果（最多 5 秒）
    local i=0
    while [[ $i -lt 50 ]]; do
        if [[ -s "$result_file" ]]; then
            local ip
            ip=$(head -n1 "$result_file")
            # 终止所有后台进程
            for pid in "${pids[@]}"; do
                kill "$pid" 2>/dev/null || true
            done
            wait 2>/dev/null || true
            rm -f "$result_file"
            echo "$ip"
            return 0
        fi
        sleep 0.1
        ((i++))
    done

    # 超时后清理
    for pid in "${pids[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    wait 2>/dev/null || true

    # 检查是否有结果
    if [[ -s "$result_file" ]]; then
        local ip
        ip=$(head -n1 "$result_file")
        rm -f "$result_file"
        echo "$ip"
        return 0
    fi

    rm -f "$result_file"
    echo "YOUR_SERVER_IP"
}

# 保存延迟缓存
save_latency_cache() {
    local -n cache_map=$1
    {
        echo "# timestamp: $(date +%s)"
        for domain in "${!cache_map[@]}"; do
            echo "$domain ${cache_map[$domain]}"
        done
    } > "$CACHE_FILE"
}

# 加载延迟缓存
# 返回 0 表示加载成功且缓存有效，返回 1 表示缓存无效或不存在
load_latency_cache() {
    local -n cache_map=$1

    # 检查缓存文件是否存在
    if [[ ! -f "$CACHE_FILE" ]]; then
        return 1
    fi

    # 读取时间戳并检查是否过期
    local timestamp
    timestamp=$(grep "^# timestamp:" "$CACHE_FILE" 2>/dev/null | awk '{print $3}')
    if [[ -z "$timestamp" ]]; then
        return 1
    fi

    local current_time
    current_time=$(date +%s)
    if (( current_time - timestamp > CACHE_TTL )); then
        return 1
    fi

    # 加载缓存数据
    while IFS=' ' read -r domain latency; do
        # 跳过注释行和空行
        [[ "$domain" =~ ^#.*$ || -z "$domain" ]] && continue
        cache_map["$domain"]=$latency
    done < "$CACHE_FILE"

    # 检查是否成功加载了数据
    if [[ ${#cache_map[@]} -eq 0 ]]; then
        return 1
    fi

    return 0
}

# 测试单个域名延迟
test_domain_latency() {
    local domain="$1"
    local t1 t2
    t1=$(date +%s%3N)
    if timeout 2 openssl s_client -connect "${domain}:443" -servername "$domain" </dev/null &>/dev/null; then
        t2=$(date +%s%3N)
        echo "$((t2 - t1))"
    else
        echo "9999"
    fi
}

# 测试单个域名并将结果写入文件（用于并行执行）
test_domain_to_file() {
    local domain="$1"
    local result_dir="$2"
    local latency
    latency=$(test_domain_latency "$domain")
    echo "$latency" > "${result_dir}/${domain}"
}

# 并行测试所有域名
# 参数1: 关联数组名称（用于存储结果）
# 设置全局变量 BEST_LATENCY 为最低延迟值
test_domains_parallel() {
    local -n _latency_map=$1
    local total=${#SNI_LIST[@]}
    local max_jobs=30
    local result_dir
    result_dir=$(mktemp -d)

    # 创建标记文件表示测试进行中
    local progress_flag="${result_dir}/.in_progress"
    touch "$progress_flag"

    # 清空结果数组
    _latency_map=()

    echo ""
    echo -e "${CYAN}$(msg testing)${NC}"

    # 启动进度显示后台进程
    (
        while [[ -f "$progress_flag" ]]; do
            local completed
            completed=$(find "$result_dir" -maxdepth 1 -type f ! -name '.in_progress' 2>/dev/null | wc -l)
            local percent=$((completed * 100 / total))
            printf "\r[%-50s] %d%% (%d/%d)          " \
                "$(printf '#%.0s' $(seq 1 $((percent / 2))))" \
                "$percent" "$completed" "$total"
            sleep 0.5
        done
    ) &
    local progress_pid=$!

    # 并行执行测试
    local running=0
    for domain in "${SNI_LIST[@]}"; do
        # 控制并发数
        while [[ $running -ge $max_jobs ]]; do
            wait -n 2>/dev/null || true
            running=$((running - 1))
        done

        # 启动后台任务
        test_domain_to_file "$domain" "$result_dir" &
        running=$((running + 1))
    done

    # 等待所有测试任务完成（不等待进度显示进程）
    # 通过检查结果文件数量来判断是否完成
    while true; do
        local completed
        completed=$(find "$result_dir" -maxdepth 1 -type f ! -name '.in_progress' 2>/dev/null | wc -l)
        if [[ "$completed" -ge "$total" ]]; then
            break
        fi
        sleep 0.2
    done

    # 停止进度显示（先删除 flag 让进程退出）
    rm -f "$progress_flag"
    sleep 0.3
    kill $progress_pid 2>/dev/null || true
    wait $progress_pid 2>/dev/null || true

    # 显示最终进度
    printf "\r[%-50s] %d%% (%d/%d)          \n" \
        "$(printf '#%.0s' $(seq 1 50))" \
        "100" "$total" "$total"

    # 读取结果到关联数组
    local best_latency=9999
    for domain in "${SNI_LIST[@]}"; do
        local result_file="${result_dir}/${domain}"
        if [[ -f "$result_file" ]]; then
            local latency
            latency=$(cat "$result_file")
            # 验证 latency 是有效整数
            if [[ "$latency" =~ ^[0-9]+$ ]] && [[ "$latency" -ne 9999 ]]; then
                _latency_map["$domain"]=$latency
                if [[ "$latency" -lt "$best_latency" ]]; then
                    best_latency=$latency
                fi
            fi
        fi
    done

    # 清理临时目录
    rm -rf "$result_dir"

    echo ""

    # 返回最佳延迟值（通过全局变量）
    BEST_LATENCY=$best_latency
}

# 并行测试所有域名（带详细输出，用于 cmd_test_sni）
# 参数1: 关联数组名称（用于存储结果）
test_domains_parallel_verbose() {
    local -n _latency_map_v=$1
    local total=${#SNI_LIST[@]}
    local max_jobs=30
    local result_dir
    result_dir=$(mktemp -d)

    # 创建标记文件表示测试进行中
    local progress_flag="${result_dir}/.in_progress"
    touch "$progress_flag"

    # 清空结果数组
    _latency_map_v=()

    # 启动进度显示后台进程
    (
        while [[ -f "$progress_flag" ]]; do
            local completed
            completed=$(find "$result_dir" -maxdepth 1 -type f ! -name '.in_progress' 2>/dev/null | wc -l)
            local percent=$((completed * 100 / total))
            printf "\r${CYAN}$(msg testing)${NC} [%-50s] %d%% (%d/%d)          " \
                "$(printf '#%.0s' $(seq 1 $((percent / 2))))" \
                "$percent" "$completed" "$total"
            sleep 0.5
        done
    ) &
    local progress_pid=$!

    # 并行执行测试
    local running=0
    for domain in "${SNI_LIST[@]}"; do
        # 控制并发数
        while [[ $running -ge $max_jobs ]]; do
            wait -n 2>/dev/null || true
            running=$((running - 1))
        done

        # 启动后台任务
        test_domain_to_file "$domain" "$result_dir" &
        running=$((running + 1))
    done

    # 等待所有测试任务完成（不等待进度显示进程）
    while true; do
        local completed
        completed=$(find "$result_dir" -maxdepth 1 -type f ! -name '.in_progress' 2>/dev/null | wc -l)
        if [[ "$completed" -ge "$total" ]]; then
            break
        fi
        sleep 0.2
    done

    # 停止进度显示（先删除 flag 让进程退出）
    rm -f "$progress_flag"
    sleep 0.3
    kill $progress_pid 2>/dev/null || true
    wait $progress_pid 2>/dev/null || true

    # 清除进度行
    printf "\r%-80s\r" " "

    # 读取结果并显示详细信息
    local idx=0
    for domain in "${SNI_LIST[@]}"; do
        idx=$((idx + 1))
        local result_file="${result_dir}/${domain}"
        if [[ -f "$result_file" ]]; then
            local latency
            latency=$(cat "$result_file")
            # 验证 latency 是有效整数
            if [[ ! "$latency" =~ ^[0-9]+$ ]] || [[ "$latency" -eq 9999 ]]; then
                printf "[%3d/%3d] ${RED}%-50s $(msg timeout)${NC}\n" "$idx" "$total" "$domain"
            else
                printf "[%3d/%3d] ${GREEN}%-50s %dms${NC}\n" "$idx" "$total" "$domain" "$latency"
                _latency_map_v["$domain"]=$latency
            fi
        fi
    done

    # 清理临时目录
    rm -rf "$result_dir"
}

# 动态选择最低延迟的 SNI（测试所有域名）
select_best_sni() {
    local total=${#SNI_LIST[@]}
    declare -A latency_map
    local best_latency=9999
    local cache_loaded=0

    # 尝试加载缓存
    if load_latency_cache latency_map; then
        cache_loaded=1
        log_info "Using cached SNI latency results (valid for $((CACHE_TTL / 60)) minutes)"
        # 从缓存计算最低延迟
        for domain in "${!latency_map[@]}"; do
            if [[ "${latency_map[$domain]}" -lt "$best_latency" ]]; then
                best_latency="${latency_map[$domain]}"
            fi
        done
    else
        # 缓存无效，执行并行测试
        log_info "$(msg testing_sni) ($(msg total_domains): $total)"

        # 使用并行测试
        test_domains_parallel latency_map
        best_latency=$BEST_LATENCY

        # 保存测试结果到缓存
        if [[ ${#latency_map[@]} -gt 0 ]]; then
            save_latency_cache latency_map
        fi
    fi

    # 检查是否有可用域名
    if [[ ${#latency_map[@]} -eq 0 ]]; then
        log_warn "$(msg sni_timeout)"
        # 即使测试失败也让用户选择
        prompt_sni_choice "" ""
        return
    fi

    # 获取排序后的 Top 5 域名
    local top_domains=()
    local top_latencies=()
    while IFS=' ' read -r lat dom; do
        top_domains+=("$dom")
        top_latencies+=("$lat")
    done < <(for domain in "${!latency_map[@]}"; do
        echo "${latency_map[$domain]} $domain"
    done | sort -n | head -5)

    # 让用户选择 SNI
    prompt_sni_choice top_domains top_latencies
}

# 让用户选择 SNI 的交互函数
# 参数1: top_domains 数组名称
# 参数2: top_latencies 数组名称
# 测试用户手动输入的逗号分隔域名列表，把排序后的结果写入传入的两个数组
# 用法: _run_custom_sni_test OUT_DOMAINS_ARR OUT_LATENCIES_ARR
_run_custom_sni_test() {
    local -n _out_domains=$1
    local -n _out_lats=$2

    {
    echo ""
    echo -e "  ${CYAN}$(msg sni_custom_test_hint)${NC}"
    echo -n "  > "
    } >/dev/tty

    local raw
    read -r raw </dev/tty

    # 按逗号分隔解析，逐个清洗并校验域名格式
    local -a parts=() domains=()
    IFS=',' read -ra parts <<< "$raw"
    local part
    for part in "${parts[@]}"; do
        part=$(echo "$part" | sed 's#^https\?://##; s#/.*$##' | tr -d '[:space:]')
        [[ -n "$part" ]] || continue
        if [[ "$part" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$ ]]; then
            domains+=("$part")
        else
            log_warn "$(msg sni_invalid_format): $part"
        fi
    done

    if [[ ${#domains[@]} -eq 0 ]]; then
        log_warn "$(msg sni_empty_input)"
        return 1
    fi

    # 仅测试这些自定义域名：临时替换 SNI_LIST，不读取也不写入内置缓存
    declare -A _lat
    local _saved_list=("${SNI_LIST[@]}")
    SNI_LIST=("${domains[@]}")
    test_domains_parallel _lat
    SNI_LIST=("${_saved_list[@]}")

    if [[ ${#_lat[@]} -eq 0 ]]; then
        log_warn "$(msg sni_custom_unreachable)"
        return 1
    fi

    # 排序取延迟最低的前 5 个，写回输出数组供选择
    _out_domains=()
    _out_lats=()
    local lat dom
    while IFS=' ' read -r lat dom; do
        _out_domains+=("$dom")
        _out_lats+=("$lat")
    done < <(for dom in "${!_lat[@]}"; do echo "${_lat[$dom]} $dom"; done | sort -n | head -5)

    log_info "$(msg sni_custom_test_done)"
    return 0
}

prompt_sni_choice() {
    local -n _in_domains=$1 2>/dev/null || true
    local -n _in_latencies=$2 2>/dev/null || true
    # 拷贝到本地可变数组；选择"测试自定义域名"后会用自定义结果替换它们
    local -a td=() tl=()
    if [[ ${#_in_domains[@]} -gt 0 ]] 2>/dev/null; then
        td=("${_in_domains[@]}")
        tl=("${_in_latencies[@]}")
    fi

    while true; do
        local has_results=false
        [[ ${#td[@]} -gt 0 ]] && has_results=true

        {
        echo ""
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}                     $(msg sni_selection_title)${NC}"
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo ""

        if $has_results; then
            echo -e "  ${BLUE}$(msg sni_top_results):${NC}"
            echo ""
            local i=1 idx
            for idx in "${!td[@]}"; do
                printf "    ${GREEN}%d.${NC} %-40s ${YELLOW}%dms${NC}\n" "$i" "${td[$idx]}" "${tl[$idx]}"
                ((i++))
            done
            echo ""
            echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
            echo ""
            echo -e "  ${GREEN}A.${NC} $(msg sni_auto_select) (${td[0]})"
            echo -e "  ${GREEN}M.${NC} $(msg sni_manual_input)"
            echo -e "  ${GREEN}C.${NC} $(msg sni_custom_test)"
            echo ""
            echo -n "  $(msg sni_choice_prompt) [A/1-5/M/C]: "
        else
            echo -e "  ${YELLOW}$(msg sni_no_results)${NC}"
            echo ""
            echo -e "  ${GREEN}D.${NC} $(msg sni_use_default) (www.tesla.com)"
            echo -e "  ${GREEN}M.${NC} $(msg sni_manual_input)"
            echo -e "  ${GREEN}C.${NC} $(msg sni_custom_test)"
            echo ""
            echo -n "  $(msg sni_choice_prompt) [D/M/C]: "
        fi
        } >/dev/tty

        local choice
        read -r choice </dev/tty
        choice=$(echo "$choice" | tr '[:lower:]' '[:upper:]')

        if $has_results; then
            case "$choice" in
                A|"")
                    SNI="${td[0]}"
                    log_info "$(msg sni_selected): ${SNI} ($(msg latency): ${tl[0]}ms)"
                    return ;;
                [1-9]|[1-9][0-9])
                    local idx=$((choice - 1))
                    if [[ $idx -ge 0 && $idx -lt ${#td[@]} ]]; then
                        SNI="${td[$idx]}"
                        log_info "$(msg sni_selected): ${SNI} ($(msg latency): ${tl[$idx]}ms)"
                    else
                        SNI="${td[0]}"
                        log_info "$(msg sni_selected): ${SNI} ($(msg latency): ${tl[0]}ms)"
                    fi
                    return ;;
                M)
                    prompt_custom_sni
                    return ;;
                C)
                    # 测试自定义域名列表，并用结果替换候选集后重新展示
                    _run_custom_sni_test td tl || true
                    continue ;;
                *)
                    SNI="${td[0]}"
                    log_info "$(msg sni_selected): ${SNI} ($(msg latency): ${tl[0]}ms)"
                    return ;;
            esac
        else
            case "$choice" in
                D|"")
                    SNI="www.tesla.com"
                    log_info "$(msg sni_use_default): ${SNI}"
                    return ;;
                M)
                    prompt_custom_sni
                    return ;;
                C)
                    _run_custom_sni_test td tl || true
                    continue ;;
                *)
                    SNI="www.tesla.com"
                    log_info "$(msg sni_use_default): ${SNI}"
                    return ;;
            esac
        fi
    done
}

# 提示用户输入自定义 SNI
prompt_custom_sni() {
    {
    echo ""
    echo -e "  ${CYAN}$(msg sni_input_hint)${NC}"
    echo -n "  SNI: "
    } >/dev/tty

    read -r custom_sni </dev/tty

    # 清理输入（移除空格和协议前缀）
    custom_sni=$(echo "$custom_sni" | sed 's/^https\?:\/\///' | sed 's/\/.*$//' | tr -d '[:space:]')

    if [[ -z "$custom_sni" ]]; then
        SNI="www.tesla.com"
        log_warn "$(msg sni_empty_input), $(msg sni_use_default): ${SNI}"
    else
        # 验证域名格式
        if [[ "$custom_sni" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$ ]]; then
            SNI="$custom_sni"
            log_info "$(msg sni_custom_set): ${SNI}"

            # 可选：测试自定义域名连通性
            echo -e "  ${CYAN}$(msg sni_testing_custom)...${NC}" >/dev/tty
            if timeout 3 openssl s_client -connect "${SNI}:443" -servername "$SNI" </dev/null &>/dev/null; then
                log_info "$(msg sni_custom_ok)"
            else
                log_warn "$(msg sni_custom_unreachable)"
            fi
        else
            log_warn "$(msg sni_invalid_format), $(msg sni_use_default)"
            SNI="www.tesla.com"
        fi
    fi
}

# 验证 Xray 配置文件有效性
validate_xray_config() {
    if [[ ! -f "$XRAY_CONF" ]]; then
        log_error "Config file not found: $XRAY_CONF"
        return 1
    fi

    # 检查文件不为空
    if [[ ! -s "$XRAY_CONF" ]]; then
        log_error "Config file is empty"
        return 1
    fi

    # 检查 JSON 有效性
    if ! jq . "$XRAY_CONF" > /dev/null 2>&1; then
        log_error "Config file contains invalid JSON"
        return 1
    fi

    # 如果 xray 可用，使用 xray -test 验证
    if command -v "$XRAY_BIN" &>/dev/null; then
        local test_output
        if ! test_output=$("$XRAY_BIN" -test -config "$XRAY_CONF" 2>&1); then
            log_error "Xray config test failed: $test_output"
            return 1
        fi
    fi

    return 0
}

# 验证 sing-box 配置文件有效性
validate_singbox_config() {
    if [[ ! -f "$SINGBOX_CONF" ]]; then
        log_error "sing-box config not found: $SINGBOX_CONF"
        return 1
    fi
    if [[ ! -s "$SINGBOX_CONF" ]]; then
        log_error "sing-box config is empty"
        return 1
    fi
    if ! jq . "$SINGBOX_CONF" > /dev/null 2>&1; then
        log_error "sing-box config contains invalid JSON"
        return 1
    fi
    if [[ -x "$SINGBOX_BIN" ]]; then
        local test_output
        if ! test_output=$("$SINGBOX_BIN" check -c "$SINGBOX_CONF" 2>&1); then
            log_error "sing-box config check failed: $test_output"
            return 1
        fi
    fi
    return 0
}

write_config() {
    mkdir -p /usr/local/etc/xray

    # 构建 inbounds 数组
    local inbounds_json="[]"

    for node_file in "$NODES_DIR"/*.env; do
        [[ -f "$node_file" ]] || continue

        # 使用安全的配置读取方式（防止命令注入）
        local n_name n_port n_uuid n_sni n_private_key n_short_id n_xhttp_port n_xhttp_path n_protocol_type
        local n_ss_method n_ss_password
        n_name=$(safe_read_config_value "$node_file" "NODE_NAME")
        n_port=$(safe_read_config_value "$node_file" "PORT")
        n_uuid=$(safe_read_config_value "$node_file" "UUID")
        n_sni=$(safe_read_config_value "$node_file" "SNI")
        n_private_key=$(safe_read_config_value "$node_file" "PRIVATE_KEY")
        n_short_id=$(safe_read_config_value "$node_file" "SHORT_ID")
        n_xhttp_port=$(safe_read_config_value "$node_file" "XHTTP_PORT")
        n_xhttp_path=$(safe_read_config_value "$node_file" "XHTTP_PATH")
        n_protocol_type=$(safe_read_config_value "$node_file" "PROTOCOL_TYPE")
        n_ss_method=$(safe_read_config_value "$node_file" "SS_METHOD")
        n_ss_password=$(safe_read_config_value "$node_file" "SS_PASSWORD")

        # 处理可能加密的敏感值
        n_private_key=$(decrypt_value "$n_private_key")
        n_uuid=$(decrypt_value "$n_uuid")
        n_ss_password=$(decrypt_value "$n_ss_password")

        # 向后兼容：旧配置没有 PROTOCOL_TYPE，根据端口判断
        if [[ -z "$n_protocol_type" ]]; then
            if [[ -n "$n_port" ]] && [[ -n "$n_xhttp_port" ]]; then
                n_protocol_type="both"
            elif [[ -n "$n_xhttp_port" ]]; then
                n_protocol_type="xhttp"
            else
                n_protocol_type="vision"
            fi
        fi

        # AnyTLS / Hysteria2 节点由 sing-box 处理，Xray 配置中跳过
        if [[ "$n_protocol_type" == "anytls" || "$n_protocol_type" == "anytls_reality" || "$n_protocol_type" == "hysteria2" ]]; then
            continue
        fi

        # 跳过无效节点（VLESS 需要 UUID，Shadowsocks 需要密码）
        if [[ "$n_protocol_type" == "shadowsocks" ]]; then
            [[ -z "$n_ss_password" ]] && continue
        else
            [[ -z "$n_uuid" ]] && continue
        fi

        # 添加 Shadowsocks inbound
        if [[ "$n_protocol_type" == "shadowsocks" ]] && [[ -n "$n_port" ]] && [[ -n "$n_ss_method" ]] && [[ -n "$n_ss_password" ]]; then
            local validated_port
            validated_port=$(get_validated_port "$n_port" true)
            if [[ -z "$validated_port" ]]; then
                log_warn "Invalid Shadowsocks port for node '$n_name', skipping"
                continue
            fi

            local ss_inbound
            ss_inbound=$(build_shadowsocks_inbound "$n_name" "$validated_port" "$n_ss_method" "$n_ss_password")
            if [[ -z "$ss_inbound" ]]; then
                log_error "Failed to build Shadowsocks inbound for node '$n_name'"
                return 1
            fi

            local new_inbounds
            if new_inbounds=$(echo "$inbounds_json" | jq --argjson inbound "$ss_inbound" '. += [$inbound]' 2>&1); then
                inbounds_json="$new_inbounds"
            else
                log_error "Failed to add Shadowsocks inbound for node '$n_name': $new_inbounds"
                return 1
            fi
            continue  # Shadowsocks 节点处理完毕，跳过 VLESS 处理
        fi

        # 添加 Vision inbound（如果协议类型包含 vision）
        if [[ "$n_protocol_type" == "vision" || "$n_protocol_type" == "both" ]] && [[ -n "$n_port" ]]; then
            # 验证端口（安全检查）
            local validated_port
            validated_port=$(get_validated_port "$n_port" true)
            if [[ -z "$validated_port" ]]; then
                log_warn "Invalid Vision port for node '$n_name', skipping"
                continue
            fi

            # 使用安全的 JSON 构建器（防止注入）
            local vision_inbound
            vision_inbound=$(build_vision_inbound "$n_name" "$validated_port" "$n_uuid" "$n_sni" "$n_private_key" "$n_short_id")
            if [[ -z "$vision_inbound" ]]; then
                log_error "Failed to build Vision inbound for node '$n_name'"
                return 1
            fi

            # 使用临时变量和错误检查来防止 jq 失败导致脚本退出
            local new_inbounds
            if new_inbounds=$(echo "$inbounds_json" | jq --argjson inbound "$vision_inbound" '. += [$inbound]' 2>&1); then
                inbounds_json="$new_inbounds"
            else
                log_error "Failed to add Vision inbound for node '$n_name': $new_inbounds"
                return 1
            fi
        fi

        # 添加 XHTTP inbound（如果协议类型包含 xhttp）
        if [[ "$n_protocol_type" == "xhttp" || "$n_protocol_type" == "both" ]] && [[ -n "$n_xhttp_port" ]] && [[ -n "$n_xhttp_path" ]]; then
            # 验证端口（安全检查）
            local validated_xhttp_port
            validated_xhttp_port=$(get_validated_port "$n_xhttp_port" true)
            if [[ -z "$validated_xhttp_port" ]]; then
                log_warn "Invalid XHTTP port for node '$n_name', skipping"
                continue
            fi

            # 使用安全的 JSON 构建器（防止注入）
            local xhttp_inbound
            xhttp_inbound=$(build_xhttp_inbound "$n_name" "$validated_xhttp_port" "$n_uuid" "$n_sni" "$n_private_key" "$n_short_id" "$n_xhttp_path")
            if [[ -z "$xhttp_inbound" ]]; then
                log_error "Failed to build XHTTP inbound for node '$n_name'"
                return 1
            fi

            # 使用临时变量和错误检查来防止 jq 失败导致脚本退出
            local new_inbounds
            if new_inbounds=$(echo "$inbounds_json" | jq --argjson inbound "$xhttp_inbound" '. += [$inbound]' 2>&1); then
                inbounds_json="$new_inbounds"
            else
                log_error "Failed to add XHTTP inbound for node '$n_name': $new_inbounds"
                return 1
            fi
        fi
    done

    # 构建 outbounds
    local outbounds_json='[{"protocol": "freedom", "tag": "direct"}, {"protocol": "blackhole", "tag": "block"}]'

    # 检查是否有 WARP 代理
    if check_warp_running; then
        local warp_outbound='{"tag": "warp_proxy", "protocol": "socks", "settings": {"servers": [{"address": "127.0.0.1", "port": '$WARP_SOCKS_PORT'}]}}'
        local new_outbounds
        if new_outbounds=$(echo "$outbounds_json" | jq --argjson outbound "$warp_outbound" '. += [$outbound]' 2>&1); then
            outbounds_json="$new_outbounds"
        else
            log_error "Failed to add WARP outbound: $new_outbounds"
            return 1
        fi
    fi

    # 构建路由规则
    local routing_json
    routing_json=$(cat <<EOF
{
  "domainStrategy": "IPIfNonMatch",
  "rules": [
    {"type": "field", "ip": ["127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "100.64.0.0/10", "::1/128", "fc00::/7", "fe80::/10"], "outboundTag": "block"},
    {"type": "field", "protocol": ["bittorrent"], "outboundTag": "block"}
  ]
}
EOF
)

    # 检查并添加 WARP 分流规则
    if [[ -f "/root/.warp_netflix" ]] && check_warp_running; then
        local new_routing
        if new_routing=$(echo "$routing_json" | jq '.rules = [{"type": "field", "domain": ["geosite:netflix"], "outboundTag": "warp_proxy"}] + .rules' 2>&1); then
            routing_json="$new_routing"
        else
            log_warn "Failed to add Netflix routing rule: $new_routing"
        fi
    fi
    if [[ -f "/root/.warp_ai" ]] && check_warp_running; then
        local new_routing
        if new_routing=$(echo "$routing_json" | jq '.rules = [{"type": "field", "domain": ["geosite:openai", "geosite:anthropic"], "outboundTag": "warp_proxy"}] + .rules' 2>&1); then
            routing_json="$new_routing"
        else
            log_warn "Failed to add AI routing rule: $new_routing"
        fi
    fi

    # 组装最终配置
    local config_json
    if ! config_json=$(jq -n \
        --argjson inbounds "$inbounds_json" \
        --argjson outbounds "$outbounds_json" \
        --argjson routing "$routing_json" \
        '{
            "log": {"loglevel": "warning"},
            "inbounds": $inbounds,
            "outbounds": $outbounds,
            "routing": $routing
        }' 2>&1); then
        log_error "Failed to assemble final config: $config_json"
        return 1
    fi

    echo "$config_json" > "$XRAY_CONF"

    # 验证配置文件有效性
    if ! validate_xray_config; then
        log_error "Generated config is invalid"
        return 1
    fi

    return 0
}

# 根据所有 AnyTLS / Hysteria2 节点生成 sing-box 配置文件
write_singbox_config() {
    mkdir -p "$SINGBOX_DIR"

    local inbounds_json="[]"

    for node_file in "$NODES_DIR"/*.env; do
        [[ -f "$node_file" ]] || continue

        local n_proto
        n_proto=$(safe_read_config_value "$node_file" "PROTOCOL_TYPE")
        [[ "$n_proto" == "anytls" || "$n_proto" == "anytls_reality" || "$n_proto" == "hysteria2" ]] || continue

        local n_name n_port n_sni n_priv n_sid n_pw n_pad_b64 n_pad
        n_name=$(safe_read_config_value "$node_file" "NODE_NAME")
        n_port=$(safe_read_config_value "$node_file" "PORT")
        n_sni=$(safe_read_config_value "$node_file" "SNI")
        n_priv=$(safe_read_config_value "$node_file" "PRIVATE_KEY")
        n_sid=$(safe_read_config_value "$node_file" "SHORT_ID")
        if [[ "$n_proto" == "hysteria2" ]]; then
            n_pw=$(safe_read_config_value "$node_file" "HY2_PASSWORD")
        else
            n_pw=$(safe_read_config_value "$node_file" "ANYTLS_PASSWORD")
        fi
        n_pad_b64=$(safe_read_config_value "$node_file" "ANYTLS_PADDING_B64")

        # 解密可能加密的敏感值
        n_priv=$(decrypt_value "$n_priv")
        n_pw=$(decrypt_value "$n_pw")

        [[ -z "$n_pw" ]] && continue

        local validated_port
        validated_port=$(get_validated_port "$n_port" true)
        if [[ -z "$validated_port" ]]; then
            log_warn "Invalid sing-box port for node '$n_name', skipping"
            continue
        fi

        local inbound
        if [[ "$n_proto" == "hysteria2" ]]; then
            local cert_path="$SINGBOX_CERT_DIR/${n_name}.crt"
            local key_path="$SINGBOX_CERT_DIR/${n_name}.key"
            if [[ ! -f "$cert_path" || ! -f "$key_path" ]]; then
                gen_selfsigned_cert "$n_name" "${n_sni:-www.bing.com}" || return 1
            fi
            if ! inbound=$(build_hysteria2_inbound "$n_name" "$validated_port" "$n_pw" \
                "${n_sni:-www.bing.com}" "$cert_path" "$key_path"); then
                log_error "Failed to build Hysteria2 inbound for node '$n_name'"
                return 1
            fi
        else
            # 还原 AnyTLS padding scheme；缺失时即时生成随机方案。
            n_pad=""
            if [[ -n "$n_pad_b64" ]]; then
                n_pad=$(echo "$n_pad_b64" | base64 -d 2>/dev/null)
            fi
            [[ -z "$n_pad" ]] && n_pad=$(gen_anytls_padding)
        fi

        if [[ "$n_proto" == "anytls_reality" ]]; then
            inbound=$(build_anytls_inbound "$n_name" "$validated_port" "$n_pw" "$n_pad" \
                "reality" "$n_sni" "$n_priv" "$n_sid" "" "")
        elif [[ "$n_proto" == "anytls" ]]; then
            local cert_path="$SINGBOX_CERT_DIR/${n_name}.crt"
            local key_path="$SINGBOX_CERT_DIR/${n_name}.key"
            # 确保自签名证书存在
            if [[ ! -f "$cert_path" || ! -f "$key_path" ]]; then
                gen_selfsigned_cert "$n_name" "${n_sni:-www.bing.com}"
            fi
            inbound=$(build_anytls_inbound "$n_name" "$validated_port" "$n_pw" "$n_pad" \
                "tls" "${n_sni:-www.bing.com}" "" "" "$cert_path" "$key_path")
        fi

        if [[ -z "$inbound" ]]; then
            log_error "Failed to build $n_proto inbound for node '$n_name'"
            return 1
        fi

        local new_inbounds
        if new_inbounds=$(echo "$inbounds_json" | jq --argjson inbound "$inbound" '. += [$inbound]' 2>&1); then
            inbounds_json="$new_inbounds"
        else
            log_error "Failed to add $n_proto inbound for node '$n_name': $new_inbounds"
            return 1
        fi
    done

    local config_json
    if ! config_json=$(jq -n \
        --argjson inbounds "$inbounds_json" \
        '{
            "log": {"level": "warn", "timestamp": true},
            "inbounds": $inbounds,
            "outbounds": [{"type": "direct", "tag": "direct"}],
            "route": {"final": "direct"}
        }' 2>&1); then
        log_error "Failed to assemble sing-box config: $config_json"
        return 1
    fi

    echo "$config_json" > "$SINGBOX_CONF"
    chmod 600 "$SINGBOX_CONF"

    if ! validate_singbox_config; then
        log_error "Generated sing-box config is invalid"
        return 1
    fi

    return 0
}

# 同步 sing-box 状态：有 AnyTLS / Hysteria2 节点则（安装并）写配置、启动服务；
# 没有则停止并禁用服务。在添加/删除节点后调用。
singbox_sync() {
    local count
    count=$(singbox_node_count)

    if [[ "$count" -eq 0 ]]; then
        # 没有 AnyTLS 节点，停止 sing-box（如果存在）
        if [[ -f "$SINGBOX_BIN" ]]; then
            service_stop "$SINGBOX_SERVICE"
            service_disable "$SINGBOX_SERVICE"
        fi
        rm -f "$SINGBOX_CONF" 2>/dev/null
        return 0
    fi

    # 有 AnyTLS 节点，确保 sing-box 已安装
    if [[ ! -f "$SINGBOX_BIN" ]]; then
        if ! install_singbox; then
            log_error "Failed to install sing-box"
            return 1
        fi
    fi

    if ! write_singbox_config; then
        return 1
    fi

    service_enable "$SINGBOX_SERVICE"
    if ! service_restart "$SINGBOX_SERVICE"; then
        log_error "sing-box service restart failed"
        return 1
    fi

    sleep 1
    if ! service_is_active "$SINGBOX_SERVICE"; then
        log_error "sing-box service failed to become active"
        return 1
    fi
    return 0
}

# 检查 WARP 是否运行
check_warp_running() {
    (echo > /dev/tcp/127.0.0.1/$WARP_SOCKS_PORT) 2>/dev/null
}

save_env() {
    init_nodes_dir

    # 使用节点名称或端口作为文件名
    local node_name="${CURRENT_NODE_NAME:-$PORT}"
    local node_file
    node_file=$(get_node_file "$node_name")

    # 使用检测到的 IP（优先使用 SERVER_IPV4，向后兼容 SERVER_IP）
    local save_ipv4="${SERVER_IPV4:-${SERVER_IP:-}}"
    local save_ipv6="${SERVER_IPV6:-}"

    # 所有字段一律使用 ${VAR:-} 展开。节点变量按协议部分赋值（AnyTLS 无 UUID、
    # Shadowsocks 无 REALITY 密钥……），在 `set -u` 下任何一个漏赋值的字段都会
    # 让安装在此处中断，且此时节点文件尚未落盘、服务也未配置。reset_node_state()
    # 已保证这些变量始终有定义，这里再兜一层，避免将来新增协议时重蹈覆辙。
    local save_uuid="${UUID:-}"
    local save_private_key="${PRIVATE_KEY:-}"
    local save_ss_password="${SS_PASSWORD:-}"
    local save_anytls_password="${ANYTLS_PASSWORD:-}"
    local save_hy2_password="${HY2_PASSWORD:-}"

    if is_encryption_enabled; then
        # encrypt_value 对空串直接返回空串，因此无需额外判空。
        save_uuid=$(encrypt_value "$save_uuid")
        save_private_key=$(encrypt_value "$save_private_key")
        [[ -n "$save_ss_password" ]] && save_ss_password=$(encrypt_value "$SS_PASSWORD")
        [[ -n "$save_anytls_password" ]] && save_anytls_password=$(encrypt_value "$ANYTLS_PASSWORD")
        [[ -n "$save_hy2_password" ]] && save_hy2_password=$(encrypt_value "$HY2_PASSWORD")
    fi

    cat > "$node_file" <<ENV
NODE_NAME=$node_name
SERVER_IP=${save_ipv4:-YOUR_SERVER_IP}
SERVER_IPV4=${save_ipv4:-}
SERVER_IPV6=${save_ipv6:-}
PORT=${PORT:-}
UUID=$save_uuid
SNI=${SNI:-}
PUBLIC_KEY=${PUBLIC_KEY:-}
PRIVATE_KEY=$save_private_key
SHORT_ID=${SHORT_ID:-}
PROTOCOL_TYPE=${PROTOCOL_TYPE:-vision}
XHTTP_PORT=${XHTTP_PORT:-}
XHTTP_PATH=${XHTTP_PATH:-}
SS_METHOD=${SS_METHOD:-}
SS_PASSWORD=$save_ss_password
ANYTLS_PASSWORD=$save_anytls_password
ANYTLS_PADDING_B64=${ANYTLS_PADDING_B64:-}
HY2_PASSWORD=$save_hy2_password
ENV
    chmod 600 "$node_file"

    CURRENT_NODE_NAME="$node_name"
}

# 生成 Vision 分享链接
get_vision_link() {
    local ip="$1"
    local node_label="$2"
    local ip_formatted="$ip"

    # IPv6 需要方括号
    if [[ "$ip" == *:* ]]; then
        ip_formatted="[$ip]"
    fi

    echo "vless://${UUID}@${ip_formatted}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${node_label}"
}

# 生成 XHTTP 分享链接
get_xhttp_link() {
    local ip="$1"
    local node_label="$2"
    local ip_formatted="$ip"

    # IPv6 需要方括号
    if [[ "$ip" == *:* ]]; then
        ip_formatted="[$ip]"
    fi

    # 注意：XHTTP 不需要 flow 参数，path 需要 URL 编码
    local encoded_path
    encoded_path=$(echo -n "$XHTTP_PATH" | sed 's|/|%2F|g')
    echo "vless://${UUID}@${ip_formatted}:${XHTTP_PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=chrome&type=xhttp&path=${encoded_path}&sni=${SNI}&sid=${SHORT_ID}#${node_label}"
}

# 生成 Shadowsocks 分享链接
# 格式: ss://BASE64(method:password)@host:port#name
get_ss_link() {
    local ip="$1"
    local node_label="$2"
    local ip_formatted="$ip"

    # IPv6 需要方括号
    if [[ "$ip" == *:* ]]; then
        ip_formatted="[$ip]"
    fi

    # SS 链接格式: ss://BASE64(method:password)@server:port#tag
    local userinfo
    userinfo=$(echo -n "${SS_METHOD}:${SS_PASSWORD}" | base64 -w0)
    echo "ss://${userinfo}@${ip_formatted}:${PORT}#${node_label}"
}

# 生成 AnyTLS 分享链接
# 格式: anytls://PASSWORD@host:port/?sni=...[&insecure=1 | &pbk=...&sid=...&fp=chrome]#name
get_anytls_link() {
    local ip="$1"
    local node_label="$2"
    local ip_formatted="$ip"

    # IPv6 需要方括号
    if [[ "$ip" == *:* ]]; then
        ip_formatted="[$ip]"
    fi

    # 密码为十六进制字符串，URI 安全，无需百分号编码
    local pw="${ANYTLS_PASSWORD}"
    local sni="${SNI:-www.bing.com}"

    if [[ "${PROTOCOL_TYPE}" == "anytls_reality" ]]; then
        # REALITY 伪装：携带公钥/short-id/指纹
        echo "anytls://${pw}@${ip_formatted}:${PORT}/?sni=${sni}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&fp=chrome#${node_label}"
    else
        # 自签名证书：客户端需允许不安全连接
        echo "anytls://${pw}@${ip_formatted}:${PORT}/?sni=${sni}&insecure=1#${node_label}"
    fi
}

# 生成 Hysteria2 分享链接。密码被限制在 URI-unreserved 字符集内。
get_hy2_link() {
    local ip="$1"
    local node_label="$2"
    local ip_formatted="$ip"

    if [[ "$ip" == *:* ]]; then
        ip_formatted="[$ip]"
    fi

    echo "hysteria2://${HY2_PASSWORD}@${ip_formatted}:${PORT}/?sni=${SNI:-www.bing.com}&insecure=1#${node_label}"
}

# 向后兼容的获取分享链接函数
get_share_link() {
    local node_file
    node_file=$(get_node_file "$CURRENT_NODE_NAME")
    # 使用安全的配置加载（防止命令注入）
    safe_load_node_config "$node_file"
    local node_label="${NODE_NAME:-RV-Reality}"
    local ip="${SERVER_IPV4:-${SERVER_IPV6:-$SERVER_IP}}"
    local proto_type="${PROTOCOL_TYPE:-vision}"

    # 根据协议类型返回对应的链接
    if [[ "$proto_type" == "hysteria2" ]] && [[ -n "${HY2_PASSWORD:-}" ]]; then
        HY2_PASSWORD=$(decrypt_value "$HY2_PASSWORD")
        get_hy2_link "$ip" "${node_label}_Hysteria2"
    elif [[ "$proto_type" == "shadowsocks" ]] && [[ -n "${SS_PASSWORD:-}" ]]; then
        # Shadowsocks 节点
        get_ss_link "$ip" "${node_label}_SS"
    elif [[ "$proto_type" == "anytls" || "$proto_type" == "anytls_reality" ]] && [[ -n "${ANYTLS_PASSWORD:-}" ]]; then
        # AnyTLS 节点
        ANYTLS_PASSWORD=$(decrypt_value "$ANYTLS_PASSWORD")
        get_anytls_link "$ip" "${node_label}_AnyTLS"
    elif [[ "$proto_type" == "xhttp" ]] && [[ -n "${XHTTP_PORT:-}" ]]; then
        # XHTTP-only 节点
        get_xhttp_link "$ip" "${node_label}_XHTTP"
    elif [[ -n "${PORT:-}" ]]; then
        # Vision 节点或 both 节点（优先显示 Vision）
        get_vision_link "$ip" "$node_label"
    elif [[ -n "${XHTTP_PORT:-}" ]]; then
        # 后备：如果没有 Vision 端口，使用 XHTTP
        get_xhttp_link "$ip" "${node_label}_XHTTP"
    else
        echo ""
    fi
}

# 显示当前节点的全部二维码。get_share_link 保持单链接兼容契约；only
# the presentation path expands a `both` node into Vision + XHTTP.
show_node_qrcodes() {
    local node_file
    node_file=$(get_node_file "$CURRENT_NODE_NAME")
    safe_load_node_config "$node_file" || return 1

    local node_label="${NODE_NAME:-RV-Reality}"
    local ip="${SERVER_IPV4:-${SERVER_IPV6:-$SERVER_IP}}"
    local proto_type="${PROTOCOL_TYPE:-vision}"
    local shown=0 link

    if [[ "$proto_type" == "both" ]]; then
        if [[ -n "${PORT:-}" ]]; then
            show_qrcode "$(get_vision_link "$ip" "${node_label}_Vision")"
            ((++shown))
        fi
        if [[ -n "${XHTTP_PORT:-}" ]]; then
            show_qrcode "$(get_xhttp_link "$ip" "${node_label}_XHTTP")"
            ((++shown))
        fi
    else
        link=$(get_share_link)
        if [[ -n "$link" ]]; then
            show_qrcode "$link"
            shown=1
        fi
    fi

    if [[ "$shown" -eq 0 ]]; then
        log_error "没有可用的节点链接 / No usable node link"
        return 1
    fi
}

show_qrcode() {
    local link="$1"
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}                    $(msg qr_title)${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    qrencode -t ANSIUTF8 "$link"
    echo ""
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    echo -e "${GREEN}$(msg share_link):${NC}"
    echo -e "${YELLOW}$link${NC}"
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    echo ""
    echo -e "${MAGENTA}$(msg qr_tip)${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
}

# 在 63 宽的标题框内居中输出（近似处理 CJK 双宽字符：显示宽度≈(字符数+字节数)/2）
_center_title() {
    local text="$1"
    local total=63 chars bytes width pad pad_str
    chars=$(printf '%s' "$text" | wc -m 2>/dev/null || echo 0)
    bytes=$(printf '%s' "$text" | wc -c 2>/dev/null || echo 0)
    [[ "${chars:-0}" -le 0 ]] && chars=${#text}
    width=$(( (chars + bytes) / 2 ))
    pad=$(( (total - width) / 2 ))
    (( pad < 0 )) && pad=0
    pad_str=$(printf '%*s' "$pad" '')
    echo -e "${GREEN}${pad_str}${text}${NC}"
}

show_info() {
    local node_file
    node_file=$(get_node_file "$CURRENT_NODE_NAME")
    # 使用安全的配置加载（防止命令注入）
    safe_load_node_config "$node_file"

    local hostname
    hostname=$(hostname 2>/dev/null || echo "server")

    # 协议类型与人类可读名称（用于标题与协议字段）
    local proto_type="${PROTOCOL_TYPE:-both}"
    local proto_label
    case "$proto_type" in
        vision)          proto_label="VLESS Vision + REALITY" ;;
        xhttp)           proto_label="VLESS XHTTP + REALITY" ;;
        both)            proto_label="VLESS Vision + XHTTP + REALITY" ;;
        shadowsocks)     proto_label="Shadowsocks 2022" ;;
        anytls)          proto_label="AnyTLS" ;;
        anytls_reality)  proto_label="AnyTLS + REALITY" ;;
        hysteria2)       proto_label="Hysteria2" ;;
        *)               proto_label="$proto_type" ;;
    esac

    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    _center_title "${proto_label}  $(msg node_info_suffix)"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${BLUE}Node Name:${NC}   ${NODE_NAME:-$CURRENT_NODE_NAME}"
    echo -e "  ${BLUE}协议类型:${NC}    $proto_label"
    if [[ -n "${SERVER_IPV4:-}" ]]; then
        echo -e "  ${BLUE}IPv4:${NC}        $SERVER_IPV4"
    fi
    if [[ -n "${SERVER_IPV6:-}" ]]; then
        echo -e "  ${BLUE}IPv6:${NC}        $SERVER_IPV6"
    fi
    if [[ -z "${SERVER_IPV4:-}" ]] && [[ -z "${SERVER_IPV6:-}" ]]; then
        echo -e "  ${BLUE}$(msg server_addr):${NC} ${SERVER_IP:-N/A}"
    fi

    # Shadowsocks 节点显示不同信息
    if [[ "$proto_type" == "shadowsocks" ]]; then
        echo -e "  ${BLUE}Port:${NC}        ${PORT:-N/A}"
        echo -e "  ${BLUE}Method:${NC}      ${SS_METHOD:-N/A}"
        echo -e "  ${BLUE}Password:${NC}    ${SS_PASSWORD:-N/A}"
        echo -e "  ${BLUE}Network:${NC}     tcp,udp"
        echo ""

        # Shadowsocks IPv4 链接
        if [[ -n "${SERVER_IPV4:-}" ]]; then
            echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
            echo -e "${GREEN}$(msg ipv4_links):${NC}"
            echo ""
            echo -e "  ${YELLOW}Shadowsocks:${NC}"
            echo -e "  $(get_ss_link "$SERVER_IPV4" "${hostname}_SS_v4")"
        fi

        # Shadowsocks IPv6 链接
        if [[ -n "${SERVER_IPV6:-}" ]]; then
            echo ""
            echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
            echo -e "${GREEN}$(msg ipv6_links):${NC}"
            echo ""
            echo -e "  ${YELLOW}Shadowsocks:${NC}"
            echo -e "  $(get_ss_link "$SERVER_IPV6" "${hostname}_SS_v6")"
        fi
    elif [[ "$proto_type" == "hysteria2" ]]; then
        HY2_PASSWORD=$(decrypt_value "$HY2_PASSWORD")
        echo -e "  ${BLUE}Port:${NC}        ${PORT:-N/A} (UDP/QUIC)"
        echo -e "  ${BLUE}Password:${NC}    ${HY2_PASSWORD:-N/A}"
        echo -e "  ${BLUE}Transport:${NC}   Hysteria2 (sing-box)"
        echo -e "  ${BLUE}SNI:${NC}         ${SNI:-www.bing.com}"
        echo -e "  ${BLUE}Insecure:${NC}    true  ${GRAY}(self-signed certificate)${NC}"
        echo ""

        if [[ -n "${SERVER_IPV4:-}" ]]; then
            echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
            echo -e "${GREEN}$(msg ipv4_links):${NC}"
            echo ""
            echo -e "  ${YELLOW}Hysteria2:${NC}"
            echo -e "  $(get_hy2_link "$SERVER_IPV4" "${hostname}_Hysteria2_v4")"
        fi
        if [[ -n "${SERVER_IPV6:-}" ]]; then
            echo ""
            echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
            echo -e "${GREEN}$(msg ipv6_links):${NC}"
            echo ""
            echo -e "  ${YELLOW}Hysteria2:${NC}"
            echo -e "  $(get_hy2_link "$SERVER_IPV6" "${hostname}_Hysteria2_v6")"
        fi
    elif [[ "$proto_type" == "anytls" || "$proto_type" == "anytls_reality" ]]; then
        # AnyTLS 节点显示
        ANYTLS_PASSWORD=$(decrypt_value "$ANYTLS_PASSWORD")
        echo -e "  ${BLUE}Port:${NC}        ${PORT:-N/A}"
        echo -e "  ${BLUE}Password:${NC}    ${ANYTLS_PASSWORD:-N/A}"
        echo -e "  ${BLUE}Transport:${NC}   AnyTLS (sing-box)"
        if [[ "$proto_type" == "anytls_reality" ]]; then
            echo -e "  ${BLUE}Security:${NC}    reality"
            echo -e "  ${BLUE}SNI:${NC}         $SNI"
            echo -e "  ${BLUE}PublicKey:${NC}   $PUBLIC_KEY"
            echo -e "  ${BLUE}ShortID:${NC}     $SHORT_ID"
            echo -e "  ${BLUE}Fingerprint:${NC} chrome"
        else
            echo -e "  ${BLUE}Security:${NC}    tls (self-signed)"
            echo -e "  ${BLUE}SNI:${NC}         ${SNI:-N/A}  ${GRAY}(证书 CN / cert CN)${NC}"
            echo -e "  ${BLUE}Insecure:${NC}    true  ${GRAY}(客户端需允许不安全连接)${NC}"
        fi

        # Padding scheme（base64 解码后展示）：每个节点随机生成，握手时自动下发给客户端
        local at_pad_b64 at_pad_text
        at_pad_b64=$(safe_read_config_value "$node_file" "ANYTLS_PADDING_B64")
        if [[ -n "$at_pad_b64" ]]; then
            at_pad_text=$(echo "$at_pad_b64" | base64 -d 2>/dev/null)
        fi
        if [[ -n "${at_pad_text:-}" ]]; then
            echo -e "  ${BLUE}Padding:${NC}     ${GRAY}(随机化, 握手时自动下发客户端, 无需客户端配置)${NC}"
            local pline
            while IFS= read -r pline; do
                [[ -n "$pline" ]] && echo -e "      ${GRAY}${pline}${NC}"
            done <<< "$at_pad_text"
        fi
        echo ""

        # AnyTLS IPv4 链接
        if [[ -n "${SERVER_IPV4:-}" ]]; then
            echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
            echo -e "${GREEN}$(msg ipv4_links):${NC}"
            echo ""
            echo -e "  ${YELLOW}AnyTLS:${NC}"
            echo -e "  $(get_anytls_link "$SERVER_IPV4" "${hostname}_AnyTLS_v4")"
        fi

        # AnyTLS IPv6 链接
        if [[ -n "${SERVER_IPV6:-}" ]]; then
            echo ""
            echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
            echo -e "${GREEN}$(msg ipv6_links):${NC}"
            echo ""
            echo -e "  ${YELLOW}AnyTLS:${NC}"
            echo -e "  $(get_anytls_link "$SERVER_IPV6" "${hostname}_AnyTLS_v6")"
        fi
    else
        # VLESS 节点显示
        # 根据协议类型显示端口（含传输层细节）
        if [[ "$proto_type" == "vision" || "$proto_type" == "both" ]] && [[ -n "${PORT:-}" ]]; then
            echo -e "  ${BLUE}$(msg vision_port):${NC}  $PORT  ${GRAY}(network=tcp, flow=xtls-rprx-vision)${NC}"
        fi
        if [[ "$proto_type" == "xhttp" || "$proto_type" == "both" ]] && [[ -n "${XHTTP_PORT:-}" ]]; then
            echo -e "  ${BLUE}$(msg xhttp_port):${NC}   $XHTTP_PORT  ${GRAY}(network=xhttp, path=${XHTTP_PATH:-/})${NC}"
        fi
        echo -e "  ${BLUE}UUID:${NC}        $UUID"
        echo -e "  ${BLUE}Security:${NC}    reality"
        echo -e "  ${BLUE}SNI:${NC}         $SNI"
        echo -e "  ${BLUE}PublicKey:${NC}   $PUBLIC_KEY"
        echo -e "  ${BLUE}ShortID:${NC}     $SHORT_ID"
        echo -e "  ${BLUE}Fingerprint:${NC} chrome"
        echo ""

        # IPv4 链接
        if [[ -n "${SERVER_IPV4:-}" ]]; then
            echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
            echo -e "${GREEN}$(msg ipv4_links):${NC}"
            echo ""
            # Vision 链接
            if [[ "$proto_type" == "vision" || "$proto_type" == "both" ]] && [[ -n "${PORT:-}" ]]; then
                echo -e "  ${YELLOW}Vision:${NC}"
                echo -e "  $(get_vision_link "$SERVER_IPV4" "${hostname}_Vision_v4")"
            fi
            # XHTTP 链接
            if [[ "$proto_type" == "xhttp" || "$proto_type" == "both" ]] && [[ -n "${XHTTP_PORT:-}" ]]; then
                echo ""
                echo -e "  ${YELLOW}XHTTP:${NC}"
                echo -e "  $(get_xhttp_link "$SERVER_IPV4" "${hostname}_XHTTP_v4")"
            fi
        fi

        # IPv6 链接
        if [[ -n "${SERVER_IPV6:-}" ]]; then
            echo ""
            echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
            echo -e "${GREEN}$(msg ipv6_links):${NC}"
            echo ""
            # Vision 链接
            if [[ "$proto_type" == "vision" || "$proto_type" == "both" ]] && [[ -n "${PORT:-}" ]]; then
                echo -e "  ${YELLOW}Vision:${NC}"
                echo -e "  $(get_vision_link "$SERVER_IPV6" "${hostname}_Vision_v6")"
            fi
            # XHTTP 链接
            if [[ "$proto_type" == "xhttp" || "$proto_type" == "both" ]] && [[ -n "${XHTTP_PORT:-}" ]]; then
                echo ""
                echo -e "  ${YELLOW}XHTTP:${NC}"
                echo -e "  $(get_xhttp_link "$SERVER_IPV6" "${hostname}_XHTTP_v6")"
            fi
        fi
    fi

    # 向后兼容：如果没有 IPv4/IPv6，使用旧的 SERVER_IP
    if [[ -z "${SERVER_IPV4:-}" ]] && [[ -z "${SERVER_IPV6:-}" ]] && [[ -n "${SERVER_IP:-}" ]]; then
        echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
        echo -e "${GREEN}$(msg share_link):${NC}"
        echo -e "${YELLOW}$(get_share_link)${NC}"
    fi

    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
}

show_proxy_service_failure_logs() {
    local service_name="$1"
    local fallback_log="${2:-}"
    local output=""

    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        [[ -n "$fallback_log" ]] && output=$(tail -n 30 "$fallback_log" 2>/dev/null || true)
    else
        output=$(journalctl -u "$service_name" --no-pager -n 30 2>/dev/null || true)
    fi
    if [[ -n "$output" ]]; then
        printf '%s\n' "----- $service_name (last 30 lines) -----" >&2
        printf '%s\n' "$output" >&2
    fi
}

# Remove only the candidate node and prove that the previous core state can be
# rebuilt. A failed rollback remains a hard failure instead of being hidden.
rollback_candidate_node() {
    local protocol="$1"
    local node_name="$2"
    local node_file
    node_file=$(get_node_file "$node_name")

    rm -f "$node_file" 2>/dev/null
    rm -f "$SINGBOX_CERT_DIR/${node_name}.crt" "$SINGBOX_CERT_DIR/${node_name}.key" 2>/dev/null

    case "$protocol" in
        anytls|anytls_reality|hysteria2)
            if ! singbox_sync; then
                log_error "Rollback failed while restoring sing-box state"
                return 1
            fi
            ;;
        *)
            if ! write_config; then
                log_error "Rollback failed while rebuilding Xray config"
                return 1
            fi
            if [[ "$(xray_node_count)" -gt 0 ]]; then
                if ! service_restart xray || ! service_is_active xray; then
                    log_error "Rollback failed while restoring Xray service"
                    return 1
                fi
            else
                service_stop xray
            fi
            ;;
    esac
}

# Open only the transports used by a node. Firewall tooling is best-effort
# because cloud security groups and host policy may be managed externally, but
# every active-backend failure is surfaced to the operator.
open_node_firewall_ports() {
    local protocol="$1"

    case "$protocol" in
        hysteria2)
            open_firewall_port "$PORT" udp || \
                log_warn "Could not automatically open UDP port $PORT"
            ;;
        shadowsocks)
            open_firewall_port "$PORT" both || \
                log_warn "Could not automatically open TCP/UDP port $PORT"
            ;;
        anytls|anytls_reality|vision)
            if [[ -n "${PORT:-}" ]]; then
                open_firewall_port "$PORT" tcp || \
                    log_warn "Could not automatically open TCP port $PORT"
            fi
            ;;
        xhttp)
            if [[ -n "${XHTTP_PORT:-}" ]]; then
                open_firewall_port "$XHTTP_PORT" tcp || \
                    log_warn "Could not automatically open TCP port $XHTTP_PORT"
            fi
            ;;
        both)
            if [[ -n "${PORT:-}" ]]; then
                open_firewall_port "$PORT" tcp || \
                    log_warn "Could not automatically open TCP port $PORT"
            fi
            if [[ -n "${XHTTP_PORT:-}" ]]; then
                open_firewall_port "$XHTTP_PORT" tcp || \
                    log_warn "Could not automatically open TCP port $XHTTP_PORT"
            fi
            ;;
    esac

    return 0
}

cmd_install() {
    if ! is_root; then
        log_error "$(msg run_as_root)"
        return 1
    fi

    log_info "$(msg installing)"

    # 清空上一次操作残留的节点变量。这些是进程级全局量：同一次菜单会话里连续安装
    # 或先查看再安装时，未重置的字段会把上一个节点的 UUID/密钥/端口带进新节点的 .env。
    reset_node_state

    # 仅安装通用依赖（curl/tar/jq/qrencode/openssl 等）。
    # 代理内核（Xray 或 sing-box）在选择协议类型之后按需安装；
    # GeoIP/GeoSite 数据库不再默认下载，仅在启用 WARP 分流时才按需获取。
    install_deps

    # 交互式输入节点名称（或使用环境变量 name=xxx）
    if [[ -n "${name:-}" ]]; then
        CURRENT_NODE_NAME=$(printf '%s' "$name" | tr -cd 'a-zA-Z0-9_-')
        if [[ -z "$CURRENT_NODE_NAME" || "$CURRENT_NODE_NAME" != "$name" ]]; then
            log_error "Node name may contain only letters, numbers, underscore, and dash"
            return 1
        fi
        # 如果名称已存在，添加后缀
        local base_name="$CURRENT_NODE_NAME"
        local counter=1
        while node_exists "$CURRENT_NODE_NAME"; do
            CURRENT_NODE_NAME="${base_name}_${counter}"
            ((++counter))
        done
    else
        CURRENT_NODE_NAME=$(prompt_node_name)
    fi
    log_info "Node name: $CURRENT_NODE_NAME"

    # 选择协议类型（除非通过环境变量指定）
    if [[ -n "${proto:-}" ]]; then
        # 支持环境变量 proto=vision/xhttp/both/shadowsocks/ss/anytls/anytls-reality/hysteria2
        case "$proto" in
            xhttp) PROTOCOL_TYPE="xhttp" ;;
            both) PROTOCOL_TYPE="both" ;;
            shadowsocks|ss) PROTOCOL_TYPE="shadowsocks" ;;
            anytls) PROTOCOL_TYPE="anytls" ;;
            anytls-reality|anytls_reality|anytlsreality) PROTOCOL_TYPE="anytls_reality" ;;
            hysteria2|hy2) PROTOCOL_TYPE="hysteria2" ;;
            *) PROTOCOL_TYPE="vision" ;;
        esac
        log_info "协议类型: $PROTOCOL_TYPE"
    elif [[ -n "${xhttp:-}" ]]; then
        # 向后兼容: xhttp=true 等同于 proto=both
        if [[ "$xhttp" == "true" ]] || [[ "$xhttp" == "1" ]] || [[ "$xhttp" == "y" ]]; then
            PROTOCOL_TYPE="both"
            log_info "协议类型: both (Vision + XHTTP)"
        fi
    else
        prompt_protocol_type
    fi

    # 按所选协议安装对应内核：VLESS / Shadowsocks 用 Xray；AnyTLS / Hysteria2 用 sing-box。
    case "$PROTOCOL_TYPE" in
        anytls|anytls_reality|hysteria2)
            : # sing-box 在对应协议分支中安装
            ;;
        *)
            install_xray || { log_error "Xray 安装失败"; return 1; }
            ;;
    esac

    # Shadowsocks 和 VLESS 的安装流程不同
    if [[ "$PROTOCOL_TYPE" == "shadowsocks" ]]; then
        # Shadowsocks 安装流程
        # 选择加密方式（或使用环境变量 ssmethod=xxx）
        if [[ -n "${ssmethod:-}" ]]; then
            SS_METHOD="$ssmethod"
            log_info "加密方式: $SS_METHOD"
        else
            prompt_ss_method
        fi

        # 生成密码（或使用环境变量 sspwd=xxx）
        if [[ -n "${sspwd:-}" ]]; then
            SS_PASSWORD="$sspwd"
            log_info "使用指定密码"
        else
            gen_ss_password
        fi

        # 选择端口
        choose_ports

        # SS 不需要 SNI, UUID, Reality Keys
        SNI=""
        UUID=""
        PUBLIC_KEY=""
        PRIVATE_KEY=""
        SHORT_ID=""
        ANYTLS_PASSWORD=""
        ANYTLS_PADDING_B64=""
        HY2_PASSWORD=""
    elif [[ "$PROTOCOL_TYPE" == "hysteria2" ]]; then
        install_singbox || { log_error "sing-box 安装失败"; return 1; }
        gen_hy2_password || return 1
        SNI="${hy2sni:-www.bing.com}"
        if ! validate_tls_server_name "$SNI"; then
            log_error "Invalid Hysteria2 TLS SNI: $SNI"
            return 1
        fi
        choose_ports || return 1

        UUID=""
        PUBLIC_KEY=""
        PRIVATE_KEY=""
        SHORT_ID=""
        SS_METHOD=""
        SS_PASSWORD=""
        ANYTLS_PASSWORD=""
        ANYTLS_PADDING_B64=""
    elif [[ "$PROTOCOL_TYPE" == "anytls" || "$PROTOCOL_TYPE" == "anytls_reality" ]]; then
        # AnyTLS 安装流程（基于 sing-box）
        install_singbox || { log_error "sing-box 安装失败"; return 1; }

        # SNI: REALITY 节点需要真实可达域名；plain 节点的 SNI 仅作伪装/证书 CN，
        # 但同样支持「测速选择 + 自定义」，与 REALITY 逻辑一致。
        if [[ -n "${reym:-}" ]]; then
            SNI="$reym"
            log_info "$(msg using_sni): $SNI"
        else
            rm -f "$CACHE_FILE" 2>/dev/null
            [[ "$PROTOCOL_TYPE" == "anytls" ]] && log_info "$(msg anytls_sni_note)"
            select_best_sni
        fi

        choose_ports

        # 生成密码与随机化 padding scheme
        gen_anytls_password
        ANYTLS_PADDING_B64="$(gen_anytls_padding | base64 -w0)"
        log_info "已生成随机化 AnyTLS padding scheme"

        # AnyTLS 两种变体都以密码认证，不使用 UUID；REALITY 变体额外需要密钥对。
        # UUID 必须在分支之外显式置空：gen_reality_keys 只产出 PUBLIC_KEY/PRIVATE_KEY/SHORT_ID，
        # 若把 UUID="" 留在 else 分支里，anytls_reality 路径就会带着未赋值的 UUID 走到
        # save_env，在 `set -u` 下直接以 "UUID: unbound variable" 终止安装。
        UUID=""
        if [[ "$PROTOCOL_TYPE" == "anytls_reality" ]]; then
            gen_reality_keys || return 1
        else
            PUBLIC_KEY=""
            PRIVATE_KEY=""
            SHORT_ID=""
        fi
        SS_METHOD=""
        SS_PASSWORD=""
        HY2_PASSWORD=""
    else
        # VLESS 安装流程
        # 安装时清除 SNI 缓存，强制重新测试
        rm -f "$CACHE_FILE" 2>/dev/null

        if [[ -n "${reym:-}" ]]; then
            SNI="$reym"
            log_info "$(msg using_sni): $SNI"
        else
            select_best_sni
        fi

        gen_uuid
        choose_ports
        gen_reality_keys
        ANYTLS_PASSWORD=""
        ANYTLS_PADDING_B64=""
        HY2_PASSWORD=""
    fi

    # 检测双栈 IP
    detect_network_stack

    save_env

    if [[ "$PROTOCOL_TYPE" == "anytls" || "$PROTOCOL_TYPE" == "anytls_reality" || "$PROTOCOL_TYPE" == "hysteria2" ]]; then
        # plain AnyTLS 与 Hysteria2 使用各节点独立的自签名证书。
        if [[ "$PROTOCOL_TYPE" == "anytls" || "$PROTOCOL_TYPE" == "hysteria2" ]]; then
            if ! gen_selfsigned_cert "$CURRENT_NODE_NAME" "$SNI"; then
                log_error "Failed to generate TLS certificate, rolling back..."
                rollback_candidate_node "$PROTOCOL_TYPE" "$CURRENT_NODE_NAME" || \
                    log_error "Manual recovery may be required for sing-box"
                return 1
            fi
        fi

        if ! singbox_sync; then
            log_error "Failed to configure or start sing-box, rolling back..."
            show_proxy_service_failure_logs "$SINGBOX_SERVICE" /var/log/sing-box.log
            rollback_candidate_node "$PROTOCOL_TYPE" "$CURRENT_NODE_NAME" || \
                log_error "Manual recovery may be required for sing-box"
            return 1
        fi

        open_node_firewall_ports "$PROTOCOL_TYPE"
    else
        # 生成 Xray 配置文件，如果失败则回滚
        if ! write_config; then
            log_error "Failed to generate Xray config, rolling back..."
            rollback_candidate_node "$PROTOCOL_TYPE" "$CURRENT_NODE_NAME" || \
                log_error "Manual recovery may be required for Xray"
            return 1
        fi

        service_enable xray
        if ! service_restart xray; then
            log_error "Xray service restart failed after install"
            show_proxy_service_failure_logs xray /var/log/xray/error.log
            rollback_candidate_node "$PROTOCOL_TYPE" "$CURRENT_NODE_NAME" || \
                log_error "Manual recovery may be required for Xray"
            return 1
        fi

        sleep 1
        if ! service_is_active xray; then
            log_error "Xray service failed to become active after install"
            show_proxy_service_failure_logs xray /var/log/xray/error.log
            rollback_candidate_node "$PROTOCOL_TYPE" "$CURRENT_NODE_NAME" || \
                log_error "Manual recovery may be required for Xray"
            return 1
        fi

        open_node_firewall_ports "$PROTOCOL_TYPE"
    fi

    log_info "$(msg install_complete)"

    show_info

    show_node_qrcodes

    # 询问是否启用定时重启 Xray（仅首次创建节点时提示，或通过环境变量 restart= 指定）
    prompt_xray_restart_on_install

    # SS2022 安装完成后自动提示时间同步
    if [[ "$PROTOCOL_TYPE" == "shadowsocks" ]]; then
        prompt_timesync_for_ss2022
    fi
}

cmd_info() {
    select_node || return 1
    show_info
}

cmd_qr() {
    select_node || return 1

    if ! command -v qrencode &>/dev/null; then
        log_info "$(msg install_deps)"
        $PKG_UPDATE >/dev/null 2>&1 || true
        $PKG_INSTALL qrencode >/dev/null 2>&1
    fi

    show_node_qrcodes
}

# 列出所有节点
cmd_list() {
    local nodes
    read -ra nodes <<< "$(list_nodes)"

    if [[ ${#nodes[@]} -eq 0 ]]; then
        log_error "$(msg config_not_found)"
        return 1
    fi

    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}                     All Nodes / 所有节点${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""

    local i=1
    for node in "${nodes[@]}"; do
        local node_file
        node_file=$(get_node_file "$node")
        # 使用安全的配置加载（防止命令注入）
        safe_load_node_config "$node_file"
        # 根据协议类型显示对应的端口
        local display_port=""
        local proto="${PROTOCOL_TYPE:-vision}"
        if [[ "$proto" == "shadowsocks" ]]; then
            display_port="${PORT:-N/A}"
        elif [[ "$proto" == "hysteria2" ]]; then
            display_port="${PORT:-N/A} (UDP)"
        elif [[ "$proto" == "xhttp" ]]; then
            display_port="${XHTTP_PORT:-N/A}"
        elif [[ "$proto" == "both" ]]; then
            display_port="${PORT:-}/${XHTTP_PORT:-}"
        else
            display_port="${PORT:-N/A}"
        fi
        echo -e "  ${GREEN}$i.${NC} ${BLUE}$node${NC}"
        if [[ "$proto" == "shadowsocks" ]]; then
            echo -e "     Port: $display_port | Method: ${SS_METHOD:-N/A}"
            echo -e "     Password: ${SS_PASSWORD:0:12}..."
        elif [[ "$proto" == "hysteria2" ]]; then
            echo -e "     Port: $display_port | Type: Hysteria2"
            echo -e "     Password: ${HY2_PASSWORD:0:12}..."
        elif [[ "$proto" == "anytls" || "$proto" == "anytls_reality" ]]; then
            local at_label="AnyTLS"
            [[ "$proto" == "anytls_reality" ]] && at_label="AnyTLS + REALITY"
            echo -e "     Port: $display_port | Type: $at_label"
            echo -e "     Password: ${ANYTLS_PASSWORD:0:12}..."
            [[ "$proto" == "anytls_reality" ]] && echo -e "     SNI: $SNI"
        else
            echo -e "     Port: $display_port | SNI: $SNI"
            echo -e "     UUID: ${UUID:0:8}..."
            if [[ -n "$XHTTP_PORT" ]] && [[ "$proto" != "vision" ]]; then
                echo -e "     XHTTP: $XHTTP_PORT"
            fi
        fi
        echo ""
        ((++i))
    done

    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
}

cmd_status() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}                     $(msg service_status)${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""

    if [[ "$(xray_node_count)" -gt 0 ]]; then
        if service_is_active xray; then
            echo -e "  Xray: ${GREEN}● Running${NC}"
        else
            echo -e "  Xray: ${RED}○ Stopped${NC}"
        fi
    fi

    if [[ "$(singbox_node_count)" -gt 0 ]]; then
        if service_is_active "$SINGBOX_SERVICE"; then
            echo -e "  sing-box (AnyTLS/Hysteria2): ${GREEN}● Running${NC}"
        else
            echo -e "  sing-box (AnyTLS/Hysteria2): ${RED}○ Stopped${NC}"
        fi
    fi

    local node_count
    node_count=$(count_nodes)
    echo -e "  Nodes: ${GREEN}${node_count}${NC}"

    # 显示每个节点的连接数
    if [[ $node_count -gt 0 ]]; then
        echo ""
        echo -e "  ${BLUE}Active connections:${NC}"
        for node_file in "$NODES_DIR"/*.env; do
            [[ -f "$node_file" ]] || continue
            local n_name n_port n_proto
            n_name=$(basename "$node_file" .env)
            n_port=$(safe_read_config_value "$node_file" "PORT")
            n_proto=$(safe_read_config_value "$node_file" "PROTOCOL_TYPE")
            if [[ "$n_proto" == "hysteria2" ]]; then
                echo -e "    $n_name (UDP $n_port): Hysteria2"
                continue
            fi
            local conn_count
            conn_count=$(ss -tn state established "( sport = :${n_port} )" 2>/dev/null | tail -n +2 | wc -l)
            echo -e "    $n_name (Port $n_port): ${GREEN}${conn_count}${NC}"
        done
    fi

    echo ""
    [[ "$(xray_node_count)" -gt 0 ]] && service_status xray
    [[ "$(singbox_node_count)" -gt 0 ]] && service_status "$SINGBOX_SERVICE"
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
}

cmd_restart() {
    local restarted=false
    if [[ "$(xray_node_count)" -gt 0 ]]; then
        service_restart xray || return 1
        restarted=true
    fi
    if [[ "$(singbox_node_count)" -gt 0 ]]; then
        service_restart "$SINGBOX_SERVICE" || return 1
        restarted=true
    fi
    if ! $restarted; then
        log_error "No configured proxy nodes"
        return 1
    fi
    log_info "$(msg service_restarted)"
}

# 重新生成配置文件（用于修复配置问题）
cmd_regenerate() {
    log_info "Regenerating proxy configs from node files..."

    local xray_count
    xray_count=$(xray_node_count)

    # 仅在存在 Xray 节点时重建并验证 Xray；Hysteria2-only 不应依赖 Xray。
    if [[ "$xray_count" -gt 0 && -f "$XRAY_CONF" ]]; then
        cp "$XRAY_CONF" "${XRAY_CONF}.bak"
        log_info "Backed up current config to ${XRAY_CONF}.bak"
    fi

    if [[ "$xray_count" -gt 0 ]]; then
        if write_config; then
            log_info "Xray config regenerated successfully"
            if ! service_restart xray; then
                log_error "Xray service restart failed. Restoring backup..."
                [[ -f "${XRAY_CONF}.bak" ]] && mv "${XRAY_CONF}.bak" "$XRAY_CONF"
                service_restart xray >/dev/null 2>&1 || true
                return 1
            fi
            sleep 1
            if ! service_is_active xray; then
                log_error "Xray service failed to start. Restoring backup..."
                if [[ -f "${XRAY_CONF}.bak" ]]; then
                    mv "${XRAY_CONF}.bak" "$XRAY_CONF"
                    service_restart xray >/dev/null 2>&1 || true
                fi
                return 1
            fi
        else
            log_error "Failed to regenerate Xray config"
            if [[ -f "${XRAY_CONF}.bak" ]]; then
                log_info "Restoring backup config..."
                mv "${XRAY_CONF}.bak" "$XRAY_CONF"
            fi
            return 1
        fi
    else
        service_stop xray
    fi

    # 同步 sing-box（AnyTLS / Hysteria2）配置。
    if ! singbox_sync; then
        log_error "sing-box config sync failed"
        return 1
    fi

    # 清理备份
    rm -f "${XRAY_CONF}.bak" 2>/dev/null
    return 0
}

# 删除单个节点
cmd_remove() {
    select_node || return 1

    local node_file
    node_file=$(get_node_file "$CURRENT_NODE_NAME")

    {
    echo ""
    echo -e "${YELLOW}About to remove node: $CURRENT_NODE_NAME${NC}"
    echo -n "Confirm? [y/N]: "
    } >/dev/tty
    read -r confirm </dev/tty

    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log_info "Cancelled"
        return 0
    fi

    rm -f "$node_file"
    # 清理可能存在的 AnyTLS / Hysteria2 自签名证书
    rm -f "$SINGBOX_CERT_DIR/${CURRENT_NODE_NAME}.crt" "$SINGBOX_CERT_DIR/${CURRENT_NODE_NAME}.key" 2>/dev/null
    log_info "Node '$CURRENT_NODE_NAME' removed"

    if ! cmd_regenerate; then
        log_error "Node removed, but the remaining proxy configuration could not be applied"
        return 1
    fi

    log_info "Config updated"
}

# 编辑已有节点的参数（端口 / SNI / 密码 / 密钥 / padding 等）
cmd_edit() {
    select_node || return 1
    local node_file
    node_file=$(get_node_file "$CURRENT_NODE_NAME")
    safe_load_node_config "$node_file"

    # safe_load 不含 padding；并解密敏感值，便于重存时正确再加密（明文配置下为 no-op）
    ANYTLS_PADDING_B64=$(safe_read_config_value "$node_file" "ANYTLS_PADDING_B64")
    UUID=$(decrypt_value "$UUID")
    PRIVATE_KEY=$(decrypt_value "$PRIVATE_KEY")
    SS_PASSWORD=$(decrypt_value "$SS_PASSWORD")
    ANYTLS_PASSWORD=$(decrypt_value "$ANYTLS_PASSWORD")
    HY2_PASSWORD=$(decrypt_value "$HY2_PASSWORD")

    local proto_type="${PROTOCOL_TYPE:-vision}"
    local changed=false
    local sni_changed=false

    while true; do
        {
        echo ""
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}        编辑节点 / Edit Node: ${CURRENT_NODE_NAME} [${proto_type}]${NC}"
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo ""
        case "$proto_type" in
            vision)
                echo -e "  ${GREEN}1.${NC} 修改端口 / Port            ${GRAY}(${PORT})${NC}"
                echo -e "  ${GREEN}2.${NC} 修改 SNI / dest            ${GRAY}(${SNI})${NC}"
                echo -e "  ${GREEN}3.${NC} 重新生成 UUID              ${GRAY}(${UUID:0:8}...)${NC}"
                echo -e "  ${GREEN}4.${NC} 重新生成 Reality 密钥对"
                ;;
            xhttp)
                echo -e "  ${GREEN}1.${NC} 修改端口 / XHTTP Port      ${GRAY}(${XHTTP_PORT})${NC}"
                echo -e "  ${GREEN}2.${NC} 修改 SNI / dest            ${GRAY}(${SNI})${NC}"
                echo -e "  ${GREEN}3.${NC} 重新生成 UUID              ${GRAY}(${UUID:0:8}...)${NC}"
                echo -e "  ${GREEN}4.${NC} 重新生成 Reality 密钥对"
                echo -e "  ${GREEN}5.${NC} 重新生成 XHTTP path        ${GRAY}(${XHTTP_PATH})${NC}"
                ;;
            both)
                echo -e "  ${GREEN}1.${NC} 修改 Vision 端口           ${GRAY}(${PORT})${NC}"
                echo -e "  ${GREEN}2.${NC} 修改 XHTTP 端口            ${GRAY}(${XHTTP_PORT})${NC}"
                echo -e "  ${GREEN}3.${NC} 修改 SNI / dest            ${GRAY}(${SNI})${NC}"
                echo -e "  ${GREEN}4.${NC} 重新生成 UUID              ${GRAY}(${UUID:0:8}...)${NC}"
                echo -e "  ${GREEN}5.${NC} 重新生成 Reality 密钥对"
                ;;
            shadowsocks)
                echo -e "  ${GREEN}1.${NC} 修改端口 / Port            ${GRAY}(${PORT})${NC}"
                echo -e "  ${GREEN}2.${NC} 修改加密方式 / Method      ${GRAY}(${SS_METHOD})${NC}"
                echo -e "  ${GREEN}3.${NC} 重新生成密码 / Password"
                ;;
            anytls|anytls_reality)
                echo -e "  ${GREEN}1.${NC} 修改端口 / Port            ${GRAY}(${PORT})${NC}"
                echo -e "  ${GREEN}2.${NC} 修改 SNI                   ${GRAY}(${SNI})${NC}"
                echo -e "  ${GREEN}3.${NC} 重新生成密码 / Password"
                echo -e "  ${GREEN}4.${NC} 重新生成 padding scheme"
                [[ "$proto_type" == "anytls_reality" ]] && echo -e "  ${GREEN}5.${NC} 重新生成 Reality 密钥对"
                ;;
            hysteria2)
                echo -e "  ${GREEN}1.${NC} 修改 UDP 端口 / UDP Port    ${GRAY}(${PORT})${NC}"
                echo -e "  ${GREEN}2.${NC} 修改 TLS SNI               ${GRAY}(${SNI})${NC}"
                echo -e "  ${GREEN}3.${NC} 重新生成密码 / Password"
                ;;
            *)
                log_error "未知协议类型: $proto_type"
                return 1
                ;;
        esac
        echo -e "  ${GREEN}0.${NC} 完成并应用 / Save & apply"
        echo ""
        echo -n "  选择要修改的项 / Select [0-5]: "
        } >/dev/tty

        local c
        read -r c </dev/tty

        case "${proto_type}:${c}" in
            *:0) break ;;

            # ---- 端口 ----
            xhttp:1)
                XHTTP_PORT=$(prompt_port "新 XHTTP 端口 / New port" "${XHTTP_PORT}")
                changed=true ;;
            both:1)
                PORT=$(prompt_port "新 Vision 端口 / New port" "${PORT}" "${XHTTP_PORT:-0}")
                changed=true ;;
            both:2)
                XHTTP_PORT=$(prompt_port "新 XHTTP 端口 / New port" "${XHTTP_PORT}" "${PORT:-0}")
                changed=true ;;
            vision:1|shadowsocks:1|anytls:1|anytls_reality:1)
                PORT=$(prompt_port "新端口 / New port" "${PORT}")
                changed=true ;;
            hysteria2:1)
                PORT=$(prompt_port "新 UDP 端口 / New UDP port" "${PORT}" 0 udp)
                changed=true ;;

            # ---- SNI（测速 + 自定义）----
            vision:2|xhttp:2|both:3|anytls:2|anytls_reality:2)
                rm -f "$CACHE_FILE" 2>/dev/null
                [[ "$proto_type" == "anytls" ]] && log_info "$(msg anytls_sni_note)"
                select_best_sni
                sni_changed=true
                changed=true ;;
            hysteria2:2)
                local new_hy2_sni
                echo -n "  TLS SNI [${SNI:-www.bing.com}]: " >/dev/tty
                read -r new_hy2_sni </dev/tty
                new_hy2_sni="${new_hy2_sni:-${SNI:-www.bing.com}}"
                if validate_tls_server_name "$new_hy2_sni"; then
                    SNI="$new_hy2_sni"
                    sni_changed=true
                    changed=true
                else
                    log_warn "Invalid TLS SNI"
                fi ;;

            # ---- UUID ----
            vision:3|xhttp:3|both:4)
                UUID=$(cat /proc/sys/kernel/random/uuid)
                log_info "新 UUID: $UUID"
                changed=true ;;

            # ---- Reality 密钥对 ----
            vision:4|xhttp:4|both:5|anytls_reality:5)
                if gen_reality_keys; then
                    log_warn "Reality 密钥已更新，客户端需同步新的 PublicKey/ShortID"
                    changed=true
                fi ;;

            # ---- XHTTP path ----
            xhttp:5)
                XHTTP_PATH="/$(openssl rand -hex 4)"
                log_info "新 path: $XHTTP_PATH"
                changed=true ;;

            # ---- Shadowsocks 加密方式（同时重新生成匹配长度的密码）----
            shadowsocks:2)
                prompt_ss_method
                gen_ss_password
                log_warn "加密方式已变更，密码已随之重新生成"
                changed=true ;;

            # ---- 密码（SS / AnyTLS）----
            shadowsocks:3)
                gen_ss_password
                log_info "密码已重新生成"
                changed=true ;;
            anytls:3|anytls_reality:3)
                gen_anytls_password
                changed=true ;;
            hysteria2:3)
                unset hy2pwd
                gen_hy2_password
                changed=true ;;

            # ---- AnyTLS padding ----
            anytls:4|anytls_reality:4)
                ANYTLS_PADDING_B64="$(gen_anytls_padding | base64 -w0)"
                log_info "padding scheme 已重新随机生成"
                changed=true ;;

            *)
                log_warn "无效选择 / invalid choice"
                sleep 1 ;;
        esac
    done

    if ! $changed; then
        log_info "未做任何修改 / No changes"
        return 0
    fi

    # 写回 .env（save_env 会按当前全局变量重写该节点配置）
    save_env

    # 重新生成对应内核配置并重启
    if [[ "$proto_type" == "anytls" || "$proto_type" == "anytls_reality" || "$proto_type" == "hysteria2" ]]; then
        # 自签名 TLS 协议改了 SNI：重新生成证书（CN 跟随新 SNI）。
        if [[ "$proto_type" == "anytls" || "$proto_type" == "hysteria2" ]] && $sni_changed; then
            rm -f "$SINGBOX_CERT_DIR/${CURRENT_NODE_NAME}.crt" "$SINGBOX_CERT_DIR/${CURRENT_NODE_NAME}.key" 2>/dev/null
            gen_selfsigned_cert "$CURRENT_NODE_NAME" "$SNI" || return 1
        fi
        if ! singbox_sync; then
            log_error "应用失败：sing-box 配置无效，请检查参数"
            return 1
        fi
        open_node_firewall_ports "$proto_type"
    else
        if ! write_config; then
            log_error "应用失败：Xray 配置无效，请检查参数"
            return 1
        fi
        service_restart xray || return 1
        open_node_firewall_ports "$proto_type"
    fi

    log_info "节点已更新 / Node updated"
    show_info
}

cmd_uninstall() {
    log_info "$(msg uninstalling)"
    # 清理定时重启计划（service/timer 或 crontab 条目）
    remove_xray_restart_schedule
    service_stop xray
    service_disable xray
    rm -f "$XRAY_CONF" "$LANG_FILE"
    rm -rf "$NODES_DIR"

    # Alpine 使用手动安装，需要手动清理
    if [[ "$PKG_MANAGER" == "apk" ]]; then
        rm -f /usr/local/bin/xray
        rm -rf /usr/local/etc/xray
        rm -rf /usr/local/share/xray
        rm -rf /var/log/xray
        rm -f /etc/init.d/xray
    else
        # Security: Download script to temp file first, then execute
        local tmp_installer="/tmp/xray-uninstall-$$.sh"
        if secure_curl "https://github.com/XTLS/Xray-install/raw/main/install-release.sh" -o "$tmp_installer"; then
            bash "$tmp_installer" remove >/dev/null 2>&1
            rm -f "$tmp_installer"
        fi
    fi

    # 卸载 sing-box（AnyTLS / Hysteria2）
    if [[ -f "$SINGBOX_BIN" ]] || [[ -f /etc/systemd/system/sing-box.service ]] || [[ -f /etc/init.d/sing-box ]]; then
        service_stop "$SINGBOX_SERVICE"
        service_disable "$SINGBOX_SERVICE"
        rm -f "$SINGBOX_BIN"
        rm -rf "$SINGBOX_DIR"
        rm -f /etc/systemd/system/sing-box.service /etc/init.d/sing-box
        rm -f /var/log/sing-box.log
        systemctl daemon-reload 2>/dev/null || true
    fi

    log_info "$(msg uninstall_complete)"
}

cmd_test_sni() {
    local total=${#SNI_LIST[@]}
    log_info "$(msg testing_sni) ($(msg total_domains): $total)"
    echo ""

    declare -A latency_map

    # 使用并行测试（带详细输出）
    test_domains_parallel_verbose latency_map

    echo ""

    # 显示排序结果（前10名）
    if [[ ${#latency_map[@]} -gt 0 ]]; then
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}                     Top 10 $(msg best_latency)${NC}"
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo ""

        # 排序并显示前10
        for domain in "${!latency_map[@]}"; do
            echo "${latency_map[$domain]} $domain"
        done | sort -n | head -10 | while read -r lat dom; do
            printf "  ${GREEN}%4dms${NC}  %s\n" "$lat" "$dom"
        done

        echo ""
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    fi

    log_info "$(msg test_complete)"
}

cmd_health() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}                     $(msg health_check)${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""

    local all_ok=true

    # 1. 仅检查实际被节点使用的代理内核。
    if [[ "$(xray_node_count)" -gt 0 ]]; then
        if service_is_active xray; then
            echo -e "  ${GREEN}✓${NC} Xray service is running"
        else
            echo -e "  ${RED}✗${NC} Xray service is not running"
            all_ok=false
        fi
    fi

    if [[ "$(singbox_node_count)" -gt 0 ]]; then
        if service_is_active "$SINGBOX_SERVICE"; then
            echo -e "  ${GREEN}✓${NC} sing-box service is running (AnyTLS/Hysteria2)"
        else
            echo -e "  ${RED}✗${NC} sing-box service is not running (AnyTLS/Hysteria2)"
            all_ok=false
        fi
    fi

    # 2. 检查节点数量
    local node_count
    node_count=$(count_nodes)
    if [[ $node_count -gt 0 ]]; then
        echo -e "  ${GREEN}✓${NC} $node_count node(s) configured"
    else
        echo -e "  ${RED}✗${NC} No nodes configured"
        all_ok=false
    fi

    # 3. 检查每个节点的端口和 SNI
    for node_file in "$NODES_DIR"/*.env; do
        [[ -f "$node_file" ]] || continue
        local n_name n_port n_sni n_xhttp_port n_protocol_type
        n_name=$(basename "$node_file" .env)
        n_port=$(safe_read_config_value "$node_file" "PORT")
        n_sni=$(safe_read_config_value "$node_file" "SNI")
        n_xhttp_port=$(safe_read_config_value "$node_file" "XHTTP_PORT")
        n_protocol_type=$(safe_read_config_value "$node_file" "PROTOCOL_TYPE")

        # 向后兼容：旧配置没有 PROTOCOL_TYPE，根据端口判断
        if [[ -z "$n_protocol_type" ]]; then
            if [[ -n "$n_port" ]] && [[ -n "$n_xhttp_port" ]]; then
                n_protocol_type="both"
            elif [[ -n "$n_xhttp_port" ]]; then
                n_protocol_type="xhttp"
            else
                n_protocol_type="vision"
            fi
        fi

        echo ""
        echo -e "  ${BLUE}Node: $n_name${NC} (${n_protocol_type})"

        # 根据协议类型检查端口
        if [[ "$n_protocol_type" == "vision" || "$n_protocol_type" == "both" ]] && [[ -n "$n_port" ]]; then
            if ss -lnt | grep -qE ":${n_port}\s"; then
                echo -e "    ${GREEN}✓${NC} Vision port $n_port is listening"
            else
                echo -e "    ${RED}✗${NC} Vision port $n_port is not listening"
                all_ok=false
            fi
        fi

        if [[ "$n_protocol_type" == "xhttp" || "$n_protocol_type" == "both" ]] && [[ -n "$n_xhttp_port" ]]; then
            if ss -lnt | grep -qE ":${n_xhttp_port}\s"; then
                echo -e "    ${GREEN}✓${NC} XHTTP port $n_xhttp_port is listening"
            else
                echo -e "    ${RED}✗${NC} XHTTP port $n_xhttp_port is not listening"
                all_ok=false
            fi
        fi

        if [[ "$n_protocol_type" == "anytls" || "$n_protocol_type" == "anytls_reality" ]] && [[ -n "$n_port" ]]; then
            if ss -lnt | grep -qE ":${n_port}\s"; then
                echo -e "    ${GREEN}✓${NC} AnyTLS port $n_port is listening"
            else
                echo -e "    ${RED}✗${NC} AnyTLS port $n_port is not listening"
                all_ok=false
            fi
        fi

        if [[ "$n_protocol_type" == "hysteria2" ]] && [[ -n "$n_port" ]]; then
            if ss -lnu 2>/dev/null | grep -qE ":${n_port}([[:space:]]|$)"; then
                echo -e "    ${GREEN}✓${NC} Hysteria2 UDP port $n_port is listening"
            else
                echo -e "    ${RED}✗${NC} Hysteria2 UDP port $n_port is not listening"
                all_ok=false
            fi
            continue
        fi

        # 测试 SNI 连接
        if [[ -n "$n_sni" ]] && timeout 3 openssl s_client -connect "${n_sni}:443" -servername "$n_sni" </dev/null &>/dev/null; then
            echo -e "    ${GREEN}✓${NC} SNI ($n_sni) is reachable"
        elif [[ -n "$n_sni" ]]; then
            echo -e "    ${YELLOW}!${NC} SNI ($n_sni) connection timeout"
        fi
    done

    echo ""
    if $all_ok; then
        echo -e "  ${GREEN}All checks passed! Nodes are healthy.${NC}"
    else
        echo -e "  ${RED}Some checks failed. Please review above.${NC}"
    fi
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
}

# ============== IP 变更检测与更新 ==============

cmd_update_ip() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}                     $(msg update_ip)${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""

    # 检查是否有节点
    local node_count
    node_count=$(count_nodes)
    if [[ $node_count -eq 0 ]]; then
        log_error "$(msg update_ip_no_nodes)"
        return 1
    fi

    # 检测当前公网 IP
    log_info "$(msg update_ip_detecting)"
    local current_ipv4 current_ipv6
    current_ipv4=$(get_ipv4)
    current_ipv6=$(get_ipv6)

    if [[ -z "$current_ipv4" ]] && [[ -z "$current_ipv6" ]]; then
        log_error "$(msg update_ip_detect_fail)"
        return 1
    fi

    [[ -n "$current_ipv4" ]] && echo -e "  ${BLUE}$(msg update_ip_current) IPv4:${NC} $current_ipv4"
    [[ -n "$current_ipv6" ]] && echo -e "  ${BLUE}$(msg update_ip_current) IPv6:${NC} $current_ipv6"
    echo ""

    # 逐节点对比并更新各自存储的 IP。
    #
    # 旧实现以"第一个节点"的存储 IP 作为全局基准来判断是否变更：当基准节点
    # 恰好已经是新 IP（例如在换 IP 之后才新增的节点排在最前）时，会被误判为
    # "无变化"而提前返回，导致换 IP 之前就存在的旧节点不会被同步，其分享链接
    # 仍显示旧 IP。这里改为对每个节点用其自身存储的 IP 单独比较与更新。
    log_info "$(msg update_ip_updating)"
    local updated_count=0

    for node_file in "$NODES_DIR"/*.env; do
        [[ -f "$node_file" ]] || continue
        local n_name n_v4 n_v6 n_changed detail
        n_name=$(basename "$node_file" .env)
        n_v4=$(safe_read_config_value "$node_file" "SERVER_IPV4")
        # 向后兼容：没有 SERVER_IPV4 时回退到 SERVER_IP
        [[ -z "$n_v4" ]] && n_v4=$(safe_read_config_value "$node_file" "SERVER_IP")
        n_v6=$(safe_read_config_value "$node_file" "SERVER_IPV6")
        n_changed=false
        detail=""

        # IPv4：仅当检测到当前 IPv4 且与该节点存储值不同时才更新
        if [[ -n "$current_ipv4" ]] && [[ "$current_ipv4" != "$n_v4" ]]; then
            if grep -q "^SERVER_IP=" "$node_file"; then
                sed -i "s|^SERVER_IP=.*|SERVER_IP=${current_ipv4}|" "$node_file"
            else
                echo "SERVER_IP=${current_ipv4}" >> "$node_file"
            fi
            if grep -q "^SERVER_IPV4=" "$node_file"; then
                sed -i "s|^SERVER_IPV4=.*|SERVER_IPV4=${current_ipv4}|" "$node_file"
            else
                echo "SERVER_IPV4=${current_ipv4}" >> "$node_file"
            fi
            detail+="\n    IPv4: ${RED}${n_v4:-N/A}${NC} → ${GREEN}${current_ipv4}${NC}"
            n_changed=true
        fi

        # IPv6：同理
        if [[ -n "$current_ipv6" ]] && [[ "$current_ipv6" != "$n_v6" ]]; then
            if grep -q "^SERVER_IPV6=" "$node_file"; then
                sed -i "s|^SERVER_IPV6=.*|SERVER_IPV6=${current_ipv6}|" "$node_file"
            else
                echo "SERVER_IPV6=${current_ipv6}" >> "$node_file"
            fi
            detail+="\n    IPv6: ${RED}${n_v6:-N/A}${NC} → ${GREEN}${current_ipv6}${NC}"
            n_changed=true
        fi

        if $n_changed; then
            echo -e "  ${GREEN}✓${NC} $(msg update_ip_node_updated): ${n_name}${detail}"
            updated_count=$((updated_count + 1))
        fi
    done

    # 所有节点的 IP 均已是最新，无需任何更新
    if [[ $updated_count -eq 0 ]]; then
        echo ""
        echo -e "  ${GREEN}✓${NC} $(msg update_ip_no_change)"
        echo ""
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        return 0
    fi

    echo ""
    log_info "$(msg update_ip_done) ($updated_count)"

    # 更新全局变量。IPv6 Only 主机上 current_ipv4 为空，此时保留原值；
    # SERVER_IP 没有独立的探测来源，必须按 `set -u` 安全的方式展开。
    [[ -n "$current_ipv4" ]] && SERVER_IPV4="$current_ipv4"
    [[ -n "$current_ipv6" ]] && SERVER_IPV6="$current_ipv6"
    SERVER_IP="${current_ipv4:-${SERVER_IP:-}}"

    # 重新同步所有实际使用的代理内核。
    log_info "$(msg update_ip_regen)"
    if cmd_regenerate; then
        echo ""
        echo -e "  ${GREEN}✓${NC} $(msg update_ip_complete)"
    else
        log_error "Failed to synchronize proxy config after IP update"
        return 1
    fi

    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
}

# ============== WARP 管理 ==============

cmd_warp() {
    while true; do
        clear
        local warp_status
        if check_warp_running; then
            warp_status="${GREEN}$(msg warp_running)${NC}"
        else
            warp_status="${RED}$(msg warp_stopped)${NC}"
        fi

        local netflix_status ai_status
        if [[ -f "/root/.warp_netflix" ]]; then
            netflix_status="${GREEN}ON${NC}"
        else
            netflix_status="${YELLOW}OFF${NC}"
        fi
        if [[ -f "/root/.warp_ai" ]]; then
            ai_status="${GREEN}ON${NC}"
        else
            ai_status="${YELLOW}OFF${NC}"
        fi

        echo ""
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}                     $(msg menu_warp)${NC}"
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo ""
        echo -e "  $(msg warp_status): $warp_status"
        echo ""
        echo -e "  ${GREEN}1.${NC} $(msg warp_install)"
        echo -e "  ${GREEN}2.${NC} $(msg warp_uninstall)"
        echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
        echo -e "  ${GREEN}3.${NC} $(msg warp_netflix) [$netflix_status]"
        echo -e "  ${GREEN}4.${NC} $(msg warp_ai) [$ai_status]"
        echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
        echo -e "  ${RED}0.${NC} Back / 返回"
        echo ""
        echo -n "  $(msg menu_choice) [0-4]: "
        read -r choice

        case "$choice" in
            1) warp_install ;;
            2) warp_uninstall ;;
            3) warp_toggle_netflix ;;
            4) warp_toggle_ai ;;
            0) return ;;
            *) ;;
        esac
    done
}

warp_install() {
    echo ""
    log_info "Installing WARP (Socks5 mode)..."
    # Security: Download to temp file with secure options
    local tmp_warp="/tmp/warp-menu-$$.sh"
    if secure_curl "https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh" -o "$tmp_warp" 2>/dev/null; then
        bash "$tmp_warp" c
        rm -f "$tmp_warp"
        if check_warp_running; then
            log_info "WARP installed successfully"
            write_config
            service_restart xray
        fi
    else
        log_error "Failed to download WARP installer"
        rm -f "$tmp_warp"
    fi
    echo ""
    read -rp "$(msg menu_press_enter)"
}

warp_uninstall() {
    echo ""
    log_info "Uninstalling WARP..."
    if command -v warp &>/dev/null; then
        warp u
    elif [[ -f menu.sh ]]; then
        bash menu.sh u
    else
        # Security: Download to temp file with secure options
        local tmp_warp="/tmp/warp-menu-$$.sh"
        if secure_curl "https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh" -o "$tmp_warp" 2>/dev/null; then
            bash "$tmp_warp" u
            rm -f "$tmp_warp"
        fi
    fi
    rm -f /root/.warp_netflix /root/.warp_ai
    write_config
    service_restart xray
    log_info "WARP uninstalled"
    echo ""
    read -rp "$(msg menu_press_enter)"
}

warp_toggle_netflix() {
    if ! check_warp_running; then
        log_warn "WARP is not running. Please install first."
        sleep 2
        return
    fi
    if [[ -f "/root/.warp_netflix" ]]; then
        rm -f /root/.warp_netflix
        log_info "Netflix routing disabled"
    else
        # 分流规则使用 geosite:netflix，需要 GeoSite 数据库
        ensure_geodata
        touch /root/.warp_netflix
        log_info "Netflix routing enabled"
    fi
    write_config
    service_restart xray
    echo ""
    read -rp "$(msg menu_press_enter)"
}

warp_toggle_ai() {
    if ! check_warp_running; then
        log_warn "WARP is not running. Please install first."
        sleep 2
        return
    fi
    if [[ -f "/root/.warp_ai" ]]; then
        rm -f /root/.warp_ai
        log_info "AI services routing disabled"
    else
        # 分流规则使用 geosite:openai/anthropic，需要 GeoSite 数据库
        ensure_geodata
        touch /root/.warp_ai
        log_info "AI services routing enabled"
    fi
    write_config
    service_restart xray
    echo ""
    read -rp "$(msg menu_press_enter)"
}

# ============== BBR 管理 ==============

cmd_bbr() {
    while true; do
        clear
        local bbr_status qdisc_status
        local cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
        local qd=$(sysctl -n net.core.default_qdisc 2>/dev/null)

        if [[ "$cc" == "bbr" ]]; then
            bbr_status="${GREEN}$(msg bbr_enabled)${NC} (BBR)"
        else
            bbr_status="${YELLOW}$(msg bbr_disabled)${NC} ($cc)"
        fi
        qdisc_status="$qd"

        echo ""
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}                     $(msg menu_bbr)${NC}"
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo ""
        echo -e "  Congestion Control: $bbr_status"
        echo -e "  Queue Discipline: ${YELLOW}$qdisc_status${NC}"
        echo ""
        echo -e "  ${GREEN}1.${NC} Enable BBR + FQ"
        echo -e "  ${GREEN}2.${NC} Disable BBR (use CUBIC)"
        echo -e "  ${GREEN}3.${NC} Apply TCP optimization"
        echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
        echo -e "  ${RED}0.${NC} Back / 返回"
        echo ""
        echo -n "  $(msg menu_choice) [0-3]: "
        read -r choice

        case "$choice" in
            1) bbr_enable ;;
            2) bbr_disable ;;
            3) bbr_optimize ;;
            0) return ;;
            *) ;;
        esac
    done
}

bbr_enable() {
    echo ""
    log_info "Enabling BBR..."
    cat > /etc/sysctl.d/99-bbr.conf <<EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    sysctl --system >/dev/null 2>&1
    log_info "BBR enabled"
    echo ""
    read -rp "$(msg menu_press_enter)"
}

bbr_disable() {
    echo ""
    log_info "Disabling BBR..."
    cat > /etc/sysctl.d/99-bbr.conf <<EOF
net.core.default_qdisc = fq_codel
net.ipv4.tcp_congestion_control = cubic
EOF
    sysctl --system >/dev/null 2>&1
    log_info "BBR disabled, using CUBIC"
    echo ""
    read -rp "$(msg menu_press_enter)"
}

bbr_optimize() {
    echo ""
    log_info "Applying TCP optimization..."
    local cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    local qd=$(sysctl -n net.core.default_qdisc 2>/dev/null)

    cat > /etc/sysctl.d/99-bbr.conf <<EOF
net.core.default_qdisc = $qd
net.ipv4.tcp_congestion_control = $cc
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_low_latency = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
EOF
    sysctl --system >/dev/null 2>&1
    log_info "TCP optimization applied"
    echo ""
    read -rp "$(msg menu_press_enter)"
}

# ============== Swap 管理 ==============

cmd_swap() {
    while true; do
        clear
        local swap_total swap_status swappiness
        swap_total=$(free -m | grep Swap | awk '{print $2}')
        swappiness=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo "60")

        if [[ "$swap_total" -eq 0 ]]; then
            swap_status="${RED}Not enabled${NC}"
        else
            swap_status="${GREEN}${swap_total}MB${NC}"
        fi

        echo ""
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}                     $(msg menu_swap)${NC}"
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo ""
        echo -e "  $(msg swap_size): $swap_status"
        echo -e "  Swappiness: ${YELLOW}$swappiness${NC}"
        echo ""
        echo -e "  ${GREEN}1.${NC} Create/Resize Swap"
        echo -e "  ${GREEN}2.${NC} Remove Swap"
        echo -e "  ${GREEN}3.${NC} Change Swappiness"
        echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
        echo -e "  ${RED}0.${NC} Back / 返回"
        echo ""
        echo -n "  $(msg menu_choice) [0-3]: "
        read -r choice

        case "$choice" in
            1) swap_create ;;
            2) swap_remove ;;
            3) swap_swappiness ;;
            0) return ;;
            *) ;;
        esac
    done
}

swap_create() {
    echo ""
    echo -n "  Enter swap size in MB [1024]: "
    read -r size
    size=${size:-1024}

    log_info "Creating ${size}MB swap..."
    swapoff /swapfile 2>/dev/null || true
    rm -f /swapfile

    if ! fallocate -l ${size}M /swapfile 2>/dev/null; then
        dd if=/dev/zero of=/swapfile bs=1M count=$size status=progress
    fi
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile

    if ! grep -q "/swapfile" /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi

    log_info "Swap created: ${size}MB"
    echo ""
    read -rp "$(msg menu_press_enter)"
}

swap_remove() {
    echo ""
    log_info "Removing swap..."
    swapoff /swapfile 2>/dev/null || true
    rm -f /swapfile
    sed -i '/\/swapfile/d' /etc/fstab 2>/dev/null || true
    log_info "Swap removed"
    echo ""
    read -rp "$(msg menu_press_enter)"
}

swap_swappiness() {
    echo ""
    local current=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo "60")
    echo -e "  Current swappiness: ${YELLOW}$current${NC}"
    echo -n "  Enter new value [0-100]: "
    read -r val
    if [[ "$val" =~ ^[0-9]+$ ]] && [[ "$val" -ge 0 ]] && [[ "$val" -le 100 ]]; then
        sysctl -w vm.swappiness=$val >/dev/null
        sed -i '/vm.swappiness/d' /etc/sysctl.conf 2>/dev/null || true
        echo "vm.swappiness = $val" >> /etc/sysctl.conf
        log_info "Swappiness set to $val"
    else
        log_error "Invalid value"
    fi
    echo ""
    read -rp "$(msg menu_press_enter)"
}

# ============== Fail2ban 管理 ==============

cmd_fail2ban() {
    # 检查是否是 Alpine (不支持 fail2ban)
    if [[ "$PKG_MANAGER" == "apk" ]]; then
        log_warn "Fail2ban is not available on Alpine Linux"
        sleep 2
        return
    fi

    while true; do
        clear
        local f2b_status banned_count

        if systemctl is-active fail2ban &>/dev/null; then
            f2b_status="${GREEN}Running${NC}"
            banned_count=$(fail2ban-client status sshd 2>/dev/null | grep "Currently banned" | grep -o "[0-9]*" || echo "0")
        else
            f2b_status="${RED}Stopped${NC}"
            banned_count="N/A"
        fi

        echo ""
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}                     $(msg menu_fail2ban)${NC}"
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo ""
        echo -e "  $(msg fail2ban_status): $f2b_status"
        echo -e "  Banned IPs: ${RED}$banned_count${NC}"
        echo ""
        echo -e "  ${GREEN}1.${NC} Install & Enable Fail2ban"
        echo -e "  ${GREEN}2.${NC} Stop Fail2ban"
        echo -e "  ${GREEN}3.${NC} View Banned IPs"
        echo -e "  ${GREEN}4.${NC} Unban IP"
        echo -e "  ${GREEN}5.${NC} View Logs"
        echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
        echo -e "  ${RED}0.${NC} Back / 返回"
        echo ""
        echo -n "  $(msg menu_choice) [0-5]: "
        read -r choice

        case "$choice" in
            1) fail2ban_install ;;
            2) fail2ban_stop ;;
            3) fail2ban_list ;;
            4) fail2ban_unban ;;
            5) fail2ban_logs ;;
            0) return ;;
            *) ;;
        esac
    done
}

fail2ban_install() {
    echo ""
    log_info "Installing Fail2ban..."

    if ! $PKG_CHECK fail2ban >/dev/null 2>&1; then
        $PKG_UPDATE >/dev/null 2>&1 || true
        $PKG_INSTALL fail2ban >/dev/null 2>&1
    fi

    # 获取当前 SSH 端口
    local ssh_port
    ssh_port=$(grep "^Port" /etc/ssh/sshd_config 2>/dev/null | head -1 | awk '{print $2}')
    ssh_port=${ssh_port:-22}

    # 配置 jail
    cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1
bantime = 1d
bantime.increment = true
bantime.factor = 1
bantime.maxtime = 30d
findtime = 7d
maxretry = 3
backend = auto

[sshd]
enabled = true
port = $ssh_port,22
mode = aggressive
EOF

    systemctl enable fail2ban >/dev/null 2>&1
    systemctl restart fail2ban >/dev/null 2>&1
    log_info "Fail2ban installed and configured"
    echo ""
    read -rp "$(msg menu_press_enter)"
}

fail2ban_stop() {
    echo ""
    systemctl stop fail2ban 2>/dev/null
    systemctl disable fail2ban 2>/dev/null
    log_info "Fail2ban stopped"
    echo ""
    read -rp "$(msg menu_press_enter)"
}

fail2ban_list() {
    echo ""
    echo -e "${CYAN}Banned IPs:${NC}"
    fail2ban-client status sshd 2>/dev/null | grep "Banned IP" || echo "  None"
    echo ""
    read -rp "$(msg menu_press_enter)"
}

fail2ban_unban() {
    echo ""
    echo -n "  Enter IP to unban: "
    read -r ip
    if [[ -n "$ip" ]]; then
        fail2ban-client set sshd unbanip "$ip" 2>/dev/null && log_info "Unbanned: $ip" || log_error "Failed to unban"
    fi
    echo ""
    read -rp "$(msg menu_press_enter)"
}

fail2ban_logs() {
    echo ""
    echo -e "${CYAN}Recent Fail2ban logs:${NC}"
    if [[ -f /var/log/fail2ban.log ]]; then
        grep -E "(Ban|Unban)" /var/log/fail2ban.log 2>/dev/null | tail -20
    else
        echo "  No logs available"
    fi
    echo ""
    read -rp "$(msg menu_press_enter)"
}

# ============== 端口管理 ==============

# 验证端口号
validate_port() {
    local port="$1"
    if [[ ! "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 ]] || [[ "$port" -gt 65535 ]]; then
        echo -e "${RED}[ERROR]${NC} 端口必须是 1-65535 之间的数字！"
        return 1
    fi
    return 0
}

# 检查端口运行状态
check_port_status() {
    local port="$1"
    if ss -tlnp 2>/dev/null | grep -q ":${port} " || \
       ss -ulnp 2>/dev/null | grep -q ":${port} "; then
        echo -e "${GREEN}运行中${NC}"
    else
        echo -e "${RED}未运行${NC}"
    fi
}

# 开放端口 (跨系统支持)
# Usage: open_firewall_port PORT [tcp|udp|both]
# 未安装或未启用任何防火墙时视为无需处理；任一活跃后端配置失败则返回非零。
open_firewall_port() {
    local port="${1:-}"
    local transport="${2:-both}"
    local failed=0 netfilter_changed=0 firewalld_changed=0
    local protocol backend rule_present ufw_status
    local -a protocols=()

    validate_port "$port" || return 1
    case "$transport" in
        tcp|udp) protocols=("$transport") ;;
        both) protocols=(tcp udp) ;;
        *)
            printf '%s\n' "Invalid firewall transport: $transport (expected tcp, udp, or both)" >&2
            return 1
            ;;
    esac

    # iptables/ip6tables 没有统一的 enabled 状态；命令存在即尝试管理。
    # -C 区分已有规则，避免重复 -I 导致规则无限堆叠。
    for backend in iptables ip6tables; do
        command -v "$backend" >/dev/null 2>&1 || continue
        if [[ "$backend" == "ip6tables" && ! -f /proc/net/if_inet6 ]]; then
            continue
        fi

        for protocol in "${protocols[@]}"; do
            rule_present=0
            "$backend" -C INPUT -p "$protocol" --dport "$port" -j ACCEPT \
                >/dev/null 2>&1 && rule_present=1
            if ((rule_present == 0)); then
                if "$backend" -I INPUT -p "$protocol" --dport "$port" -j ACCEPT \
                    >/dev/null 2>&1; then
                    netfilter_changed=1
                else
                    failed=1
                fi
            fi
        done
    done

    # 仅在本次新增了 netfilter 规则时持久化；重复调用不反复 save。
    if ((netfilter_changed == 1)) && command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >/dev/null 2>&1 || failed=1
    fi

    # firewall-cmd --state 成功表示 firewalld 当前活跃。
    if command -v firewall-cmd >/dev/null 2>&1 \
        && firewall-cmd --state >/dev/null 2>&1; then
        for protocol in "${protocols[@]}"; do
            if ! firewall-cmd --permanent --query-port="${port}/${protocol}" \
                >/dev/null 2>&1; then
                if firewall-cmd --permanent --add-port="${port}/${protocol}" \
                    >/dev/null 2>&1; then
                    firewalld_changed=1
                else
                    failed=1
                fi
            fi
        done
        if ((firewalld_changed == 1)); then
            firewall-cmd --reload >/dev/null 2>&1 || failed=1
        fi
    fi

    # ufw 自身会对已有 allow 规则去重；显式携带传输层协议。
    if command -v ufw >/dev/null 2>&1; then
        if ufw_status=$(ufw status 2>/dev/null); then
            if printf '%s\n' "$ufw_status" | grep -q '^Status:[[:space:]]*active'; then
                for protocol in "${protocols[@]}"; do
                    ufw allow "${port}/${protocol}" >/dev/null 2>&1 || failed=1
                done
            fi
        else
            # 安装了 ufw 但无法读取状态，不能安全当作“未启用”。
            failed=1
        fi
    fi

    ((failed == 0))
}

# 获取当前端口配置
get_current_ports() {
    local ssh_config="/etc/ssh/sshd_config"

    # SSH 端口
    CURRENT_SSH=$(grep "^Port" "$ssh_config" 2>/dev/null | head -n 1 | awk '{print $2}')
    [[ -z "$CURRENT_SSH" ]] && CURRENT_SSH=22

    # Xray 端口
    if [[ -f "$XRAY_CONF" ]] && command -v jq &>/dev/null; then
        CURRENT_VISION=$(jq -r '.inbounds[] | select(.tag=="vision_node" or .tag=="vless-reality-vision" or .settings.clients) | .port' "$XRAY_CONF" 2>/dev/null | head -1)
        CURRENT_XHTTP=$(jq -r '.inbounds[] | select(.tag=="xhttp_node") | .port' "$XRAY_CONF" 2>/dev/null | head -1)
    else
        CURRENT_VISION="N/A"
        CURRENT_XHTTP="N/A"
    fi

    [[ -z "$CURRENT_VISION" || "$CURRENT_VISION" == "null" ]] && CURRENT_VISION="N/A"
    [[ -z "$CURRENT_XHTTP" || "$CURRENT_XHTTP" == "null" ]] && CURRENT_XHTTP="N/A"
}

SSH_ROLLBACK_PID=""
SSH_ROLLBACK_ID=""
SSH_ROLLBACK_CONFIG=""
SSH_ROLLBACK_BACKUP=""
SSH_ROLLBACK_BACKUP_ID=""
SSH_ROLLBACK_ORIGINAL_PORT=""
SSH_ROLLBACK_MARKER=""
SSH_ROLLBACK_MARKER_TOKEN=""
SSH_ROLLBACK_RESULT_FILE=""
SSH_ROLLBACK_STATE_DIR=""
SSH_ROLLBACK_STATE_ID=""
SSH_ROLLBACK_STATE_TOKEN=""
SSH_ROLLBACK_TOKEN_FILE=""
SSH_ROLLBACK_TOKEN_ID=""
SSH_ROLLBACK_SIGNAL_PENDING=""
SSH_ROLLBACK_CLAIM_RESULT=""

ssh_rollback_sync_path() {
    local path="$1"
    command -v sync >/dev/null 2>&1 || return 1
    if sync --help 2>&1 | grep -q -- '--file-system'; then
        command sync -f "$path"
    else
        command sync
    fi
}

ssh_rollback_file_identity() {
    local path="$1"
    [[ -f "$path" && ! -L "$path" ]] || return 1
    stat -c '%d:%i' "$path" 2>/dev/null
}

ssh_rollback_tracked_file() {
    local path="$1" expected_id="$2" owner identity
    [[ -n "$path" && -n "$expected_id" && -f "$path" && ! -L "$path" ]] || return 1
    owner=$(stat -c '%u' "$path" 2>/dev/null) || return 1
    identity=$(ssh_rollback_file_identity "$path") || return 1
    [[ "$owner" == "$EUID" && "$identity" == "$expected_id" ]]
}

ssh_rollback_owned_file() {
    local path="$1" expected_id="$2" mode
    ssh_rollback_tracked_file "$path" "$expected_id" || return 1
    mode=$(stat -c '%a' "$path" 2>/dev/null) || return 1
    [[ "$mode" =~ ^[0-7]+$ ]] || return 1
    (( (8#$mode & 077) == 0 ))
}

ssh_rollback_backup_is_valid() {
    local backup_file="$1"
    if [[ -n "$SSH_ROLLBACK_STATE_DIR" ]]; then
        ssh_rollback_state_valid || return 1
        [[ "$backup_file" == "$SSH_ROLLBACK_STATE_DIR/sshd_config.backup" ]] || return 1
        ssh_rollback_owned_file "$backup_file" "$SSH_ROLLBACK_BACKUP_ID"
    else
        # Compatibility for the existing timer helper contract. Production
        # change_ssh_port always uses the stricter private-state branch above.
        ssh_rollback_tracked_file "$backup_file" "$SSH_ROLLBACK_BACKUP_ID"
    fi
}

ssh_rollback_state_valid() {
    local owner mode identity token_value
    [[ -n "$SSH_ROLLBACK_STATE_DIR" && -n "$SSH_ROLLBACK_STATE_ID" \
        && -n "$SSH_ROLLBACK_STATE_TOKEN" && -n "$SSH_ROLLBACK_TOKEN_FILE" \
        && -n "$SSH_ROLLBACK_TOKEN_ID" ]] || return 1
    [[ -d "$SSH_ROLLBACK_STATE_DIR" && ! -L "$SSH_ROLLBACK_STATE_DIR" ]] || return 1
    owner=$(stat -c '%u' "$SSH_ROLLBACK_STATE_DIR" 2>/dev/null) || return 1
    mode=$(stat -c '%a' "$SSH_ROLLBACK_STATE_DIR" 2>/dev/null) || return 1
    identity=$(stat -c '%d:%i' "$SSH_ROLLBACK_STATE_DIR" 2>/dev/null) || return 1
    [[ "$owner" == "$EUID" && "$mode" =~ ^[0-7]+$ \
        && "$identity" == "$SSH_ROLLBACK_STATE_ID" ]] || return 1
    (( (8#$mode & 077) == 0 )) || return 1
    [[ "$SSH_ROLLBACK_TOKEN_FILE" == "$SSH_ROLLBACK_STATE_DIR/token" ]] || return 1
    ssh_rollback_owned_file "$SSH_ROLLBACK_TOKEN_FILE" "$SSH_ROLLBACK_TOKEN_ID" || return 1
    IFS= read -r token_value < "$SSH_ROLLBACK_TOKEN_FILE" || return 1
    [[ "$token_value" == "$SSH_ROLLBACK_STATE_TOKEN" ]] || return 1
    ssh_rollback_phase_current >/dev/null
}

ssh_rollback_phase_is_valid() {
    local phase="$1" phase_file phase_id phase_value
    [[ "$phase" == "pending" || "$phase" == "confirmed" || "$phase" == "rolling-back" ]] || return 1
    phase_file="$SSH_ROLLBACK_STATE_DIR/phase.$phase"
    [[ -f "$phase_file" && ! -L "$phase_file" ]] || return 1
    phase_id=$(ssh_rollback_file_identity "$phase_file") || return 1
    ssh_rollback_owned_file "$phase_file" "$phase_id" || return 1
    IFS= read -r phase_value < "$phase_file" || return 1
    [[ "$phase_value" == "$SSH_ROLLBACK_STATE_TOKEN" ]]
}

ssh_rollback_phase_current() {
    local phase found=""
    for phase in pending confirmed rolling-back; do
        if [[ -e "$SSH_ROLLBACK_STATE_DIR/phase.$phase" || -L "$SSH_ROLLBACK_STATE_DIR/phase.$phase" ]]; then
            [[ -z "$found" ]] || return 1
            ssh_rollback_phase_is_valid "$phase" || return 1
            found="$phase"
        fi
    done
    [[ -n "$found" ]] || return 1
    printf '%s\n' "$found"
}

ssh_rollback_claim_phase() {
    local target="$1" current source_file target_file
    SSH_ROLLBACK_CLAIM_RESULT=""
    [[ "$target" == "confirmed" || "$target" == "rolling-back" ]] || return 1
    ssh_rollback_state_valid || return 1
    current=$(ssh_rollback_phase_current) || return 1
    [[ "$current" == "pending" ]] || return 1
    source_file="$SSH_ROLLBACK_STATE_DIR/phase.pending"
    target_file="$SSH_ROLLBACK_STATE_DIR/phase.$target"
    [[ ! -e "$target_file" && ! -L "$target_file" ]] || return 1
    mv -- "$source_file" "$target_file" || return 1
    SSH_ROLLBACK_CLAIM_RESULT="$target"
    ssh_rollback_phase_is_valid "$target" || return 1
    ssh_rollback_sync_path "$SSH_ROLLBACK_STATE_DIR" || return 2
}

ssh_rollback_prepare_state() {
    local state_record state_dir state_id state_token token_file token_id
    local saved_int saved_term saved_hup pending_signal

    [[ -z "$SSH_ROLLBACK_STATE_DIR" && -z "$SSH_ROLLBACK_STATE_ID" \
        && -z "$SSH_ROLLBACK_STATE_TOKEN" && -z "$SSH_ROLLBACK_TOKEN_FILE" \
        && -z "$SSH_ROLLBACK_TOKEN_ID" ]] || return 1
    declare -F lock_prepare_parent >/dev/null 2>&1 || return 1
    lock_prepare_parent || return 1

    SSH_ROLLBACK_SIGNAL_PENDING=""
    saved_int=$(trap -p INT || true)
    saved_term=$(trap -p TERM || true)
    saved_hup=$(trap -p HUP || true)
    trap 'SSH_ROLLBACK_SIGNAL_PENDING=INT' INT
    trap 'SSH_ROLLBACK_SIGNAL_PENDING=TERM' TERM
    trap 'SSH_ROLLBACK_SIGNAL_PENDING=HUP' HUP

    state_record=$(
        local candidate_dir="" candidate_id="" candidate_token candidate_token_id="" token_tmp phase_tmp complete=0
        trap '' INT TERM HUP
        umask 077
        cleanup_candidate_state() {
            ((complete == 0)) || return 0
            [[ -n "$candidate_dir" && -n "$candidate_id" \
                && -d "$candidate_dir" && ! -L "$candidate_dir" \
                && "$(stat -c '%d:%i' "$candidate_dir" 2>/dev/null)" == "$candidate_id" ]] || return 0
            [[ -n "$token_tmp" && -f "$token_tmp" && ! -L "$token_tmp" ]] && rm -f -- "$token_tmp"
            [[ -n "$phase_tmp" && -f "$phase_tmp" && ! -L "$phase_tmp" ]] && rm -f -- "$phase_tmp"
            [[ -f "$candidate_dir/phase.pending" && ! -L "$candidate_dir/phase.pending" ]] && rm -f -- "$candidate_dir/phase.pending"
            [[ -f "$candidate_dir/token" && ! -L "$candidate_dir/token" ]] && rm -f -- "$candidate_dir/token"
            rmdir "$candidate_dir" 2>/dev/null || true
        }
        trap cleanup_candidate_state EXIT
        candidate_token="${EUID}-$$-${RANDOM}-${RANDOM}"
        candidate_dir=$(mktemp -d "$LOCK_PARENT/ssh-rollback.XXXXXXXX") || exit 1
        candidate_id=$(stat -c '%d:%i' "$candidate_dir" 2>/dev/null) || {
            rmdir "$candidate_dir" 2>/dev/null || true
            exit 1
        }
        token_tmp="$candidate_dir/.token-${candidate_token}"
        if ! (set -o noclobber; printf '%s\n' "$candidate_token" > "$token_tmp") 2>/dev/null; then
            rmdir "$candidate_dir" 2>/dev/null || true
            exit 1
        fi
        chmod 600 "$token_tmp" 2>/dev/null || exit 1
        mv -- "$token_tmp" "$candidate_dir/token" || exit 1
        candidate_token_id=$(ssh_rollback_file_identity "$candidate_dir/token") || exit 1
        phase_tmp="$candidate_dir/.phase-${candidate_token}"
        if ! (set -o noclobber; printf '%s\n' "$candidate_token" > "$phase_tmp") 2>/dev/null; then
            exit 1
        fi
        chmod 600 "$phase_tmp" 2>/dev/null || exit 1
        mv -- "$phase_tmp" "$candidate_dir/phase.pending" || exit 1
        complete=1
        printf '%s\t%s\t%s\t%s\n' "$candidate_dir" "$candidate_id" "$candidate_token" \
            "$candidate_token_id"
    )
    local create_status=$?

    if [[ -n "$saved_int" ]]; then eval "$saved_int"; else trap - INT; fi
    if [[ -n "$saved_term" ]]; then eval "$saved_term"; else trap - TERM; fi
    if [[ -n "$saved_hup" ]]; then eval "$saved_hup"; else trap - HUP; fi
    pending_signal="$SSH_ROLLBACK_SIGNAL_PENDING"
    SSH_ROLLBACK_SIGNAL_PENDING=""

    if ((create_status == 0)); then
        IFS=$'\t' read -r state_dir state_id state_token token_id <<< "$state_record"
        token_file="$state_dir/token"
        SSH_ROLLBACK_STATE_DIR="$state_dir"
        SSH_ROLLBACK_STATE_ID="$state_id"
        SSH_ROLLBACK_STATE_TOKEN="$state_token"
        SSH_ROLLBACK_TOKEN_FILE="$token_file"
        SSH_ROLLBACK_TOKEN_ID="$token_id"
        ssh_rollback_state_valid || create_status=1
    fi

    if [[ -n "$pending_signal" ]]; then
        kill -s "$pending_signal" "$$" 2>/dev/null || return 1
    fi
    ((create_status == 0))
}

ssh_rollback_create_backup() {
    local ssh_config="$1" tmp_file
    ssh_rollback_state_valid || return 1
    SSH_ROLLBACK_BACKUP="$SSH_ROLLBACK_STATE_DIR/sshd_config.backup"
    tmp_file="$SSH_ROLLBACK_STATE_DIR/.backup-${SSH_ROLLBACK_STATE_TOKEN}"
    [[ ! -e "$SSH_ROLLBACK_BACKUP" && ! -L "$SSH_ROLLBACK_BACKUP" ]] || return 1
    if ! (umask 077; set -o noclobber; command cat -- "$ssh_config" > "$tmp_file") 2>/dev/null; then
        return 1
    fi
    chmod 600 "$tmp_file" || return 1
    mv -- "$tmp_file" "$SSH_ROLLBACK_BACKUP" || return 1
    SSH_ROLLBACK_BACKUP_ID=$(ssh_rollback_file_identity "$SSH_ROLLBACK_BACKUP") || return 1
    ssh_rollback_owned_file "$SSH_ROLLBACK_BACKUP" "$SSH_ROLLBACK_BACKUP_ID" || return 1
    ssh_rollback_sync_path "$SSH_ROLLBACK_BACKUP" || return 1
    ssh_rollback_sync_path "$SSH_ROLLBACK_STATE_DIR"
}

ssh_rollback_marker_is_valid() {
    local marker="$1" marker_token="$2" marker_id marker_value
    [[ -n "$marker" && -n "$marker_token" && -f "$marker" && ! -L "$marker" ]] || return 1
    marker_id=$(ssh_rollback_file_identity "$marker") || return 1
    ssh_rollback_owned_file "$marker" "$marker_id" || return 1
    IFS= read -r marker_value < "$marker" || return 1
    [[ "$marker_value" == "$marker_token" ]]
}

ssh_rollback_create_marker() {
    local marker="$1" marker_token="$2" tmp_file marker_id
    ssh_rollback_state_valid || return 1
    [[ "$marker" == "$SSH_ROLLBACK_STATE_DIR/confirmed" && ! -e "$marker" && ! -L "$marker" ]] || return 1
    tmp_file="$SSH_ROLLBACK_STATE_DIR/.confirmed-${marker_token}"
    if ! (umask 077; set -o noclobber; printf '%s\n' "$marker_token" > "$tmp_file") 2>/dev/null; then
        return 1
    fi
    chmod 600 "$tmp_file" || return 1
    mv -- "$tmp_file" "$marker" || return 1
    marker_id=$(ssh_rollback_file_identity "$marker") || return 1
    ssh_rollback_owned_file "$marker" "$marker_id" || return 1
    ssh_rollback_marker_is_valid "$marker" "$marker_token"
}

ssh_rollback_result_is_valid() {
    local result_value result_id
    [[ -n "$SSH_ROLLBACK_RESULT_FILE" && -f "$SSH_ROLLBACK_RESULT_FILE" \
        && ! -L "$SSH_ROLLBACK_RESULT_FILE" ]] || return 1
    result_id=$(ssh_rollback_file_identity "$SSH_ROLLBACK_RESULT_FILE") || return 1
    ssh_rollback_owned_file "$SSH_ROLLBACK_RESULT_FILE" "$result_id" || return 1
    IFS= read -r result_value < "$SSH_ROLLBACK_RESULT_FILE" || return 1
    [[ "$result_value" == "${SSH_ROLLBACK_STATE_TOKEN}:rolled-back" ]]
}

ssh_rollback_record_result() {
    local tmp_file result_id
    [[ -n "$SSH_ROLLBACK_STATE_DIR" ]] || return 0
    ssh_rollback_state_valid || return 1
    SSH_ROLLBACK_RESULT_FILE="$SSH_ROLLBACK_STATE_DIR/rolled-back"
    if [[ -e "$SSH_ROLLBACK_RESULT_FILE" || -L "$SSH_ROLLBACK_RESULT_FILE" ]]; then
        ssh_rollback_result_is_valid || return 1
        ssh_rollback_sync_path "$SSH_ROLLBACK_RESULT_FILE" || return 1
        ssh_rollback_sync_path "$SSH_ROLLBACK_STATE_DIR"
        return $?
    fi
    tmp_file="$SSH_ROLLBACK_STATE_DIR/.rolled-back-${SSH_ROLLBACK_STATE_TOKEN}"
    if ! (umask 077; set -o noclobber; \
        printf '%s\n' "${SSH_ROLLBACK_STATE_TOKEN}:rolled-back" > "$tmp_file") 2>/dev/null; then
        return 1
    fi
    chmod 600 "$tmp_file" || return 1
    mv -- "$tmp_file" "$SSH_ROLLBACK_RESULT_FILE" || return 1
    result_id=$(ssh_rollback_file_identity "$SSH_ROLLBACK_RESULT_FILE") || return 1
    ssh_rollback_owned_file "$SSH_ROLLBACK_RESULT_FILE" "$result_id" || return 1
    ssh_rollback_result_is_valid || return 1
    ssh_rollback_sync_path "$SSH_ROLLBACK_RESULT_FILE" || return 1
    ssh_rollback_sync_path "$SSH_ROLLBACK_STATE_DIR"
}

ssh_rollback_config_is_live() {
    [[ "$1" == "/etc/ssh/sshd_config" ]]
}

ssh_rollback_validate_config() {
    local ssh_config="$1" sshd_bin=""
    ssh_rollback_config_is_live "$ssh_config" || return 0
    if command -v sshd >/dev/null 2>&1; then
        sshd_bin=$(command -v sshd)
    elif [[ -x /usr/sbin/sshd ]]; then
        sshd_bin=/usr/sbin/sshd
    else
        echo -e "${RED}[ERROR]${NC} 找不到 sshd，无法验证 SSH 配置。" >&2
        return 1
    fi
    "$sshd_bin" -t -f "$ssh_config"
}

ssh_rollback_restart_service() {
    local ssh_config="$1"
    ssh_rollback_config_is_live "$ssh_config" || return 0
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service sshd restart 2>/dev/null || rc-service ssh restart 2>/dev/null
    else
        systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
    fi
}

ssh_rollback_remove_backup() {
    local backup_file="$1"
    ssh_rollback_backup_is_valid "$backup_file" || return 1
    rm -f -- "$backup_file" || return 1
    ssh_rollback_sync_path "$SSH_ROLLBACK_STATE_DIR"
}

ssh_rollback_remove_state() {
    local marker_id="" result_id="" phase phase_id entry state_parent
    [[ -n "$SSH_ROLLBACK_STATE_DIR" ]] || return 0
    ssh_rollback_state_valid || return 1
    [[ ! -e "$SSH_ROLLBACK_BACKUP" && ! -L "$SSH_ROLLBACK_BACKUP" ]] || return 1
    # Persist any preceding backup deletion before removing the completion
    # evidence that proves rollback finished.
    ssh_rollback_sync_path "$SSH_ROLLBACK_STATE_DIR" || return 1
    for entry in "$SSH_ROLLBACK_STATE_DIR"/* "$SSH_ROLLBACK_STATE_DIR"/.[!.]* \
        "$SSH_ROLLBACK_STATE_DIR"/..?*; do
        [[ -e "$entry" || -L "$entry" ]] || continue
        case "$entry" in
            "$SSH_ROLLBACK_TOKEN_FILE"|"$SSH_ROLLBACK_MARKER"|"$SSH_ROLLBACK_RESULT_FILE"|\
            "$SSH_ROLLBACK_STATE_DIR/phase.pending"|"$SSH_ROLLBACK_STATE_DIR/phase.confirmed"|\
            "$SSH_ROLLBACK_STATE_DIR/phase.rolling-back") ;;
            *) return 1 ;;
        esac
    done
    if [[ -n "$SSH_ROLLBACK_MARKER" && -e "$SSH_ROLLBACK_MARKER" ]]; then
        ssh_rollback_marker_is_valid "$SSH_ROLLBACK_MARKER" "$SSH_ROLLBACK_MARKER_TOKEN" || return 1
        marker_id=$(ssh_rollback_file_identity "$SSH_ROLLBACK_MARKER") || return 1
        ssh_rollback_owned_file "$SSH_ROLLBACK_MARKER" "$marker_id" || return 1
        rm -f -- "$SSH_ROLLBACK_MARKER" || return 1
    fi
    if [[ -n "$SSH_ROLLBACK_RESULT_FILE" && -e "$SSH_ROLLBACK_RESULT_FILE" ]]; then
        ssh_rollback_result_is_valid || return 1
        result_id=$(ssh_rollback_file_identity "$SSH_ROLLBACK_RESULT_FILE") || return 1
        ssh_rollback_owned_file "$SSH_ROLLBACK_RESULT_FILE" "$result_id" || return 1
        rm -f -- "$SSH_ROLLBACK_RESULT_FILE" || return 1
    fi
    phase=$(ssh_rollback_phase_current) || return 1
    phase_id=$(ssh_rollback_file_identity "$SSH_ROLLBACK_STATE_DIR/phase.$phase") || return 1
    ssh_rollback_owned_file "$SSH_ROLLBACK_STATE_DIR/phase.$phase" "$phase_id" || return 1
    rm -f -- "$SSH_ROLLBACK_STATE_DIR/phase.$phase" || return 1
    ssh_rollback_owned_file "$SSH_ROLLBACK_TOKEN_FILE" "$SSH_ROLLBACK_TOKEN_ID" || return 1
    rm -f -- "$SSH_ROLLBACK_TOKEN_FILE" || return 1
    ssh_rollback_sync_path "$SSH_ROLLBACK_STATE_DIR" || return 1
    [[ -d "$SSH_ROLLBACK_STATE_DIR" && ! -L "$SSH_ROLLBACK_STATE_DIR" \
        && "$(stat -c '%d:%i' "$SSH_ROLLBACK_STATE_DIR" 2>/dev/null)" == "$SSH_ROLLBACK_STATE_ID" ]] || return 1
    state_parent=${SSH_ROLLBACK_STATE_DIR%/*}
    rmdir "$SSH_ROLLBACK_STATE_DIR" || return 1
    ssh_rollback_sync_path "$state_parent"
}

ssh_rollback_discard_unstarted_state() {
    local entry entry_id
    [[ -z "$SSH_ROLLBACK_BACKUP_ID" && -z "$SSH_ROLLBACK_PID" ]] || return 1
    ssh_rollback_state_valid || return 1
    for entry in "$SSH_ROLLBACK_STATE_DIR"/* "$SSH_ROLLBACK_STATE_DIR"/.[!.]* \
        "$SSH_ROLLBACK_STATE_DIR"/..?*; do
        [[ -e "$entry" || -L "$entry" ]] || continue
        case "$entry" in
            "$SSH_ROLLBACK_TOKEN_FILE"|"$SSH_ROLLBACK_STATE_DIR/phase.pending") ;;
            "$SSH_ROLLBACK_STATE_DIR/.backup-${SSH_ROLLBACK_STATE_TOKEN}"|\
            "$SSH_ROLLBACK_STATE_DIR/.confirmed-${SSH_ROLLBACK_STATE_TOKEN}"|\
            "$SSH_ROLLBACK_STATE_DIR/.rolled-back-${SSH_ROLLBACK_STATE_TOKEN}")
                entry_id=$(ssh_rollback_file_identity "$entry") || return 1
                ssh_rollback_owned_file "$entry" "$entry_id" || return 1
                rm -f -- "$entry" || return 1
                ;;
            *) return 1 ;;
        esac
    done
    SSH_ROLLBACK_BACKUP=""
    SSH_ROLLBACK_MARKER=""
    SSH_ROLLBACK_RESULT_FILE=""
    ssh_rollback_remove_state
}

# SSH rollback helper: restore original port after atomically claiming rollback.
_ssh_rollback_claimed() {
    local ssh_config="$1"
    local backup_file="$2"
    local original_port="$3"

    [[ "$(ssh_rollback_phase_current 2>/dev/null || true)" == "rolling-back" ]] || return 1
    ssh_rollback_backup_is_valid "$backup_file" || return 1
    command cat -- "$backup_file" > "$ssh_config" || return 1
    ssh_rollback_sync_path "$ssh_config" || return 1
    ssh_rollback_validate_config "$ssh_config" || return 1
    ssh_rollback_restart_service "$ssh_config" || return 1
    ssh_rollback_record_result || return 1
    ssh_rollback_remove_backup "$backup_file" || return 1

    echo -e "\n${YELLOW}[AUTO-ROLLBACK]${NC} SSH 端口已自动恢复为 ${original_port}"
}

_ssh_rollback() {
    local ssh_config="$1" backup_file="$2" original_port="$3" claim_status=0
    ssh_rollback_claim_phase rolling-back || claim_status=$?
    if ((claim_status != 0)); then
        ((claim_status == 2)) && [[ "$SSH_ROLLBACK_CLAIM_RESULT" == "rolling-back" ]] || return 1
    fi
    _ssh_rollback_claimed "$ssh_config" "$backup_file" "$original_port" || return 1
    ssh_rollback_remove_state || return 1
    clear_ssh_rollback_state
}

clear_ssh_rollback_state() {
    SSH_ROLLBACK_PID=""
    SSH_ROLLBACK_ID=""
    SSH_ROLLBACK_CONFIG=""
    SSH_ROLLBACK_BACKUP=""
    SSH_ROLLBACK_BACKUP_ID=""
    SSH_ROLLBACK_ORIGINAL_PORT=""
    SSH_ROLLBACK_MARKER=""
    SSH_ROLLBACK_MARKER_TOKEN=""
    SSH_ROLLBACK_RESULT_FILE=""
    SSH_ROLLBACK_STATE_DIR=""
    SSH_ROLLBACK_STATE_ID=""
    SSH_ROLLBACK_STATE_TOKEN=""
    SSH_ROLLBACK_TOKEN_FILE=""
    SSH_ROLLBACK_TOKEN_ID=""
    SSH_ROLLBACK_CLAIM_RESULT=""
}

stop_ssh_rollback_timer() {
    local current_id=""
    if [[ "$SSH_ROLLBACK_PID" =~ ^[0-9]+$ ]]; then
        current_id=$(cleanup_process_identity "$SSH_ROLLBACK_PID" 2>/dev/null || true)
        if [[ -n "$current_id" ]]; then
            [[ -n "$SSH_ROLLBACK_ID" && "$current_id" == "$SSH_ROLLBACK_ID" ]] || return 1
            kill "$SSH_ROLLBACK_PID" 2>/dev/null || return 1
        fi
        wait "$SSH_ROLLBACK_PID" 2>/dev/null || true
        current_id=$(cleanup_process_identity "$SSH_ROLLBACK_PID" 2>/dev/null || true)
        [[ -z "$current_id" || "$current_id" != "$SSH_ROLLBACK_ID" ]] || return 1
    fi
    SSH_ROLLBACK_PID=""
    SSH_ROLLBACK_ID=""
}

start_ssh_rollback_timer() {
    local ssh_config="$1" backup_file="$2" original_port="$3" timeout="$4" marker="$5"
    local backup_id marker_token
    backup_id=$(ssh_rollback_file_identity "$backup_file") || return 1
    SSH_ROLLBACK_BACKUP_ID="$backup_id"
    ssh_rollback_backup_is_valid "$backup_file" || return 1
    [[ "$(ssh_rollback_phase_current 2>/dev/null || true)" == "pending" ]] || return 1
    marker_token="${SSH_ROLLBACK_STATE_TOKEN:-${EUID}-$$-${RANDOM}-${RANDOM}}"
    SSH_ROLLBACK_MARKER_TOKEN="$marker_token"
    (
        local claim_status=0
        sleep "$timeout"
        # Once the timeout has elapsed, rollback claiming and recovery form a
        # critical transaction.  A signal sent to the whole process group also
        # reaches this worker and every external command it starts.  Ignore the
        # interactive termination signals from immediately before the claim
        # through durable result publication and backup removal; the parent
        # receives the same signal, waits for this identity-bound worker, and
        # performs the requested signal exit after cleanup.  Before the sleep
        # completes the worker keeps the default dispositions, so a still-
        # pending timer remains promptly cancellable by stop_ssh_rollback_timer.
        trap '' INT TERM HUP
        ssh_rollback_claim_phase rolling-back || claim_status=$?
        # Only a fully successful claim proves that this worker owns the
        # rollback.  A non-zero result (whether from a durability error or a
        # competing claimant changing the visible phase) carries no claimant
        # identity and must never authorize a second restore.
        if ((claim_status == 0)); then
            _ssh_rollback_claimed "$ssh_config" "$backup_file" "$original_port"
        else
            local observed_phase
            observed_phase=$(ssh_rollback_phase_current 2>/dev/null || true)
            [[ "$observed_phase" == "confirmed" || "$observed_phase" == "rolling-back" ]]
        fi
    ) &
    SSH_ROLLBACK_PID=$!
    SSH_ROLLBACK_ID=$(cleanup_process_identity "$SSH_ROLLBACK_PID" 2>/dev/null || true)
    SSH_ROLLBACK_CONFIG="$ssh_config"
    SSH_ROLLBACK_BACKUP="$backup_file"
    SSH_ROLLBACK_ORIGINAL_PORT="$original_port"
    SSH_ROLLBACK_MARKER="$marker"
    [[ -n "$SSH_ROLLBACK_STATE_DIR" ]] && \
        SSH_ROLLBACK_RESULT_FILE="$SSH_ROLLBACK_STATE_DIR/rolled-back"
    if [[ -z "$SSH_ROLLBACK_ID" ]]; then
        kill "$SSH_ROLLBACK_PID" 2>/dev/null || true
        wait "$SSH_ROLLBACK_PID" 2>/dev/null || true
        return 1
    fi
}

ssh_rollback_wait_for_timer_completion() {
    local current_id="" wait_status=0
    [[ "$(ssh_rollback_phase_current 2>/dev/null || true)" == "rolling-back" ]] || return 1
    if [[ "$SSH_ROLLBACK_PID" =~ ^[0-9]+$ ]]; then
        current_id=$(cleanup_process_identity "$SSH_ROLLBACK_PID" 2>/dev/null || true)
        if [[ -n "$current_id" ]]; then
            [[ -n "$SSH_ROLLBACK_ID" && "$current_id" == "$SSH_ROLLBACK_ID" ]] || return 1
        fi
        wait "$SSH_ROLLBACK_PID" || wait_status=$?
        ((wait_status == 0)) || return 1
        current_id=$(cleanup_process_identity "$SSH_ROLLBACK_PID" 2>/dev/null || true)
        [[ -z "$current_id" || "$current_id" != "$SSH_ROLLBACK_ID" ]] || return 1
    fi
    ssh_rollback_result_is_valid || return 1
    [[ ! -e "$SSH_ROLLBACK_BACKUP" && ! -L "$SSH_ROLLBACK_BACKUP" ]]
}

ssh_rollback_confirm() {
    local phase
    if ssh_rollback_claim_phase confirmed; then
        stop_ssh_rollback_timer || return 1
        ssh_rollback_remove_backup "$SSH_ROLLBACK_BACKUP" || return 1
        ssh_rollback_remove_state || return 1
        clear_ssh_rollback_state
        return 0
    fi
    phase=$(ssh_rollback_phase_current 2>/dev/null || true)
    if [[ "$phase" == "rolling-back" ]]; then
        if ! ssh_rollback_wait_for_timer_completion; then
            echo -e "${RED}[ERROR]${NC} 确认输掉回滚竞态，且无法验证回滚完成；状态已保留。" >&2
            return 1
        fi
        ssh_rollback_remove_state || return 1
        clear_ssh_rollback_state
        echo -e "${YELLOW}[ROLLBACK WON]${NC} 确认输掉回滚竞态；已等待并验证回滚完成。" >&2
        return 2
    fi
    echo -e "${RED}[ERROR]${NC} 无法安全提交确认；phase 状态已保留。" >&2
    return 1
}

cleanup_pending_ssh_rollback() {
    local phase claim_status=0
    [[ -n "$SSH_ROLLBACK_PID" || -n "$SSH_ROLLBACK_STATE_DIR" ]] || return 0
    if [[ -n "$SSH_ROLLBACK_STATE_DIR" && -z "$SSH_ROLLBACK_BACKUP_ID" ]]; then
        if [[ -n "$SSH_ROLLBACK_PID" ]]; then
            stop_ssh_rollback_timer || return 1
        fi
        ssh_rollback_discard_unstarted_state || return 1
        clear_ssh_rollback_state
        return 0
    fi
    phase=$(ssh_rollback_phase_current) || return 1
    case "$phase" in
        pending)
            ssh_rollback_claim_phase rolling-back || claim_status=$?
            if ((claim_status != 0)) \
                && ! { ((claim_status == 2)) && [[ "$SSH_ROLLBACK_CLAIM_RESULT" == "rolling-back" ]]; }; then
                phase=$(ssh_rollback_phase_current 2>/dev/null || true)
                [[ "$phase" == "rolling-back" ]] || return 1
                ssh_rollback_wait_for_timer_completion || return 1
            else
                if [[ -n "$SSH_ROLLBACK_PID" ]]; then
                    stop_ssh_rollback_timer || return 1
                fi
                _ssh_rollback_claimed "$SSH_ROLLBACK_CONFIG" "$SSH_ROLLBACK_BACKUP" \
                    "$SSH_ROLLBACK_ORIGINAL_PORT" || return 1
            fi
            ssh_rollback_remove_state || return 1
            ;;
        confirmed)
            if [[ -n "$SSH_ROLLBACK_PID" ]]; then
                stop_ssh_rollback_timer || return 1
            fi
            if [[ -e "$SSH_ROLLBACK_BACKUP" || -L "$SSH_ROLLBACK_BACKUP" ]]; then
                ssh_rollback_remove_backup "$SSH_ROLLBACK_BACKUP" || return 1
            fi
            ssh_rollback_remove_state || return 1
            ;;
        rolling-back)
            if [[ -n "$SSH_ROLLBACK_PID" ]]; then
                ssh_rollback_wait_for_timer_completion || return 1
            elif ! ssh_rollback_result_is_valid; then
                _ssh_rollback_claimed "$SSH_ROLLBACK_CONFIG" "$SSH_ROLLBACK_BACKUP" \
                    "$SSH_ROLLBACK_ORIGINAL_PORT" || return 1
            fi
            ssh_rollback_remove_state || return 1
            ;;
        *) return 1 ;;
    esac
    clear_ssh_rollback_state
}

# 修改 SSH 端口（带自动回滚保护）
change_ssh_port() {
    local ssh_config="/etc/ssh/sshd_config"
    local backup_file=""
    local rollback_marker=""
    local rollback_timeout=120  # 2 minutes to confirm

    # 安全警告框
    clear
    echo -e "${RED}################################################################${NC}"
    echo -e "${RED}#                    高风险操作警告 (WARNING)                  #${NC}"
    echo -e "${RED}################################################################${NC}"
    echo -e "${RED}#${NC}                                                              ${RED}#${NC}"
    echo -e "${RED}#${NC}  1. 云服务器用户 (阿里云/腾讯云/AWS等)：                     ${RED}#${NC}"
    echo -e "${RED}#${NC}     必须先在网页控制台的【安全组/防火墙】放行新端口！        ${RED}#${NC}"
    echo -e "${RED}#${NC}     (脚本只能修改系统内部防火墙，无法修改云平台安全组)       ${RED}#${NC}"
    echo -e "${RED}#${NC}                                                              ${RED}#${NC}"
    echo -e "${RED}#${NC}  2. 修改后你有 ${rollback_timeout} 秒时间确认连接是否正常         ${RED}#${NC}"
    echo -e "${RED}#${NC}     如果未确认，端口将自动恢复为原端口 ($CURRENT_SSH)       ${RED}#${NC}"
    echo -e "${RED}#${NC}                                                              ${RED}#${NC}"
    echo -e "${RED}#${NC}  3. 请新开一个 SSH 窗口测试新端口，然后回来输入 'confirm'   ${RED}#${NC}"
    echo -e "${RED}#${NC}                                                              ${RED}#${NC}"
    echo -e "${RED}################################################################${NC}"
    echo ""

    read -p "我已知晓风险，确认继续修改? (y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "${YELLOW}>>> 操作已取消。${NC}"
        sleep 1
        return
    fi

    echo ""
    read -p "请输入新的 SSH 端口 [当前: $CURRENT_SSH]: " new_port
    [[ -z "$new_port" ]] && return
    validate_port "$new_port" || return

    # Security: validate port more strictly
    new_port=$(get_validated_port "$new_port" false) || return

    echo -e "${BLUE}正在修改 SSH 端口...${NC}"

    # Step 1: Create an owned private rollback state and backup BEFORE any changes.
    if ! ssh_rollback_prepare_state; then
        echo -e "${RED}[ERROR]${NC} 无法安全创建 SSH 回滚状态，未修改配置。" >&2
        return 1
    fi
    rollback_marker="$SSH_ROLLBACK_STATE_DIR/confirmed"
    SSH_ROLLBACK_CONFIG="$ssh_config"
    SSH_ROLLBACK_ORIGINAL_PORT="$CURRENT_SSH"
    SSH_ROLLBACK_MARKER="$rollback_marker"
    SSH_ROLLBACK_MARKER_TOKEN="$SSH_ROLLBACK_STATE_TOKEN"
    SSH_ROLLBACK_RESULT_FILE="$SSH_ROLLBACK_STATE_DIR/rolled-back"
    if ! ssh_rollback_create_backup "$ssh_config"; then
        echo -e "${RED}[ERROR]${NC} 无法安全创建 SSH 回滚备份，未修改配置。" >&2
        cleanup_pending_ssh_rollback || \
            echo -e "${RED}[ERROR]${NC} 未能安全清理回滚状态；写锁必须保留。" >&2
        return 1
    fi
    backup_file="$SSH_ROLLBACK_BACKUP"
    echo -e "${GREEN}[BACKUP]${NC} 配置已备份到 $backup_file"

    # Step 2: Modify config
    if grep -q "^Port" "$ssh_config"; then
        if ! sed -i "s/^Port.*/Port $new_port/" "$ssh_config"; then
            _ssh_rollback "$ssh_config" "$backup_file" "$CURRENT_SSH" || \
                echo -e "${RED}[ERROR]${NC} 配置写入及自动恢复均失败；安全备份已保留。" >&2
            return 1
        fi
    else
        if ! echo "Port $new_port" >> "$ssh_config"; then
            _ssh_rollback "$ssh_config" "$backup_file" "$CURRENT_SSH" || \
                echo -e "${RED}[ERROR]${NC} 配置写入及自动恢复均失败；安全备份已保留。" >&2
            return 1
        fi
    fi

    if ! ssh_rollback_validate_config "$ssh_config"; then
        echo -e "${RED}[ERROR]${NC} 新 SSH 配置验证失败，正在恢复原配置。" >&2
        _ssh_rollback "$ssh_config" "$backup_file" "$CURRENT_SSH" || \
            echo -e "${RED}[ERROR]${NC} 自动恢复失败；安全备份已保留在 $backup_file" >&2
        return 1
    fi

    # Step 3: Open firewall for new port
    open_firewall_port "$new_port"

    # Step 4: Start a tracked background rollback timer
    if ! start_ssh_rollback_timer "$ssh_config" "$backup_file" "$CURRENT_SSH" \
        "$rollback_timeout" "$rollback_marker"; then
        echo -e "${RED}[ERROR]${NC} 无法启动 SSH 回滚计时器，正在恢复原配置。" >&2
        _ssh_rollback "$ssh_config" "$backup_file" "$CURRENT_SSH" || \
            echo -e "${RED}[ERROR]${NC} 自动恢复失败；安全备份已保留在 $backup_file" >&2
        return 1
    fi

    # Step 5: Restart SSH service
    echo -e "${BLUE}[INFO]${NC} 重启 SSH 服务..."
    if ! ssh_rollback_restart_service "$ssh_config"; then
        echo -e "${RED}[ERROR]${NC} SSH 服务重启失败，正在恢复原配置。" >&2
        if ! cleanup_pending_ssh_rollback; then
            echo -e "${RED}[ERROR]${NC} 自动恢复失败；安全备份和状态已保留。" >&2
        fi
        return 1
    fi

    # Step 6: Wait for user confirmation
    echo ""
    echo -e "${YELLOW}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║  SSH 端口已修改为 $new_port                                     ${NC}"
    echo -e "${YELLOW}║                                                               ${NC}"
    echo -e "${YELLOW}║  请立即在【新窗口】测试: ssh -p $new_port user@server          ${NC}"
    echo -e "${YELLOW}║                                                               ${NC}"
    echo -e "${YELLOW}║  如果连接成功，请在这里输入 'confirm' 保留更改                ${NC}"
    echo -e "${YELLOW}║  如果 ${rollback_timeout} 秒内未确认，端口将自动恢复为 $CURRENT_SSH     ${NC}"
    echo -e "${YELLOW}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    local user_confirm=""
    local start_time=$SECONDS
    while [[ $((SECONDS - start_time)) -lt $rollback_timeout ]]; do
        local remaining=$((rollback_timeout - (SECONDS - start_time)))
        echo -ne "\r  剩余时间: ${remaining}s | 输入 'confirm' 确认: "
        if read -t 1 -r user_confirm; then
            break
        fi
    done
    echo ""

    if [[ "$user_confirm" == "confirm" ]]; then
        if ssh_rollback_confirm; then
            echo -e "${GREEN}[SUCCESS]${NC} SSH 端口修改已确认！新端口: $new_port"
        else
            local confirm_status=$?
            ((confirm_status == 2)) || \
                echo -e "${RED}[ERROR]${NC} 无法安全提交确认；回滚状态已保留。" >&2
            return 1
        fi
    else
        # Timeout or cancelled, rollback will happen automatically
        echo -e "${YELLOW}[TIMEOUT]${NC} 未收到确认，将自动回滚..."
        # Force immediate rollback instead of waiting
        if ! cleanup_pending_ssh_rollback; then
            echo -e "${RED}[ERROR]${NC} SSH 自动回滚未完整成功；安全备份和状态已保留。" >&2
            return 1
        fi
    fi

    read -n 1 -s -r -p "按任意键继续..."
}

# 修改 Vision 端口
change_vision_port() {
    if [[ ! -f "$XRAY_CONF" ]]; then
        echo -e "${RED}[ERROR]${NC} Xray 配置文件不存在！"
        read -n 1 -s -r -p "按任意键继续..."
        return
    fi

    read -p "请输入新的 Vision 端口 [当前: $CURRENT_VISION]: " new_port
    [[ -z "$new_port" ]] && return
    validate_port "$new_port" || return

    echo -e "${BLUE}正在修改 Vision 端口...${NC}"

    # 使用 jq 修改端口
    if command -v jq &>/dev/null; then
        # 尝试多种 tag 名称
        local tmp_file="${XRAY_CONF}.tmp"
        jq --argjson port "$new_port" '
            (.inbounds[] | select(.tag=="vision_node" or .tag=="vless-reality-vision" or (.settings.clients and .streamSettings.realitySettings)) | .port) |= $port
        ' "$XRAY_CONF" > "$tmp_file" && mv "$tmp_file" "$XRAY_CONF"
    fi

    # 更新节点配置文件
    for node_file in "$NODES_DIR"/*.env; do
        [[ -f "$node_file" ]] || continue
        if grep -q "^PORT=" "$node_file"; then
            sed -i "s/^PORT=.*/PORT=$new_port/" "$node_file"
        fi
    done

    # 开放防火墙
    open_firewall_port "$new_port"

    # 重启 Xray
    echo -e "${BLUE}[INFO]${NC} 重启 Xray 服务..."
    service_restart xray

    echo -e "${GREEN}修改成功！${NC}"
    read -n 1 -s -r -p "按任意键继续..."
}

# 修改 XHTTP 端口
change_xhttp_port() {
    if [[ ! -f "$XRAY_CONF" ]]; then
        echo -e "${RED}[ERROR]${NC} Xray 配置文件不存在！"
        read -n 1 -s -r -p "按任意键继续..."
        return
    fi

    if [[ "$CURRENT_XHTTP" == "N/A" ]]; then
        echo -e "${YELLOW}[WARN]${NC} XHTTP 未启用"
        read -n 1 -s -r -p "按任意键继续..."
        return
    fi

    read -p "请输入新的 XHTTP 端口 [当前: $CURRENT_XHTTP]: " new_port
    [[ -z "$new_port" ]] && return
    validate_port "$new_port" || return

    echo -e "${BLUE}正在修改 XHTTP 端口...${NC}"

    # 使用 jq 修改端口
    if command -v jq &>/dev/null; then
        local tmp_file="${XRAY_CONF}.tmp"
        jq --argjson port "$new_port" '
            (.inbounds[] | select(.tag=="xhttp_node") | .port) |= $port
        ' "$XRAY_CONF" > "$tmp_file" && mv "$tmp_file" "$XRAY_CONF"
    fi

    # 更新节点配置文件
    for node_file in "$NODES_DIR"/*.env; do
        [[ -f "$node_file" ]] || continue
        if grep -q "^XHTTP_PORT=" "$node_file"; then
            sed -i "s/^XHTTP_PORT=.*/XHTTP_PORT=$new_port/" "$node_file"
        fi
    done

    # 开放防火墙
    open_firewall_port "$new_port"

    # 重启 Xray
    echo -e "${BLUE}[INFO]${NC} 重启 Xray 服务..."
    service_restart xray

    echo -e "${GREEN}修改成功！${NC}"
    read -n 1 -s -r -p "按任意键继续..."
}

# 端口管理菜单
cmd_ports() {
    while true; do
        get_current_ports
        clear
        echo ""
        echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}              端口管理面板 (Port Manager)              ${NC}"
        echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
        echo ""
        echo -e "  服务              端口            状态"
        echo -e "${CYAN}───────────────────────────────────────────────────────${NC}"
        printf "  ${GREEN}1.${NC} 修改 SSH          ${YELLOW}%-12s${NC}  %s\n" "$CURRENT_SSH" "$(check_port_status "$CURRENT_SSH")"
        printf "  ${GREEN}2.${NC} 修改 Vision       ${YELLOW}%-12s${NC}  %s\n" "$CURRENT_VISION" "$([[ "$CURRENT_VISION" != "N/A" ]] && check_port_status "$CURRENT_VISION" || echo -e "${RED}N/A${NC}")"
        printf "  ${GREEN}3.${NC} 修改 XHTTP        ${YELLOW}%-12s${NC}  %s\n" "$CURRENT_XHTTP" "$([[ "$CURRENT_XHTTP" != "N/A" ]] && check_port_status "$CURRENT_XHTTP" || echo -e "${RED}N/A${NC}")"
        echo -e "${CYAN}───────────────────────────────────────────────────────${NC}"
        echo -e "  ${RED}0.${NC} 返回 (Back)"
        echo ""
        read -p "请输入选项 [0-3]: " choice

        case "$choice" in
            1) change_ssh_port ;;
            2) change_vision_port ;;
            3) change_xhttp_port ;;
            0) return ;;
            *) echo -e "${RED}输入无效${NC}"; sleep 1 ;;
        esac
    done
}

# ============== 日志查看 ==============

cmd_logs() {
    while true; do
        clear
        echo ""
        echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}              日志查看器 (Log Viewer)                  ${NC}"
        echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
        echo ""
        echo -e "  ${GREEN}1.${NC} Xray 日志 (最新 50 行)"
        echo -e "  ${GREEN}2.${NC} Xray 错误日志"
        echo -e "  ${GREEN}3.${NC} SSH 登录日志"
        echo -e "  ${GREEN}4.${NC} Fail2ban 日志"
        echo -e "  ${GREEN}5.${NC} 系统日志"
        echo -e "${CYAN}───────────────────────────────────────────────────────${NC}"
        echo -e "  ${RED}0.${NC} 返回 (Back)"
        echo ""
        read -p "请输入选项 [0-5]: " choice

        case "$choice" in
            1)
                echo ""
                echo -e "${CYAN}>>> Xray 日志 (最新 50 行):${NC}"
                echo ""
                if [[ "$INIT_SYSTEM" == "openrc" ]]; then
                    if [[ -f /var/log/xray/access.log ]]; then
                        tail -50 /var/log/xray/access.log
                    else
                        echo "日志文件不存在"
                    fi
                else
                    journalctl -u xray --no-pager -n 50 2>/dev/null || echo "无法读取日志"
                fi
                echo ""
                read -rp "$(msg menu_press_enter)"
                ;;
            2)
                echo ""
                echo -e "${CYAN}>>> Xray 错误日志:${NC}"
                echo ""
                if [[ "$INIT_SYSTEM" == "openrc" ]]; then
                    if [[ -f /var/log/xray/error.log ]]; then
                        tail -50 /var/log/xray/error.log
                    else
                        echo "日志文件不存在"
                    fi
                else
                    journalctl -u xray --no-pager -p err -n 50 2>/dev/null || echo "无法读取日志"
                fi
                echo ""
                read -rp "$(msg menu_press_enter)"
                ;;
            3)
                echo ""
                echo -e "${CYAN}>>> SSH 登录日志:${NC}"
                echo ""
                if [[ -f /var/log/auth.log ]]; then
                    grep -E "sshd.*(Accepted|Failed)" /var/log/auth.log 2>/dev/null | tail -30
                elif [[ -f /var/log/secure ]]; then
                    grep -E "sshd.*(Accepted|Failed)" /var/log/secure 2>/dev/null | tail -30
                else
                    journalctl -u ssh -u sshd --no-pager -n 30 2>/dev/null || echo "无法读取日志"
                fi
                echo ""
                read -rp "$(msg menu_press_enter)"
                ;;
            4)
                echo ""
                echo -e "${CYAN}>>> Fail2ban 日志:${NC}"
                echo ""
                if [[ -f /var/log/fail2ban.log ]]; then
                    grep -E "(Ban|Unban)" /var/log/fail2ban.log 2>/dev/null | tail -30
                else
                    echo "Fail2ban 日志不存在"
                fi
                echo ""
                read -rp "$(msg menu_press_enter)"
                ;;
            5)
                echo ""
                echo -e "${CYAN}>>> 系统日志 (最新 50 行):${NC}"
                echo ""
                if [[ -f /var/log/syslog ]]; then
                    tail -50 /var/log/syslog
                elif [[ -f /var/log/messages ]]; then
                    tail -50 /var/log/messages
                else
                    journalctl --no-pager -n 50 2>/dev/null || echo "无法读取日志"
                fi
                echo ""
                read -rp "$(msg menu_press_enter)"
                ;;
            0) return ;;
            *) echo -e "${RED}输入无效${NC}"; sleep 1 ;;
        esac
    done
}

# ============== 独立工具安装 ==============

install_standalone_tools() {
    local bin_dir="/usr/local/bin"

    echo -e "${BLUE}[INFO]${NC} 安装独立工具命令到 ${bin_dir}..."

    # 1. info 命令 - 显示节点信息
    cat > "${bin_dir}/xray-info" << 'TOOLEOF'
#!/bin/bash
# Reality Vision - Info Tool
SCRIPT_PATH="/root/reality_vision.sh"
if [[ -f "$SCRIPT_PATH" ]]; then
    bash "$SCRIPT_PATH" info
elif command -v reality-vision &>/dev/null; then
    reality-vision info
else
    echo "Reality Vision script not found"
    exit 1
fi
TOOLEOF
    chmod +x "${bin_dir}/xray-info"

    # 2. ports 命令 - 端口管理
    cat > "${bin_dir}/xray-ports" << 'TOOLEOF'
#!/bin/bash
# Reality Vision - Ports Tool
SCRIPT_PATH="/root/reality_vision.sh"
if [[ -f "$SCRIPT_PATH" ]]; then
    bash "$SCRIPT_PATH" ports
elif command -v reality-vision &>/dev/null; then
    reality-vision ports
else
    echo "Reality Vision script not found"
    exit 1
fi
TOOLEOF
    chmod +x "${bin_dir}/xray-ports"

    # 3. logs 命令 - 日志查看
    cat > "${bin_dir}/xray-logs" << 'TOOLEOF'
#!/bin/bash
# Reality Vision - Logs Tool
SCRIPT_PATH="/root/reality_vision.sh"
if [[ -f "$SCRIPT_PATH" ]]; then
    bash "$SCRIPT_PATH" logs
elif command -v reality-vision &>/dev/null; then
    reality-vision logs
else
    echo "Reality Vision script not found"
    exit 1
fi
TOOLEOF
    chmod +x "${bin_dir}/xray-logs"

    # 4. bbr 命令
    cat > "${bin_dir}/xray-bbr" << 'TOOLEOF'
#!/bin/bash
# Reality Vision - BBR Tool
SCRIPT_PATH="/root/reality_vision.sh"
if [[ -f "$SCRIPT_PATH" ]]; then
    bash "$SCRIPT_PATH" bbr
elif command -v reality-vision &>/dev/null; then
    reality-vision bbr
else
    echo "Reality Vision script not found"
    exit 1
fi
TOOLEOF
    chmod +x "${bin_dir}/xray-bbr"

    # 5. swap 命令
    cat > "${bin_dir}/xray-swap" << 'TOOLEOF'
#!/bin/bash
# Reality Vision - Swap Tool
SCRIPT_PATH="/root/reality_vision.sh"
if [[ -f "$SCRIPT_PATH" ]]; then
    bash "$SCRIPT_PATH" swap
elif command -v reality-vision &>/dev/null; then
    reality-vision swap
else
    echo "Reality Vision script not found"
    exit 1
fi
TOOLEOF
    chmod +x "${bin_dir}/xray-swap"

    # 6. warp 命令
    cat > "${bin_dir}/xray-warp" << 'TOOLEOF'
#!/bin/bash
# Reality Vision - WARP Tool
SCRIPT_PATH="/root/reality_vision.sh"
if [[ -f "$SCRIPT_PATH" ]]; then
    bash "$SCRIPT_PATH" warp
elif command -v reality-vision &>/dev/null; then
    reality-vision warp
else
    echo "Reality Vision script not found"
    exit 1
fi
TOOLEOF
    chmod +x "${bin_dir}/xray-warp"

    # 7. f2b 命令 - Fail2ban
    cat > "${bin_dir}/xray-f2b" << 'TOOLEOF'
#!/bin/bash
# Reality Vision - Fail2ban Tool
SCRIPT_PATH="/root/reality_vision.sh"
if [[ -f "$SCRIPT_PATH" ]]; then
    bash "$SCRIPT_PATH" fail2ban
elif command -v reality-vision &>/dev/null; then
    reality-vision fail2ban
else
    echo "Reality Vision script not found"
    exit 1
fi
TOOLEOF
    chmod +x "${bin_dir}/xray-f2b"

    # 8. timesync 命令 - 时间同步
    cat > "${bin_dir}/xray-timesync" << 'TOOLEOF'
#!/bin/bash
# Reality Vision - TimeSync Tool
SCRIPT_PATH="/root/reality_vision.sh"
if [[ -f "$SCRIPT_PATH" ]]; then
    bash "$SCRIPT_PATH" timesync
elif command -v reality-vision &>/dev/null; then
    reality-vision timesync
else
    echo "Reality Vision script not found"
    exit 1
fi
TOOLEOF
    chmod +x "${bin_dir}/xray-timesync"

    # 9. 主脚本链接
    if [[ -f "/root/reality_vision.sh" ]]; then
        ln -sf "/root/reality_vision.sh" "${bin_dir}/reality-vision" 2>/dev/null || true
    fi

    echo -e "${GREEN}[OK]${NC} 独立工具已安装！可用命令:"
    echo "  xray-info     - 查看节点信息"
    echo "  xray-ports    - 端口管理"
    echo "  xray-logs     - 日志查看"
    echo "  xray-bbr      - BBR 管理"
    echo "  xray-swap     - Swap 管理"
    echo "  xray-warp     - WARP 管理"
    echo "  xray-f2b      - Fail2ban 管理"
    echo "  xray-timesync - 时间同步管理"
}

# ============== 时间同步管理 ==============

# 检测虚拟化/容器类型
# 返回: none, lxc, docker, openvz, kvm, vmware, 等
detect_virt_type() {
    # 优先使用 systemd-detect-virt
    if command -v systemd-detect-virt &>/dev/null; then
        local virt
        virt=$(systemd-detect-virt 2>/dev/null || echo "none")
        echo "$virt"
        return
    fi
    # 手动检测
    if [[ -f /proc/1/environ ]] && tr '\0' '\n' < /proc/1/environ 2>/dev/null | grep -q "^container=lxc"; then
        echo "lxc"
    elif [[ -f /.dockerenv ]]; then
        echo "docker"
    elif [[ -d /proc/vz ]] && [[ ! -d /proc/bc ]]; then
        echo "openvz"
    else
        echo "none"
    fi
}

# 检查是否在容器环境中运行
is_container_env() {
    local virt
    virt=$(detect_virt_type)
    case "$virt" in
        lxc|lxc-libvirt|docker|podman|openvz|containerd|systemd-nspawn)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# 检查系统是否有修改时钟的权限 (CAP_SYS_TIME)
check_time_capability() {
    # 方法1: 尝试无害的 adjtimex 查询
    if command -v adjtimex &>/dev/null; then
        adjtimex --print &>/dev/null && return 0
    fi
    # 方法2: 检查 /proc/1/status 的 CapEff (bit 25 = CAP_SYS_TIME)
    if [[ -f /proc/1/status ]]; then
        local cap_eff
        cap_eff=$(grep "^CapEff:" /proc/1/status 2>/dev/null | awk '{print $2}')
        if [[ -n "$cap_eff" ]]; then
            # CAP_SYS_TIME = bit 25 = 0x2000000
            local cap_dec
            cap_dec=$(printf "%d" "0x$cap_eff" 2>/dev/null || echo 0)
            if (( cap_dec & 0x2000000 )); then
                return 0
            else
                return 1
            fi
        fi
    fi
    # 方法3: 尝试直接执行 chronyd 测试 (最可靠的检测)
    # 无法判断时默认假设有权限, 让后续操作自然失败并捕获
    return 0
}

# 检查 chrony 是否已安装
is_timesync_installed() {
    command -v chronyd &>/dev/null
}

# 获取时间同步状态
get_timesync_status() {
    if ! is_timesync_installed; then
        echo "not_installed"
        return
    fi
    if service_is_active chronyd 2>/dev/null || service_is_active chrony 2>/dev/null; then
        echo "running"
    else
        echo "stopped"
    fi
}

# 获取 chrony 服务名 (不同发行版名称不同)
get_chrony_service_name() {
    if [[ "$PKG_MANAGER" == "apt" ]]; then
        echo "chrony"
    else
        echo "chronyd"
    fi
}

# 显示容器环境时间同步的提示信息
show_container_timesync_hint() {
    local virt
    virt=$(detect_virt_type)
    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${YELLOW}⚠${NC}  $(msg timesync_container_warn)"
    echo -e "  $(msg timesync_container_type): ${CYAN}${virt}${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  $(msg timesync_container_detail)"
    echo ""
    if [[ "$virt" == "lxc" ]] || [[ "$virt" == "lxc-libvirt" ]]; then
        echo -e "  ${BLUE}$(msg timesync_pve_title):${NC}"
        echo ""
        echo -e "  ${GREEN}$(msg timesync_pve_method1):${NC}"
        echo -e "    $(msg timesync_pve_host_tip)"
        echo ""
        echo -e "  ${GREEN}$(msg timesync_pve_method2):${NC}"
        echo -e "    $(msg timesync_pve_cap_step1)"
        echo -e "    ${CYAN}nano /etc/pve/lxc/<CTID>.conf${NC}"
        echo -e "    $(msg timesync_pve_cap_step2)"
        echo -e "    ${CYAN}lxc.cap.keep: sys_time${NC}"
        echo -e "    $(msg timesync_pve_cap_step3)"
        echo ""
    elif [[ "$virt" == "docker" ]] || [[ "$virt" == "podman" ]]; then
        echo -e "  ${BLUE}Docker/Podman:${NC}"
        echo -e "    $(msg timesync_docker_tip)"
        echo -e "    ${CYAN}docker run --cap-add SYS_TIME ...${NC}"
        echo ""
    fi
    echo -e "  ${GREEN}$(msg timesync_container_no_host)${NC}"
    echo -e "    $(msg timesync_check) → $(msg menu_choice) 3"
    echo ""
}

# 安装并启用时间同步
timesync_install() {
    echo ""

    # 容器环境检测
    if is_container_env && ! check_time_capability; then
        show_container_timesync_hint
        echo -n "  $(msg timesync_try_anyway) [y/N]: "
        read -r try_anyway
        if [[ ! "$try_anyway" =~ ^[Yy]$ ]]; then
            return
        fi
        echo ""
    fi

    if is_timesync_installed; then
        log_info "$(msg timesync_already)"
        local svc_name
        svc_name=$(get_chrony_service_name)
        if ! service_is_active "$svc_name" 2>/dev/null; then
            log_info "$(msg timesync_installing)"
            service_enable "$svc_name"
            if ! service_start "$svc_name" 2>/dev/null; then
                timesync_handle_start_failure
                return
            fi
            log_info "$(msg timesync_installed)"
        fi
        echo ""
        read -rp "$(msg menu_press_enter)"
        return
    fi

    log_info "$(msg timesync_installing)"

    # 安装 chrony
    case "$PKG_MANAGER" in
        apt)
            apt-get update -y >/dev/null 2>&1
            apt-get install -y chrony >/dev/null 2>&1
            ;;
        dnf)
            dnf install -y chrony >/dev/null 2>&1
            ;;
        yum)
            yum install -y chrony >/dev/null 2>&1
            ;;
        apk)
            apk add --no-cache chrony >/dev/null 2>&1
            ;;
    esac

    # 停用 systemd-timesyncd 避免冲突 (仅 systemd 系统)
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        if systemctl is-active --quiet systemd-timesyncd 2>/dev/null; then
            systemctl stop systemd-timesyncd 2>/dev/null || true
            systemctl disable systemd-timesyncd 2>/dev/null || true
        fi
    fi

    # 配置 Chrony - 使用全球可达的 NTP 服务器
    local chrony_conf="/etc/chrony/chrony.conf"
    if [[ "$PKG_MANAGER" == "dnf" ]] || [[ "$PKG_MANAGER" == "yum" ]]; then
        chrony_conf="/etc/chrony.conf"
    elif [[ "$PKG_MANAGER" == "apk" ]]; then
        chrony_conf="/etc/chrony/chrony.conf"
        mkdir -p /etc/chrony
    fi

    cat > "$chrony_conf" <<CHRONYCFG
server time.google.com iburst
server time.cloudflare.com iburst
server pool.ntp.org iburst
driftfile /var/lib/chrony/chrony.drift
makestep 1.0 3
rtcsync
CHRONYCFG

    # Alpine 需要确保 driftfile 目录存在
    if [[ "$PKG_MANAGER" == "apk" ]]; then
        mkdir -p /var/lib/chrony
    fi

    # 启动并启用服务
    local svc_name
    svc_name=$(get_chrony_service_name)
    service_enable "$svc_name"

    if ! service_restart "$svc_name" 2>/dev/null; then
        timesync_handle_start_failure
        return
    fi

    # 强制同步一次
    sleep 1
    chronyc -a makestep >/dev/null 2>&1 || true

    # 写入硬件时钟 (容器中可能失败，忽略错误)
    hwclock --systohc 2>/dev/null || true

    log_info "$(msg timesync_installed)"
    echo ""
    echo -e "  $(msg timesync_current): ${GREEN}$(date -R)${NC}"
    echo ""
    read -rp "$(msg menu_press_enter)"
}

# 处理 chrony 启动失败
timesync_handle_start_failure() {
    local svc_name
    svc_name=$(get_chrony_service_name)

    echo ""
    log_error "$(msg timesync_start_failed)"
    echo ""

    # 检查是否是容器环境导致的 adjtimex 错误
    local journal_err=""
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        journal_err=$(journalctl -u "$svc_name" --no-pager -n 10 2>/dev/null || true)
    fi

    if echo "$journal_err" | grep -q "adjtimex.*not permitted\|Operation not permitted" 2>/dev/null; then
        show_container_timesync_hint
    else
        echo -e "  ${BLUE}$(msg timesync_check_log):${NC}"
        echo ""
        if [[ -n "$journal_err" ]]; then
            echo "$journal_err" | tail -5 | while IFS= read -r line; do
                echo "    $line"
            done
        fi
        echo ""
    fi

    read -rp "$(msg menu_press_enter)"
}

# 通过 HTTP 头检查时间准确度 (无需任何特权，适用于容器环境)
timesync_check() {
    echo ""
    log_info "$(msg timesync_checking)"
    echo ""

    local remote_epoch="" local_epoch="" offset=""
    local sources=("https://www.google.com" "https://www.cloudflare.com" "https://www.apple.com")
    local src_used=""

    for src in "${sources[@]}"; do
        local http_date
        http_date=$(curl -sI --max-time 5 --proto '=https' "$src" 2>/dev/null | grep -i "^date:" | sed 's/^[Dd]ate: *//' | tr -d '\r')
        if [[ -n "$http_date" ]]; then
            remote_epoch=$(date -d "$http_date" +%s 2>/dev/null)
            if [[ -n "$remote_epoch" ]]; then
                src_used="$src"
                break
            fi
        fi
    done

    if [[ -z "$remote_epoch" ]]; then
        log_error "$(msg timesync_offset_fail)"
        echo ""
        read -rp "$(msg menu_press_enter)"
        return
    fi

    local_epoch=$(date +%s)
    offset=$(( local_epoch - remote_epoch ))
    # 取绝对值
    local abs_offset=${offset#-}

    echo -e "  $(msg timesync_current): ${YELLOW}$(date -R)${NC}"
    echo -e "  Remote (${src_used}): ${YELLOW}$(date -d "@$remote_epoch" -R 2>/dev/null)${NC}"
    echo ""
    echo -e "  $(msg timesync_offset): ${CYAN}${offset}${NC} $(msg timesync_seconds)"
    echo ""

    if [[ "$abs_offset" -le 30 ]]; then
        echo -e "  ${GREEN}✓${NC} $(msg timesync_offset_ok)"
    elif [[ "$abs_offset" -le 90 ]]; then
        echo -e "  ${YELLOW}⚠${NC} $(msg timesync_offset_warn)"
        echo -e "  ${YELLOW}    (SS2022 tolerance: ~30s)${NC}"
    else
        echo -e "  ${RED}✗${NC} $(msg timesync_offset_warn)"
        echo -e "  ${RED}    (SS2022 tolerance: ~30s, current: ${abs_offset}s)${NC}"
        echo ""
        if is_container_env && ! check_time_capability; then
            echo -e "  ${YELLOW}$(msg timesync_container_no_host)${NC}"
            echo -e "  $(msg timesync_container_detail)"
        fi
    fi

    echo ""
    read -rp "$(msg menu_press_enter)"
}

# 强制同步时间
timesync_force() {
    echo ""
    if ! is_timesync_installed; then
        log_error "$(msg timesync_not_installed)"
        echo ""
        read -rp "$(msg menu_press_enter)"
        return
    fi

    log_info "$(msg timesync_forcing)"

    local svc_name
    svc_name=$(get_chrony_service_name)

    # 确保服务在运行
    if ! service_is_active "$svc_name" 2>/dev/null; then
        if ! service_start "$svc_name" 2>/dev/null; then
            timesync_handle_start_failure
            return
        fi
        sleep 1
    fi

    # 强制步进同步
    chronyc -a makestep 2>/dev/null

    # 写入硬件时钟
    hwclock --systohc 2>/dev/null || true

    log_info "$(msg timesync_forced)"
    echo ""
    echo -e "  $(msg timesync_current): ${GREEN}$(date -R)${NC}"
    echo ""

    # 显示 chronyc tracking 信息
    if command -v chronyc &>/dev/null; then
        echo -e "  ${BLUE}Chrony Tracking:${NC}"
        chronyc tracking 2>/dev/null | while IFS= read -r line; do
            echo "    $line"
        done
    fi

    echo ""
    read -rp "$(msg menu_press_enter)"
}

# 卸载时间同步
timesync_uninstall() {
    echo ""
    if ! is_timesync_installed; then
        log_error "$(msg timesync_not_installed)"
        echo ""
        read -rp "$(msg menu_press_enter)"
        return
    fi

    log_info "$(msg timesync_removing)"

    local svc_name
    svc_name=$(get_chrony_service_name)

    service_stop "$svc_name"
    service_disable "$svc_name"

    case "$PKG_MANAGER" in
        apt)
            apt-get remove -y chrony >/dev/null 2>&1
            ;;
        dnf)
            dnf remove -y chrony >/dev/null 2>&1
            ;;
        yum)
            yum remove -y chrony >/dev/null 2>&1
            ;;
        apk)
            apk del chrony >/dev/null 2>&1
            ;;
    esac

    log_info "$(msg timesync_removed)"
    echo ""
    read -rp "$(msg menu_press_enter)"
}

# 时间同步菜单
cmd_timesync() {
    while true; do
        clear
        local sync_status sync_display svc_name

        sync_status=$(get_timesync_status)
        case "$sync_status" in
            running)
                sync_display="${GREEN}$(msg timesync_synced)${NC}"
                ;;
            stopped)
                sync_display="${YELLOW}Stopped${NC}"
                ;;
            *)
                sync_display="${RED}$(msg timesync_not_installed)${NC}"
                ;;
        esac

        echo ""
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}                     $(msg timesync_title)${NC}"
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo ""
        echo -e "  $(msg timesync_status): $sync_display"
        echo -e "  $(msg timesync_current): ${YELLOW}$(date -R)${NC}"
        echo -e "  $(msg timesync_timezone): ${YELLOW}$(cat /etc/timezone 2>/dev/null || timedatectl show -p Timezone --value 2>/dev/null || echo 'N/A')${NC}"

        # 显示容器类型提示
        if is_container_env; then
            local virt
            virt=$(detect_virt_type)
            echo -e "  $(msg timesync_env): ${YELLOW}${virt}${NC}"
        fi
        echo ""

        # 如果 chrony 已安装并运行，显示源信息
        if [[ "$sync_status" == "running" ]] && command -v chronyc &>/dev/null; then
            echo -e "  ${BLUE}NTP Sources:${NC}"
            chronyc sources 2>/dev/null | tail -n +3 | while IFS= read -r line; do
                echo "    $line"
            done
            echo ""
        fi

        echo -e "  ${GREEN}1.${NC} $(msg timesync_install)"
        echo -e "  ${GREEN}2.${NC} $(msg timesync_force)"
        echo -e "  ${GREEN}3.${NC} $(msg timesync_check)"
        echo -e "  ${GREEN}4.${NC} $(msg timesync_uninstall)"
        echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
        echo -e "  ${RED}0.${NC} Back / 返回"
        echo ""
        echo -n "  $(msg menu_choice) [0-4]: "
        read -r choice

        case "$choice" in
            1) timesync_install ;;
            2) timesync_force ;;
            3) timesync_check ;;
            4) timesync_uninstall ;;
            0) return ;;
            *) ;;
        esac
    done
}

# SS2022 安装后自动提示时间同步
prompt_timesync_for_ss2022() {
    # 已安装且运行中则跳过
    if is_timesync_installed; then
        local svc_name
        svc_name=$(get_chrony_service_name)
        if service_is_active "$svc_name" 2>/dev/null; then
            return
        fi
    fi

    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${YELLOW}⚠${NC}  $(msg timesync_ss2022_hint)"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    # 容器环境且无权限: 只允许校验或跳过，绝不尝试修改宿主机时钟。
    if is_container_env && ! check_time_capability; then
        echo -e "  $(msg timesync_container_no_host)"
        echo -e "  ${GREEN}1.${NC} $(msg timesync_check)"
        echo -e "  ${RED}0.${NC} $(msg timesync_skip)"
        echo ""
        echo -n "  $(msg menu_choice) [0-1]: "
        local answer
        read -r answer
        if [[ "$answer" == "1" ]]; then
            timesync_check
        fi
        return 0
    fi

    echo -e "  ${GREEN}1.${NC} $(msg timesync_install)"
    echo -e "  ${GREEN}2.${NC} $(msg timesync_check)"
    echo -e "  ${RED}0.${NC} $(msg timesync_skip)"
    echo ""
    echo -n "  $(msg menu_choice) [0-2]: "
    local answer
    read -r answer
    case "$answer" in
        1) timesync_install ;;
        2) timesync_check ;;
        *) return 0 ;;
    esac
}

# ============== 系统工具菜单 ==============

cmd_tools() {
    while true; do
        clear
        echo ""
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}                     $(msg tools_menu)${NC}"
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo ""
        echo -e "  ${BLUE}[网络优化]${NC}"
        echo -e "  ${GREEN}1.${NC} $(msg menu_warp)"
        echo -e "  ${GREEN}2.${NC} $(msg menu_bbr)"
        echo ""
        echo -e "  ${BLUE}[系统管理]${NC}"
        echo -e "  ${GREEN}3.${NC} $(msg menu_swap)"
        echo -e "  ${GREEN}4.${NC} $(msg menu_fail2ban)"
        echo -e "  ${GREEN}5.${NC} $(msg menu_timesync)"
        echo ""
        echo -e "  ${BLUE}[服务管理]${NC}"
        echo -e "  ${GREEN}6.${NC} 端口管理 (Ports)"
        echo -e "  ${GREEN}7.${NC} 日志查看 (Logs)"
        echo -e "  ${GREEN}8.${NC} $(msg xray_restart_title)"
        echo -e "  ${GREEN}9.${NC} $(msg xray_release_title)"
        echo ""
        echo -e "  ${BLUE}[其他]${NC}"
        echo -e "  ${GREEN}10.${NC} 安装独立工具命令"
        echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
        echo -e "  ${RED}0.${NC} Back / 返回"
        echo ""
        echo -n "  $(msg menu_choice) [0-10]: "
        read -r choice

        case "$choice" in
            1) cmd_warp ;;
            2) cmd_bbr ;;
            3) cmd_swap ;;
            4) cmd_fail2ban ;;
            5) cmd_timesync ;;
            6) cmd_ports ;;
            7) cmd_logs ;;
            8) cmd_xray_restart ;;
            9) cmd_xray_release_menu ;;
            10)
                install_standalone_tools
                echo ""
                read -rp "$(msg menu_press_enter)"
                ;;
            0) return ;;
            *) ;;
        esac
    done
}

# ============== 主菜单 ==============

show_menu() {
    clear
    local status_icon node_count
    if service_is_active xray; then
        status_icon="${GREEN}●${NC}"
    else
        status_icon="${RED}○${NC}"
    fi
    node_count=$(count_nodes)

    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}         ${YELLOW}$(msg menu_title)${NC}              ${CYAN}║${NC}"
    echo -e "${CYAN}╠═══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC}                                                               ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   ${GREEN}1.${NC} $(msg menu_install) (Add Node)                                  ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   ${GREEN}2.${NC} $(msg menu_info)                                          ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   ${GREEN}3.${NC} $(msg menu_qr)                                            ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   ${GREEN}4.${NC} $(msg menu_status)  [$status_icon] (${node_count} nodes)                         ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   ${GREEN}5.${NC} List Nodes / 列出节点                                     ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   ${GREEN}6.${NC} Remove Node / 删除节点                                    ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   ${GREEN}E.${NC} Edit Node / 编辑节点                                      ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   ${GREEN}7.${NC} $(msg menu_restart)                                            ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   ${GREEN}8.${NC} $(msg menu_test_sni)                                      ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   ${GREEN}9.${NC} $(msg menu_health)                                             ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}                                                               ${CYAN}║${NC}"
    echo -e "${CYAN}╠═══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC}   ${BLUE}I.${NC} $(msg update_ip) / 更新节点 IP                                ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   ${BLUE}T.${NC} $(msg menu_tools) (WARP/BBR/Swap/Fail2ban/TimeSync)          ${CYAN}║${NC}"
    echo -e "${CYAN}╠═══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC}                                                               ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   ${MAGENTA}L.${NC} $(msg menu_lang)                                            ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   ${YELLOW}U.${NC} $(msg menu_uninstall) (All)                                     ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   ${RED}0.${NC} $(msg menu_exit)                                                ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}                                                               ${CYAN}║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

main_menu() {
    while true; do
        show_menu
        echo -n "   $(msg menu_choice) [0-9,E,I,T,L,U]: "
        read -r choice
        echo ""

        case "$choice" in
            1)
                cmd_install
                echo ""
                read -rp "$(msg menu_press_enter)"
                ;;
            2)
                cmd_info
                echo ""
                read -rp "$(msg menu_press_enter)"
                ;;
            3)
                cmd_qr
                echo ""
                read -rp "$(msg menu_press_enter)"
                ;;
            4)
                cmd_status
                echo ""
                read -rp "$(msg menu_press_enter)"
                ;;
            5)
                cmd_list
                echo ""
                read -rp "$(msg menu_press_enter)"
                ;;
            6)
                cmd_remove
                echo ""
                read -rp "$(msg menu_press_enter)"
                ;;
            7)
                cmd_restart
                echo ""
                read -rp "$(msg menu_press_enter)"
                ;;
            8)
                cmd_test_sni
                echo ""
                read -rp "$(msg menu_press_enter)"
                ;;
            9)
                cmd_health
                echo ""
                read -rp "$(msg menu_press_enter)"
                ;;
            [Ee])
                cmd_edit
                echo ""
                read -rp "$(msg menu_press_enter)"
                ;;
            [Ii])
                cmd_update_ip
                echo ""
                read -rp "$(msg menu_press_enter)"
                ;;
            [Tt])
                cmd_tools
                ;;
            [Ll])
                select_language
                ;;
            [Uu])
                cmd_uninstall
                echo ""
                read -rp "$(msg menu_press_enter)"
                ;;
            0)
                echo -e "${GREEN}Bye!${NC}"
                exit 0
                ;;
            *)
                log_error "$(msg menu_invalid)"
                sleep 1
                ;;
        esac
    done
}

show_help() {
    echo ""
    echo -e "${CYAN}VLESS TCP REALITY Vision (Enhanced Edition)${NC}"
    echo ""
    echo "Usage: bash $0 [command]"
    echo ""
    echo "Commands:"
    echo "  (none)      Show interactive menu"
    echo "  install     Add a new node"
    echo "  list        List all nodes"
    echo "  info        Show node information"
    echo "  qr          Show QR code"
    echo "  status      Show service status"
    echo "  health      Run health check"
    echo "  remove      Remove a node"
    echo "  edit        Edit an existing node (port/SNI/password/keys...)"
    echo "  restart     Restart service"
    echo "  regenerate  Regenerate config from node files (fix config issues)"
    echo "  update-ip   Detect IP change and update all node configs"
    echo "  uninstall   Uninstall all nodes and Xray"
    echo "  test-sni    Test all SNI latency"
    echo ""
    echo "System Tools:"
    echo "  tools       System tools menu (WARP/BBR/Swap/Fail2ban/TimeSync/Ports/Logs)"
    echo "  ports       Port management (SSH/Vision/XHTTP)"
    echo "  logs        Log viewer"
    echo "  warp        WARP routing management"
    echo "  bbr         BBR/TCP optimization"
    echo "  swap        Swap management"
    echo "  fail2ban    Fail2ban management"
    echo "  timesync    System time synchronization (NTP/Chrony)"
    echo "  xray-restart  Schedule periodic Xray restart (systemd timer or cron)"
    echo "  xray-version  Show installed/stable/prerelease Xray versions"
    echo "  xray-update   Safely update Xray with config test and rollback"
    echo ""
    echo "Other:"
    echo "  menu        Show interactive menu"
    echo "  help        Show this help"
    echo ""
    echo "Optional parameters (for install):"
    echo "  name=xxx      Specify node name"
    echo "  reym=xxx      Specify SNI domain (VLESS / AnyTLS+REALITY)"
    echo "  proto=xxx     Protocol type: vision, xhttp, both, shadowsocks,"
    echo "                anytls, anytls-reality, or hysteria2 (hy2)"
    echo "  vlpt=xxx      Specify Vision port (for vision/both)"
    echo "  xhpt=xxx      Specify XHTTP port (for xhttp/both)"
    echo "  uuid=xxx      Specify UUID (VLESS only)"
    echo ""
    echo "Shadowsocks parameters:"
    echo "  ssmethod=xxx  Encryption: 2022-blake3-aes-256-gcm (default),"
    echo "                2022-blake3-chacha20-poly1305, chacha20-ietf-poly1305, aes-256-gcm"
    echo "  sspwd=xxx     Specify password (auto-generated if not set)"
    echo "  sspt=xxx      Specify Shadowsocks port"
    echo "  xhttp=true    (deprecated) Same as proto=both"
    echo ""
    echo "AnyTLS parameters (powered by sing-box; Xray does not support AnyTLS):"
    echo "  atpt=xxx      Specify AnyTLS port"
    echo "  atpwd=xxx     Specify AnyTLS password (auto-generated if not set)"
    echo "                Padding scheme is randomized per node and auto-pushed to clients"
    echo ""
    echo "Hysteria2 parameters (powered by sing-box):"
    echo "  hy2pt=xxx     Specify Hysteria2 UDP port"
    echo "  hy2pwd=xxx    Specify 8-128 character URI-safe password"
    echo "  hy2sni=xxx    Specify TLS SNI (default: www.bing.com)"
    echo ""
    echo "Periodic Xray restart (optional, non-interactive):"
    echo "  restart=daily   Daily restart (04:00)"
    echo "  restart=12h     Every 12 hours"
    echo "  restart=6h      Every 6 hours"
    echo "  restart=weekly  Weekly restart (Sun 04:00)"
    echo "  restart=no      Skip the restart schedule prompt"
    echo ""
    echo "Xray release management:"
    echo "  XRAY_CHANNEL=stable|prerelease  Select the release channel (default: stable)"
    echo "  XRAY_VERSION=v26.7.11           Install an explicit Xray version (highest priority)"
    echo "  xray_channel=stable|prerelease  Lowercase compatibility alias"
    echo "  xray_version=v26.7.11           Lowercase compatibility alias"
    echo ""
    echo "Examples:"
    echo "  bash $0                                    # Interactive menu"
    echo "  bash $0 install                            # Add node (interactive)"
    echo "  name=hk1 bash $0 install                   # Add Vision node with name"
    echo "  name=jp1 proto=xhttp bash $0 install       # Add XHTTP only node"
    echo "  name=sg1 proto=both bash $0 install        # Add Vision + XHTTP node"
    echo "  name=at1 proto=anytls bash $0 install      # Add AnyTLS node (self-signed)"
    echo "  name=ar1 proto=anytls-reality bash $0 install  # Add AnyTLS + REALITY node"
    echo "  name=hy2 proto=hysteria2 bash $0 install   # Add Hysteria2 UDP node"
    echo "  bash $0 tools                              # System tools menu"
    echo "  bash $0 ports                              # Port management"
    echo "  bash $0 logs                               # Log viewer"
    echo "  XRAY_CHANNEL=prerelease bash $0 xray-update  # Update including prereleases"
    echo "  XRAY_VERSION=v26.7.11 bash $0 xray-update    # Install a specified Xray version"
    echo ""
}

# ============== 主入口 ==============

# 加载语言设置
load_lang

# 如果没有语言设置且是交互模式，先选择语言
init_language_if_needed() {
    if [[ -z "$CURRENT_LANG" ]]; then
        select_language
    fi
}

# 单实例锁检查（对于可能冲突的操作）
check_lock_for_write_ops() {
    if lock_acquire_smart; then
        return 0
    fi
    local lock_path="${LOCK_FILE:-${LOCK_DIR:-unknown}}"
    local owner_pid="" liveness=0
    owner_pid=$(lock_recorded_pid) || owner_pid=""
    log_error "$(msg script_running)"
    log_error "Lock path: $lock_path"
    if [[ -n "$owner_pid" ]]; then
        lock_pid_liveness "$owner_pid" || liveness=$?
        if ((liveness == 1)); then
            log_warn "$(msg lock_stale_hint) (PID $owner_pid)"
            log_warn "$(msg lock_stale_action) rm -rf -- $lock_path"
        elif ((liveness == 0)); then
            log_error "$(msg lock_owner_alive) (PID $owner_pid)"
        fi
    fi
    exit 1
}

case "${1:-}" in
    install)
        check_lock_for_write_ops
        init_language_if_needed
        cmd_install
        ;;
    list)
        init_language_if_needed
        cmd_list
        ;;
    info)
        init_language_if_needed
        cmd_info
        ;;
    qr)
        init_language_if_needed
        cmd_qr
        ;;
    status)
        init_language_if_needed
        cmd_status
        ;;
    health)
        init_language_if_needed
        cmd_health
        ;;
    remove)
        check_lock_for_write_ops
        init_language_if_needed
        cmd_remove
        ;;
    edit)
        check_lock_for_write_ops
        init_language_if_needed
        cmd_edit
        ;;
    restart)
        check_lock_for_write_ops
        init_language_if_needed
        cmd_restart
        ;;
    regenerate|regen)
        check_lock_for_write_ops
        init_language_if_needed
        cmd_regenerate
        ;;
    update-ip)
        check_lock_for_write_ops
        init_language_if_needed
        cmd_update_ip
        ;;
    uninstall)
        check_lock_for_write_ops
        init_language_if_needed
        cmd_uninstall
        ;;
    test-sni)
        init_language_if_needed
        cmd_test_sni
        ;;
    tools)
        check_lock_for_write_ops
        init_language_if_needed
        cmd_tools
        ;;
    warp)
        check_lock_for_write_ops
        init_language_if_needed
        cmd_warp
        ;;
    bbr)
        check_lock_for_write_ops
        init_language_if_needed
        cmd_bbr
        ;;
    swap)
        check_lock_for_write_ops
        init_language_if_needed
        cmd_swap
        ;;
    fail2ban)
        check_lock_for_write_ops
        init_language_if_needed
        cmd_fail2ban
        ;;
    timesync)
        check_lock_for_write_ops
        init_language_if_needed
        cmd_timesync
        ;;
    xray-restart|restart-schedule)
        check_lock_for_write_ops
        init_language_if_needed
        cmd_xray_restart
        ;;
    xray-version)
        cmd_xray_version
        ;;
    xray-update)
        check_lock_for_write_ops
        cmd_xray_update
        ;;
    ports)
        check_lock_for_write_ops
        init_language_if_needed
        cmd_ports
        ;;
    logs)
        init_language_if_needed
        cmd_logs
        ;;
    menu|"")
        check_lock_for_write_ops
        init_language_if_needed
        main_menu
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        show_help
        ;;
esac
# proxy-hub-bundle-manifest-v1
# header-bytes=536 header-sha256=3df1cad78a529b3a24d9a027c1dd8ca2941af51a0933a381cc6cefb6b0453533
# body-bytes=412593 body-sha256=bf11dca958a7b6b1a3bc0dcec00106bb24a3d58abc1d3fad5396f1d99d63ee46
# build-id=bf11dca958a7b6b1a3bc0dcec00106bb24a3d58abc1d3fad5396f1d99d63ee46
# module-count=11
# proxy-hub-bundle-end-v1
