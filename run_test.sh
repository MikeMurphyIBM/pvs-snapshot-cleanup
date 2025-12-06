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

#---------------------------------------------------------
#  Part 1:  Authentication and Volume Identification
#---------------------------------------------------------

echo "--- PowerVS Cleanup and Rollback Operation - Part 1 ---"

# --- 1. Authenticate and Target Resources ---
echo "1. Authenticating to IBM Cloud and targeting PowerVS instance..."

# Login using API Key and set region
# We use --no-wait where possible to speed up execution
ibmcloud login --apikey "$API_KEY" -r "$REGION" --no-wait > /dev/null 2>&1 || {
    echo "Authentication failed. Exiting."
    exit 1
}

# Target Resource Group
ibmcloud target -g "$RESOURCE_GROUP_NAME" --no-wait > /dev/null 2>&1 || {
    echo "Failed to target resource group $RESOURCE_GROUP_NAME. Exiting."
    exit 1
}

# Target PowerVS Workspace using CRN
# Note: ibmcloud pi ws tg sets the context for all subsequent 'ibmcloud pi' commands
ibmcloud pi ws tg "$PVS_CRN" --no-wait > /dev/null 2>&1 || {
    echo "Failed to target PowerVS workspace $PVS_CRN. Exiting."
    exit 1
}

echo "Authentication and targeting successful."

# --- 2. Identify Attached Volumes ---
echo "2. Identifying attached volumes for LPAR: $LPAR_NAME"

# List volumes attached to the LPAR in JSON format
# If the command fails (e.g., LPAR not found), echo an empty JSON array "{}" or "[]" to prevent script crash
VOLUME_DATA=$(ibmcloud pi ins vol ls "$LPAR_NAME" --json 2>/dev/null || echo "[]")

# If volume data retrieval failed or returned empty results
if [ "$VOLUME_DATA" == "[]" ] || [ -z "$(echo "$VOLUME_DATA" | jq '.[]')" ]; then
    echo "Error: Could not retrieve volume data or no volumes found for $LPAR_NAME. Exiting."
    exit 1
fi

# Extract Boot Volume ID (where "bootable" == true)
# -r ensures raw output (no quotes around the UUID)
BOOT_VOL=$(echo "$VOLUME_DATA" | jq -r '.[] | select(.bootable == true) | .volumeID')

# Extract Data Volume IDs (where "bootable" == false)
# jq extracts IDs, paste joins them with commas for cleaner output
DATA_VOLS=$(echo "$VOLUME_DATA" | jq -r '.[] | select(.bootable == false) | .volumeID' | paste -sd "," -)

# Check if BOOT_VOL was found (critical for rollback operation)
if [ -z "$BOOT_VOL" ]; then
    echo "Error: Could not identify the required bootable volume (bootable == true). Cannot proceed."
    exit 1
fi

# Print required output format
echo "Boot Volume: $BOOT_VOL"
echo "Data Volume(s): $DATA_VOLS"

echo "--- Part 1 Complete ---"
echo ""

#---------------------------------------------------------
#  Part 2:  Snapshot Identification
#---------------------------------------------------------

# --- Assuming BOOT_VOL variable is defined from Part 1 ---

echo "--- PowerVS Cleanup and Rollback Operation - Part 2 ---"

# Check if BOOT_VOL variable is available (safety check)
if [[ -z "$BOOT_VOL" ]]; then
    echo "ERROR: BOOT_VOL variable is missing from Part 1 context. Cannot proceed."
    exit 1
fi

echo "Fetching metadata for Volume ID: $BOOT_VOL..."
# Retrieve volume details in JSON format. Suppress errors but exit on critical failure.
BOOT_VOL_JSON=$(ibmcloud pi vol get "$BOOT_VOL" --json 2>/dev/null)

# Check if volume data retrieval was successful (checking for null or empty content)
if [ -z "$BOOT_VOL_JSON" ] || [ "$(echo "$BOOT_VOL_JSON" | jq -r '.volumeID')" == "null" ]; then
    echo "ERROR: Could not retrieve valid metadata for volume $BOOT_VOL. Exiting."
    exit 2
fi

# Extract timestamp from volume name
TS=$(echo "$BOOT_VOL_JSON" | jq -r '
    .name | capture("(?<ts>[1-9]{12})").ts
')

echo "Extracted timestamp: $TS"

if [[ -z "$TS" ]] || [[ "$TS" == "null" ]]; then
    echo "ERROR: No valid 12-digit timestamp found in volume name for correlation."
    exit 3
fi

echo "Fetching snapshot list across the workspace..."
# Note: ibmcloud pi instance snapshot ls lists snapshots created within the current workspace context
ALL_SNAPS_JSON=$(ibmcloud pi instance snapshot ls --json 2>/dev/null || echo "[]")

# If volume data retrieval failed or returned empty results
if [ "$ALL_SNAPS_JSON" == "[]" ] || [ -z "$(echo "$ALL_SNAPS_JSON" | jq '.[]')" ]; then
    echo "WARNING: No snapshots found in this workspace. Correlation will fail."
fi

# Find matching snapshot by identifying the timestamp in the snapshot name
MATCHING_SNAPSHOT_JSON=$(echo "$ALL_SNAPS_JSON" | jq -r --arg ts "$TS" '
    .[] | select(.name | test($ts))
')

if [[ -z "$MATCHING_SNAPSHOT_JSON" ]]; then
    echo "ERROR: No snapshot found matching timestamp $TS in the workspace. Cannot determine rollback target."
    exit 4
fi

# Extracting the ID and Name from the first matching snapshot found
MATCHING_SNAPSHOT_ID=$(echo "$MATCHING_SNAPSHOT_JSON" | head -n 1 | jq -r '.snapshotID')
MATCHING_SNAPSHOT_NAME=$(echo "$MATCHING_SNAPSHOT_JSON" | head -n 1 | jq -r '.name')

if [[ -z "$MATCHING_SNAPSHOT_ID" ]]; then
    echo "ERROR: Successfully matched a snapshot name, but failed to extract the Snapshot ID. Exiting."
    exit 5
fi

# Print correlation results
echo "--------------------------------------------"
echo "Snapshot Match Found (Rollback Target)"
echo "Volume ID:        $BOOT_VOL"
echo "Snapshot ID:      $MATCHING_SNAPSHOT_ID"
echo "Snapshot Name:    $MATCHING_SNAPSHOT_NAME"
echo "Timestamp Match:  $TS"
echo "--------------------------------------------"

echo "--- Part 2 Complete ---"
echo ""

#---------------------------------------------------------
#  Part 2:  Snapshot Identification
#---------------------------------------------------------


