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

# Parse arguments
VERBOSE=false
while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--verbose) VERBOSE=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Helper: Purge all LBs with retry
purge_lbs() {
    local label="$1"
    echo -e "${YELLOW}🧹 Removing all LoadBalancers ($label)...${NC}"
    for RETRY in 1 2 3 4 5; do
        ORPHAN_LBS=$(hcloud load-balancer list -o no-header -o columns=id,name 2>/dev/null || echo "")
        if [[ -z "$ORPHAN_LBS" ]]; then
            echo "   No LoadBalancers found."
            return 0
        fi
        local remaining=0
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            LB_ID=$(echo "$line" | awk '{print $1}')
            LB_NAME=$(echo "$line" | awk '{print $2}')
            if [[ "$VERBOSE" == "true" ]]; then
                echo "   Deleting LB: $LB_ID ($LB_NAME)"
            fi
            if hcloud load-balancer delete "$LB_ID" 2>/dev/null; then
                [[ "$VERBOSE" == "true" ]] && echo -e "   ${GREEN}Deleted LB $LB_ID ($LB_NAME)${NC}"
            else
                remaining=$((remaining+1))
            fi
        done <<< "$ORPHAN_LBS"
        if [[ "$remaining" -eq 0 ]]; then
            echo -e "   ${GREEN}All LoadBalancers purged.${NC}"
            return 0
        fi
        echo -e "   ${YELLOW}Attempt $RETRY: $remaining LBs remain, waiting 10s...${NC}"
        sleep 10
    done
    echo -e "   ${RED}Could not purge all LBs after 5 attempts.${NC}"
}

# STEP 1: Purge LBs BEFORE tofu destroy
# CCM-managed LBs are not in tofu state. Deleting them first prevents
# stale LBs from blocking network resource deletion during tofu destroy.
purge_lbs "pre-destroy"

# STEP 2: Destroy tofu-managed infrastructure
echo -e "${YELLOW}🗑️  Destroying tofu-managed infrastructure...${NC}"
set +e
if [[ "$VERBOSE" == "true" ]]; then
    (cd "$ENV_DIR" && tofu destroy -var-file="$TF_VARS" -auto-approve)
else
    (cd "$ENV_DIR" && tofu destroy -var-file="$TF_VARS" -auto-approve >/dev/null 2>&1)
fi
TOFU_RC=$?
set -e

if [[ "$TOFU_RC" -ne 0 ]]; then
    echo -e "${RED}⚠️  Tofu destroy completed with warnings or partial cleanup.${NC}"
fi

# STEP 3: Wait for CCM to deregister any LBs that existed during destroy
# CCM runs a reconciliation loop; it may take 10-30 seconds after node deletion
# to fully deregister and delete the associated Hetzner LoadBalancer.
echo -e "${YELLOW}⏳ Waiting 30s for CCM to deregister LoadBalancers...${NC}"
sleep 30

# STEP 4: Final LB sweep — catch anything CCM didn't clean up
purge_lbs "post-destroy"

echo -e "${GREEN}🎉 Cleanup complete.${NC}"