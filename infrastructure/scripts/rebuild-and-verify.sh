#!/bin/bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
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
CLEAN_FLAGS=""
[[ "$VERBOSE" == "true" ]] && CLEAN_FLAGS="-v"

# Debug log directory (created on failure)
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_DIR="$HOME/Documents/DKH Dataengineering/SDP/debug/debug-${TIMESTAMP}"
mkdir -p "$LOG_DIR" 2>/dev/null || true

APPLIED=false
APPLY_SUCCESS=false
LAST_ATTEMPTED=""
CLEANUP_DONE=false
FAILED_STEP=""

# Helper: Collect debug info before destruction
collect_debug_logs() {
    local exit_code=$1
    echo -e "${YELLOW}⚠️  Collecting debug logs before cleanup...${NC}"

    # Create log directory
    mkdir -p "$LOG_DIR"

    # Save failed step info
    {
        echo "Failed Step: ${FAILED_STEP:-unknown}"
        echo "Exit Code: $exit_code"
        echo "Last Location: ${LAST_ATTEMPTED:-none}"
        echo "Timestamp: $(date -Iseconds)"
        echo "Master IP: ${MASTER_IP:-none}"
    } > "$LOG_DIR/failure-info.txt"

    if [ -n "$MASTER_IP" ]; then
        # Cluster state
        echo "Collecting cluster state..." >&2
        ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR -o UserKnownHostsFile=/dev/null root@"$MASTER_IP" "kubectl get all --all-namespaces -o yaml" > "$LOG_DIR/all-resources.yaml" 2>&1 || true
        ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR -o UserKnownHostsFile=/dev/null root@"$MASTER_IP" "kubectl get pods -A -o wide" > "$LOG_DIR/pods.txt" 2>&1 || true
        ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR -o UserKnownHostsFile=/dev/null root@"$MASTER_IP" "kubectl get events --all-namespaces --sort-by='.lastTimestamp'" > "$LOG_DIR/events.txt" 2>&1 || true

        # Velero-specific (if we failed on Step 9+)
        if [[ "$FAILED_STEP" =~ ^[9-]|1[0-2]$ ]]; then
            echo "Collecting Velero debug info..." >&2
            ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR -o UserKnownHostsFile=/dev/null root@"$MASTER_IP" "kubectl get pods -n velero -o wide" > "$LOG_DIR/velero-pods.txt" 2>&1 || true
            ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR -o UserKnownHostsFile=/dev/null root@"$MASTER_IP" "kubectl describe application velero -n argocd" > "$LOG_DIR/velero-application.txt" 2>&1 || true
            ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR -o UserKnownHostsFile=/dev/null root@"$MASTER_IP" "kubectl logs deployment/velero -n velero --tail=200" > "$LOG_DIR/velero-server-logs.txt" 2>&1 || true
            ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR -o UserKnownHostsFile=/dev/null root@"$MASTER_IP" "kubectl get backupstoragelocations -n velero -o yaml" > "$LOG_DIR/velero-bsl.yaml" 2>&1 || true
        fi

        # ArgoCD status
        ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR -o UserKnownHostsFile=/dev/null root@"$MASTER_IP" "kubectl get applications -n argocd -o yaml" > "$LOG_DIR/argocd-apps.yaml" 2>&1 || true
        ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR -o UserKnownHostsFile=/dev/null root@"$MASTER_IP" "kubectl describe application sdp-root -n argocd" > "$LOG_DIR/argocd-root-app.txt" 2>&1 || true

        # Cloud-init status
        ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR -o UserKnownHostsFile=/dev/null root@"$MASTER_IP" "cloud-init status --long" > "$LOG_DIR/cloud-init-status.txt" 2>&1 || true

        # SSH host key info
        ssh-keyscan -H "$MASTER_IP" >> "$LOG_DIR/host-keys.txt" 2>&1 || true
    fi

    # OpenTofu state (local)
    if [ -f "$ENV_DIR/terraform.tfstate" ]; then
        cp "$ENV_DIR/terraform.tfstate" "$LOG_DIR/" 2>&1 || true
    fi
    if [ -f "$ENV_DIR/terraform.tfstate.backup" ]; then
        cp "$ENV_DIR/terraform.tfstate.backup" "$LOG_DIR/" 2>&1 || true
    fi

    # Tofu apply log (from current attempt)
    if [ -f "/tmp/tofu_apply_${LAST_ATTEMPTED}_${TIMESTAMP}.log" ]; then
        cp "/tmp/tofu_apply_${LAST_ATTEMPTED}_${TIMESTAMP}.log" "$LOG_DIR/" 2>&1 || true
    fi

    # Verify script output (captured from failure)
    if [ -n "${VERIFY_RC:-}" ] && [ "${VERIFY_RC}" != "0" ]; then
        echo "Verify Script RC: $VERIFY_RC" >> "$LOG_DIR/failure-info.txt"
    fi

    echo -e "${GREEN}✅ Debug logs saved to $LOG_DIR${NC}"
    echo -e "${CYAN}To view: ls -lh $LOG_DIR${NC}"
}

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

# Cleanup function — collects logs BEFORE destroying
cleanup() {
    local exit_code=$?
    [[ "$CLEANUP_DONE" == "true" ]] && return 0
    CLEANUP_DONE=true

    trap - INT TERM

    # Collect debug logs if there was a failure
    if [[ "$APPLY_SUCCESS" != "true" && -n "$LAST_ATTEMPTED" ]]; then
        collect_debug_logs "$exit_code"
    fi

    # Proceed with normal cleanup if build actually started
    if [[ "$APPLY_SUCCESS" != "true" && -n "$LAST_ATTEMPTED" ]]; then
        echo ""
        echo -e "${YELLOW}🧹 Cleanup triggered — full teardown...${NC}"
        "$SCRIPT_DIR/clean-all.sh" $CLEAN_FLAGS
    fi

    if [[ "$exit_code" -ne 0 ]]; then
        echo -e "${RED}❌ Build failed with exit code $exit_code${NC}"
        echo -e "${CYAN}Debug logs: $LOG_DIR${NC}"
    fi

    exit $exit_code
}
trap cleanup EXIT INT TERM

# 1. INITIAL PURGE — before ANY tofu operations
echo -e "${YELLOW}🗑️  Initial LB purge before infrastructure reset...${NC}"
purge_all_lbs "pre-build"

# 2. Destroy existing tofu-managed infrastructure
"$SCRIPT_DIR/clean-all.sh" $CLEAN_FLAGS

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
    APPLY_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    LOG_FILE="/tmp/tofu_apply_${LOCATION}_${APPLY_TIMESTAMP}.log"
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
            FAILED_STEP="tofu-apply-${LOCATION}-capacity"
            continue
        else
            echo -e "${RED}💥 Non-recoverable error:${NC}"
            tail -50 "$LOG_FILE"
            FAILED_STEP="tofu-apply-${LOCATION}-error"
            exit 1
        fi
    fi
done

if [[ "$APPLIED" != "true" ]]; then
    echo -e "${RED}💥 All locations exhausted. Deployment failed.${NC}"
    FAILED_STEP="all-locations-exhausted"
    exit 1
fi

# 4. Extract Master IP with state refresh
echo -e "${YELLOW}🔍 Extracting Master IP...${NC}"
(cd "$ENV_DIR" && tofu refresh -var-file="$TF_VARS" -auto-approve >/dev/null 2>&1) || true
MASTER_IP=$(cd "$ENV_DIR" && tofu output -json server_public_ips | jq -r '.[0]')
[[ -z "$MASTER_IP" || "$MASTER_IP" == "null" ]] && { echo -e "${RED}❌ Failed to extract Master IP${NC}"; FAILED_STEP="extract-master-ip"; exit 1; }
export MASTER_IP
echo "Master IP: $MASTER_IP"

# 5. Wait for SSH readiness
FAILED_STEP="ssh-wait"
echo -e "${YELLOW}⏳ Waiting for SSH access...${NC}"
until ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o LogLevel=ERROR -o UserKnownHostsFile=/dev/null root@"$MASTER_IP" "echo 'SSH ready'" >/dev/null 2>&1; do
    sleep 2
done

# 6. Wait for cloud-init to complete (poll every 10s)
echo -e "${YELLOW}⏳ Waiting for cloud-init to complete...${NC}"
FAILED_STEP="cloud-init-wait"
for _ in $(seq 1 60); do
    CI_STATUS=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@"$MASTER_IP" "cloud-init status" 2>/dev/null || echo "")
    if echo "$CI_STATUS" | grep -q "status: done"; then
        break
    fi
    if echo "$CI_STATUS" | grep -q "status: error"; then
        echo -e "\n${RED}❌ cloud-init reported error:${NC}"
        echo "$CI_STATUS"
        FAILED_STEP="cloud-init-error"
        exit 1
    fi
    echo -n "."
    sleep 10
done
echo -e "${GREEN}✅ cloud-init complete.${NC}"

# 7. Run verification
echo -e "${GREEN}✅ Running verification...${NC}"
FAILED_STEP="verify-cluster"
set +e
"$SCRIPT_DIR/verify-cluster.sh"
VERIFY_RC=$?
set -e

if [[ "$VERIFY_RC" -eq 0 ]]; then
    APPLY_SUCCESS=true
    FAILED_STEP=""
    echo -e "${GREEN}🎉 Rebuild cycle complete.${NC}"
else
    echo -e "${RED}❌ Verification failed. Cleanup will trigger.${NC}"
    exit 1
fi