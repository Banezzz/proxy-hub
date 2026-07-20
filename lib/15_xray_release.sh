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
