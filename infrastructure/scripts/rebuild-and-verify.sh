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

# Parse arguments
VERBOSE=false
while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--verbose) VERBOSE=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Control tofu apply output visibility
SHOW_APPLY_OUTPUT="$VERBOSE"

# State tracking
APPLIED=false              # Tracks apply phase success
APPLY_SUCCESS=false        # Tracks overall cycle success (apply + verify)
LAST_ATTEMPTED=""
CLEANUP_DONE=false

cleanup() {
    local exit_code=$?
    [[ "$CLEANUP_DONE" == "true" ]] && return 0
    CLEANUP_DONE=true

    # Disable signal traps so Ctrl-C during cleanup doesn't kill the destroy
    trap - INT TERM

    if [[ "$APPLY_SUCCESS" != "true" && -n "$LAST_ATTEMPTED" ]]; then
        echo ""
        echo -e "${YELLOW}🧹 Cleanup triggered — full teardown...${NC}"
        "$SCRIPT_DIR/clean-all.sh"
    fi
    exit $exit_code
}
trap cleanup EXIT INT TERM

# 1. Initial Destroy via clean-all.sh
echo -e "${YELLOW}🗑️  Destroying any existing infrastructure...${NC}"
"$SCRIPT_DIR/clean-all.sh"

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
    set +e
    if [[ "$SHOW_APPLY_OUTPUT" == "true" ]]; then
        (cd "$ENV_DIR" && tofu apply -var-file="$TF_VARS" -var="location=$LOCATION" -auto-approve 2>&1 | tee /tmp/tofu_apply.log)
    else
        (cd "$ENV_DIR" && tofu apply -var-file="$TF_VARS" -var="location=$LOCATION" -auto-approve >/tmp/tofu_apply.log 2>&1)
        echo -e "${YELLOW}📋 Apply output logged to /tmp/tofu_apply.log${NC}"
    fi
    APPLY_RC=$?
    set -e

    if [[ "$APPLY_RC" -eq 0 ]]; then
        APPLIED=true
        echo -e "${GREEN}✅ Successfully applied in $LOCATION${NC}"
        break
    else
        echo -e "${RED}❌ Apply failed in $LOCATION. Checking error...${NC}"

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

if [[ "$APPLIED" != "true" ]]; then
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
until ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o LogLevel=ERROR -o UserKnownHostsFile=/dev/null root@"$MASTER_IP" "echo 'SSH ready'" >/dev/null 2>&1; do
    sleep 2
done

# 5. Run verification
echo -e "${GREEN}✅ Running verification...${NC}"
set +e
"$SCRIPT_DIR/verify-cluster.sh"
VERIFY_RC=$?
set -e

if [[ "$VERIFY_RC" -eq 0 ]]; then
    APPLY_SUCCESS=true
    echo -e "${GREEN}🎉 Rebuild cycle complete.${NC}"
else
    echo -e "${RED}❌ Verification failed. Check logs.${NC}"
    exit 1
fi