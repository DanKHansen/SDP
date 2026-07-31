#!/usr/bin/env bash
#==============================================================================
# test-backup-restore.sh — Automated Velero Backup/Restore Validation
# Part of SDP Phase 0 final validation gate
#
# Tests: Populate → Backup → Destroy → Restore → Verify Data Integrity
#
# Usage: ./test-backup-restore.sh [-v|--verbose]
#
# Exit codes:
#   0 — All steps passed, data integrity verified
#   1 — Any step failed (details in output)
#==============================================================================

set -euo pipefail

# --- Configuration ---
NAMESPACE="test-backup"
STATEFULSET="postgres-test"
POD_NAME="${STATEFULSET}-0"
DB_NAME="testdb"
DB_USER="postgres"
DB_PASS="testpassword123"
APP_NAME="test-backup"
ARGOCD_NS="argocd"
BACKUP_NAME="sdp-test-$(date +%Y%m%d-%H%M%S)"
RESTORE_NAME="sdp-restore-$(date +%Y%m%d-%H%M%S)"
TEST_TABLE="backup_validation"
MARKER="SDP_PHASE0_$(date +%s)"
MAX_WAIT=300          # 5 minutes max per wait operation
POLL_INTERVAL=5

# --- Verbose mode ---
VERBOSE=false
if [[ "${1:-}" == "-v" || "${1:-}" == "--verbose" ]]; then
  VERBOSE=true
fi

# --- Helpers ---
log()   { echo "[$(date '+%H:%M:%S')] $*"; }
debug() { $VERBOSE && echo "[$(date '+%H:%M:%S')] [DEBUG] $*" || true; }

# --- State tracking ---
ARGOCD_SUSPENDED=false
TEST_DATA_INSERTED=false
BACKUP_CREATED=false

cleanup() {
  local exit_code=$?
  if [[ "$ARGOCD_SUSPENDED" == "true" && $exit_code -ne 0 ]]; then
    log "WARNING: Failure during suspended ArgoCD — resuming sync to restore cluster state"
    kubectl patch application "$APP_NAME" -n "$ARGOCD_NS" --type='merge' -p='{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}' 2>/dev/null || true
  fi
  if [[ $exit_code -eq 0 ]]; then
    log "✅ All steps passed — backup/restore validated"
  else
    log "❌ Test FAILED at exit code $exit_code"
  fi
  exit $exit_code
}

trap cleanup EXIT

# --- Wait helpers ---
wait_for() {
  local label="$1"; shift
  local elapsed=0
  while ! "$@" >/dev/null 2>&1; do
    sleep $POLL_INTERVAL
    elapsed=$((elapsed + POLL_INTERVAL))
    if [[ $elapsed -ge $MAX_WAIT ]]; then
      log "❌ TIMEOUT waiting for: $label (waited ${elapsed}s)"
      return 1
    fi
    debug "Waiting for: $label (${elapsed}s/${MAX_WAIT}s)"
  done
  log "✅ $label ready (${elapsed}s)"
}

wait_for_velero_phase() {
  local resource="$1"    # backup or restore
  local name="$2"
  local phase="$3"       # Completed
  local elapsed=0
  while true; do
    local status
    status=$(kubectl get "$resource" "$name" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [[ "$status" == "$phase" ]]; then
      log "✅ $resource '$name' reached phase: $phase (${elapsed}s)"
      return 0
    fi
    # Check for terminal failure phases
    if [[ "$status" == "Failed" || "$status" == "PartiallyFailed" ]]; then
      log "❌ $resource '$name' entered phase: $status"
      return 1
    fi
    sleep $POLL_INTERVAL
    elapsed=$((elapsed + POLL_INTERVAL))
    if [[ $elapsed -ge $MAX_WAIT ]]; then
      log "❌ TIMEOUT: $resource '$name' never reached $phase (waited ${elapsed}s, last status: ${status:-none})"
      return 1
    fi
    debug "$resource '$name' status: ${status:-pending} (${elapsed}s/${MAX_WAIT}s)"
  done
}

# ============================================================================
# STEP 1: Verify prerequisites
# ============================================================================
log "=== Step 1: Verify Prerequisites ==="

# Velero must be running
VELERO_PODS=$(kubectl get deployment velero -n velero -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
if [[ "$VELERO_PODS" -lt 1 ]]; then
  log "❌ Velero deployment not ready (${VELERO_PODS}/1 replicas)"
  exit 1
fi
debug "Velero deployment: ${VELERO_PODS}/1 replicas"

# Node-Agent must be running
NODE_AGENT=$(kubectl get daemonset node-agent -n velero -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
if [[ "$NODE_AGENT" -lt 1 ]]; then
  log "❌ Velero node-agent daemonset not ready (${NODE_AGENT} pods)"
  exit 1
fi
debug "Node-agent pods: ${NODE_AGENT}"

# Backup Storage Location must be Available
BSL_PHASE=$(kubectl get backupstoragelocation -n velero default -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
if [[ "$BSL_PHASE" != "Available" ]]; then
  log "❌ Backup Storage Location not Available (current: ${BSL_PHASE:-unknown})"
  exit 1
fi
debug "BSL phase: $BSL_PHASE"

# Test workload must be running
TEST_PODS=$(kubectl get statefulset "$STATEFULSET" -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "")
if [[ -z "$TEST_PODS" || "$TEST_PODS" -lt 1 ]]; then
  log "❌ Test workload not running (${STATEFULSET} not found or 0 replicas)"
  exit 1
fi
debug "Test workload: ${TEST_PODS}/1 replicas"

log "All prerequisites verified"

# ============================================================================
# STEP 2: Populate test data
# ============================================================================
log "=== Step 2: Populate Test Data ==="

# Wait for pod to be ready
wait_for "pod ${POD_NAME} Running" \
  kubectl get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Running

# Insert a marker row we can verify after restore
log "Inserting marker row: $MARKER"

kubectl exec -n "$NAMESPACE" "$POD_NAME" -- \
  psql -U "$DB_USER" -d "$DB_NAME" -c "DROP TABLE IF EXISTS ${TEST_TABLE};" 2>/dev/null || true

kubectl exec -n "$NAMESPACE" "$POD_NAME" -- \
  psql -U "$DB_USER" -d "$DB_NAME" -c "
    CREATE TABLE ${TEST_TABLE} (
      id SERIAL PRIMARY KEY,
      marker TEXT NOT NULL,
      created_at TIMESTAMP DEFAULT NOW()
    );
  "

kubectl exec -n "$NAMESPACE" "$POD_NAME" -- \
  psql -U "$DB_USER" -d "$DB_NAME" -c "INSERT INTO ${TEST_TABLE} (marker) VALUES ('${MARKER}');"

# Verify the insert worked
ROW_COUNT=$(kubectl exec -n "$NAMESPACE" "$POD_NAME" -- \
  psql -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM ${TEST_TABLE} WHERE marker = '${MARKER}';" 2>/dev/null | tr -d ' ')

if [[ "${ROW_COUNT:-0}" -ne 1 ]]; then
  log "❌ Failed to insert test data (row count: ${ROW_COUNT:-0})"
  exit 1
fi

TEST_DATA_INSERTED=true
log "Test data inserted and verified (marker: $MARKER)"

# ============================================================================
# STEP 3: Create Velero backup
# ============================================================================
log "=== Step 3: Create Velero Backup ==="

log "Creating backup: $BACKUP_NAME (namespace: $NAMESPACE)"
velero backup create "$BACKUP_NAME" \
  --include-namespaces "$NAMESPACE" \
  --wait \
  --timeout 5m 2>/dev/null || true

# Even with --wait, poll explicitly to be sure
wait_for_velero_phase backup "$BACKUP_NAME" Completed

BACKUP_CREATED=true
log "Backup completed: $BACKUP_NAME"

# Verify backup has volume snapshots
VOLUME_SNAPSHOTS=$(kubectl get backup "$BACKUP_NAME" -o jsonpath='{.status.volumeBackups}' 2>/dev/null | jq 'length' 2>/dev/null || echo "0")
debug "Volume snapshots in backup: ${VOLUME_SNAPSHOTS}"
if [[ "${VOLUME_SNAPSHOTS:-0}" -lt 1 ]]; then
  log "⚠️  WARNING: No volume snapshots in backup — PVC data may not be captured. Continuing anyway..."
fi

# ============================================================================
# STEP 4: Delete test workload
# ============================================================================
log "=== Step 4: Delete Test Workload ==="

# Suspend ArgoCD auto-sync to prevent it from immediately recreating the namespace
log "Suspending ArgoCD auto-sync for: $APP_NAME"
kubectl patch application "$APP_NAME" -n "$ARGOCD_NS" \
  --type='json' \
  -p='[{"op":"replace","path":"/spec/syncPolicy/automated","value":null}]' 2>/dev/null || true

ARGOCD_SUSPENDED=true
log "ArgoCD auto-sync suspended"

# Delete the namespace (this removes pods + PVCs)
log "Deleting namespace: $NAMESPACE"
kubectl delete namespace "$NAMESPACE" --ignore-not-found=true

# Wait for namespace to be gone
wait_for "namespace $NAMESPACE deleted" \
  bash -c "! kubectl get namespace '$NAMESPACE' >/dev/null 2>&1"

# Wait for PVC to be fully gone
wait_for "PVC data-${POD_NAME} deleted" \
  bash -c "! kubectl get pvc \"data-${POD_NAME}\" -n '$NAMESPACE' >/dev/null 2>&1"

log "Namespace and all resources deleted"

# ============================================================================
# STEP 5: Restore from backup
# ============================================================================
log "=== Step 5: Restore from Backup ==="

log "Creating restore: $RESTORE_NAME from backup: $BACKUP_NAME"
velero restore create "$RESTORE_NAME" \
  --from-backup "$BACKUP_NAME" \
  --wait \
  --timeout 5m 2>/dev/null || true

wait_for_velero_phase restore "$RESTORE_NAME" Completed

# Check restore results for warnings/errors
RESTORE_ERRORS=$(kubectl get restore "$RESTORE_NAME" -o jsonpath='{.status.errors}' 2>/dev/null || echo "0")
RESTORE_WARNINGS=$(kubectl get restore "$RESTORE_NAME" -o jsonpath='{.status.warnings}' 2>/dev/null || echo "0")
debug "Restore errors: ${RESTORE_ERRORS}, warnings: ${RESTORE_WARNINGS}"

log "Restore completed: $RESTORE_NAME"

# ============================================================================
# STEP 6: Verify restored workload
# ============================================================================
log "=== Step 6: Verify Restored Workload ==="

# Wait for StatefulSet to come back
wait_for "StatefulSet $STATEFULSET exists" \
  kubectl get statefulset "$STATEFULSET" -n "$NAMESPACE" 2>/dev/null | grep -q .

wait_for "StatefulSet $STATEFULSET ready (1/1)" \
  bash -c "[ \"\$(kubectl get statefulset $STATEFULSET -n $NAMESPACE -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)\" -ge 1 ]"

# Wait for pod to be Running
wait_for "pod ${POD_NAME} Running" \
  kubectl get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Running

log "Restored workload is running"

# ============================================================================
# STEP 7: Verify data integrity
# ============================================================================
log "=== Step 7: Verify Data Integrity ==="

# Give PostgreSQL a moment to initialize
sleep 5

RESTORED_MARKER=$(kubectl exec -n "$NAMESPACE" "$POD_NAME" -- \
  psql -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT marker FROM ${TEST_TABLE} LIMIT 1;" 2>/dev/null | tr -d ' \n')

if [[ "$RESTORED_MARKER" == "$MARKER" ]]; then
  log "✅ Data integrity VERIFIED — marker '$RESTORED_MARKER' matches expected '$MARKER'"
else
  log "❌ Data integrity FAILED — expected '$MARKER', got '${RESTORED_MARKER:-empty}'"
  exit 1
fi

# ============================================================================
# STEP 8: Resume ArgoCD and cleanup
# ============================================================================
log "=== Step 8: Resume ArgoCD ==="

# Re-enable ArgoCD auto-sync
kubectl patch application "$APP_NAME" -n "$ARGOCD_NS" \
  --type='merge' \
  -p='{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}' 2>/dev/null || true

ARGOCD_SUSPENDED=false
log "ArgoCD auto-sync resumed"

# ============================================================================
# SUMMARY
# ============================================================================
echo ""
log "============================================="
log "  SDP Phase 0 — Backup/Restore Test PASSED"
log "============================================="
log "Backup:    $BACKUP_NAME"
log "Restore:   $RESTORE_NAME"
log "Marker:    $MARKER"
log "Verified:  Data intact after destroy → restore"
log "============================================="
echo ""

exit 0