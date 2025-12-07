#!/bin/bash

# ============================================================
# CLOUD LOGGING TAGS
# ============================================================
SCRIPT_NAME="SNAPSHOT-CLEANUP"
log_info()  { echo "[INFO]  [$SCRIPT_NAME] $1"; }
log_warn()  { echo "[WARN]  [$SCRIPT_NAME] $1" >&2; }
log_error() { echo "[ERROR] [$SCRIPT_NAME] $1" >&2; }
log_stage() {
    echo ""
    echo "==============================="
    echo "[STAGE] [$SCRIPT_NAME] $1"
    echo "Timestamp: $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    echo "==============================="
    echo ""
}

JOB_SUCCESS=0

log_stage "Starting Cleanup Job"

# ============================================================
# ENVIRONMENT VARIABLES
# ============================================================
API_KEY="${IBMCLOUD_API_KEY}"
REGION="us-south"
RESOURCE_GROUP_NAME="Default"
CLOUD_INSTANCE_ID="cc84ef2f-babc-439f-8594-571ecfcbe57a"
LPAR_NAME="empty-ibmi-lpar"
PVS_CRN="crn:v1:bluemix:public:power-iaas:dal10:a/21d74dd4fe814dfca20570bbb93cdbff:cc84ef2f-babc-439f-8594-571ecfcbe57a::"


# ============================================================
# STEP 1 — AUTHENTICATION
# ============================================================
log_stage "Authenticating and Targeting"
log_info "Logging into IBM Cloud..."

ibmcloud login --apikey "$API_KEY" -r "$REGION" > /dev/null 2>&1 \
    || { log_error "Authentication failed"; exit 1; }

ibmcloud target -g "$RESOURCE_GROUP_NAME" > /dev/null 2>&1 \
    || { log_error "Failed to set target group"; exit 1; }

ibmcloud pi workspace target "$PVS_CRN" > /dev/null 2>&1 \
    || { log_error "Failed to target workspace"; exit 1; }

log_info "Cloud authentication OK"


# ============================================================
# STEP 2 — IDENTIFY VOLUMES
# ============================================================
log_stage "Identifying Storage Volumes"

VOLUME_DATA=$(ibmcloud pi ins vol ls "$LPAR_NAME" --json 2>/dev/null || echo "[]")

if [[ "$VOLUME_DATA" == "[]" ]]; then
    log_error "No volume data discovered — exiting"
    exit 1
fi

BOOT_VOL=$(echo "$VOLUME_DATA" | jq -r '.volumes[] | select(.bootVolume==true) | .volumeID')
DATA_VOLS=$(echo "$VOLUME_DATA" | jq -r '.volumes[] | select(.bootVolume==false) | .volumeID' | paste -sd "," -)

log_info "Boot Volume: $BOOT_VOL"
log_info "Data Volumes: $DATA_VOLS"


# ============================================================
# STEP 3 — LOCATE SNAPSHOT BASED ON TIMESTAMP
# ============================================================
log_stage "Identifying Snapshot Associated to Clone"

BOOT_NAME=$(echo "$VOLUME_DATA" | jq -r ".volumes[] | select(.volumeID==\"$BOOT_VOL\") | .name")
TIMESTAMP=$(echo "$BOOT_NAME" | grep -oE '[0-9]{12}')

log_info "Extracted timestamp: $TIMESTAMP"

SNAP_JSON=$(ibmcloud pi instance snapshot ls --json || echo "{}")

MATCHING_SNAPSHOT_ID=$(echo "$SNAP_JSON" | jq -r ".snapshots[] | select(.name | contains(\"$TIMESTAMP\")) | .snapshotID" | head -n 1)

MATCHING_SNAPSHOT_NAME=$(echo "$SNAP_JSON" | jq -r ".snapshots[] | select(.name | contains(\"$TIMESTAMP\")) | .name" | head -n 1)

log_info "Snapshot found: $MATCHING_SNAPSHOT_ID — Name: $MATCHING_SNAPSHOT_NAME"


# ============================================================
# STEP 4 — SHUTDOWN LPAR
# ============================================================
log_stage "Shutting Down LPAR"

get_lpar_status() {
    ibmcloud pi ins get "$LPAR_NAME" --json | jq -r '.status'
}

STATUS=$(get_lpar_status | tr '[:lower:]' '[:upper:]')
log_info "Initial status: $STATUS"

if [[ "$STATUS" != "SHUTOFF" && "$STATUS" != "OFF" ]]; then
    log_info "Issuing immediate shutdown..."
    ibmcloud pi ins act "$LPAR_NAME" --operation immediate-shutdown || {
        log_warn "Immediate failed — issuing graceful stop"
        ibmcloud pi ins act "$LPAR_NAME" --operation stop \
            || { log_error "Shutdown failed"; exit 1; }
    }
else
    log_info "Shutdown skipped — already powered off"
fi


# ============================================================
# STEP 5 — DETACH ALL VOLUMES
# ============================================================
log_stage "Detaching Volumes"

check_volumes_detached() {
    VD=$(ibmcloud pi ins vol ls "$LPAR_NAME" --json || echo "{}")
    [[ -z $(echo "$VD" | jq -r '.volumes[]?') ]]
}

if ! check_volumes_detached; then
    log_info "Executing bulk detach..."

    ibmcloud pi ins vol bulk-detach "$LPAR_NAME" --detach-all --detach-primary || \
        log_warn "Bulk detach returned non-zero — proceeding anyway"

    WAIT=180
    ELAPSED=0

    while [[ $ELAPSED -lt $WAIT ]]; do
        if check_volumes_detached; then
            log_info "Volumes successfully detached"
            break
        fi

        log_info "Waiting... elapsed=${ELAPSED}s"
        sleep 20
        ELAPSED=$((ELAPSED+20))
    done
fi


# ============================================================
# STEP 6 — DELETE ALL VOLUMES
# ============================================================
log_stage "Deleting all storage volumes"

IFS=',' read -r -a DATA_ARRAY <<< "$DATA_VOLS"

log_info "Deleting boot volume $BOOT_VOL"
ibmcloud pi vol delete "$BOOT_VOL" || log_warn "Delete request returned non-zero"

for vol in "${DATA_ARRAY[@]}"; do
    [[ -z $vol ]] && continue
    log_info "Deleting data volume $vol"
    ibmcloud pi vol delete "$vol" || log_warn "Delete request returned non-zero"
done

check_vol_deleted() {
    ibmcloud pi vol get "$1" > /dev/null 2>&1 && return 1 || return 0
}


# Verify Boot deletion
ATTEMPTS=0
while [[ $ATTEMPTS -lt 120 ]]; do
    if check_vol_deleted "$BOOT_VOL"; then
        log_info "Boot volume deleted"
        break
    fi
    sleep 10
    ATTEMPTS=$((ATTEMPTS+10))
done


# ============================================================
# STEP 7 — DELETE SNAPSHOT
# ============================================================
log_stage "Deleting Snapshot"

check_snap_deleted() {
    ibmcloud pi instance snapshot get "$1" > /dev/null 2>&1 \
        && return 1 || return 0
}

log_info "Deleting snapshot $MATCHING_SNAPSHOT_NAME ($MATCHING_SNAPSHOT_ID)"
ibmcloud pi instance snapshot delete "$MATCHING_SNAPSHOT_ID" \
    || { log_error "Snapshot delete failed"; exit 7; }

SNAP_WAIT=120
ELAPSED=0

while [[ $ELAPSED -lt $SNAP_WAIT ]]; do
    if check_snap_deleted "$MATCHING_SNAPSHOT_ID"; then
        log_info "Snapshot deletion verified"
        break
    fi

    log_info "Waiting for snapshot deletion... elapsed=$ELAPSED"
    sleep 10
    ELAPSED=$((ELAPSED+10))
done


# ============================================================
# STEP 8 — OPTIONAL DELETE LPAR
# ============================================================
log_stage "Optional LPAR Deletion"

EXECUTE_LPAR_DELETE="${EXECUTE_LPAR_DELETE:-false}"

if [[ "$EXECUTE_LPAR_DELETE" != "true" ]]; then
    log_info "Skipping instance deletion — flag=${EXECUTE_LPAR_DELETE}"
    JOB_SUCCESS=1
else
    log_info "Deleting LPAR per user request..."

    ibmcloud pi ins delete "$LPAR_NAME" -f || {
        log_error "Deletion request rejected"
        exit 8
    }

    WAIT=300
    TIME=0

    while [[ $TIME -lt $WAIT ]]; do
        if ! ibmcloud pi ins get "$LPAR_NAME" >/dev/null 2>&1; then
            log_info "LPAR successfully deleted"
            break
        fi
        log_info "Verifying deletion... elapsed=$TIME"
        sleep 30
        TIME=$((TIME+30))
    done
    JOB_SUCCESS=1
fi


# ============================================================
# CLEAN EXIT
# ============================================================
log_stage "C_
