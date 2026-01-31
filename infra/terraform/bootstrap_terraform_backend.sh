#!/bin/bash

# Usage: ./bootstrap_terraform_backend.sh <resource group> <storage_account_name> <blob_container_name>
# Example: ./deploy.sh myResourceGroup mytfstateaccount mycontainer

set -euo pipefail

if [ "$#" -ne 4 ]; then
    echo "Usage: $0 <resource_group> <storage_account_name> <is_storage_account_firewalled> <container_name>"
    exit 1
fi

RESOURCE_GROUP="$1"
STORAGE_ACCOUNT="$2"
FIREWALLED="$3"
CONTAINER_NAME="$4"
LOCATION="West US"

echo "Creating resource group: $RESOURCE_GROUP"
az group create \
    --name "$RESOURCE_GROUP" \
    --location "$LOCATION"

if [ "$FIREWALLED" = "yes" ]; then
    echo "Creating firewalled storage account: $STORAGE_ACCOUNT"
    az storage account create \
        --name "$STORAGE_ACCOUNT" \
        --resource-group "$RESOURCE_GROUP" \
        --location "$LOCATION" \
        --sku Standard_LRS \
        --kind StorageV2 \
        --public-network-access Enabled \
        --default-action Deny \
        --bypass AzureServices

    echo "Getting my public IP..."
    MY_IP=$(curl -s https://api.ipify.org)
    echo "My IP is: $MY_IP"

    echo "Adding network rule for my IP..."
    az storage account network-rule add \
        --resource-group "$RESOURCE_GROUP" \
        --account-name "$STORAGE_ACCOUNT" \
        --ip-address "$MY_IP"

    echo "Pausing for 30 seconds to allow firewall rules to propagate..."
    sleep 30
    echo "Allowed IP: $MY_IP"
else
    echo "Creating storage account: $STORAGE_ACCOUNT"
    az storage account create \
        --name "$STORAGE_ACCOUNT" \
        --resource-group "$RESOURCE_GROUP" \
        --location "$LOCATION" \
        --sku Standard_LRS \
        --kind StorageV2 \
        --public-network-access Enabled \
        --default-action Allow
fi

echo "Retrieving storage account key"
ACCOUNT_KEY=$(az storage account keys list \
    --resource-group "$RESOURCE_GROUP" \
    --account-name "$STORAGE_ACCOUNT" \
    --query "[0].value" -o tsv)

echo "Creating blob container: $CONTAINER_NAME"
az storage container create \
    --name "$CONTAINER_NAME" \
    --account-name "$STORAGE_ACCOUNT" \
    --account-key "$ACCOUNT_KEY"

echo "Done!"
echo "Resource Group: $RESOURCE_GROUP"
echo "Storage Account: $STORAGE_ACCOUNT"
echo "Blob Container: $CONTAINER_NAME"
