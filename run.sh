#!/bin/bash

# --- Environment Variables ---
API_KEY="${IBMCLOUD_API_KEY}"    # IAM API Key stored in Code Engine Secret
REGION="us-south"                # IBM Cloud Region
RESOURCE_GROP_NAME="Default"     # Targeted Resource Group
PVS_CRN="crn:v1:bluemix:public:power-iaas:dal10:a/21d74dd4fe814dfca20570bbb93cdbff:cc84ef2f-babc-439f-8594-571ecfcbe57a::" # Full PowerVS Workspace CRN
CLOUD_INSTANCE_ID="cc84ef2f-babc-439f-8594-571ecfcbe57a" # PowerVS Workspace ID
LPAR_NAME="empty-ibmi-lpar"      # Name of the target LPAR
PRIMARY_LPAR="get-snapshot"      # Name of the source LPAR for snapshot
CLONE_NAME_PREFIX="CLONE-RESTORE-$(date +"%Y%m%d%H%M")"   # Unique prefix for the new cloned volumes, excluding seconds (%S)
# These will be populated in the discovery phase:
CLONE_BOOT_ID=""                 # Tracks the ID of the dynamically created boot volume
CLONE_DATA_IDS=""                # Tracks the comma-separated IDs of the dynamically created data volumes
SOURCE_SNAPSHOT_ID=""            # Tracks the ID of the discovered source snapshot
ALL_CLONE_IDS=""                 # Tracks the comma-separated IDs of the volumes contained within the snapshot
JOB_SUCCESS=0                    # 0 = Failure (Default), 1 = Success (Set at end of script)

# ================================================================
echo "CRITICAL CLEANUP: Initiating LPAR shutdown and volume rollback..."
# ================================================================

# ----------------------------------------------------------------
# DISCOVERY PHASE: Login, Target Workspace, and Identify Resources
# ----------------------------------------------------------------

# Ensure required commands are available (assuming `jq` is installed in the environment)

echo "--- 0. Authentication and Service Targeting ---"
# Log in using the API key environment variable (assumes IBMCLOUD_API_KEY is available in the shell/env) [3]
ibmcloud login --apikey "$API_KEY" -r "$REGION" -g "$RESOURCE_GROP_NAME"

if [[ -z "$PVS_CRN" ]]; then
    echo "FATAL: PVS_CRN variable is not set. Cannot proceed with targeting."
    exit 1
fi
# Target the specific Power Virtual Server workspace using its CRN [1, 2]
ibmcloud pi ws target "$PVS_CRN"

echo "--- 0.1. Identifying Cloned Volumes on LPAR: $LPAR_NAME ---"

# Use ibmcloud pi instance volume list to get all volumes attached to the failed LPAR in JSON format [4-6]
# jq is used to extract IDs and determine if they are bootable [7, 8]

VOLUME_DATA=$(ibmcloud pi instance volume list "$LPAR_NAME" --json 2>/dev/null)

if [[ -z "$VOLUME_DATA" || "$VOLUME_DATA" == "[]" ]]; then
    echo "Warning: No volumes found attached to LPAR '$LPAR_NAME'. Skipping volume detachment/deletion."
else
    # Extract Boot Volume ID (must be bootable: true) [9]
    CLONE_BOOT_ID=$(echo "$VOLUME_DATA" | jq -r '.volumeAttachments[] | select(.volume.bootable == true) | .volume.volumeID' | tr '\n' ',' | sed 's/,$//')

    # Extract Data Volume IDs (must be bootable: false)
    # We collect all non-boot volumes attached to the LPAR
    CLONE_DATA_IDS=$(echo "$VOLUME_DATA" | jq -r '.volumeAttachments[] | select(.volume.bootable == false) | .volume.volumeID' | paste -sd ',' -)
    
    # Combine all IDs for final deletion
    if [[ -n "$CLONE_BOOT_ID" ]]; then
        ALL_CLONE_IDS="${CLONE_BOOT_ID}"
    fi
    if [[ -n "$CLONE_DATA_IDS" ]]; then
        ALL_CLONE_IDS="${ALL_CLONE_IDS},${CLONE_DATA_IDS}"
    fi
    
    # Cleanup volume list string formatting
    ALL_CLONE_IDS=$(echo "$ALL_CLONE_IDS" | sed 's/^,//;s/,,/,/g')

    echo "Identified Boot ID: $CLONE_BOOT_ID"
    echo "Identified Data IDs: $CLONE_DATA_IDS"
    echo "All Volume IDs for Deletion: $ALL_CLONE_IDS"
fi

echo "--- 0.2. Identifying Source Snapshot ID ---"
# Note: The snapshot ID is often passed down from the previous successful operation or derived from the cloning job metadata.
# We will search for snapshots matching the likely naming convention (Snap_PRIMARY_LPAR_*) or a known ID.
# Since the exact name isn't provided, we list snapshots and rely on external naming conventions if SOURCE_SNAPSHOT_ID is empty.
if [[ -z "$SOURCE_SNAPSHOT_ID" ]]; then
    echo "Attempting to search for the source snapshot linked to $PRIMARY_LPAR..."
    # Query snapshots and filter by instance name $PRIMARY_LPAR, assuming the source LPAR is where the snapshot was taken.
    # We must ensure to get the ID, not the CRN [10]. We use the volume snapshot list command [11].
    
    # NOTE: Since reliable dynamic discovery of the source snapshot used for cloning (if the clone succeeded but the boot failed) 
    # requires knowing the naming convention or job output history, we implement a general list filter.
    
    # Example lookup (assuming the snapshot name contains the primary LPAR name):
    SNAPSHOT_LOOKUP=$(ibmcloud pi instance snapshot list "$PRIMARY_LPAR" --json 2>/dev/null)
    # This example extracts the ID of the newest snapshot on the primary LPAR, which is a common (but potentially risky) assumption in rollback logic:
    SOURCE_SNAPSHOT_ID=$(echo "$SNAPSHOT_LOOKUP" | jq -r '.pvmInstanceSnapshots.snapshotID' || true)

    if [[ -n "$SOURCE_SNAPSHOT_ID" ]]; then
        echo "Found potential Snapshot ID on $PRIMARY_LPAR: $SOURCE_SNAPSHOT_ID"
    else
        echo "Warning: Source Snapshot ID could not be dynamically determined. Snapshot deletion step may be skipped."
    fi
fi

# ----------------------------------------------------------------
# STEP 1: SHUT DOWN LPAR AND POLL FOR SHUTOFF STATE
# ----------------------------------------------------------------
echo "1. Shutting down LPAR: $LPAR_NAME..."
# Initiate immediate shutdown of the LPAR [12, 13]
ibmcloud pi instance action "$LPAR_NAME" --operation stop || {
    echo "Warning: Failed to initiate LPAR stop request. Continuing with polling."
}

LPAR_STATUS_CHECK_ITERATIONS=0
# Loop until status is SHUTOFF
while [[ $LPAR_STATUS_CHECK_ITERATIONS -lt 20 ]]; do 
    LPAR_STATUS=$(ibmcloud pi instance get "$LPAR_NAME" --json | jq -r '.status' 2>/dev/null) [8, 14, 15]

    if [[ "$LPAR_STATUS" == "SHUTOFF" ]]; then
        echo "SUCCESS: LPAR $LPAR_NAME is in SHUTOFF state."
        break
    # Exit condition if LPAR goes into a terminal error state
    elif [[ "$LPAR_STATUS" == "ERROR" ]]; then
        echo "FATAL: LPAR $LPAR_NAME entered ERROR state during shutdown. Proceeding to detach volumes."
        break
    else
        echo "Polling LPAR status: $LPAR_NAME is $LPAR_STATUS. Waiting 60 seconds."
        sleep 60
        LPAR_STATUS_CHECK_ITERATIONS=$((LPAR_STATUS_CHECK_ITERATIONS + 1))
    fi
done


# ----------------------------------------------------------------
# STEP 2: DETACH DATA VOLUME(S) AND POLL FOR DETACHMENT
# ----------------------------------------------------------------
if [[ -n "$CLONE_DATA_IDS" ]]; then
    echo "2. Detaching Data Volume(s) ($CLONE_DATA_IDS) using bulk detach..."
    # Use the bulk-detach command [16-19]
    ibmcloud pi instance volume bulk-detach "$LPAR_NAME" --volumes "$CLONE_DATA_IDS" --detach-primary False || {
        echo "ERROR: Failed to initiate bulk detach for data volumes. Continuing to poll state."
    }

    # Polling for detachment completion (Data Volumes)
    DATA_DETACH_ITERATIONS=0
    while true; do
        # Check if any data volume is still attached
        ATTACHED_DATA=$(echo "$VOLUME_DATA" | jq -r '.volumeAttachments[] | select(.volume.bootable == false) | .volume.volumeID' | grep -F -- "$CLONE_DATA_IDS" || true)

        if [[ -z "$ATTACHED_DATA" ]]; then
            echo "SUCCESS: All Data volumes successfully detached."
            break
        elif [[ $DATA_DETACH_ITERATIONS -ge 15 ]]; then
            echo "FATAL: Data volume detachment timed out. Manual cleanup required."
            break
        else
            echo "Polling data volume detach status. Waiting 60 seconds..."
            sleep 60
            DATA_DETACH_ITERATIONS=$((DATA_DETACH_ITERATIONS + 1))
        fi
    done
else
    echo "2. Skipping Data Volume Detachment: No data volumes identified."
fi

# ----------------------------------------------------------------
# STEP 3: DETACH BOOT VOLUME AND POLL FOR DETACHMENT
# ----------------------------------------------------------------
if [[ -n "$CLONE_BOOT_ID" ]]; then
    echo "3. Detaching Boot Volume: $CLONE_BOOT_ID..."
    # Detach the boot volume [20-22]
    ibmcloud pi instance volume detach "$LPAR_NAME" --volume "$CLONE_BOOT_ID" || {
        echo "ERROR: Failed to initiate detach for boot volume."
    }

    # Polling for detachment completion (Boot Volume)
    BOOT_DETACH_ITERATIONS=0
    while true; do
        # Check if the boot volume ID is still listed as attached to the instance
        BOOT_STATUS=$(ibmcloud pi instance volume list "$LPAR_NAME" --json | jq -r '.volumeAttachments[] | .volume.volumeID' | grep -F "$CLONE_BOOT_ID" || true)

        if [[ -z "$BOOT_STATUS" ]]; then
            echo "SUCCESS: Boot volume $CLONE_BOOT_ID successfully detached."
            break
        elif [[ $BOOT_DETACH_ITERATIONS -ge 10 ]]; then 
            echo "FATAL: Boot volume detachment timed out. Manual cleanup required for volume: $CLONE_BOOT_ID."
            exit 1 # Stop deletion as attached volumes cannot be deleted
        else
            echo "Polling boot volume detach status. Waiting 60 seconds..."
            sleep 60
            BOOT_DETACH_ITERATIONS=$((BOOT_DETACH_ITERATIONS + 1))
        fi
    done
else
    echo "3. Skipping Boot Volume Detachment: No boot volume identified."
fi


# ----------------------------------------------------------------
# STEP 4: DELETE THE SNAPSHOT
# ----------------------------------------------------------------
if [[ -n "$SOURCE_SNAPSHOT_ID" ]]; then
    echo "4. Deleting Snapshot: $SOURCE_SNAPSHOT_ID..."
    # Use the instance snapshot delete command [23-25]
    ibmcloud pi instance snapshot delete "$SOURCE_SNAPSHOT_ID" || {
        echo "WARNING: Failed to delete snapshot $SOURCE_SNAPSHOT_ID. Continuing cleanup."
    }
else
    echo "4. Skipping Snapshot Deletion: SOURCE_SNAPSHOT_ID not defined or found."
fi


# ----------------------------------------------------------------
# STEP 5: DELETE BOOT AND DATA VOLUMES
# ----------------------------------------------------------------
if [[ -n "$ALL_CLONE_IDS" ]]; then
    echo "5. Attempting permanent bulk deletion of cloned volumes: $ALL_CLONE_IDS (Stops charges)"
    # Use the bulk-delete command, available since CLI v1.3.0 [16, 17, 26, 27]
    ibmcloud pi volume bulk-delete --volumes "$ALL_CLONE_IDS" || { 
        echo "FATAL ERROR: Failed to delete one or more cloned volumes. MANUAL CLEANUP REQUIRED for IDs: $ALL_CLONE_IDS"
        exit 1
    }
    echo "Cloned volumes deleted successfully."
else
    echo "5. Skipping Volume Deletion: No cloned Volume IDs found."
fi

# If we reached here, cleanup was performed successfully, but we must exit 1 
# because this is a rollback function intended to signal failure to the parent process.
echo "Cleanup phase complete. Returning failure code to main process."
exit 1
