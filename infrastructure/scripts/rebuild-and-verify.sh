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

SHOW_APPLY_OUTPUT="$VERBOSE"

# State tracking
APPLIED=false
APPLY_SUCCESS=false
LAST_ATTEMPTED=""
CLEANUP_DONE=false

# Helper: Aggressively purge ALL Hetzner LoadBalancers with retry
purge_all_lbs() {
    echo -e "${YELLOW}🧹 Purging all LoadBalancers (with retry)...${NC}"
    for RETRY in 1 2 3 4 5; do
        ORPHAN_LBS=$(hcloud load-balancer list -o no-header -o columns=id 2>/dev/null || echo "")
        if [[ -z "$ORPHAN_LBS" ]]; then
            echo -e "   ${GREEN}All LoadBalancers purged.${NC}"
            return 0
        fi
        while IFS= read -r lb_id; do
            [[ -z "$lb_id" ]] && continue
            hcloud load-balancer delete "$lb_id" 2>/dev/null || true
        done <<< "$ORPHAN_LBS"
        REMAINING=$(hcloud load-balancer list -o no-header -o columns=id 2>/dev/null | wc -l || echo "0")
        if [[ "$REMAINING" -eq 0 ]]; then
            echo -e "   ${GREEN}All LoadBalancers purged.${NC}"
            return 0
        fi
        echo -e "   ${YELLOW}Attempt $RETRY: $REMAINING LBs still exist, waiting 10s...${NC}"
        sleep 10
    done
    echo -e "   ${RED}Could not purge all LBs after 5 attempts. Continuing anyway.${NC}"
}

cleanup() {
    local exit_code=$?
    [[ "$CLEANUP_DONE" == "true" ]] && return 0
    CLEANUP_DONE=true

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

    # Location change: aggressive LB purge + state reset + full destroy
    if [[ "$LOCATION" != "${PREV_LOCATION:-}" && -n "${PREV_LOCATION:-}" ]]; then
        echo -e "${YELLOW}⚠️  Location changed from ${PREV_LOCATION} to $LOCATION. Forcing full teardown...${NC}"

        # Purge ALL LBs first (CCM-managed, not in tofu state)
        # Retry loop because CCM needs time to deregister after node deletion
        purge_all_lbs

        # Remove stale state to force fresh planning
        rm -f "$ENV_DIR/.terraform.lock.hcl" "$ENV_DIR/terraform.tfstate.backup" 2>/dev/null || true
        (cd "$ENV_DIR" && tofu init -reconfigure -input=false >/dev/null 2>&1) || true

        # Force destroy any remaining tofu resources
        (cd "$ENV_DIR" && tofu destroy -var-file="$TF_VARS" -var="location=$LOCATION" -auto-approve) || true

        # Second LB sweep after destroy (nodes gone, CCM should have deregistered)
        purge_all_lbs
    fi
    PREV_LOCATION="$LOCATION"

    # Apply — override location via CLI var, never mutate dev.tfvars
    echo -e "${YELLOW}🔨 Running tofu apply...${NC}"
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    LOG_FILE="/tmp/tofu_apply_${LOCATION}_${TIMESTAMP}.log"
    set +e
    if [[ "$SHOW_APPLY_OUTPUT" == "true" ]]; then
        (cd "$ENV_DIR" && tofu apply -var-file="$TF_VARS" -var="location=$LOCATION" -auto-approve 2>&1 | tee "$LOG_FILE")
    else
        (cd "$ENV_DIR" && tofu apply -var-file="$TF_VARS" -var="location=$LOCATION" -auto-approve >"$LOG_FILE" 2>&1)
        echo -e "${YELLOW}📋 Apply output logged to $LOG_FILE${NC}"
    fi
    APPLY_RC=$?
    set -e

    if [[ "$APPLY_RC" -eq 0 ]]; then
        APPLIED=true
        echo -e "${GREEN}✅ Successfully applied in $LOCATION${NC}"
        break
    else
        echo -e "${RED}❌ Apply failed in $LOCATION. Checking error...${NC}"

        if grep -qi "unavailable\|capacity\|insufficient\|cannot move" "$LOG_FILE"; then
            echo -e "${YELLOW}⚠️  Capacity or resource conflict detected. Will try next location.${NC}"
            continue
        else
            echo -e "${RED}💥 Non-recoverable error. Stopping.${NC}"
            cat "$LOG_FILE"
            exit 1
        fi
    fi
done

if [[ "$APPLIED" != "true" ]]; then
    echo -e "${RED}💥 All locations exhausted. Deployment failed.${NC}"
    exit 1
fi

# 3. Extract Master IP with state refresh
echo -e "${YELLOW}🔍 Extracting Master IP...${NC}"
(cd "$ENV_DIR" && tofu refresh -var-file="$TF_VARS" -auto-approve >/dev/null 2>&1) || true
MASTER_IP=$(cd "$ENV_DIR" && tofu output -json server_public_ips | jq -r '.[0]')
[[ -z "$MASTER_IP" || "$MASTER_IP" == "null" ]] && { echo -e "${RED}❌ Failed to extract Master IP${NC}"; exit 1; }
export MASTER_IP
echo "Master IP: $MASTER_IP"

# 4. Wait for SSH readiness + buffer for cloud-init
echo -e "${YELLOW}⏳ Waiting for SSH access...${NC}"
until ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o LogLevel=ERROR -o UserKnownHostsFile=/dev/null root@"$MASTER_IP" "echo 'SSH ready'" >/dev/null 2>&1; do
    sleep 2
done
# Buffer: cloud-init runcmd may still be executing K3s installation
sleep 10

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