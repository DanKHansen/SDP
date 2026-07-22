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

# State tracking
APPLY_SUCCESS=false
LAST_ATTEMPTED=""

echo -e "${YELLOW}🔄 SDP Rebuild & Verify Cycle (Production-Ready)${NC}"
echo "Working directory: $ENV_DIR"

# Cleanup function — destroys orphaned resources on failure
cleanup() {
    local exit_code=$?
    if [[ "$APPLY_SUCCESS" != "true" && -n "$LAST_ATTEMPTED" ]]; then
        echo ""
        echo -e "${YELLOW}🧹 Cleanup triggered — destroying orphaned resources in $LAST_ATTEMPTED...${NC}"
        (cd "$ENV_DIR" && tofu destroy -var-file="$TF_VARS" -var="location=$LAST_ATTEMPTED" -auto-approve) || {
            echo -e "${RED}⚠️  Cleanup failed. Manual intervention required:${NC}"
            echo "   tofu -chdir=$ENV_DIR destroy -var-file=$TF_VARS -var='location=$LAST_ATTEMPTED'"
        }
    fi
    exit $exit_code
}
trap cleanup EXIT ERR INT TERM

# 1. Initial Destroy (with confirmation if not in CI)
if [[ "${CI:-}" != "true" && "${FORCE_DESTROY:-}" != "1" ]]; then
    read -rp "⚠️  Confirm initial destroy (y/N)? " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
fi

echo -e "${YELLOW}🗑️  Destroying any existing infrastructure...${NC}"
(cd "$ENV_DIR" && tofu destroy -var-file="$TF_VARS" -auto-approve) || true

# 2. Apply with Automatic Location Failover
for LOCATION in "${LOCATIONS[@]}"; do
    LAST_ATTEMPTED="$LOCATION"
    echo -e "${YELLOW}🏗️  Attempting apply in location: $LOCATION...${NC}"

    # CRITICAL: If location changed from previous attempt, force a full destroy
    # to recreate the network and firewall in the new region.
    if [[ "$LOCATION" != "${PREV_LOCATION:-}" && -n "${PREV_LOCATION:-}" ]]; then
        echo -e "${YELLOW}⚠️  Location changed from ${PREV_LOCATION} to $LOCATION. Forcing full destroy to recreate network...${NC}"
        (cd "$ENV_DIR" && tofu destroy -var-file="$TF_VARS" -var="location=$PREV_LOCATION" -auto-approve) || true
    fi
    PREV_LOCATION="$LOCATION"

    # Try to apply — override location via CLI var, never mutate dev.tfvars
    echo -e "${YELLOW}🔨 Running tofu apply...${NC}"
    if (cd "$ENV_DIR" && tofu apply -var-file="$TF_VARS" -var="location=$LOCATION" -auto-approve 2>&1 | tee /tmp/tofu_apply.log); then
        APPLY_SUCCESS=true
        echo -e "${GREEN}✅ Successfully applied in $LOCATION${NC}"
        break
    else
        echo -e "${RED}❌ Apply failed in $LOCATION. Checking error...${NC}"

        # Check for specific capacity or resource_unavailable errors
        if grep -qi "unavailable\|capacity\|insufficient\|cannot move" /tmp/tofu_apply.log; then
            echo -e "${YELLOW}⚠️  Capacity or resource conflict detected. Will try next location.${NC}"
            continue
        else
            echo -e "${RED}💥 Non-recoverable error. Stopping.${NC}"
            cat /tmp/tofu_apply.log
            exit 1
        fi
    fi
done

if [[ "$APPLY_SUCCESS" != "true" ]]; then
    echo -e "${RED}💥 All locations exhausted. Deployment failed.${NC}"
    exit 1
fi

# 3. Extract Master IP (dev.tfvars intact — location is the successful one)
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