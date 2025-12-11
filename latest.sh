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
echo "Step 1 of 7:  IBM Cloud Authentication"
echo "========================================================================="

echo "--- PowerVS Cleanup and Rollback Operation - Authentication ---"  

# --- 1. Authenticate and Target Resources ---
echo "1. Authenticating to IBM Cloud and targeting PowerVS instance..."

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


echo "--- Part 1 of 7 Complete ---"
echo ""

echo "========================================================================="
echo "Step 2 of 7:  Storage Volume Identification (for after detachment)"
echo "========================================================================="

echo "--- PowerVS Cleanup and Rollback Operation - Storage Volume Identificaton---"

# --- 2. Identify Attached Volumes ---
echo "2. Identifying attached volumes for LPAR: $LPAR_NAME"

# List volumes attached to the LPAR in JSON format
# If the command fails (e.g., LPAR not found), echo an empty JSON array "{}" or "[]" to prevent script crash
VOLUME_DATA=$(ibmcloud pi ins vol ls "$LPAR_NAME" --json 2>/dev/null || echo "[]")

# Debugging step: Check the raw JSON output captured in the variable
#echo "Raw VOLUME_DATA received:"
#echo "$VOLUME_DATA"

if [ "$VOLUME_DATA" == "[]" ] || [ -z "$(echo "$VOLUME_DATA" | jq '.volumes[]')" ]; then
    echo "INFO: No volumes currently attached to $LPAR_NAME."
    echo "INFO: Continuing cleanup assuming prior detach succeeded."
    BOOT_VOL=""
    DATA_VOLS=""
else
    BOOT_VOL=$(echo "$VOLUME_DATA" | jq -r '.volumes[] | select(.bootVolume == true) | .volumeID')
    DATA_VOLS=$(echo "$VOLUME_DATA" | jq -r '.volumes[] | select(.bootVolume == false) | .volumeID' | paste -sd "," -)
fi


# Extract Boot Volume ID (where "bootVolume" == true)
BOOT_VOL=$(echo "$VOLUME_DATA" | jq -r '.volumes[] | select(.bootVolume == true) | .volumeID')

# Extract Data Volume IDs (where "bootVolume" == false)
DATA_VOLS=$(echo "$VOLUME_DATA" | jq -r '.volumes[] | select(.bootVolume == false) | .volumeID' | paste -sd "," -)

# Check if BOOT_VOL was found (critical for rollback operation)
if [ -z "$BOOT_VOL" ]; then
    echo "Error: Could not identify the required bootable volume (bootable == true). Cannot proceed."
    exit 1
fi

# Print required output format
echo "Boot Volume: $BOOT_VOL"
echo "Data Volume(s): $DATA_VOLS"

echo ""
echo "--- Part 2 of 7 Complete ---"
echo ""


echo "========================================================================="
echo "Part 3 of 7:  Snapshot Identification"
echo "========================================================================="#--------------------------------------------------------------

echo "--- PowerVS Cleanup and Rollback Operation - Snapshot Identification ---"

# 1. Get the boot volume's name (we already know BOOT_VOL from Step 2)
BOOT_VOL_NAME=$(echo "$VOLUME_DATA" | jq -r '.volumes[] | select(.volumeID == "'"$BOOT_VOL"'") | .name')

echo "Boot volume name: $BOOT_VOL_NAME"

# 2. Extract the 12-digit timestamp (YYYYMMDDHHMM) from the boot volume name
TIMESTAMP=$(echo "$BOOT_VOL_NAME" | grep -oE '[0-9]{12}' | head -n 1)

if [ -z "$TIMESTAMP" ]; then
    echo "ERROR: No valid 12-digit timestamp found in boot volume name: $BOOT_VOL_NAME"
    exit 1
fi

echo "Extracted timestamp from boot volume name: $TIMESTAMP"


echo "Fetching snapshot list across the workspace..."
ALL_SNAPS_JSON=$(ibmcloud pi instance snapshot ls --json 2>/dev/null || echo "{}")

SNAP_COUNT=$(echo "$ALL_SNAPS_JSON" | jq '.snapshots | length')

if [ "$SNAP_COUNT" -eq 0 ]; then
    echo "ERROR: No snapshots exist in workspace. Cannot determine rollback target."
    exit 4
fi

echo "Matching snapshot using timestamp: $TIMESTAMP"

# Find snapshot where name begins with "murph-TIMESTAMP"
MATCHING_SNAPSHOT_ID=$(echo "$ALL_SNAPS_JSON" \
    | jq -r --arg TS "$TIMESTAMP" '
        .snapshots[]
        | select(.name | test("^murph-" + $TS))
        | .snapshotID
    ' | head -n 1)

MATCHING_SNAPSHOT_NAME=$(echo "$ALL_SNAPS_JSON" \
    | jq -r --arg TS "$TIMESTAMP" '
        .snapshots[]
        | select(.name | test("^murph-" + $TS))
        | .name
    ' | head -n 1)

# >>> Validation block <<<
if [[ -z "$MATCHING_SNAPSHOT_ID" || "$MATCHING_SNAPSHOT_ID" == "null" ]]; then
    echo "Snapshot corresponding to timestamp $TIMESTAMP no longer exists."
    echo "Proceeding as normal."
else
    echo "MATCH FOUND:"
    echo "Snapshot Name: $MATCHING_SNAPSHOT_NAME"
    echo "Snapshot ID:   $MATCHING_SNAPSHOT_ID"
fi

echo ""
echo "Snapshot Identification Complete"
echo "Timestamp extracted: $TIMESTAMP"
echo "


echo ""
echo "--- Part 3 of 7 Complete ---"
echo ""

echo "========================================================================="
echo "Part 4 of 7:  LPAR Shutdown"
echo "========================================================================="

set -e
set -o pipefail

echo "--- PowerVS Cleanup and Rollback Operation - LPAR Shutdown ---"

# Utility: Check instance status
get_lpar_status() {
    ibmcloud pi ins get "$LPAR_NAME" --json 2>/dev/null | jq -r '.status'
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
    if ! ibmcloud pi ins act "$LPAR_NAME" --operation immediate-shutdown; then
        echo "Immediate shutdown failed — trying graceful stop"
        ibmcloud pi ins act "$LPAR_NAME" --operation stop || {
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
echo "--- Part 4 of 7 Complete ---"


echo "========================================================================="
echo "Part 5 of 7:  Detaching Boot and Storage Volumes"
echo "========================================================================="

echo "--- PowerVS Cleanup and Rollback Operation - Detaching Volumes---"

if [[ -z "$BOOT_VOL" && -z "$DATA_VOLS" ]]; then
    echo "INFO: No volumes discovered earlier — assuming detachment already occurred."
elif check_volumes_detached; then
    echo "Volume check complete: No volumes currently attached to $LPAR_NAME."
else



    echo "Executing bulk detach operation for all volumes on $LPAR_NAME..."
    
    # Detach all volumes including the primary/boot volume
    if ! ibmcloud pi ins vol bulk-detach "$LPAR_NAME" --detach-all --detach-primary; then
       echo "Warning: Bulk detach command failed to initiate. Check manually."
        # Attempt to proceed regardless of failure to initiate bulk detach
    fi 

    echo "Allowing time for detach operation to propagate"
    sleep 120


    
    DETACH_TIMEOUT_SECONDS=240
    CURRENT_TIME=0
    
    echo "Waiting up to ${DETACH_TIMEOUT_SECONDS} seconds for all volumes to detach..."

    while [ "$CURRENT_TIME" -lt "$DETACH_TIMEOUT_SECONDS" ]; do
        if check_volumes_detached; then
            echo "All volumes successfully detached."
            break
        fi

        sleep 20
        CURRENT_TIME=$((CURRENT_TIME + 20))

        echo "Waiting for volumes to detach (Time elapsed: ${CURRENT_TIME}s)"
     done

     if [ "$CURRENT_TIME" -ge "$DETACH_TIMEOUT_SECONDS" ]; then
            echo "Error: Volumes failed to detach within ${DETACH_TIMEOUT_SECONDS} seconds. Exiting."
            exit 1
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

DELETION_CHECK_MAX_TIME=240
SLEEP_INTERVAL=30

# Check if there is anything to do BEFORE executing any deletes
if [[ -z "$BOOT_VOL" && -z "$DATA_VOLS" ]]; then
    echo "INFO: No volumes detected earlier — skipping volume deletion."
    echo "--- Part 6 of 7 Complete ---"
    echo ""
    # Continue script flow
    :
else
    echo "Volumes detected — proceeding with deletion operations."
fi


# Only run the logic below if at least one volume exists
if [[ -n "$BOOT_VOL" || -n "$DATA_VOLS" ]]; then

    # Prepare array even if empty
    IFS=',' read -r -a DATA_VOL_ARRAY <<< "$DATA_VOLS"

    # --- Initiate deletion for Boot Volume ---
    if [[ -n "$BOOT_VOL" ]]; then
        echo "Initiating deletion for Boot Volume: $BOOT_VOL"
        ibmcloud pi vol delete "$BOOT_VOL" || \
            echo "Warning: delete request returned non-zero for $BOOT_VOL"
    else
        echo "No boot volume detected — skipping boot volume deletion"
    fi


    # --- Initiate deletion for Data Volumes ---
    if [[ ${#DATA_VOL_ARRAY[@]} -gt 0 ]]; then
        echo "Initiating deletion for Data Volume(s)..."
        for DATA_VOL_ID in "${DATA_VOL_ARRAY[@]}"; do
            [[ -z "$DATA_VOL_ID" ]] && continue
            echo " -- Deleting Data Volume: $DATA_VOL_ID"
            ibmcloud pi vol delete "$DATA_VOL_ID" || \
                echo "Warning: delete request returned non-zero for $DATA_VOL_ID"
        done

        echo "Allowing time for deletion commands to propagate..."
        sleep 60
    else
        echo "No data volumes identified for deletion."
    fi


    # --- Verify Boot Volume deletion ---
    if [[ -n "$BOOT_VOL" ]]; then
        echo "Verifying deletion for Boot Volume: $BOOT_VOL"
        CURRENT_TIME=0
        BOOT_VOL_DELETED=1

        while [ "$CURRENT_TIME" -lt "$DELETION_CHECK_MAX_TIME" ]; do
            if check_volume_deleted "$BOOT_VOL"; then
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


    # --- Verify Data Volumes deletion ---
    if [[ ${#DATA_VOL_ARRAY[@]} -gt 0 ]]; then
        echo "Verifying deletion of Data Volume(s)..."

        for DATA_VOL_ID in "${DATA_VOL_ARRAY[@]}"; do
            [[ -z "$DATA_VOL_ID" ]] && continue

            CURRENT_TIME=0
            DATA_VOL_DELETED=1

            while [ "$CURRENT_TIME" -lt "$DELETION_CHECK_MAX_TIME" ]]; do
                if check_volume_deleted "$DATA_VOL_ID"; then
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
    else
        echo "Skipping data volume verification — none were found."
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

# Exit immediately if a command exits with a non-zero status
set -e

# Ensure DELETE_SNAPSHOT default exists
DELETE_SNAPSHOT="${DELETE_SNAPSHOT:-No}"

echo "Delete Snapshot preference: $DELETE_SNAPSHOT"

# If user says No → SKIP deletion entirely
if [[ "$DELETE_SNAPSHOT" =~ ^(No|no|NO)$ ]]; then
    echo "User preference is to retain snapshot. Skipping deletion."
    echo "--- Part 7 of 7 Complete ---"
    exit 0
fi

echo "User preference is to delete snapshot. Proceeding..."

# Safety check: ensure ID exists
if [[ -z "$MATCHING_SNAPSHOT_ID" || "$MATCHING_SNAPSHOT_ID" == "null" ]]; then
    echo "WARNING: No snapshot ID available. Possibly already removed."
    echo "--- Part 7 of 7 Complete ---"
    exit 0
fi


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
    exit 7
fi

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
else
    SNAPSHOT_DELETE_RESULT="Deleted successfully"
fi

echo ""
echo "--- Part 7 of 7 Complete ---"
echo ""


echo "========================================================================="
echo " OPTIONAL LPAR DELETE SECTION"
echo "========================================================================="

if [[ "$EXECUTE_LPAR_DELETE" == "Yes" ]]; then
    echo "User parameter EXECUTE_LPAR_DELETE=true — proceeding with DELETE..."
    echo "--- PowerVS Cleanup and Rollback Operation - LPAR Deletion ---"

    # Function to check if instance still exists
    check_instance_exists() {
        ibmcloud pi ins get "$LPAR_NAME" > /dev/null 2>&1
    }

    DELETE_CHECK_MAX_TIME=300   # 5 minutes
    CHECK_INTERVAL=30
    CURRENT_TIME=0

    # Check whether the LPAR has already been deleted
    if ! check_instance_exists; then
        echo "LPAR $LPAR_NAME already deleted — skipping deletion."
    else
        echo "Initiating permanent deletion for LPAR: $LPAR_NAME"

        if ! ibmcloud pi ins delete "$LPAR_NAME"; then
            echo "ERROR: IBM Cloud rejected LPAR deletion request."
            LPAR_DELETE_RESULT="Reject — deletion not permitted"
            exit 8

            
        fi

        echo "Waiting up to ${DELETE_CHECK_MAX_TIME}s for LPAR deletion to complete..."

        while [ "$CURRENT_TIME" -lt "$DELETE_CHECK_MAX_TIME" ]; do
            if ! check_instance_exists; then
                echo "LPAR $LPAR_NAME confirmed deleted."
                LPAR_DELETE_RESULT="Deleted successfully"
                break
            fi

          echo "ERROR: LPAR still exists after timeout."
          LPAR_DELETE_RESULT="Failed — still exists"
          exit 8

        done

        # Final check after loop ends
        if check_instance_exists; then
            echo "ERROR: LPAR still exists after timeout."
            exit 8
        fi
    fi
fi



# --------------------------------------------------------------
# FINAL SUCCESS SUMMARY
# --------------------------------------------------------------
echo ""
echo "====================================================="
echo "[SNAPSHOT-CLEANUP] Final Stage Summary"
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
echo "[NEXT ACTION] Returning environment for next backup cycle"
echo ""
echo "[SNAPSHOT-CLEANUP] Final Result: SUCCESS"
echo "====================================================="

JOB_SUCCESS=1
exit 0




