#!/bin/bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_DIR="$SCRIPT_DIR/../environments/dev"
TF_VARS="dev.tfvars"

# Priority list of Hetzner locations
LOCATIONS=("nbg1" "hel1" "fsn1")

echo -e "${YELLOW}🔄 SDP Rebuild & Verify Cycle (Production-Ready)${NC}"
echo "Working directory: $ENV_DIR"

# 1. Initial Destroy (with confirmation if not in CI)
if [[ "${CI:-}" != "true" && "${FORCE_DESTROY:-}" != "1" ]]; then
    read -rp "⚠️  Confirm initial destroy (y/N)? " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
fi

echo -e "${YELLOW}🗑️  Destroying any existing infrastructure...${NC}"
(cd "$ENV_DIR" && tofu destroy -var-file="$TF_VARS" -auto-approve) || true

APPLY_SUCCESS=false
LAST_LOCATION=""

# 2. Apply with Automatic Location Failover
for LOCATION in "${LOCATIONS[@]}"; do
    echo -e "${YELLOW}🏗️  Attempting apply in location: $LOCATION...${NC}"

    # Update tfvars temporarily
    cp "$ENV_DIR/$TF_VARS" "$ENV_DIR/${TF_VARS}.bak"
    sed -i "s/^location\s*=.*/location = \"$LOCATION\"/" "$ENV_DIR/$TF_VARS"

    # CRITICAL: If location changed from previous attempt, force a full destroy
    # to recreate the network and firewall in the new region.
    if [[ "$LOCATION" != "$LAST_LOCATION" && -n "$LAST_LOCATION" ]]; then
        echo -e "${YELLOW}⚠️  Location changed from $LAST_LOCATION to $LOCATION. Forcing full destroy to recreate network...${NC}"
        (cd "$ENV_DIR" && tofu destroy -var-file="$TF_VARS" -auto-approve) || true
    fi
    LAST_LOCATION="$LOCATION"

    # Try to apply
    echo -e "${YELLOW}🔨 Running tofu apply...${NC}"
    if (cd "$ENV_DIR" && tofu apply -var-file="$TF_VARS" -auto-approve 2>&1 | tee /tmp/tofu_apply.log); then
        APPLY_SUCCESS=true
        echo -e "${GREEN}✅ Successfully applied in $LOCATION${NC}"
        break
    else
        echo -e "${RED}❌ Apply failed in $LOCATION. Checking error...${NC}"

        # Check for specific capacity or resource_unavailable errors
        if grep -qi "unavailable\|capacity\|insufficient\|cannot move" /tmp/tofu_apply.log; then
            echo -e "${YELLOW}⚠️  Capacity or resource conflict detected. Will try next location.${NC}"
            # Restore backup (though we overwrite in next loop anyway)
            mv "$ENV_DIR/${TF_VARS}.bak" "$ENV_DIR/$TF_VARS"
            continue
        else
            echo -e "${RED}💥 Non-recoverable error. Stopping.${NC}"
            cat /tmp/tofu_apply.log
            mv "$ENV_DIR/${TF_VARS}.bak" "$ENV_DIR/$TF_VARS"
            exit 1
        fi
    fi
done

if [[ "$APPLY_SUCCESS" != "true" ]]; then
    echo -e "${RED}💥 All locations exhausted. Deployment failed.${NC}"
    exit 1
fi

# 3. Extract Master IP
echo -e "${YELLOW}🔍 Extracting Master IP...${NC}"
MASTER_IP=$(cd "$ENV_DIR" && tofu output -json server_public_ips | jq -r '.[0]')
[[ -z "$MASTER_IP" || "$MASTER_IP" == "null" ]] && { echo -e "${RED}❌ Failed to extract Master IP${NC}"; exit 1; }
export MASTER_IP
echo "Master IP: $MASTER_IP"

# 4. Wait for SSH readiness
echo -e "${YELLOW}⏳ Waiting for SSH access...${NC}"
until ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@"$MASTER_IP" "echo 'SSH ready'" >/dev/null 2>&1; do
    sleep 2
done

# 5. Run verification
echo -e "${GREEN}✅ Running verification...${NC}"
"$SCRIPT_DIR/verify-cluster.sh"

echo -e "${GREEN}🎉 Rebuild cycle complete.${NC}"