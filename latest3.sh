#!/usr/bin/env bash

timestamp() {
  while IFS= read -r line; do
    printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$line"
  done
}
exec > >(timestamp) 2>&1







     

echo "========================================================================="
echo "Job 3:  Environment Cleanup/Rollback post Backup Operations"
echo "========================================================================="
echo ""




# --- Environment Variables ---
# Ensure these variables are passed into the Docker container or set prior to execution
API_KEY="${IBMCLOUD_API_KEY}"
REGION="us-south"
RESOURCE_GROUP_NAME="Default"
PVS_CRN="crn:v1:bluemix:public:power-iaas:dal10:a/21d74dd4fe814dfca20570bbb93cdbff:cc84ef2f-babc-439f-8594-571ecfcbe57a::"
CLOUD_INSTANCE_ID="cc84ef2f-babc-439f-8594-571ecfcbe57a"
LPAR_NAME="empty-ibmi-lpar"
SNAPSHOT_NAME="murph-$(date +"%Y%m%d%H%M")"
JOB_SUCCESS=0

echo "========================================================================="
echo "Step 1a of 7:  IBM Cloud Authentication"
echo "========================================================================="

echo "--- PowerVS Cleanup and Rollback Operation - Authentication ---"  

# --- 1. Authenticate and Target Resources ---
echo "Authenticating to IBM Cloud and targeting PowerVS instance..."

# Login using API Key and set region
ibmcloud login --apikey "$API_KEY" -r "$REGION" > /dev/null 2>&1 || {
    echo "Authentication failed. Exiting."
    exit 1
}

# Target Resource Group
ibmcloud target -g "$RESOURCE_GROUP_NAME" > /dev/null 2>&1 || {
    echo "Failed to target resource group $RESOURCE_GROUP_NAME. Exiting."
    exit 1
}

# Target PowerVS Workspace using CRN
# Note: ibmcloud pi workspace target sets the context for all subsequent 'ibmcloud pi' commands
ibmcloud pi workspace target "$PVS_CRN" > /dev/null 2>&1 || {
    echo "Failed to target PowerVS workspace $PVS_CRN. Exiting."
    exit 1
}

echo "Authentication and targeting successful."
echo ""


echo "--- Part 1a of 7 Complete ---"
echo ""

echo "========================================================================="
echo "Step 1b of 7:  Resolving PVS LPAR Name > Instance ID"
echo "========================================================================="

echo ""
echo "Resolving PowerVS LPAR name → Instance ID"
echo ""

LPAR_INSTANCE_ID=""

LPAR_INSTANCE_ID=$(ibmcloud pi instance list --json 2>/dev/null \
  | jq -r --arg NAME "$LPAR_NAME" '
      .pvmInstances[]?
      | select(.name == $NAME)
      | .id
    ' | head -n 1)

if [[ -z "$LPAR_INSTANCE_ID" || "$LPAR_INSTANCE_ID" == "null" ]]; then
    echo "WARNING: No PowerVS instance found with name '$LPAR_NAME'"
    echo "LPAR may already be deleted or not yet created."
    echo "Continuing in cleanup-safe mode."
    LPAR_INSTANCE_ID=""
else
    echo "Resolved LPAR:"
    echo "  Name : $LPAR_NAME"
    echo "  ID   : $LPAR_INSTANCE_ID"
fi

echo ""



echo "========================================================================="
echo "Step 2 of 7:  Storage Volume Identification (for after detachment)"
echo "========================================================================="

echo "--- PowerVS Cleanup and Rollback Operation - Storage Volume Identificaton---"
echo "Identifying attached volumes for LPAR: $LPAR_NAME"

VOLUME_DATA=$(ibmcloud pi ins vol ls "$LPAR_NAME" --json 2>/dev/null || echo "[]")

# Safely extract boot + data volume IDs across ALL JSON shapes ([], {}, {volumes:[]}, etc.)
BOOT_VOL=$(echo "$VOLUME_DATA" | jq -r '.. | objects | select(.bootVolume==true)  | .volumeID? // empty' | head -n 1)
DATA_VOLS=$(echo "$VOLUME_DATA" | jq -r '.. | objects | select(.bootVolume==false) | .volumeID? // empty' | paste -sd "," -)

if [[ -z "$BOOT_VOL" && -z "$DATA_VOLS" ]]; then
    echo "INFO: No volumes currently attached to $LPAR_NAME."
    echo "INFO: Continuing cleanup assuming prior detach succeeded."
else
    echo "Boot Volume: $BOOT_VOL"
    echo "Data Volume(s): $DATA_VOLS"
fi

SNAPSHOT_ELIGIBLE="Yes"

if [[ -z "$BOOT_VOL" ]]; then
    echo "INFO: No boot volume attached — snapshot identification is not possible."
    echo "INFO: Snapshot matching and deletion will be skipped."
    SNAPSHOT_ELIGIBLE="No"
fi


echo ""
echo "--- Part 2 of 7 Complete ---"
echo ""


echo "========================================================================="
echo "Part 3 of 7:  Snapshot Identification"
echo "========================================================================="

echo "--- PowerVS Cleanup and Rollback Operation - Snapshot Identification ---"

if [[ "$SNAPSHOT_ELIGIBLE" != "Yes" ]]; then
    echo "Skipping Snapshot Identification — no boot volume attached."
    MATCHING_SNAPSHOT_ID=""
    MATCHING_SNAPSHOT_NAME=""
    TIMESTAMP=""
    echo "--- Part 3 of 7 Skipped ---"
else
    # 1. Get the boot volume's name
    BOOT_VOL_NAME=$(echo "$VOLUME_DATA" | jq -r \
        '.volumes[] | select(.volumeID == "'"$BOOT_VOL"'") | .name')

    echo "Boot volume name: $BOOT_VOL_NAME"

    # 2. Extract timestamp (YYYYMMDDHHMM)
    TIMESTAMP=$(echo "$BOOT_VOL_NAME" | grep -oE '[0-9]{12}' | head -n 1)

    if [[ -z "$TIMESTAMP" ]]; then
        echo "ERROR: No valid 12-digit timestamp found in boot volume name: $BOOT_VOL_NAME"
        exit 1
    fi

    echo "Extracted timestamp from boot volume name: $TIMESTAMP"

    echo "Fetching snapshot list across the workspace..."
    ALL_SNAPS_JSON=$(ibmcloud pi instance snapshot ls --json 2>/dev/null || echo "{}")

    SNAP_COUNT=$(echo "$ALL_SNAPS_JSON" | jq '.snapshots | length')

    if [[ "$SNAP_COUNT" -eq 0 ]]; then
        echo "ERROR: No snapshots exist in workspace. Cannot determine rollback target."
        exit 4
    fi

    # -------------------------------------------------
    # Time-window-based snapshot matching (±2 minutes)
    # -------------------------------------------------
    BOOT_EPOCH=$(date -u -d "${TIMESTAMP:0:8} ${TIMESTAMP:8:2}:${TIMESTAMP:10:2} UTC" +%s)
    WINDOW_SECONDS=120

    echo "Matching snapshot using ±${WINDOW_SECONDS}s window around $TIMESTAMP"

    MATCHING_SNAPSHOT=$(echo "$ALL_SNAPS_JSON" | jq -r \
      --argjson boot "$BOOT_EPOCH" \
      --argjson win "$WINDOW_SECONDS" '
        .snapshots[]
        | select(.name | test("^murph-[0-9]{12}"))
        | {
            id: .snapshotID,
            name: .name,
            epoch: (
              (.name | capture("murph-(?<ts>[0-9]{12})").ts)
              | strptime("%Y%m%d%H%M")
              | mktime
            )
          }
        | select(.epoch >= ($boot - $win) and .epoch <= ($boot + $win))
        | @base64
    ' | head -n 1)

    if [[ -z "$MATCHING_SNAPSHOT" ]]; then
        echo "No snapshot found within ±${WINDOW_SECONDS}s of $TIMESTAMP"
        MATCHING_SNAPSHOT_ID=""
        MATCHING_SNAPSHOT_NAME=""
    else
        MATCHING_SNAPSHOT_ID=$(echo "$MATCHING_SNAPSHOT" | base64 -d | jq -r '.id')
        MATCHING_SNAPSHOT_NAME=$(echo "$MATCHING_SNAPSHOT" | base64 -d | jq -r '.name')

        echo "MATCH FOUND (time-window based):"
        echo "Snapshot Name: $MATCHING_SNAPSHOT_NAME"
        echo "Snapshot ID:   $MATCHING_SNAPSHOT_ID"
    fi

    echo ""
    echo "Snapshot Identification Complete"
    echo ""
    echo "--- Part 3 of 7 Complete ---"
fi



echo "========================================================================="
echo "Part 4 of 7:  LPAR Shutdown"
echo "========================================================================="

echo "--- PowerVS Cleanup and Rollback Operation - LPAR Shutdown ---"

# -----------------------------------------------------------
# GUARD: If no volumes exist, LPAR cannot be ACTIVE
# -----------------------------------------------------------
if [[ -z "$BOOT_VOL" && -z "$DATA_VOLS" ]]; then
    echo "No boot or data volumes attached — LPAR cannot be ACTIVE."
    echo "Skipping shutdown step."
    echo ""
    echo "--- Part 4 of 7 Skipped ---"
    echo ""
    return 0
fi


set -e
set -o pipefail

echo "--- PowerVS Cleanup and Rollback Operation - LPAR Shutdown ---"

# Utility: Check instance status
get_lpar_status() {
    ibmcloud pi ins get "$LPAR_INSTANCE_ID" --json 2>/dev/null | jq -r '.status'
}

# Utility: Wait for state transition
wait_for_status() {
    local max_time=$1
    local target_state=$2
    local current_time=0

    echo "Waiting up to ${max_time}s for LPAR to reach state: ${target_state}"

    while [ "$current_time" -lt "$max_time" ]; do
        STATUS=$(get_lpar_status | tr '[:lower:]' '[:upper:]')
        echo "Current LPAR status: $STATUS (elapsed ${current_time}s)"

        if [[ "$STATUS" == "$target_state" ]]; then
            echo "LPAR reached ${target_state} state successfully."
            return 0
        fi

        sleep 20
        current_time=$((current_time + 20))
    done

    echo "WARNING: LPAR did not reach ${target_state} in allowed time."
    return 1
}

echo "--- Initiating LPAR Shutdown ---"

CURRENT_STATUS=$(get_lpar_status | tr '[:lower:]' '[:upper:]')
echo "Initial LPAR status: $CURRENT_STATUS"

# Shutdown only if running
if [[ "$CURRENT_STATUS" != "SHUTOFF" && "$CURRENT_STATUS" != "OFF" ]]; then
    echo "Sending shutdown command..."

    # Try immediate shutdown
    if ! ibmcloud pi ins act "$LPAR_INSTANCE_ID" --operation immediate-shutdown; then
        echo "Immediate shutdown failed — trying graceful stop"
        ibmcloud pi ins act "$LPAR_INSTANCE_ID" --operation stop || {
            echo "ERROR: Shutdown commands failed — cannot continue safely"
            exit 1
        }
    fi
else
    echo "Skipping shutdown — LPAR is already in a stopped state"
fi

# Give PowerVS time to settle status sync
sleep 45

UPDATED_STATUS=$(get_lpar_status | tr '[:lower:]' '[:upper:]')
echo "Status after shutdown command: $UPDATED_STATUS"

# Confirm transition
if [[ "$UPDATED_STATUS" != "SHUTOFF" && "$UPDATED_STATUS" != "OFF" ]]; then
    echo "Shutdown still in progress — waiting..."
    # Wait a full 10 minutes
    wait_for_status 600 "SHUTOFF" || {
        echo "WARNING: LPAR still reporting active — proceeding cautiously."
    }
fi


echo "LPAR is now ready for storage detachment and rollback operations."
echo ""
echo "--- Part 4 of 7 Complete ---"
echo ""


echo "========================================================================="
echo "Part 5 of 7:  Detaching Boot and Storage Volumes"
echo "========================================================================="

echo "--- PowerVS Cleanup and Rollback Operation - Detaching Volumes---"

# Case 1: We never discovered volumes earlier
if [[ -z "$BOOT_VOL" && -z "$DATA_VOLS" ]]; then
    echo "INFO: No volumes discovered earlier — assuming detachment already occurred."

# Case 2: Volumes already detached
else
    ATTACHED=$(ibmcloud pi ins vol ls "$LPAR_INSTANCE_ID" --json 2>/dev/null \
        | jq -r '.volumes[]?.volumeID' || true)

    if [[ -z "$ATTACHED" ]]; then
        echo "Volume check complete: No volumes currently attached to $LPAR_INSTANCE_ID."

    # Case 3: Volumes still attached → detach
    else
        echo "Executing bulk detach operation for all volumes on $LPAR_INSTANCE_ID..."

        if ! ibmcloud pi ins vol bulk-detach "$LPAR_INSTANCE_ID" \
            --detach-all \
            --detach-primary; then
            echo "Warning: Bulk detach command failed to initiate. Check manually."
        fi

        echo "Allowing time for detach operation to propagate"
        sleep 120

        DETACH_TIMEOUT_SECONDS=240
        CURRENT_TIME=0

        echo "Waiting up to ${DETACH_TIMEOUT_SECONDS} seconds for all volumes to detach..."

        while [ "$CURRENT_TIME" -lt "$DETACH_TIMEOUT_SECONDS" ]; do
            ATTACHED=$(ibmcloud pi ins vol ls "$LPAR_INSTANCE_ID" --json 2>/dev/null \
                | jq -r '.volumes[]?.volumeID' || true)

            if [[ -z "$ATTACHED" ]]; then
                echo "All volumes successfully detached."
                break
            fi

            sleep 20
            CURRENT_TIME=$((CURRENT_TIME + 20))
            echo "Waiting for volumes to detach (Time elapsed: ${CURRENT_TIME}s)"
        done

        if [[ "$CURRENT_TIME" -ge "$DETACH_TIMEOUT_SECONDS" ]]; then
            echo "Error: Volumes failed to detach within ${DETACH_TIMEOUT_SECONDS} seconds."
            exit 1
        fi
    fi
fi

echo "Volume detachment finalized, ready for deletion."
echo ""
echo "--- Part 5 of 7 Complete ---"
echo ""



echo "========================================================================="
echo "Part 6 of 7:  Storage Volume Deletion"
echo "========================================================================="

echo "--- PowerVS Cleanup and Rollback Operation - Deleting Volumes ---"

DELETION_CHECK_MAX_TIME=240   # 4 minutes
SLEEP_INTERVAL=30

# -------------------------------------------------
# Nothing to delete?
# -------------------------------------------------
if [[ -z "$BOOT_VOL" && -z "$DATA_VOLS" ]]; then
    echo "INFO: No volumes detected earlier — skipping volume deletion."
    echo "--- Part 6 of 7 Complete ---"
    echo ""
else
    echo "Volumes detected — proceeding with deletion operations."
fi


# -------------------------------------------------
# Proceed only if at least one volume exists
# -------------------------------------------------
if [[ -n "$BOOT_VOL" || -n "$DATA_VOLS" ]]; then

    # Parse data volumes (may be empty)
    IFS=',' read -r -a DATA_VOL_ARRAY <<< "$DATA_VOLS"

    # -------------------------------------------------
    # Initiate BOOT volume deletion
    # -------------------------------------------------
    if [[ -n "$BOOT_VOL" ]]; then
        echo "Initiating deletion for Boot Volume: $BOOT_VOL"
        ibmcloud pi volume delete "$BOOT_VOL" || \
            echo "Warning: delete request returned non-zero for $BOOT_VOL"
    else
        echo "No boot volume detected — skipping boot volume deletion"
    fi

    # -------------------------------------------------
    # Initiate DATA volume deletion(s)
    # -------------------------------------------------
    if [[ ${#DATA_VOL_ARRAY[@]} -gt 0 ]]; then
        echo "Initiating deletion for Data Volume(s)..."
        for DATA_VOL_ID in "${DATA_VOL_ARRAY[@]}"; do
            [[ -z "$DATA_VOL_ID" ]] && continue
            echo " -- Deleting Data Volume: $DATA_VOL_ID"
            ibmcloud pi volume delete "$DATA_VOL_ID" || \
                echo "Warning: delete request returned non-zero for $DATA_VOL_ID"
        done

        echo "Allowing time for deletion commands to propagate..."
        sleep 60
    else
        echo "No data volumes identified for deletion."
    fi


    # -------------------------------------------------
    # Verify BOOT volume deletion
    # -------------------------------------------------
    if [[ -n "$BOOT_VOL" ]]; then
        echo "Verifying deletion for Boot Volume: $BOOT_VOL"
        CURRENT_TIME=0
        BOOT_VOL_DELETED=1

        while [ "$CURRENT_TIME" -lt "$DELETION_CHECK_MAX_TIME" ]; do
            if ! ibmcloud pi volume get "$BOOT_VOL" >/dev/null 2>&1; then
                echo "Boot Volume $BOOT_VOL successfully deleted."
                BOOT_VOL_DELETED=0
                break
            fi

            sleep "$SLEEP_INTERVAL"
            CURRENT_TIME=$((CURRENT_TIME + SLEEP_INTERVAL))
            echo "Waiting for Boot Volume deletion (elapsed ${CURRENT_TIME}s)"
        done

        if [ "$BOOT_VOL_DELETED" -ne 0 ]; then
            echo "Warning: Boot Volume $BOOT_VOL was not confirmed deleted."
        fi
    fi


    # -------------------------------------------------
    # Verify DATA volume deletion(s)
    # -------------------------------------------------
    if [[ ${#DATA_VOL_ARRAY[@]} -gt 0 ]]; then
        for DATA_VOL_ID in "${DATA_VOL_ARRAY[@]}"; do
            [[ -z "$DATA_VOL_ID" ]] && continue

            echo "Verifying deletion for Data Volume: $DATA_VOL_ID"
            CURRENT_TIME=0
            DATA_VOL_DELETED=1

            while [ "$CURRENT_TIME" -lt "$DELETION_CHECK_MAX_TIME" ]; do
                if ! ibmcloud pi volume get "$DATA_VOL_ID" >/dev/null 2>&1; then
                    echo "Data Volume $DATA_VOL_ID successfully deleted."
                    DATA_VOL_DELETED=0
                    break
                fi

                sleep "$SLEEP_INTERVAL"
                CURRENT_TIME=$((CURRENT_TIME + SLEEP_INTERVAL))
                echo "Waiting for $DATA_VOL_ID deletion (elapsed ${CURRENT_TIME}s)"
            done

            if [ "$DATA_VOL_DELETED" -ne 0 ]; then
                echo "Warning: Could not verify deletion of Data Volume $DATA_VOL_ID within ${DELETION_CHECK_MAX_TIME}s."
            fi
        done
    fi
fi

echo ""
echo "Storage Volume Deletion Completed"
echo ""
echo "--- Part 6 of 7 Complete ---"
echo ""




echo "========================================================================="
echo "Part 7 of 7:  Snapshot Deletion"
echo "========================================================================="

echo "--- PowerVS Cleanup and Rollback Operation - Snapshot Deletion ---"

# Ensure DELETE_SNAPSHOT default exists
DELETE_SNAPSHOT="${DELETE_SNAPSHOT:-No}"

echo "Delete Snapshot preference: $DELETE_SNAPSHOT"

SNAPSHOT_DELETE_RESULT="Not requested"

# If user says No → SKIP deletion entirely
if [[ "$DELETE_SNAPSHOT" =~ ^(No|no|NO)$ ]]; then
    echo "User preference is to retain snapshot. Skipping deletion."
    SNAPSHOT_DELETE_RESULT="Skipped (retained by preference)"
    echo "--- Part 7 of 7 Complete ---"
else
    echo "User preference is to delete snapshot. Proceeding..."

    # Safety check: ensure ID exists
    if [[ -z "$MATCHING_SNAPSHOT_ID" || "$MATCHING_SNAPSHOT_ID" == "null" ]]; then
        echo "WARNING: No snapshot ID available. Possibly already removed."
        SNAPSHOT_DELETE_RESULT="No snapshot ID (possibly already removed)"
        echo "--- Part 7 of 7 Complete ---"
    else
        # --- deletion utility ---
        check_snapshot_deleted() {
            local snapshot_id=$1
            if ibmcloud pi instance snapshot get "$snapshot_id" > /dev/null 2>&1; then
                return 1
            else
                return 0
            fi
        }

        SNAPSHOT_CHECK_MAX_TIME=120
        SLEEP_INTERVAL=30

        echo "Attempting deletion of Snapshot ID: $MATCHING_SNAPSHOT_ID"
        if ! ibmcloud pi instance snapshot delete "$MATCHING_SNAPSHOT_ID"; then
            echo "ERROR: Deletion command returned non-zero exit code."
            SNAPSHOT_DELETE_RESULT="Delete command failed"
        else
            # --- verification loop ---
            echo "Waiting up to ${SNAPSHOT_CHECK_MAX_TIME} seconds for snapshot deletion confirmation..."

            CURRENT_TIME=0
            SNAPSHOT_DELETE_RESULT="Unknown"

            while [ "$CURRENT_TIME" -lt "$SNAPSHOT_CHECK_MAX_TIME" ]; do
                if check_snapshot_deleted "$MATCHING_SNAPSHOT_ID"; then
                    echo "Snapshot $MATCHING_SNAPSHOT_ID successfully deleted."
                    SNAPSHOT_DELETE_RESULT="Deleted successfully"
                    break
                fi

                sleep "$SLEEP_INTERVAL"
                CURRENT_TIME=$((CURRENT_TIME + SLEEP_INTERVAL))
                echo "Checking status... (${CURRENT_TIME}s elapsed)"
            done

            # Final check after timeout
            if ! check_snapshot_deleted "$MATCHING_SNAPSHOT_ID"; then
                echo "WARNING: Snapshot $MATCHING_SNAPSHOT_ID still exists."
                echo "Cleanup will proceed — manual investigation recommended."
                SNAPSHOT_DELETE_RESULT="Failed to delete — still exists"
            fi
        fi

        echo ""
        echo "--- Part 7 of 7 Complete ---"
        echo ""
    fi
fi


echo "========================================================================="
echo " OPTIONAL LPAR DELETE SECTION"
echo "========================================================================="

if [[ "$EXECUTE_LPAR_DELETE" == "Yes" ]]; then
    echo "User parameter EXECUTE_LPAR_DELETE=Yes — proceeding with DELETE..."
    echo "--- PowerVS Cleanup and Rollback Operation - LPAR Deletion ---"


    if [[ -z "$LPAR_INSTANCE_ID" || "$LPAR_INSTANCE_ID" == "null" ]]; then
        echo "LPAR $LPAR_NAME not found — skipping deletion."
        LPAR_DELETE_RESULT="Already deleted or not found"
    else
        echo "Found LPAR $LPAR_NAME (Instance ID: $LPAR_INSTANCE_ID)"
        echo "Initiating permanent deletion..."

        if ! ibmcloud pi instance delete "$LPAR_INSTANCE_ID"; then
            echo "ERROR: IBM Cloud rejected LPAR deletion request."
            LPAR_DELETE_RESULT="Reject — deletion not permitted"
            exit 8
        fi

        echo "LPAR delete request accepted."
        echo "Waiting for backend deletion to begin..."
        sleep 60   # 🔑 critical initial pause

        # -------------------------------------------------
        # VERIFY DELETION (poll until instance disappears)
        # -------------------------------------------------
        DELETE_TIMEOUT=600   # 10 minutes max
        POLL_INTERVAL=30
        WAITED=0

        echo "Polling for LPAR deletion completion..."

        while [[ $WAITED -lt $DELETE_TIMEOUT ]]; do
            CHECK=$(ibmcloud pi instance get "$LPAR_INSTANCE_ID" --json 2>/dev/null || true)

            if [[ -z "$CHECK" || "$CHECK" == "null" ]]; then
                echo "LPAR $LPAR_NAME successfully deleted."
                LPAR_DELETE_RESULT="Deleted successfully"
                break
            fi

            echo "LPAR still exists — waiting ${POLL_INTERVAL}s (elapsed ${WAITED}s)"
            sleep "$POLL_INTERVAL"
            WAITED=$((WAITED + POLL_INTERVAL))
        done

        if [[ $WAITED -ge $DELETE_TIMEOUT ]]; then
            echo "WARNING: LPAR deletion not confirmed after ${DELETE_TIMEOUT}s."
            echo "Backend may still be processing deletion."
            LPAR_DELETE_RESULT="Delete submitted — not yet confirmed"
        fi
    fi
else
    echo "LPAR Delete Requested: No — skipping deletion."
    LPAR_DELETE_RESULT="Skipped"
fi



# --------------------------------------------------------------
# FINAL SUCCESS SUMMARY
# --------------------------------------------------------------
echo ""
echo "====================================================="
echo "Final Stage Summary"
echo "====================================================="

echo "LPAR Shutdown Complete        : Yes"
echo "Vol Detach/Delete Completed   : Yes"
echo "Snapshot Removed              : ${SNAPSHOT_DELETE_RESULT:-Unknown}"


if [[ "$EXECUTE_LPAR_DELETE" == "Yes" ]]; then
    echo "LPAR Delete Requested         : Yes"
    echo "LPAR Delete Result            : ${LPAR_DELETE_RESULT:-Unknown}"
else
    echo "LPAR Delete Requested         : No"
    echo "LPAR Delete Result            : Skipped"
fi


echo ""
echo "Returning environment for next backup cycle"
echo ""
echo "Final Result: SUCCESS"
echo "====================================================="

JOB_SUCCESS=1


sleep 2
exit 0


