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

# Safe load all config values from node file
# Usage: safe_load_node_config FILE
# Sets variables: NODE_NAME, PORT, UUID, SNI, PUBLIC_KEY, PRIVATE_KEY, SHORT_ID,
#                 PROTOCOL_TYPE, XHTTP_PORT, XHTTP_PATH, SERVER_IP, SERVER_IPV4, SERVER_IPV6,
#                 SS_METHOD, SS_PASSWORD, ANYTLS_PASSWORD, HY2_PASSWORD
safe_load_node_config() {
    local file="$1"

    [[ ! -f "$file" ]] && return 1

    # Reset all variables first
    NODE_NAME="" PORT="" UUID="" SNI="" PUBLIC_KEY="" PRIVATE_KEY="" SHORT_ID=""
    PROTOCOL_TYPE="" XHTTP_PORT="" XHTTP_PATH="" SERVER_IP="" SERVER_IPV4="" SERVER_IPV6=""
    SS_METHOD="" SS_PASSWORD="" ANYTLS_PASSWORD="" HY2_PASSWORD=""

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
