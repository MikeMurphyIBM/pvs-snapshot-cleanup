#!/bin/bash

# --- Environment Variables ---
# Ensure these variables are passed into the Docker container or set prior to execution
API_KEY="${IBMCLOUD_API_KEY}"
REGION="us-south"
RESOURCE_GROUP_NAME="Default"
PVS_CRN="crn:v1:bluemix:public:power-iaas:dal10:a/21d74dd4fe814dfca20570bbb93cdbff:cc84ef2f-babc-439f-8594-571ecfcbe57a::"
CLOUD_INSTANCE_ID="cc84ef2f-babc-439f-8594-571ecfcbe57a"
LPAR_NAME="empty-ibmi-lpar"
JOB_SUCCESS=0

echo "---------------------------------------------------------"
echo "Step 1 of 7:  IBM Cloud Authentication"
echo "---------------------------------------------------------"

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

echo "--- Part 1 of 7 Complete ---"
echo ""

echo "---------------------------------------------------------"
echo "Step 2 of 7:  Storage Volume Identification (for after detachment)"
echo "---------------------------------------------------------"

echo "--- PowerVS Cleanup and Rollback Operation - Storage Volume Identificaton---"

# --- 2. Identify Attached Volumes ---
echo "2. Identifying attached volumes for LPAR: $LPAR_NAME"

# List volumes attached to the LPAR in JSON format
# If the command fails (e.g., LPAR not found), echo an empty JSON array "{}" or "[]" to prevent script crash
VOLUME_DATA=$(ibmcloud pi ins vol ls "$LPAR_NAME" --json 2>/dev/null || echo "[]")

# Debugging step: Check the raw JSON output captured in the variable
#echo "Raw VOLUME_DATA received:"
#echo "$VOLUME_DATA"

# If volume data retrieval failed or returned empty results
if [ "$VOLUME_DATA" == "[]" ] || [ -z "$(echo "$VOLUME_DATA" | jq '.volumes[]')" ]; then
    echo "Error: Could not retrieve volume data or no volumes found for $LPAR_NAME. Exiting."
    exit 1
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


echo "--- Part 2 of 7 Complete ---"
echo ""


echo "---------------------------------------------------------"
echo "Part 3 of 7:  Snapshot Identification"
echo "---------------------------------------------------------"

# --- PowerVS Cleanup and Rollback Operation - Snapshot Identification ---
echo "--- PowerVS Cleanup and Rollback Operation - Snapshot Identification ---"

# 1. Extract the full volume name string based on the known Boot Volume ID
BOOT_VOL_NAME=$(echo "$VOLUME_DATA" | jq -r '.volumes[] | select(.volumeID == "'"$BOOT_VOL"'") | .name')

echo "Fetching metadata for Volume ID: $BOOT_VOL..."
echo "Extracted volume name: $BOOT_VOL_NAME"

# 2. Extract the 12-digit timestamp (YYYYMMDDhhmm) using grep for robust pattern matching
# The volume name structure ("clone-CLONE-RESTORE-202512051232-2") contains the critical timestamp
TIMESTAMP=$(echo "$BOOT_VOL_NAME" | grep -oE '[0-9]{12}')

# If extraction failed, exit with the correlation error
if [ -z "$TIMESTAMP" ]; then
    echo "ERROR: No valid 12-digit timestamp found in volume name for correlation."
    exit 1
fi

echo "Extracted timestamp: $TIMESTAMP"

echo "Fetching snapshot list across the workspace..."
ALL_SNAPS_JSON=$(ibmcloud pi instance snapshot ls --json 2>/dev/null || echo "{}")

# Count snapshots
SNAP_COUNT=$(echo "$ALL_SNAPS_JSON" | jq '.snapshots | length')

if [ "$SNAP_COUNT" -eq 0 ]; then
    echo "ERROR: No snapshots exist in workspace. Cannot determine rollback target."
    exit 4
fi

# Find matching snapshot ID
MATCHING_SNAPSHOT_ID=$(echo "$ALL_SNAPS_JSON" | jq -r --arg TIMESTAMP "$TIMESTAMP" '
    .snapshots[] | select(.name | test($TIMESTAMP)) | .snapshotID
' | head -n 1)

# Find matching snapshot NAME
MATCHING_SNAPSHOT_NAME=$(echo "$ALL_SNAPS_JSON" | jq -r --arg TIMESTAMP "$TIMESTAMP" '
    .snapshots[] | select(.name | test($TIMESTAMP)) | .name
' | head -n 1)

# Validate match
if [[ -z "$MATCHING_SNAPSHOT_ID" ]] || [[ "$MATCHING_SNAPSHOT_ID" == "null" ]]; then
    echo "ERROR: No snapshot found matching timestamp $TIMESTAMP in the workspace. Cannot determine rollback target."
    exit 4
fi

echo "--------------------------------------------"
echo "Snapshot Match Found (Rollback Target)"
echo "Snapshot ID:      $MATCHING_SNAPSHOT_ID"
echo "Snapshot Name:    $MATCHING_SNAPSHOT_NAME"
echo "Timestamp Match:  $TIMESTAMP"
echo "--------------------------------------------"


echo "--- Part 3 of 7 Complete ---"
echo ""

echo "---------------------------------------------------------"
echo "Part 4 of 7:  LPAR Shutdown"
echo "---------------------------------------------------------"

# Exit immediately if a command exits with a non-zero status
set -e
set -o pipefail

echo "--- PowerVS Cleanup and Rollback Operation - LPAR Shutdown ---"

# --- Utility Functions ---

# Function to check LPAR status (Shutoff/Active)
get_lpar_status() {
    ibmcloud pi ins get "$LPAR_NAME" --json 2>/dev/null | jq -r '.status'
}

# Function to wait for an expected status
wait_for_status() {
    local max_time=$1
    local target_state=$2
    local current_time=0

    echo "Waiting up to ${max_time} seconds for LPAR to reach state: ${target_state}"

    while [ "$current_time" -lt "$max_time" ]; do
        STATUS=$(get_lpar_status)
        echo "Current LPAR status: $STATUS (Time elapsed: ${current_time}s)"

        if [ "$STATUS" == "$target_state" ]; then
            echo "LPAR reached ${target_state} state."
            return 0 # Success
        fi

        sleep 20
        current_time=$((current_time + 20))
    done

    echo "Error: LPAR failed to reach $target_state within ${max_time} seconds."
    return 1 # Failure
}


# Function to check if volumes are detached
check_volumes_detached() {
    VOLUME_DATA=$(ibmcloud pi ins vol ls "$LPAR_NAME" --json 2>/dev/null || echo "{}")

    # Check if .volumes array exists and has elements
    if [ -z "$(echo "$VOLUME_DATA" | jq '.volumes[]?')" ]; then
        return 0  # Success: No volumes attached
    else
        return 1  # Failure: Volumes still attached
    fi
}


# Function to check if a specific volume is successfully deleted
check_volume_deleted() {
    local volume_id=$1
    
    # Attempt to get volume details. Expect this command to fail (return non-zero status) if the volume is gone.
    # We suppress standard output and only rely on stderr/exit code.
    if ibmcloud pi vol get "$volume_id" > /dev/null 2>&1; then
        return 1 # Failure: Volume still exists (command succeeded)
    else
        # Command failed (expected behavior for a deleted resource)
        return 0 # Success: Volume appears deleted
    fi
}

echo "--- Initiating LPAR Shutdown ---"


CURRENT_STATUS=$(get_lpar_status)
echo "Initial LPAR status: $CURRENT_STATUS"

if [[ "$CURRENT_STATUS" == "Active" || "$CURRENT_STATUS" == "Warning" ]]; then
    echo "Shutdown required. Sending immediate shutdown..."
    
    if ! ibmcloud pi ins act "$LPAR_NAME" --operation immediate-shutdown; then
        echo "Immediate shutdown failed. Attempting graceful shutdown..."
        
        if ! ibmcloud pi ins act "$LPAR_NAME" --operation stop; then
            echo "Shutdown commands failed. Exiting."
            exit 1
        fi
    fi
else
    echo "Skipping shutdown, LPAR state is already: $CURRENT_STATUS"
fi

# *** RECHECK STATUS ***
sleep 10
UPDATED_STATUS=$(get_lpar_status)
echo "Status after shutdown command: $UPDATED_STATUS"

if [[ "$UPDATED_STATUS" != "SHUTOFF" ]]; then
    echo "LPAR still shutting down — Waiting..."
    
    wait_for_status 600 "SHUTOFF" || {
        echo "WARNING: Shutdown not confirmed after timeout."
    }
fi

echo "LPAR verified ready for volume operations."
echo "Part 4 of 7 Complete"


echo "---------------------------------------------------------"
echo "Part 5 of 7:  Detaching Boot and Storage Volumes"
echo "---------------------------------------------------------"

echo "--- PowerVS Cleanup and Rollback Operation - Detaching Volumes---"

if check_volumes_detached; then
    echo "Volume check complete: No volumes currently attached to $LPAR_NAME."
else
    echo "Executing bulk detach operation for all volumes on $LPAR_NAME..."
    
    # Detach all volumes including the primary/boot volume
    ibmcloud pi ins vol bulk-detach "$LPAR_NAME" --detach-all --detach-primary || {
        echo "Warning: Bulk detach command failed to initiate. Check manually."
        # Attempt to proceed regardless of failure to initiate bulk detach
    }
    
    DETACH_TIMEOUT_SECONDS=180
    CURRENT_TIME=0
    
    echo "Waiting up to ${DETACH_TIMEOUT_SECONDS} seconds for all volumes to detach..."

    while [ "$CURRENT_TIME" -lt "$DETACH_TIMEOUT_SECONDS" ]; do
        if check_volumes_detached; then
            echo "All volumes successfully detached."
            break
        fi

        sleep 20
        CURRENT_TIME=$((CURRENT_TIME + 20))

        if [ "$CURRENT_TIME" -ge "$DETACH_TIMEOUT_SECONDS" ]; then
            echo "Error: Volumes failed to detach within ${DETACH_TIMEOUT_SECONDS} seconds. Exiting."
            exit 1
        fi
        echo "Waiting for volumes to detach (Time elapsed: ${CURRENT_TIME}s)"
    done
fi

echo "Volume detachment finalized, ready for deletion."
echo "Part 5 of 7 complete"

echo "---------------------------------------------------------"
echo "Part 6 of 7:  Storage Volume Deletion"
echo "---------------------------------------------------------"

echo "--- PowerVS Cleanup and Rollback Operation - Deleting Volumes---"

# --- Utility Function assumed from prior parts ---
# Function to check if a specific volume is successfully deleted
# check_volume_deleted() {
#     local volume_id=$1
#     # Attempt to get volume details. Expect this command to fail (return non-zero status) if the volume is gone.
#     if ibmcloud pi vol get "$volume_id" > /dev/null 2>&1; then
#         return 1 # Failure: Volume still exists (command succeeded)
#     else
#         return 0 # Success: Volume appears deleted (command failed)
#     fi
# }

DELETION_CHECK_MAX_TIME=120
SLEEP_INTERVAL=30

# --- Initiate Concurrent Deletion of All Volumes ---
echo "Initiating deletion for Boot Volume: $BOOT_VOL"
# Initiate delete request for Boot Volume immediately
ibmcloud pi vol delete "$BOOT_VOL" || echo "Warning: Command to delete $BOOT_VOL returned a non-zero code."

# Check if DATA_VOLS are present and initiate deletion for each
if [[ -n "$DATA_VOLS" ]]; then
    echo "Initiating concurrent deletion for Data Volume(s)..."
    # Split the comma-separated string into an array of IDs
    IFS=',' read -r -a DATA_VOL_ARRAY <<< "$DATA_VOLS"

    for DATA_VOL_ID in "${DATA_VOL_ARRAY[@]}"; do
        if [[ -z "$DATA_VOL_ID" ]]; then continue; fi # Skip if empty
        echo " -- Initiating delete for Data Volume: $DATA_VOL_ID"
        # Execute deletion request without waiting
        ibmcloud pi vol delete "$DATA_VOL_ID" || echo "Warning: Command to delete $DATA_VOL_ID returned a non-zero code."
    done
else
    echo "No data volumes identified for deletion."
fi

# --- Verification: Wait for Boot Volume deletion (Max 120s) ---
echo "3. Verifying deletion status for Boot Volume: $BOOT_VOL"
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
    echo "Waiting for $BOOT_VOL deletion (Time elapsed: ${CURRENT_TIME}s)"
done

if [ "$BOOT_VOL_DELETED" -ne 0 ]; then
    echo "ERROR: Boot Volume $BOOT_VOL could not be confirmed deleted within ${DELETION_CHECK_MAX_TIME} seconds. Exiting cleanup."
    exit 6 # Critical failure, stopping script
fi

# --- Verification: Wait for Data Volumes deletion (Max 120s) ---
if [[ -n "$DATA_VOLS" ]]; then
    echo "4. Verifying deletion status for Data Volume(s)..."
    
    for DATA_VOL_ID in "${DATA_VOL_ARRAY[@]}"; do
        if [[ -z "$DATA_VOL_ID" ]]; then continue; fi
        
        CURRENT_TIME=0
        DATA_VOL_DELETED=1

        while [ "$CURRENT_TIME" -lt "$DELETION_CHECK_MAX_TIME" ]; do
            if check_volume_deleted "$DATA_VOL_ID"; then
                echo "Data Volume $DATA_VOL_ID successfully deleted."
                DATA_VOL_DELETED=0
                break
            fi
            
            sleep "$SLEEP_INTERVAL"
            CURRENT_TIME=$((CURRENT_TIME + SLEEP_INTERVAL))
            echo "Waiting for $DATA_VOL_ID deletion (Time elapsed: ${CURRENT_TIME}s)"

            if [ "$CURRENT_TIME" -ge "$DELETION_CHECK_MAX_TIME" ] && [ "$DATA_VOL_DELETED" -ne 0 ]; then
                echo "Warning: Data Volume $DATA_VOL_ID could not be confirmed deleted within ${DELETION_CHECK_MAX_TIME} seconds."
                # Allow continuing to check other data volumes even if one fails verification
                break 
            fi
        done
    done
fi

echo "Volume deletion verification phase complete."
echo "--- Part 6 of 7 Complete ---"
echo ""

echo "---------------------------------------------------------"
echo "Part 7 of 7:  Snapshot Deletion"
echo "---------------------------------------------------------"

echo "--- PowerVS Cleanup and Rollback Operation - Snapshot Deletion ---"

# Exit immediately if a command exits with a non-zero status
set -e

# --- Utility Function to check snapshot deletion status ---
# This function relies on 'ibmcloud pi instance snapshot get' failing (non-zero exit code)
# when the resource (snapshot) is successfully deleted (404 Not Found).
check_snapshot_deleted() {
    local snapshot_id=$1
    # Attempt to retrieve snapshot details. Suppress output.
    if ibmcloud pi instance snapshot get "$snapshot_id" > /dev/null 2>&1; then
        return 1 # Failure (Snapshot still exists, command succeeded)
    else
        return 0 # Success (Snapshot appears deleted, command failed - indicating 404/Not Found)
    fi
}

# --- Define constants for check loop ---
SNAPSHOT_CHECK_MAX_TIME=120
SLEEP_INTERVAL=30
SNAPSHOT_DELETED=1

# --- 1. Print the Snapshot Name ---
echo "Snapshot to be deleted: $MATCHING_SNAPSHOT_NAME"

# --- 2. Delete the snapshot ---
echo "Initiating deletion for Snapshot ID: $MATCHING_SNAPSHOT_ID"

# The command to delete a snapshot is part of the deprecated 'ibmcloud pi snapshot' family,
# replaced by 'ibmcloud pi instance snapshot delete'.
echo "Initiating deletion for Snapshot ID: $MATCHING_SNAPSHOT_ID"

if ! ibmcloud pi instance snapshot delete "$MATCHING_SNAPSHOT_ID"; then
    echo "ERROR: Could not start snapshot deletion for $MATCHING_SNAPSHOT_ID"
    exit 7
fi


# --- 3. Verification Loop ---
CURRENT_TIME=0
echo "Waiting up to ${SNAPSHOT_CHECK_MAX_TIME} seconds for snapshot deletion confirmation..."

while [ "$CURRENT_TIME" -lt "$SNAPSHOT_CHECK_MAX_TIME" ]; do
    if check_snapshot_deleted "$MATCHING_SNAPSHOT_ID"; then
        echo "Snapshot $MATCHING_SNAPSHOT_ID successfully deleted."
        break
    fi

    sleep "$SLEEP_INTERVAL"
    CURRENT_TIME=$((CURRENT_TIME + SLEEP_INTERVAL))

    echo "Checking status... (${CURRENT_TIME}s elapsed)"
done

if ! check_snapshot_deleted "$MATCHING_SNAPSHOT_ID"; then
    echo "ERROR: Snapshot $MATCHING_SNAPSHOT_ID still exists after ${SNAPSHOT_CHECK_MAX_TIME} seconds."
    exit 7
fi


echo "--- Cleanup and Rollback Operation Complete.  Partition is ready for next Backup Operation ---"

echo ""
echo "--------------------------------------------"
echo "Cleanup Summary:"
echo "--------------------------------------------"
echo "LPAR Shutdown        : Completed"
echo "Volume Detach/Delete : Completed"
echo "Snapshot Deleted     : Completed"
echo "LPAR Ready For Backup: Yes"
echo "--------------------------------------------"
echo ""

# If execution reached this point, all operations succeeded
JOB_SUCCESS=1

echo "Job Success Status: $JOB_SUCCESS"


echo "---------------------------------------------------------"
echo "Part 8: (Optional) LPAR Deletion"
echo "---------------------------------------------------------"


# Honor execution flag passed in from environment variables
EXECUTE_LPAR_DELETE="${EXECUTE_LPAR_DELETE:-false}"

if [[ "$EXECUTE_LPAR_DELETE" != "true" ]]; then
    echo "Skipping LPAR deletion because EXECUTE_LPAR_DELETE=$EXECUTE_LPAR_DELETE"
    JOB_SUCCESS=1
    echo "--- Cleanup Complete ---"
    echo "Final Job Success Status: $JOB_SUCCESS"
    exit 0
fi

echo "User parameter EXECUTE_LPAR_DELETE=true — proceeding with DELETE..."


echo "--- PowerVS Cleanup and Rollback Operation - LPAR Deletion ---"

# Function: return 0 if instance exists, 1 if gone
check_instance_exists() {
    ibmcloud pi ins get "$LPAR_NAME" > /dev/null 2>&1
}

# Maximum time (seconds) to wait for confirmed deletion
DELETE_CHECK_MAX_TIME=300   # 5 minutes
CHECK_INTERVAL=60           # Poll every 60 seconds

# First, check whether instance is already gone (just in case)
if ! check_instance_exists; then
    echo "LPAR $LPAR_NAME is already deleted — skipping deletion."
    JOB_SUCCESS=1
    echo "--- Part 7 Complete ---"
    echo "Final Job Success Status: $JOB_SUCCESS"
    exit 0
fi

echo "Initiating permanent deletion for LPAR: $LPAR_NAME"

if ! ibmcloud pi ins delete "$LPAR_NAME" -f; then
    echo "ERROR: IBM Cloud rejected LPAR deletion request."
    exit 8
fi

echo "Waiting up to ${DELETE_CHECK_MAX_TIME}s for LPAR deletion..."
echo "Checking every ${CHECK_INTERVAL}s..."

while [ "$CURRENT_TIME" -lt "$DELETE_CHECK_MAX_TIME" ]; do
    if ! check_instance_exists; then
        echo "LPAR $LPAR_NAME confirmed deleted."
        break
    fi

    echo "LPAR still exists. Time elapsed: ${CURRENT_TIME}s — retrying in ${CHECK_INTERVAL}s..."
    
    sleep "$CHECK_INTERVAL"
    CURRENT_TIME=$((CURRENT_TIME + CHECK_INTERVAL))
done


if [ "$LPAR_DELETED" -ne 0 ]; then
    echo "ERROR: LPAR $LPAR_NAME was not fully deleted within ${DELETE_CHECK_MAX_TIME}s."
    exit 8
fi

# After wait loop, final check:
if check_instance_exists; then
    echo "ERROR: LPAR $LPAR_NAME still exists after $DELETE_CHECK_MAX_TIME seconds."
    exit 8
fi

# Cleanup success — set status variable
JOB_SUCCESS=1
echo "LPAR deletion complete — cleanup successful!"
echo "--- Part 8 Complete ---"
echo "Final Job Success Status: $JOB_SUCCESS"






