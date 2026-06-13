#!/bin/bash

# =============================================================================
# telegram.sh — Telegram notification helper for Oracle Cloud A1 War Script
#
# Source this file in oracle_cloud_instance_creator.sh:
#   source "${SCRIPT_DIR}/telegram.sh"
#
# Required env vars (loaded from .env):
#   TELEGRAM_ENABLED         — "true" to activate (default: false)
#   TELEGRAM_TOKEN           — Bot token from @BotFather
#   TELEGRAM_CHAT_ID         — Chat/group ID
#   TELEGRAM_NOTIFY_INTERVAL — Send status every N attempts (default: 100, 0 = disable)
#   TELEGRAM_SEND_KEY        — "true" to send encrypted SSH key on start (default: false)
#   GPG_PASSWORD             — Passphrase to encrypt the SSH key file with gpg
# =============================================================================

# ─────────────────────────────────────────────
# Internal: check if Telegram is active
# ─────────────────────────────────────────────
_telegram_enabled() {
    [[ "${TELEGRAM_ENABLED:-false}" == "true" ]]
}

# ─────────────────────────────────────────────
# Validate Telegram config (call once at startup)
# Returns 1 and logs a warning if misconfigured
# ─────────────────────────────────────────────
telegram_validate() {
    if ! _telegram_enabled; then
        return 0
    fi

    local ok=1
    if [[ -z "${TELEGRAM_TOKEN:-}" ]]; then
        echo "[WARN] TELEGRAM_ENABLED=true but TELEGRAM_TOKEN is not set." >&2
        ok=0
    fi
    if [[ -z "${TELEGRAM_CHAT_ID:-}" ]]; then
        echo "[WARN] TELEGRAM_ENABLED=true but TELEGRAM_CHAT_ID is not set." >&2
        ok=0
    fi
    if [[ "$ok" -eq 0 ]]; then
        echo "[WARN] Telegram notifications will be DISABLED for this run." >&2
        TELEGRAM_ENABLED="false"
        return 1
    fi

    # Quick connectivity test
    local response
    response=$(curl -s --max-time 10 \
        "https://api.telegram.org/bot${TELEGRAM_TOKEN}/getMe" 2>&1)
    if ! echo "$response" | grep -q '"ok":true'; then
        echo "[WARN] Telegram bot token appears invalid or unreachable. Notifications disabled." >&2
        echo "[WARN] Response: $response" >&2
        TELEGRAM_ENABLED="false"
        return 1
    fi

    return 0
}

# ─────────────────────────────────────────────
# Send a plain/Markdown text message
# Usage: send_telegram_message "text here"
# FIX: Use --data-urlencode so special chars and real newlines are sent correctly
# ─────────────────────────────────────────────
send_telegram_message() {
    _telegram_enabled || return 0

    local message="$1"
    local response
    response=$(curl -s --max-time 15 -X POST \
        "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=${message}" \
        -d "parse_mode=Markdown" 2>&1)

    if ! echo "$response" | grep -q '"ok":true'; then
        echo "[WARN] Telegram sendMessage failed: $response" >&2
        return 1
    fi
    return 0
}

# ─────────────────────────────────────────────
# Send a GPG-encrypted file to Telegram
# Usage: send_telegram_file "/path/to/private.key" "optional caption"
#
# Requires: gpg installed, GPG_PASSWORD set in .env
# FIX: Uses --output to write .gpg into /tmp (avoids CWD collision)
# The .gpg temp file is deleted immediately after upload.
# ─────────────────────────────────────────────
send_telegram_file() {
    _telegram_enabled || return 0

    local file_path="$1"
    local caption="${2:-Encrypted SSH Key Backup}"
    # FIX: write temp file to /tmp, not next to source (CWD-independent)
    local gpg_file="/tmp/$(basename "${file_path}").gpg"

    # Validate GPG password
    if [[ -z "${GPG_PASSWORD:-}" ]]; then
        send_telegram_message "⚠️ *Backup Failed:* GPG_PASSWORD is not set in .env!"
        return 1
    fi

    # Validate source file exists
    if [[ ! -f "$file_path" ]]; then
        send_telegram_message "⚠️ *Backup Failed:* File \`${file_path}\` not found!"
        return 1
    fi

    # Check gpg is installed
    if ! command -v gpg &>/dev/null; then
        send_telegram_message "⚠️ *Backup Failed:* \`gpg\` is not installed on this system!"
        return 1
    fi

    # FIX: --output explicitly sets destination; avoids CWD ambiguity
    if ! echo "${GPG_PASSWORD}" | gpg --batch --yes --passphrase-fd 0 \
            -c --output "$gpg_file" "$file_path" 2>&1; then
        send_telegram_message "⚠️ *Backup Failed:* GPG encryption error on \`${file_path}\`!"
        rm -f "$gpg_file"
        return 1
    fi

    # Send encrypted file
    local response
    response=$(curl -s --max-time 60 -X POST \
        "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendDocument" \
        -F "chat_id=${TELEGRAM_CHAT_ID}" \
        -F "document=@${gpg_file};filename=$(basename "${file_path}").gpg" \
        -F "caption=${caption}" 2>&1)

    # FIX: Always clean up temp file regardless of upload result
    rm -f "$gpg_file"

    if echo "$response" | grep -q '"ok":true'; then
        send_telegram_message "$(printf '✅ *SSH Key Backup Successful!*\n\n🔐 Sent encrypted (GPG)\n📄 File: `%s`\n🔑 Decrypt with: `gpg -d %s.gpg`' \
            "$(basename "$file_path")" "$(basename "$file_path")")"
        return 0
    else
        send_telegram_message "$(printf '⚠️ *Upload to Telegram Failed!*\nGPG encryption succeeded but upload failed.\nResponse: `%s`' \
            "${response:0:200}")"
        return 1
    fi
}

# ─────────────────────────────────────────────
# Send periodic status update every N attempts
# Usage: telegram_notify_periodic $attempt $max_label
# Only sends when attempt % TELEGRAM_NOTIFY_INTERVAL == 0
# ─────────────────────────────────────────────
telegram_notify_periodic() {
    _telegram_enabled || return 0

    local attempt=$1
    local max_label="${2:-INF}"
    local interval="${TELEGRAM_NOTIFY_INTERVAL:-100}"

    # Disabled if interval is 0
    [[ "$interval" -le 0 ]] && return 0

    # Only fire on multiples of interval
    [[ $((attempt % interval)) -ne 0 ]] && return 0

    send_telegram_message "$(printf '📊 *Oracle ARM War — Status Update*\n\n🔄 Attempt: *#%s* / %s\n⏰ Time: `%s`\n📋 Status: Still retrying... ⚔️\n\n_Next update at attempt #%s_' \
        "$attempt" "$max_label" "$(date '+%Y-%m-%d %H:%M:%S')" "$((attempt + interval))")"
}

# ─────────────────────────────────────────────
# Notification helpers — called by main script
# ─────────────────────────────────────────────

telegram_notify_start() {
    _telegram_enabled || return 0
    local max_label="${1:-INF}"
    send_telegram_message "$(printf '🚀 *Oracle Cloud ARM War — Started!*\n\n⚙️ Spec: `%s` OCPU / `%s` GB RAM / `%s` GB disk\n📍 Region: `%s`\n🎯 Max retries: *%s*\n⏰ Started at: `%s`\n\n_Sit back and relax — I will notify you when we win!_ 🎯' \
        "${OCPU:-4}" "${MEMORY:-24}" "${BOOT_VOLUME:-100}" \
        "${AVAILABILITY_DOMAIN:-unknown}" "$max_label" \
        "$(date '+%Y-%m-%d %H:%M:%S')")"
}

telegram_notify_success() {
    _telegram_enabled || return 0
    local attempt=$1
    local instance_id="${2:-N/A}"
    local public_ip="${3:-N/A}"
    local private_key_path="${4:-}"

    send_telegram_message "$(printf '🎉 *WAR WON! Oracle ARM Instance Created!*\n\n✅ *Instance ID:* `%s`\n🌐 *Public IP:* `%s`\n💻 *SSH:* `ssh -i %s ubuntu@%s`\n🔄 *Attempts taken:* %s\n⏰ *Created at:* `%s`' \
        "$instance_id" "$public_ip" \
        "${private_key_path%.pub}" "$public_ip" \
        "$attempt" "$(date '+%Y-%m-%d %H:%M:%S')")"
}

telegram_notify_fatal() {
    _telegram_enabled || return 0
    local error_msg="$1"
    send_telegram_message "$(printf '❌ *FATAL ERROR — Script Stopped!*\n\n🚫 This error will not resolve by retrying.\n📋 Error: `%s`\n⏰ Time: `%s`\n\n_Please check your .env config or OCI IAM permissions._' \
        "${error_msg:0:300}" "$(date '+%Y-%m-%d %H:%M:%S')")"
}

telegram_notify_interrupted() {
    _telegram_enabled || return 0
    local attempt="${1:-unknown}"
    send_telegram_message "$(printf '⚠️ *Script Interrupted*\n\n🛑 Manually stopped after *%s* attempts.\n⏰ Time: `%s`' \
        "$attempt" "$(date '+%Y-%m-%d %H:%M:%S')")"
}

telegram_notify_war_lost() {
    _telegram_enabled || return 0
    local max_retries="$1"
    send_telegram_message "$(printf '💀 *WAR LOST — Max Retries Exhausted*\n\n🔄 Tried *%s* times with no success.\n⏰ Time: `%s`\n\n_Consider changing region or running again later._' \
        "$max_retries" "$(date '+%Y-%m-%d %H:%M:%S')")"
}
