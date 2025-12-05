#!/bin/bash

# --- Environment Variables ---
API_KEY="${IBMCLOUD_API_KEY}"    # IAM API Key stored in Code Engine Secret
REGION="us-south"                # IBM Cloud Region
RESOURCE_GROP_NAME="Default"     # Targeted Resource Group
PVS_CRN="crn:v1:bluemix:public:power-iaas:dal10:a/21d74dd4fe814dfca20570bbb93cdbff:cc84ef2f-babc-439f-8594-571ecfcbe57a::" # Full PowerVS Workspace CRN
CLOUD_INSTANCE_ID="cc84ef2f-babc-439f-8594-571ecfcbe57a" # PowerVS Workspace ID
LPAR_NAME="empty-ibmi-lpar"      # Name of the target LPAR
JOB_SUCCESS=0 # Default to failure for safety in case of crash

# --- Dynamic Variables (Populated during Discovery) ---
CLONE_BOOT_ID=""
CLONE_DATA_IDS=""
ALL_CLONE_IDS=""
SNAPSHOT_ID=""
SNAPSHOT_TIME_REF=""

# --- Configuration ---
POLL_INTERVAL=60 # seconds
MAX_POLL_ITERATIONS=20 # Max 20 minutes for LPAR shutdown, adjustment applied later for volume detach

# ================================================================
echo "--- CRITICAL CLEANUP: PowerVS Resource Rollback Started ---"
# ================================================================

# ----------------------------------------------------------------
# PHASE 0: Authentication and Resource Discovery
# ----------------------------------------------------------------

echo "1. Authenticating and targeting workspace: $PVS_CRN in $REGION..."
ibmcloud login --apikey "$API_KEY" -r "$REGION" -g "$RESOURCE_GROP_NAME" > /dev/null
ibmcloud pi ws target "$PVS_CRN"

echo "2. Identifying attached volumes on LPAR: $LPAR_NAME"

# List volumes attached to the LPAR. The failover '|| echo "[]"' handles CLI command failure (exit code > 0).
# VOLUME_DATA still needs robust parsing in case the command succeeds but returns empty/null attachments array.
VOLUME_DATA=$(ibmcloud pi instance volume list "$LPAR_NAME" --json 2>/dev/null || echo "{}")

# --- Improved Robust Parsing using jq ---

# 1. Extract Boot Volume ID(s): Filters for bootable == true.
#    Logic: Check if .volumeAttachments exists AND is an array. If so, iterate over elements; otherwise, use empty.
CLONE_BOOT_ID=$(echo "$VOLUME_DATA" | jq -r '
    .volumeAttachments | 
    if type == "array" then .[] else empty end
    | select(.volume.bootable == true)
    | .volume.volumeID
' | paste -sd ',' - || true | sed 's/^,\|,$//')

# 2. Extract Data Volume ID(s): Filters for bootable == false.
CLONE_DATA_IDS=$(echo "$VOLUME_DATA" | jq -r '
    .volumeAttachments | 
    if type == "array" then .[] else empty end
    | select(.volume.bootable == false)
    | .volume.volumeID
' | paste -sd ',' - || true | sed 's/^,\|,$//')


# --- Remaining logic (combining IDs and extracting Snapshot Time Reference) ---

# Combine all IDs for final deletion (uses volume IDs)
ALL_CLONE_IDS="${CLONE_BOOT_ID}"
if [[ -n "$CLONE_DATA_IDS" ]]; then
    # Ensure there is a comma only if CLONE_BOOT_ID exists
    if [[ -n "$CLONE_BOOT_ID" ]]; then
        ALL_CLONE_IDS="${ALL_CLONE_IDS},${CLONE_DATA_IDS}"
    else
        ALL_CLONE_IDS="${CLONE_DATA_IDS}"
    fi
fi
ALL_CLONE_IDS=$(echo "$ALL_CLONE_IDS" | sed 's/^,\|,$//;s/,,/,/g')

echo "Discovered Boot ID: ${CLONE_BOOT_ID:-N/A}"
echo "Discovered Data IDs: ${CLONE_DATA_IDS:-N/A}"
echo "All Volume IDs for deletion: ${ALL_CLONE_IDS}"

# Determine the time reference for the snapshot search
if [[ -n "$ALL_CLONE_IDS" ]]; then
    # Grab the name of the first attached volume that matches the naming convention
    VOLUME_NAME=$(echo "$VOLUME_DATA" | jq -r '
        .volumeAttachments | 
        if type == "array" then ..volume.name else empty end
    ' 2>/dev/null)
    
    # Extract YYYYMMDDHHMM timestamp (12 digits) from the volume name
    # Expected format: clone-CLONE-RESTORE-YYYYMMDDHHMM-x
    # We rely on the naming convention prefix: CLONE-RESTORE-
    if [[ "$VOLUME_NAME" =~ CLONE-RESTORE-([1-9]{12}) ]]; then
        SNAPSHOT_TIME_REF="${BASH_REMATCH[1]}"
        echo "Extracted timestamp reference for snapshot search: $SNAPSHOT_TIME_REF"
    else
        echo "Warning: Could not extract timestamp from volume name '$VOLUME_NAME'."
    fi
fi

# ----------------------------------------------------------------
# PHASE 1: Shut Down LPAR and Poll for SHUTOFF
# ----------------------------------------------------------------
echo "3. Shutting down LPAR: $LPAR_NAME..."
# Use ibmcloud pi instance action with the stop operation [12, 13]
ibmcloud pi instance action "$LPAR_NAME" --operation stop || echo "Warning: Failed to initiate LPAR stop. Continuing with polling."

ITERATIONS=0
while [[ $ITERATIONS -lt $MAX_POLL_ITERATIONS ]]; do
    LPAR_STATUS=$(ibmcloud pi instance get "$LPAR_NAME" --json | jq -r '.status' 2>/dev/null || echo "NOT_FOUND")

    if [[ "$LPAR_STATUS" == "SHUTOFF" ]]; then
        echo "SUCCESS: LPAR $LPAR_NAME is in SHUTOFF state [14]."
        break
    elif [[ "$LPAR_STATUS" == "ERROR" ]]; then
        echo "FATAL: LPAR $LPAR_NAME entered ERROR state during shutdown. Proceeding to detach volumes."
        break
    elif [[ "$LPAR_STATUS" == "NOT_FOUND" ]]; then
        echo "WARNING: LPAR $LPAR_NAME not found. Assuming already removed. Proceeding to volume deletion."
        break
    else
        echo "Polling LPAR status: $LPAR_NAME is $LPAR_STATUS. Waiting $POLL_INTERVAL seconds..."
        sleep "$POLL_INTERVAL"
        ITERATIONS=$((ITERATIONS + 1))
    fi
done

# ----------------------------------------------------------------
# PHASE 2: Detach Data Volume(s) and Poll for Detachment
# ----------------------------------------------------------------
if [[ -n "$CLONE_DATA_IDS" ]]; then
    echo "4. Detaching Data Volume(s) using bulk detach: $CLONE_DATA_IDS"
    # Use ibmcloud pi instance volume bulk-detach to detach multiple volumes at once [15-17]
    # We specify --detach-primary False to only target data volumes if the list might be ambiguous
    ibmcloud pi instance volume bulk-detach "$LPAR_NAME" --volumes "$CLONE_DATA_IDS" --detach-primary False || echo "Error initiating bulk detach for data volumes."

    ITERATIONS=0
    while [[ $ITERATIONS -lt 15 ]]; do # Max 15 mins for data detach
        # Check attached volumes list
        ATTACHED_VOLUMES=$(ibmcloud pi instance volume list "$LPAR_NAME" --json | jq -r '[.volumeAttachments[] | select(.volume.bootable == false) | .volume.volumeID] | join(",")' | grep -F -- "$CLONE_DATA_IDS" || true)

        if [[ -z "$ATTACHED_VOLUMES" ]]; then
            echo "SUCCESS: All Data volumes successfully detached."
            break
        else
            echo "Polling data volume detach status. Still attached: $ATTACHED_VOLUMES. Waiting $POLL_INTERVAL seconds..."
            sleep "$POLL_INTERVAL"
            ITERATIONS=$((ITERATIONS + 1))
        fi
    done
else
    echo "5. Skipping Data Volume Detachment: No data volumes identified."
fi

# ----------------------------------------------------------------
# PHASE 3: Detach Boot Volume and Poll for Detachment
# ----------------------------------------------------------------
if [[ -n "$CLONE_BOOT_ID" ]]; then
    echo "6. Detaching Boot Volume: $CLONE_BOOT_ID"
    # Use individual detach command for the boot volume [18, 19]
    ibmcloud pi instance volume detach "$LPAR_NAME" --volume "$CLONE_BOOT_ID" || echo "Error initiating detach for boot volume."

    ITERATIONS=0
    while [[ $ITERATIONS -lt 10 ]]; do # Max 10 mins for boot detach
        # Check if the boot volume ID is still listed as attached
        BOOT_STATUS=$(ibmcloud pi instance volume list "$LPAR_NAME" --json | jq -r '[.volumeAttachments[] | select(.volume.bootable == true) | .volume.volumeID] | join(",")' | grep -F "$CLONE_BOOT_ID" || true)

        if [[ -z "$BOOT_STATUS" ]]; then
            echo "SUCCESS: Boot volume $CLONE_BOOT_ID successfully detached."
            break
        else
            echo "Polling boot volume detach status. Still attached. Waiting $POLL_INTERVAL seconds..."
            sleep "$POLL_INTERVAL"
            ITERATIONS=$((ITERATIONS + 1))
        fi
    done
    if [[ $ITERATIONS -eq 10 ]]; then
        echo "FATAL: Boot volume detachment timed out. Volumes remain attached. Aborting subsequent deletion steps."
        exit 1
    fi
else
    echo "7. Skipping Boot Volume Detachment: No boot volume identified."
fi

# ----------------------------------------------------------------
# PHASE 4: Snapshot Discovery, Correlation (by Time), and Deletion
# ----------------------------------------------------------------
if [[ -n "$SNAPSHOT_TIME_REF" ]]; then
    # Expected snapshot name format: TMP_SNAP_YYYYMMDDHHMM
    TARGET_SNAPSHOT_NAME="TMP_SNAP_${SNAPSHOT_TIME_REF}"
    echo "8. Searching for Snapshot matching name: ${TARGET_SNAPSHOT_NAME}..."

    # List all snapshots in the workspace and filter by the target name
    # Using the recommended 'ibmcloud pi instance snapshot list' [20, 21]
    SNAPSHOT_LIST=$(ibmcloud pi instance snapshot list --json 2>/dev/null)
    
    # Filter the list for the snapshot matching the constructed name and extract its ID
    SNAPSHOT_ID=$(echo "$SNAPSHOT_LIST" | jq -r ".pvmInstanceSnapshots[] | select(.name == \"$TARGET_SNAPSHOT_NAME\") | .snapshotID" || true)

    if [[ -n "$SNAPSHOT_ID" ]]; then
        echo "Found matching Snapshot ID ($SNAPSHOT_ID) based on time reference. Deleting now."
        # Use ibmcloud pi instance snapshot delete [20, 22]
        ibmcloud pi instance snapshot delete "$SNAPSHOT_ID" || {
            echo "WARNING: Failed to delete snapshot $SNAPSHOT_ID. Manual deletion may be required."
        }
    else
        echo "Warning: No snapshot found matching name: $TARGET_SNAPSHOT_NAME. Skipping snapshot deletion."
    fi
else
    echo "9. Skipping Snapshot Discovery: No time reference could be established from cloned volume names."
fi


# ----------------------------------------------------------------
# PHASE 5: Delete Boot and Data Volumes
# ----------------------------------------------------------------
if [[ -n "$ALL_CLONE_IDS" ]]; then
    echo "10. Deleting all cloned volumes (Boot and Data) to stop charges: $ALL_CLONE_IDS"
    
    # Volumes must be detached before deletion can proceed [23].
    # Use ibmcloud pi volume bulk-delete to efficiently remove all clones [15, 24, 25]
    ibmcloud pi volume bulk-delete --volumes "$ALL_CLONE_IDS" || {
        echo "FATAL ERROR: Failed to delete one or more cloned volumes. MANUAL CLEANUP REQUIRED for IDs: $ALL_CLONE_IDS"
        exit 1 # Exit 1 to signal failure to the parent job execution platform
    }
    echo "SUCCESS: All cloned volumes deleted successfully."
else
    echo "11. Skipping Volume Deletion: No cloned Volume IDs found."
fi

# --- Cleanup Complete ---
echo "--- Full Resource Cleanup Completed Successfully. ---"
# Since this script is the cleanup/rollback procedure, successful completion should exit 0.
JOB_SUCCESS=1
exit 0



