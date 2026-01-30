#!/bin/bash
# Script to generate linkerd multicluster kubeconfigs and store them in Vault
# This script should be run after the multicluster extension is deployed

set -e

# Configuration
VAULT_ADDR="${VAULT_ADDR:-https://hcvault.mattgerega.net}"
VAULT_PATH="secrets-k8/linkerd-multicluster"
INTERNAL_CONTEXT="internal"
INTERNAL_CLUSTER_NAME="in-cluster-local"
GATEWAY_ADDRESS="tfx-internal.gerega.net:30143"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Linkerd Multicluster Kubeconfig to Vault ===${NC}"
echo ""

# Check if logged into Vault
if ! vault token lookup &>/dev/null; then
    echo -e "${RED}Error: Not logged into Vault. Please run 'vault login' first.${NC}"
    exit 1
fi

echo -e "${YELLOW}This script will:${NC}"
echo "1. Generate kubeconfig for production -> internal link"
echo "2. Generate kubeconfig for nonproduction -> internal link"
echo "3. Store them in Vault at: ${VAULT_PATH}"
echo ""
read -p "Continue? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 0
fi

# Function to generate and store kubeconfig
store_kubeconfig() {
    local SOURCE_CLUSTER=$1
    local SERVICE_ACCOUNT_NAME=$2
    local VAULT_KEY=$3

    echo -e "${GREEN}Generating kubeconfig for ${SOURCE_CLUSTER} -> ${INTERNAL_CLUSTER_NAME}...${NC}"

    # Generate the kubeconfig using linkerd multicluster link-gen
    KUBECONFIG_DATA=$(linkerd --context=${INTERNAL_CONTEXT} multicluster link-gen \
        --cluster-name ${INTERNAL_CLUSTER_NAME} \
        --gateway-addresses ${GATEWAY_ADDRESS} \
        --service-account-name ${SERVICE_ACCOUNT_NAME} | \
        grep -A 1000 "kind: Secret" | \
        grep "kubeconfig:" | \
        head -1 | \
        awk '{print $2}')

    if [ -z "$KUBECONFIG_DATA" ]; then
        echo -e "${RED}Error: Failed to generate kubeconfig${NC}"
        return 1
    fi

    echo -e "${GREEN}Storing kubeconfig in Vault at ${VAULT_PATH}/${VAULT_KEY}...${NC}"

    # Store in Vault
    vault kv put ${VAULT_PATH}/${VAULT_KEY} kubeconfig="${KUBECONFIG_DATA}"

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Successfully stored ${VAULT_KEY} in Vault${NC}"
    else
        echo -e "${RED}✗ Failed to store ${VAULT_KEY} in Vault${NC}"
        return 1
    fi

    echo ""
}

# Generate and store production kubeconfig
store_kubeconfig \
    "production" \
    "linkerd-service-mirror-remote-access-production" \
    "production-to-internal"

# Generate and store nonproduction kubeconfig
store_kubeconfig \
    "nonproduction" \
    "linkerd-service-mirror-remote-access-nonproduction" \
    "nonproduction-to-internal"

echo -e "${GREEN}=== Complete ===${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "1. Commit and push the multicluster Helm chart updates"
echo "2. ArgoCD will sync and create ExternalSecrets"
echo "3. ExternalSecrets will pull kubeconfigs from Vault"
echo "4. Linkerd multicluster links will be established"
echo ""
echo "Verify with:"
echo "  linkerd --context=production multicluster check"
echo "  linkerd --context=nonproduction multicluster check"
