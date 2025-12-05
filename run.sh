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
# PHASE 0: Authentication and Resource Discovery (Updated to use ID)
# ----------------------------------------------------------------

echo "0.1. Authenticating and targeting workspace: $PVS_CRN in $REGION..."
ibmcloud login --apikey "$API_KEY" -r "$REGION" -g "$RESOURCE_GROP_NAME" > /dev/null
ibmcloud pi ws target "$PVS_CRN" [1]

# --- NEW STEP: Retrieve unique LPAR Instance ID ---
echo "0.2. Retrieving unique Instance ID for LPAR: $LPAR_NAME"
# List all instances and filter by name to get the unique Instance ID.
# This uses the stable pattern that lists all PVM instances [2, 3].
LPAR_ID=$(ibmcloud pi instance list --json 2>/dev/null | \
          jq -r ".pvmInstances[] | select(.name == \"$LPAR_NAME\") | .pvmInstanceID" || true)

if [[ -z "$LPAR_ID" ]]; then
    echo "FATAL: Could not find unique Instance ID for LPAR '$LPAR_NAME'. Exiting cleanup."
    exit 1
fi
echo "Found Instance ID: $LPAR_ID"

# --- MODIFIED STEP: Identify attached volumes using Instance ID ---
echo "0.3. Identifying attached volumes using Instance ID: $LPAR_ID"
# Use the stable Instance ID instead of the name for volume listing [4, 5].
VOLUME_DATA=$(ibmcloud pi instance volume list "$LPAR_ID" --json 2>/dev/null || echo "{}")

# Check if volume data is empty/malformed
if [[ "$VOLUME_DATA" == "{}" || "$VOLUME_DATA" == "[]" ]]; then
    echo "Warning: Volume list retrieval failed or LPAR '$LPAR_NAME' has no attached volumes."
fi

# --- Hardened Parsing using jq ---
# 1. Extract Boot Volume ID(s): Filters for bootable == true.
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

# Combine all IDs for final deletion (Logic unchanged)
ALL_CLONE_IDS="${CLONE_BOOT_ID}"
if [[ -n "$CLONE_DATA_IDS" ]]; then
    if [[ -n "$CLONE_BOOT_ID" ]]; then
        ALL_CLONE_IDS="${ALL_CLONE_IDS},${CLONE_DATA_IDS}"
    else
        ALL_CLONE_IDS="${CLONE_DATA_IDS}"
    fi
fi
ALL_CLONE_IDS=$(echo "$ALL_CLONE_IDS" | sed 's/^,\|,$//;s/,,/,/g')

echo "Discovered Boot ID: ${CLONE_BOOT_ID:-N/A}"
echo "Discovered Data IDs: ${CLONE_DATA_IDS:-N/A}"

if [[ -z "$ALL_CLONE_IDS" ]]; then
    echo "No clone volumes detected. Exiting cleanup successfully."
    exit 0
fi

# Determine the time reference for the snapshot search (Logic unchanged)
VOLUME_NAME=$(echo "$VOLUME_DATA" | jq -r '.volumeAttachments[] | .volume.name' 2>/dev/null | head -n 1 || true)
if [[ "$VOLUME_NAME" =~ CLONE-RESTORE-([6-14]{12}) ]]; then
    SNAPSHOT_TIME_REF="${BASH_REMATCH[6]}"
    echo "Extracted timestamp reference for snapshot search: $SNAPSHOT_TIME_REF"
else
    echo "Warning: Could not extract YYYYMMDDHHMM timestamp from volume name '$VOLUME_NAME'."
fi


# ----------------------------------------------------------------
# PHASE 1: Immediate Shutdown and Poll for SHUTOFF (Forceful approach requested)
# ----------------------------------------------------------------
echo "1. Shutting down LPAR: $LPAR_NAME..."
# We use LPAR_NAME for actions as the PowerVS CLI often accepts either ID or Name [15, 16].
LPAR_STATUS=$(ibmcloud pi instance get "$LPAR_NAME" --json | jq -r '.status' 2>/dev/null || echo "ACTIVE")

if [[ "$LPAR_STATUS" != "SHUTOFF" ]]; then
    echo "LPAR status is $LPAR_STATUS. Initiating **immediate-shutdown** operation."
    
    # Execute the immediate-shutdown operation (hard stop) [15, 17]
    ibmcloud pi instance action "$LPAR_NAME" --operation immediate-shutdown || echo "Warning: Failed to initiate immediate-shutdown."
    
    # Polling loop
    ITERATIONS=0
    while [[ $ITERATIONS -lt $MAX_SHUTDOWN_ITERATIONS ]]; do
        LPAR_STATUS=$(ibmcloud pi instance get "$LPAR_NAME" --json | jq -r '.status' 2>/dev/null || echo "NOT_FOUND")

        if [[ "$LPAR_STATUS" == "SHUTOFF" ]]; then
            echo "SUCCESS: LPAR $LPAR_NAME reached SHUTOFF state. Proceeding to detach volumes."
            break
        elif [[ "$LPAR_STATUS" == "ERROR" ]]; then
            echo "WARNING: LPAR $LPAR_NAME entered ERROR state. Proceeding to detach volumes, but manual check needed."
            break
        elif [[ "$LPAR_STATUS" == "NOT_FOUND" ]]; then
            echo "WARNING: LPAR $LPAR_NAME not found. Proceeding to volume deletion phase."
            break
        else
            echo "Polling LPAR status: $LPAR_NAME is $LPAR_STATUS. Waiting $POLL_INTERVAL seconds..."
            sleep "$POLL_INTERVAL"
            ITERATIONS=$((ITERATIONS + 1))
        fi
    done

    if [[ "$LPAR_STATUS" != "SHUTOFF" && "$LPAR_STATUS" != "ERROR" && "$LPAR_STATUS" != "NOT_FOUND" ]]; then
        echo "FATAL: LPAR shutdown timed out. Volumes cannot be safely detached or deleted."
        exit 1
    fi
else
    echo "LPAR $LPAR_NAME is already in SHUTOFF state. Skipping shutdown."
fi

# ----------------------------------------------------------------
# PHASE 2: Detach DATA Volume(s) and Poll for Detachment (Data must precede Boot)
# ----------------------------------------------------------------
if [[ -n "$CLONE_DATA_IDS" ]]; then
    echo "2. Detaching Data Volume(s) first: $CLONE_DATA_IDS"
    # Use ibmcloud pi instance volume bulk-detach [18]
    ibmcloud pi instance volume bulk-detach "$LPAR_NAME" --volumes "$CLONE_DATA_IDS" --detach-primary False || echo "Error initiating bulk detach for data volumes."

    ITERATIONS=0
    while [[ $ITERATIONS -lt 15 ]]; do 
        # Check if non-bootable volumes are still attached
        ATTACHED_DATA_VOLUMES=$(ibmcloud pi instance volume list "$LPAR_NAME" --json | jq -r '[.volumeAttachments[] | select(.volume.bootable == false) | .volume.volumeID] | join(",")' | grep -F -- "$CLONE_DATA_IDS" || true)

        if [[ -z "$ATTACHED_DATA_VOLUMES" ]]; then
            echo "SUCCESS: All Data volumes successfully detached."
            break
        else
            echo "Polling data volume detach status. Still attached: $ATTACHED_DATA_VOLUMES. Waiting $POLL_INTERVAL seconds..."
            sleep "$POLL_INTERVAL"
            ITERATIONS=$((ITERATIONS + 1))
        fi
    done
    
    if [[ $ITERATIONS -ge 15 ]]; then
        echo "FATAL: Data volume detachment timed out. Cannot proceed safely."
        exit 1
    fi
else
    echo "2. Skipping Data Volume Detachment: No data volumes identified."
fi

# ----------------------------------------------------------------
# PHASE 3: Detach BOOT Volume and Poll for Detachment
# ----------------------------------------------------------------
if [[ -n "$CLONE_BOOT_ID" ]]; then
    echo "3. Detaching Boot Volume: $CLONE_BOOT_ID"
    # Use individual detach command [5, 19]
    ibmcloud pi instance volume detach "$LPAR_NAME" --volume "$CLONE_BOOT_ID" || echo "Error initiating detach for boot volume."

    ITERATIONS=0
    while [[ $ITERATIONS -lt 10 ]]; do 
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
    if [[ $ITERATIONS -ge 10 ]]; then
        echo "FATAL: Boot volume detachment timed out. Cannot proceed with deletion."
        exit 1
    fi
else
    echo "3. Skipping Boot Volume Detachment: No boot volume identified."
fi

# ----------------------------------------------------------------
# PHASE 4: Snapshot Discovery and Deletion
# ----------------------------------------------------------------
if [[ -n "$SNAPSHOT_TIME_REF" ]]; then
    TARGET_SNAPSHOT_NAME="TMP_SNAP_${SNAPSHOT_TIME_REF}"
    echo "4. Searching for Snapshot matching name: ${TARGET_SNAPSHOT_NAME}..."

    # List snapshots in the workspace
    SNAPSHOT_LIST=$(ibmcloud pi instance snapshot list --json 2>/dev/null) [20]
    
    # Filter the list for the snapshot matching the constructed name and extract its ID
    SNAPSHOT_ID=$(echo "$SNAPSHOT_LIST" | jq -r ".pvmInstanceSnapshots[] | select(.name == \"$TARGET_SNAPSHOT_NAME\") | .snapshotID" || true)

    if [[ -n "$SNAPSHOT_ID" ]]; then
        echo "Found matching Snapshot ID ($SNAPSHOT_ID). Deleting now."
        # Use ibmcloud pi instance snapshot delete [20]
        ibmcloud pi instance snapshot delete "$SNAPSHOT_ID" || {
            echo "WARNING: Failed to delete snapshot $SNAPSHOT_ID. Manual deletion may be required."
        }
    else
        echo "Warning: No snapshot found matching name: $TARGET_SNAPSHOT_NAME. Skipping snapshot deletion."
    fi
else
    echo "4. Skipping Snapshot Discovery: No time reference could be established."
fi

# ----------------------------------------------------------------
# PHASE 5: Delete Volumes (Boot and Data)
# ----------------------------------------------------------------
if [[ -n "$ALL_CLONE_IDS" ]]; then
    echo "5. Deleting all cloned volumes (Boot and Data) to stop charges: $ALL_CLONE_IDS"
    
    # Use ibmcloud pi volume bulk-delete
    ibmcloud pi volume bulk-delete --volumes "$ALL_CLONE_IDS" || { [21]
        echo "FATAL ERROR: Failed to delete one or more cloned volumes. MANUAL CLEANUP REQUIRED for IDs: $ALL_CLONE_IDS"
        exit 1
    }
    echo "SUCCESS: All cloned volumes deleted successfully."
else
    echo "5. Skipping Volume Deletion: No cloned Volume IDs found."
fi

# --- Cleanup Complete ---
echo "--- Full Resource Cleanup Completed Successfully. ---"
exit 0


