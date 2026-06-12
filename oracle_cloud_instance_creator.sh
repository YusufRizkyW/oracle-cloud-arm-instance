#!/bin/bash
set -uo pipefail

# =============================================================================
# Oracle Cloud A1 Instance War Script
# Auto-retry instance creation until a free-tier ARM slot is available.
#
# Usage:
#   ./oracle_cloud_instance_creator.sh          # foreground
#   nohup ./oracle_cloud_instance_creator.sh &  # background
#
# Requires: oci-cli, .env file (see below), SSH public key
# =============================================================================

# ==================== CONFIG ====================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
LOG_FILE="${SCRIPT_DIR}/oci_a1_retry.log"
STATUS_FILE="${SCRIPT_DIR}/oci_a1_status.txt"

# Load Telegram helper functions
# shellcheck source=telegram.sh
source "${SCRIPT_DIR}/telegram.sh"

# Cooldown periods (seconds) — random range per error type
CAPACITY_COOLDOWN_MIN=120     CAPACITY_COOLDOWN_MAX=300    # Out of host capacity → 2-5 min
RATE_LIMIT_COOLDOWN_MIN=180  RATE_LIMIT_COOLDOWN_MAX=600  # 429 TooManyRequests  → 3-10 min
NETWORK_COOLDOWN_MIN=120      NETWORK_COOLDOWN_MAX=240     # Network/timeout      → 2-4 min
GENERIC_COOLDOWN_MIN=60      GENERIC_COOLDOWN_MAX=180     # Unknown errors       → 1-3 min

# ==================== LOGGING ====================
log()           { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
log_error()     { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" | tee -a "$LOG_FILE" >&2; }
update_status() { echo "$*" > "$STATUS_FILE"; }

# Random cooldown between min and max (inclusive)
random_cooldown() {
    local min=$1 max=$2
    local range=$((max - min + 1))
    echo $((RANDOM % range + min))
}

# ==================== FUNCTIONS ====================

load_env() {
    if [[ ! -f "$ENV_FILE" ]]; then
        log_error "Config not found: $ENV_FILE"
        exit 1
    fi

    source "$ENV_FILE"

    # Validate required variables
    local missing=()
    [[ -z "${TENANCY_ID:-}" ]]           && missing+=("TENANCY_ID")
    [[ -z "${IMAGE_ID:-}" ]]             && missing+=("IMAGE_ID")
    [[ -z "${SUBNET_ID:-}" ]]            && missing+=("SUBNET_ID")
    [[ -z "${AVAILABILITY_DOMAIN:-}" ]]  && missing+=("AVAILABILITY_DOMAIN")
    [[ -z "${PATH_TO_PUBLIC_SSH_KEY:-}" ]] && missing+=("PATH_TO_PUBLIC_SSH_KEY")

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required variables in $ENV_FILE: ${missing[*]}"
        exit 1
    fi

    # Optional variables with defaults
    OCPU="${OCPU:-4}"
    MEMORY="${MEMORY:-24}"
    BOOT_VOLUME="${BOOT_VOLUME:-100}"
    PROFILE="${PROFILE:-DEFAULT}"
    MAX_RETRIES="${MAX_RETRIES:-1000}"  # 0 = infinite

    # Telegram optional variables with defaults
    TELEGRAM_ENABLED="${TELEGRAM_ENABLED:-false}"
    TELEGRAM_NOTIFY_INTERVAL="${TELEGRAM_NOTIFY_INTERVAL:-100}"
    TELEGRAM_SEND_KEY="${TELEGRAM_SEND_KEY:-false}"

    log "Config loaded from $ENV_FILE"
    log "Target spec: ${OCPU} OCPU / ${MEMORY} GB RAM / ${BOOT_VOLUME} GB disk"
    if [[ "$MAX_RETRIES" -eq 0 ]]; then
        log "Max retries: INFINITE"
    else
        log "Max retries: $MAX_RETRIES"
    fi
}

check_ssh_key() {
    if [[ ! -f "$PATH_TO_PUBLIC_SSH_KEY" ]]; then
        log_error "SSH public key not found: $PATH_TO_PUBLIC_SSH_KEY"
        exit 1
    fi
    log "SSH key: $PATH_TO_PUBLIC_SSH_KEY"
}

check_connection() {
    log "Checking OCI connection..."
    if ! oci iam availability-domain list --profile "$PROFILE" > /dev/null 2>&1; then
        log_error "Connection to Oracle Cloud failed. Check your OCI CLI setup and config!"
        exit 1
    fi
    log "OCI connection OK"
}

create_instance() {
    local attempt=$1
    local max_label
    if [[ "$MAX_RETRIES" -eq 0 ]]; then max_label="INF"; else max_label="$MAX_RETRIES"; fi
    log "Attempt #${attempt}/${max_label} — ${OCPU} OCPU / ${MEMORY} GB / ${BOOT_VOLUME} GB disk"
    update_status "Attempt #${attempt}/${max_label} at $(date '+%Y-%m-%d %H:%M:%S')"

    local output exit_code=0

    output=$(oci compute instance launch \
        --no-retry \
        --auth api_key \
        --profile "$PROFILE" \
        --compartment-id "$TENANCY_ID" \
        --availability-domain "$AVAILABILITY_DOMAIN" \
        --shape VM.Standard.A1.Flex \
        --shape-config "{\"ocpus\": $OCPU, \"memoryInGBs\": $MEMORY}" \
        --image-id "$IMAGE_ID" \
        --subnet-id "$SUBNET_ID" \
        --display-name "a1-${OCPU}c${MEMORY}g-$(date +%s)" \
        --assign-public-ip true \
        --boot-volume-size-in-gbs "$BOOT_VOLUME" \
        --ssh-authorized-keys-file "$PATH_TO_PUBLIC_SSH_KEY" \
        --wait-for-state RUNNING \
        --max-wait-seconds 300 \
        2>&1) || exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        log "=========================================="
        log "SUCCESS! Instance created!"
        log "=========================================="
        log "$output"
        update_status "SUCCESS at $(date)"

        # Extract instance ID and fetch public IP
        # Uses POSIX-compatible grep + sed (no -P flag required)
        local instance_id public_ip
        instance_id=$(echo "$output" | grep -o '"id": *"[^"]*"' | head -1 | sed 's/"id": *"//;s/"$//')
        if [[ -n "$instance_id" ]]; then
            log "Instance ID: $instance_id"

            sleep 10
            local vnics_output
            vnics_output=$(oci compute instance list-vnics \
                --instance-id "$instance_id" \
                --profile "$PROFILE" 2>&1) || true
            public_ip=$(echo "$vnics_output" | grep -o '"public-ip": *"[^"]*"' | head -1 | sed 's/"public-ip": *"//;s/"$//')

            if [[ -n "$public_ip" ]]; then
                log "Public IP: $public_ip"
                log "SSH command: ssh -i ${PATH_TO_PUBLIC_SSH_KEY%.pub} ubuntu@$public_ip"
            fi
        fi

        telegram_notify_success "$attempt" "$instance_id" "$public_ip" "$PATH_TO_PUBLIC_SSH_KEY"
        return 0
    fi

    # Parse error type → adaptive random cooldown
    local cooldown
    if echo "$output" | grep -qi "Out of host capacity"; then
        cooldown=$(random_cooldown $CAPACITY_COOLDOWN_MIN $CAPACITY_COOLDOWN_MAX)
        log "Out of capacity — retry in ${cooldown}s (range: ${CAPACITY_COOLDOWN_MIN}-${CAPACITY_COOLDOWN_MAX}s)"
        sleep "$cooldown"
    elif echo "$output" | grep -qi "TooManyRequests\|429"; then
        cooldown=$(random_cooldown $RATE_LIMIT_COOLDOWN_MIN $RATE_LIMIT_COOLDOWN_MAX)
        log "Rate limited — backoff ${cooldown}s (range: ${RATE_LIMIT_COOLDOWN_MIN}-${RATE_LIMIT_COOLDOWN_MAX}s)"
        sleep "$cooldown"
    elif echo "$output" | grep -qi "network\|timeout\|connection"; then
        cooldown=$(random_cooldown $NETWORK_COOLDOWN_MIN $NETWORK_COOLDOWN_MAX)
        log "Network error — retry in ${cooldown}s (range: ${NETWORK_COOLDOWN_MIN}-${NETWORK_COOLDOWN_MAX}s)"
        sleep "$cooldown"
    elif echo "$output" | grep -qi "InvalidParameter\|LimitExceeded\|NotAuthorizedOrNotFound"; then
        log_error "Fatal error (won't auto-resolve): $output"
        update_status "FATAL ERROR at $(date)"
        telegram_notify_fatal "$output"
        exit 1
    else
        cooldown=$(random_cooldown $GENERIC_COOLDOWN_MIN $GENERIC_COOLDOWN_MAX)
        log_error "Unknown error — retry in ${cooldown}s (range: ${GENERIC_COOLDOWN_MIN}-${GENERIC_COOLDOWN_MAX}s)"
        log_error "$output"
        sleep "$cooldown"
    fi

    return 1
}

# ==================== MAIN ====================

# Graceful shutdown handler
trap 'log "Interrupted by signal"; update_status "Interrupted at $(date)"; telegram_notify_interrupted "$attempt"; exit 130' INT TERM

log "=========================================="
log "Oracle Cloud A1 War — Starting"
log "=========================================="

load_env
check_ssh_key
check_connection
update_status "War started at $(date)"

# ── Telegram: validate config, send start notification, backup SSH key ──
telegram_validate

if [[ "$MAX_RETRIES" -eq 0 ]]; then _max_label="INFINITE"; else _max_label="$MAX_RETRIES"; fi
telegram_notify_start "$_max_label"

if [[ "${TELEGRAM_SEND_KEY:-false}" == "true" ]]; then
    priv_key="${PATH_TO_PUBLIC_SSH_KEY%.pub}"
    log "Sending encrypted SSH key backup to Telegram..."
    send_telegram_file "$priv_key" "🔐 Oracle ARM Private Key Backup — $(date '+%Y-%m-%d %H:%M:%S')"
fi
# ────────────────────────────────────────────────────────────────────────

attempt=0
while true; do
    attempt=$((attempt + 1))

    # Check max retries (0 = infinite)
    if [[ "$MAX_RETRIES" -gt 0 && "$attempt" -gt "$MAX_RETRIES" ]]; then
        log_error "=========================================="
        log_error "WAR LOST — $MAX_RETRIES attempts exhausted"
        log_error "=========================================="
        update_status "FAILED at $(date) after $MAX_RETRIES attempts"
        telegram_notify_war_lost "$MAX_RETRIES"
        exit 1
    fi

    telegram_notify_periodic "$attempt" "${_max_label:-INF}"

    if create_instance "$attempt"; then
        log "=========================================="
        log "WAR WON after $attempt attempts!"
        log "=========================================="
        exit 0
    fi
done
