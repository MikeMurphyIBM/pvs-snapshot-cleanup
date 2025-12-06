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
# PHASE 0: Authentication and Resource Discovery (STABILIZED)
# ----------------------------------------------------------------

echo "0.1. Authenticating and targeting workspace: $PVS_CRN in $REGION..."
ibmcloud login --apikey "$API_KEY" -r "$REGION" -g "$RESOURCE_GROP_NAME" > /dev/null
ibmcloud pi ws target "$PVS_CRN"

# --- NEW STABILIZATION STEP: Retrieve unique LPAR Instance ID ---
echo "0.2. Retrieving unique Instance ID for LPAR: $LPAR_NAME"

# Use instance list command, which proved stable, and filter by name to get the pvmInstanceID.
LPAR_ID=$(ibmcloud pi instance list --json 2>/dev/null | \
          jq -r ".pvmInstances[] | select(.name == \"$LPAR_NAME\") | .id" || true)

if [[ -z "$LPAR_ID" ]]; then
    echo "FATAL: Could not find unique Instance ID for LPAR '$LPAR_NAME'. Exiting cleanup."
    exit 1
fi
echo "Found Instance ID: $LPAR_ID"

# --- MODIFIED STEP: Identify attached volumes using Instance ID ---
echo "0.3. Identifying attached volumes using Instance ID: $LPAR_ID"
VOLUME_DATA=$(ibmcloud pi instance volume list "$LPAR_ID" --json 2>/dev/null || echo "{}")

# Check if volume data is empty/malformed
if [[ "$VOLUME_DATA" == "{}" || "$VOLUME_DATA" == "[]" ]]; then
    echo "Warning: Volume list retrieval failed or LPAR '$LPAR_NAME' has no attached volumes."
fi

# 1. Extract Boot Volume ID(s): Filters for bootable == true.
CLONE_BOOT_ID=$(echo "$VOLUME_DATA" | jq -r '
    .volumes | 
    if type == "array" then .[] else empty end
    | select(.bootable == true)
    | .volumeID
' | paste -sd ',' - || true | sed 's/^,\|,$//')

# 2. Extract Data Volume ID(s): Filters for bootable == false.
CLONE_DATA_IDS=$(echo "$VOLUME_DATA" | jq -r '
    .volumes | 
    if type == "array" then .[] else empty end
    | select(.bootable == false)
    | .volumeID
' | paste -sd ',' - || true | sed 's/^,\|,$//')

# Combine all IDs for final deletion
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

# FIX: Safely retrieve the name of the first clone volume for timestamp extraction.
VOLUME_NAME=$(echo "$VOLUME_DATA" | jq -r '
    .volumes[] | 
    if .name | startswith("clone-CLONE-RESTORE-") then .name else empty end 
' 2>/dev/null | head -n 1 || echo "")

# Extract the 12-digit timestamp (YYYYMMDDHHMM) from the volume name.
SNAPSHOT_TIME_REF=""
# FIX: Use correct Bash regex syntax to capture exactly 12 digits.
# Assuming $VOLUME_NAME looks like 'clone-CLONE-RESTORE-202512060039-2'
if [[ "$VOLUME_NAME" =~ CLONE-RESTORE-([1-9]{12}) ]]; then
    # BASH_REMATCH[1] holds the content of the first capture group (the 12 digits).
    SNAPSHOT_TIME_REF="${BASH_REMATCH[1]}"
    echo "Extracted timestamp reference for snapshot search: $SNAPSHOT_TIME_REF"
else
    echo "Warning: Could not extract YYYYMMDDHHMM timestamp from volume name '$VOLUME_NAME'."
fi


# ----------------------------------------------------------------
# PHASE 1: Immediate Shutdown and Poll for SHUTOFF (Skipping graceful stop)
# ----------------------------------------------------------------
echo "1. Shutting down LPAR: $LPAR_NAME..."
LPAR_STATUS=$(ibmcloud pi instance get "$LPAR_NAME" --json | jq -r '.status' 2>/dev/null || echo "ACTIVE")

if [[ "$LPAR_STATUS" != "SHUTOFF" ]]; then
    echo "LPAR status is $LPAR_STATUS. Initiating **immediate-shutdown** operation."
    
    # Use immediate-shutdown operation (hard stop) [12, 13]
    ibmcloud pi instance action "$LPAR_NAME" --operation immediate-shutdown || echo "Warning: Failed to initiate immediate-shutdown."

    # Define maximum wait time (5 minutes) and check interval
MAX_WAIT=300
INTERVAL=10
CURRENT_WAIT=0

echo "Waiting for LPAR $LPAR_NAME to reach SHUTOFF state (Max $MAX_WAIT seconds)..."

while [[ "$CURRENT_WAIT" -lt "$MAX_WAIT" ]]; do
    # Fetch the current status of the instance. The ibmcloud pi instance get command
    # provides details on the PVM instance [5].
    STATUS=$(ibmcloud pi instance get "$LPAR_NAME" --json | jq -r .status)

    if [[ "$STATUS" == "SHUTOFF" ]]; then
        echo "SUCCESS: LPAR $LPAR_NAME is SHUTOFF. Proceeding to volume detachment."
        break
    elif [[ "$STATUS" == "ACTIVE" || "$STATUS" == "SHUTTING_DOWN" ]]; then
        echo "Current status: $STATUS. Waiting $INTERVAL seconds..."
        sleep "$INTERVAL"
        CURRENT_WAIT=$((CURRENT_WAIT + INTERVAL))
    else
        # Handle unexpected intermediate states gracefully
        echo "Warning: Current status: $STATUS. Waiting $INTERVAL seconds..."
        sleep "$INTERVAL"
        CURRENT_WAIT=$((CURRENT_WAIT + INTERVAL))
    fi
done

if [[ "$STATUS" != "SHUTOFF" ]]; then
    echo "FATAL: LPAR shutdown timed out after $MAX_WAIT seconds. Volumes cannot be safely detached or deleted."
    exit 1
fi
    
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
# PHASE 2: Detach DATA Volume(s) and Poll (Must precede Boot volume detach)
# ----------------------------------------------------------------

if [[ -n "$CLONE_DATA_IDS" || -n "$CLONE_BOOT_ID" ]]; then
    # FIX 1: Updated descriptive output to reflect detachment of all volumes
    echo "2. Detaching ALL volumes (Data and Boot) from LPAR: $LPAR_NAME"
    # Bulk detach command remains correct for detaching both volumes simultaneously
    ibmcloud pi instance volume bulk-detach "$LPAR_NAME" --detach-all True --detach-primary True || echo "Error initiating bulk detach for ALL volumes."

    # FIX 2: Combine Boot and Data IDs for comprehensive checking
    ALL_CRITICAL_IDS="$CLONE_BOOT_ID,$CLONE_DATA_IDS"

    ITERATIONS=0
    # Assuming $MAX_DETACH_ITERATIONS and $POLL_INTERVAL are defined globally
    while [[ $ITERATIONS -lt $MAX_DETACH_ITERATIONS ]]; do
        ALL_DETACHED=true
        
        # Fetch ALL attached volume IDs (Boot and Data), returning a comma-separated list of IDs
        CURRENT_ATTACHED_VOLUMES=$(ibmcloud pi instance volume list "$LPAR_NAME" --json | jq -r '[.volumes[].volumeID] | join(",")' 2>/dev/null || true)
        
        STILL_ATTACHED_CRITICAL_VOLUMES=""
        
        # Convert combined IDs string into an array
        IFS=',' read -r -a ALL_IDS_ARRAY <<< "$ALL_CRITICAL_IDS"
        
        # FIX 3: Iterate through every expected critical ID (Boot and Data)
        for VOL_ID in "${ALL_IDS_ARRAY[@]}"; do
            # Check if this critical volume ID is still present in the list of currently attached volumes
            if [[ -n "$VOL_ID" ]] && echo "$CURRENT_ATTACHED_VOLUMES" | grep -q "$VOL_ID"; then
                ALL_DETACHED=false
                STILL_ATTACHED_CRITICAL_VOLUMES+="$VOL_ID "
            fi
        done
        
        if [[ "$ALL_DETACHED" == "true" ]]; then
            echo "SUCCESS: All critical volumes successfully detached."
            break
        else
            # Display which specific volumes remain attached
            echo "Polling detachment status. Still attached: $STILL_ATTACHED_CRITICAL_VOLUMES. Waiting $POLL_INTERVAL seconds..."
            sleep "$POLL_INTERVAL"
            ITERATIONS=$((ITERATIONS + 1))
        fi
    done
    
    # Final check block ensures FATAL exit if the while loop timed out
    if [[ "$ALL_DETACHED" != "true" ]]; then
        echo "FATAL: Volume detachment timed out. Cannot proceed safely."
        exit 1
    fi
else
    echo "2. Skipping Volume Detachment: No critical volumes identified."
fi

# ----------------------------------------------------------------
# PHASE 3: Detach BOOT Volume and Poll
# ----------------------------------------------------------------


# ----------------------------------------------------------------
# PHASE 4: Snapshot Discovery and Deletion
# ----------------------------------------------------------------

if [[ -n "$SNAPSHOT_TIME_REF" ]]; then
    # Construct the expected snapshot name using the extracted timestamp
    TARGET_SNAPSHOT_NAME="TMP_SNAP_$SNAPSHOT_TIME_REF"
    echo "4. Attempting to locate and delete snapshot: $TARGET_SNAPSHOT_NAME"

    # Query all snapshots and use jq to find the exact ID matching the unique name
    SNAPSHOT_ID_TO_DELETE=$(ibmcloud pi instance snapshot list --json | \
        jq -r ".snapshots[] | select(.name == \"$TARGET_SNAPSHOT_NAME\") | .snapshotID")

    if [[ -n "$SNAPSHOT_ID_TO_DELETE" ]]; then
        echo "Found target Snapshot ID: $SNAPSHOT_ID_TO_DELETE. Deleting..."
        
        # Deleting the corresponding snapshot is standard cleanup practice in PowerVS environments
        ibmcloud pi instance snapshot delete "$LPAR_ID" --snapshot "$SNAPSHOT_ID_TO_DELETE" || {
            echo "ERROR: Failed to delete snapshot $TARGET_SNAPSHOT_NAME. Manual cleanup required."
            exit 1
        }
        echo "SUCCESS: Snapshot $TARGET_SNAPSHOT_NAME deleted."
    else
        echo "Warning: Target snapshot $TARGET_SNAPSHOT_NAME not found. Skipping snapshot cleanup."
    fi
else
    echo "4. Skipping Snapshot Deletion: No valid timestamp extracted (SNAPSHOT_TIME_REF is empty)."
fi

# ----------------------------------------------------------------
# PHASE 5: Delete Volumes (Boot and Data)
# ----------------------------------------------------------------
if [[ -n "$ALL_CLONE_IDS" ]]; then
    echo "5. Deleting all cloned volumes (Boot and Data) to stop charges: $ALL_CLONE_IDS"
    
    # Use ibmcloud pi volume bulk-delete [14, 21]
    ibmcloud pi volume bulk-delete --volumes "$ALL_CLONE_IDS" || {
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


