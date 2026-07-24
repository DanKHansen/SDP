#!/bin/bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_DIR="$SCRIPT_DIR/../environments/dev"
TF_VARS="dev.tfvars"
LOCATIONS=("nbg1" "hel1" "fsn1")

VERBOSE=false
while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--verbose) VERBOSE=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

SHOW_APPLY_OUTPUT="$VERBOSE"

APPLIED=false
APPLY_SUCCESS=false
LAST_ATTEMPTED=""
CLEANUP_DONE=false

# Helper: Purge ALL Hetzner LoadBalancers with retry
purge_all_lbs() {
    local phase="${1:-unknown}"
    echo -e "${YELLOW}🧹 Purging all LoadBalancers (phase: $phase)...${NC}"

    for RETRY in 1 2 3 4 5; do
        ORPHAN_LBS=$(hcloud load-balancer list -o noheader -o columns=id,name 2>/dev/null || echo "")

        if [[ -z "$ORPHAN_LBS" ]]; then
            echo -e "   ${GREEN}No LoadBalancers found.${NC}"
            return 0
        fi

        local deleted_count=0
        local failed_count=0

        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            LB_ID=$(echo "$line" | awk '{print $1}')
            LB_NAME=$(echo "$line" | awk '{print $2}')

            if [[ "$VERBOSE" == "true" ]]; then
                echo "   Deleting: $LB_ID ($LB_NAME)"
            fi

            if hcloud load-balancer delete "$LB_ID" 2>&1; then
                ((deleted_count++))
                [[ "$VERBOSE" == "true" ]] && echo -e "   ${GREEN}✓ Deleted $LB_ID${NC}"
            else
                ((failed_count++))
                echo -e "   ${RED}✗ Failed to delete $LB_ID${NC}" >&2
            fi
        done <<< "$ORPHAN_LBS"

        REMAINING=$(hcloud load-balancer list -o noheader -o columns=id 2>/dev/null | wc -l || echo "0")

        if [[ "$REMAINING" -eq 0 ]]; then
            echo -e "   ${GREEN}All LoadBalancers purged ($deleted_count deleted).${NC}"
            return 0
        fi

        echo -e "   ${YELLOW}Attempt $RETRY: $REMAINING LB(s) remain, deleting $failed_count failed, waiting 10s...${NC}"
        sleep 10
    done

    echo -e "   ${RED}⚠️  Could not purge all LBs after 5 attempts ($failed_count failed).${NC}"
    return 1
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

# 1. INITIAL PURGE — before ANY tofu operations
echo -e "${YELLOW}🗑️  Initial LB purge before infrastructure reset...${NC}"
purge_all_lbs "pre-build"

# 2. Destroy existing tofu-managed infrastructure
"$SCRIPT_DIR/clean-all.sh"

# 3. Apply with Automatic Location Failover
for LOCATION in "${LOCATIONS[@]}"; do
    LAST_ATTEMPTED="$LOCATION"
    echo -e "${YELLOW}🏗️  Attempting apply in location: $LOCATION...${NC}"

    # Location change: force full teardown
    if [[ "$LOCATION" != "${PREV_LOCATION:-}" && -n "${PREV_LOCATION:-}" ]]; then
        echo -e "${YELLOW}⚠️  Location changed from ${PREV_LOCATION} to $LOCATION.${NC}"

        purge_all_lbs "location-change"
        rm -f "$ENV_DIR/.terraform.lock.hcl" "$ENV_DIR/terraform.tfstate.backup" 2>/dev/null || true
        (cd "$ENV_DIR" && tofu init -reconfigure -input=false >/dev/null 2>&1) || true
        (cd "$ENV_DIR" && tofu destroy -var-file="$TF_VARS" -var="location=$LOCATION" -auto-approve) || true
        purge_all_lbs "location-change-post-destroy"

        PREV_LOCATION="$LOCATION"
    fi

    # Apply
    echo -e "${YELLOW}🔨 Running tofu apply...${NC}"
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    LOG_FILE="/tmp/tofu_apply_${LOCATION}_${TIMESTAMP}.log"
    set +e
    if [[ "$SHOW_APPLY_OUTPUT" == "true" ]]; then
        (cd "$ENV_DIR" && tofu apply -var-file="$TF_VARS" -var="location=$LOCATION" -auto-approve 2>&1 | tee "$LOG_FILE")
    else
        (cd "$ENV_DIR" && tofu apply -var-file="$TF_VARS" -var="location=$LOCATION" -auto-approve >"$LOG_FILE" 2>&1)
        echo -e "${YELLOW}📋 Logged to $LOG_FILE${NC}"
    fi
    APPLY_RC=$?
    set -e

    if [[ "$APPLY_RC" -eq 0 ]]; then
        APPLIED=true
        echo -e "${GREEN}✅ Successfully applied in $LOCATION${NC}"
        break
    else
        echo -e "${RED}❌ Apply failed in $LOCATION.${NC}"
        if grep -qi "unavailable\|capacity\|insufficient\|cannot move" "$LOG_FILE"; then
            echo -e "${YELLOW}⚠️  Capacity conflict. Trying next location.${NC}"
            continue
        else
            echo -e "${RED}💥 Non-recoverable error:${NC}"
            tail -50 "$LOG_FILE"
            exit 1
        fi
    fi
done

if [[ "$APPLIED" != "true" ]]; then
    echo -e "${RED}💥 All locations exhausted. Deployment failed.${NC}"
    exit 1
fi

# 4. Extract Master IP with state refresh
echo -e "${YELLOW}🔍 Extracting Master IP...${NC}"
(cd "$ENV_DIR" && tofu refresh -var-file="$TF_VARS" -auto-approve >/dev/null 2>&1) || true
MASTER_IP=$(cd "$ENV_DIR" && tofu output -json server_public_ips | jq -r '.[0]')
[[ -z "$MASTER_IP" || "$MASTER_IP" == "null" ]] && { echo -e "${RED}❌ Failed to extract Master IP${NC}"; exit 1; }
export MASTER_IP
echo "Master IP: $MASTER_IP"

# 5. Wait for SSH readiness
echo -e "${YELLOW}⏳ Waiting for SSH access...${NC}"
until ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o LogLevel=ERROR -o UserKnownHostsFile=/dev/null root@"$MASTER_IP" "echo 'SSH ready'" >/dev/null 2>&1; do
    sleep 2
done
sleep 10

# 6. Run verification
echo -e "${GREEN}✅ Running verification...${NC}"
set +e
"$SCRIPT_DIR/verify-cluster.sh"
VERIFY_RC=$?
set -e

if [[ "$VERIFY_RC" -eq 0 ]]; then
    APPLY_SUCCESS=true
    echo -e "${GREEN}🎉 Rebuild cycle complete.${NC}"
else
    echo -e "${RED}❌ Verification failed. Cleanup will trigger.${NC}"
    exit 1
fi