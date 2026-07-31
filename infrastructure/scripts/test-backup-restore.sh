#!/usr/bin/env bash
#==============================================================================
# test-backup-restore.sh — Automated Velero Backup/Restore Validation
# Phase 0 final validation gate
#
# Tests: Populate → Backup → Destroy → Restore → Verify Data Integrity
# Usage: ./test-backup-restore.sh [-v|--verbose]
# Exit codes: 0 = pass, 1 = fail
#==============================================================================

set -euo pipefail

# --- Configuration ---
NAMESPACE="test-backup"
STATEFULSET="postgres-test"
POD_NAME="${STATEFULSET}-0"
DB_NAME="testdb"
DB_USER="postgres"
BACKUP_NAME="sdp-test-$(date +%Y%m%d-%H%M%S)"
RESTORE_NAME="sdp-restore-$(date +%Y%m%d-%H%M%S)"
TEST_TABLE="backup_validation"
MARKER="SDP_PHASE0_$(date +%s)"
MAX_WAIT=300
POLL_INTERVAL=5

# --- State tracking ---
VERBOSE=false
ARGOCD_SUSPENDED=false

# --- Argument parsing ---
if [[ "${1:-}" == "-v" || "${1:-}" == "--verbose" ]]; then
  VERBOSE=true
fi

# --- Logging ---
log() {
  printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$*" >&2
}

debug() {
  if [[ "$VERBOSE" == "true" ]]; then
    printf "[%s] [DEBUG] %s\n" "$(date '+%H:%M:%S')" "$*" >&2
  fi
}

# --- Cleanup handler ---
cleanup() {
  local exit_code=$?
  if [[ "$ARGOCD_SUSPENDED" == "true" && $exit_code -ne 0 ]]; then
    log "WARNING: Failure detected — resuming ArgoCD sync to restore cluster state"
    kubectl patch application test-backup -n argocd --type='merge' \
      -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}' 2>/dev/null || true
  fi
  if [[ $exit_code -eq 0 ]]; then
    log "=== PASS: Backup/Restore validation completed successfully ==="
  else
    log "=== FAIL: Backup/Restore validation failed at exit code $exit_code ==="
  fi
  exit $exit_code
}

trap cleanup EXIT

# --- Wait helpers ---
wait_for_predicate() {
  local description="$1"
  shift
  local elapsed=0
  while ! "$@" >/dev/null 2>&1; do
    sleep "$POLL_INTERVAL"
    elapsed=$((elapsed + POLL_INTERVAL))
    if [[ $elapsed -ge $MAX_WAIT ]]; then
      log "TIMEOUT: $description (${elapsed}s exceeded ${MAX_WAIT}s limit)"
      return 1
    fi
    debug "Waiting: $description (${elapsed}s/${MAX_WAIT}s)"
  done
  log "READY: $description (${elapsed}s)"
}

wait_for_velero_phase() {
  local resource="$1"
  local name="$2"
  local expected_phase="$3"
  local elapsed=0

  while true; do
    local status
    status="$(kubectl get "$resource" "$name" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")"

    if [[ "$status" == "$expected_phase" ]]; then
      log "VELERO: $resource '$name' reached phase: $status (${elapsed}s)"
      return 0
    fi

    if [[ "$status" == "Failed" || "$status" == "PartiallyFailed" ]]; then
      log "ERROR: $resource '$name' entered terminal phase: $status"
      return 1
    fi

    sleep "$POLL_INTERVAL"
    elapsed=$((elapsed + POLL_INTERVAL))
    if [[ $elapsed -ge $MAX_WAIT ]]; then
      log "TIMEOUT: $resource '$name' never reached $expected_phase (last status: ${status:-none})"
      return 1
    fi
    debug "Velero $resource status: ${status:-pending} (${elapsed}s)"
  done
}

# --- Step 1: Prerequisites ---
step_prerequisites() {
  log "=== Step 1: Verify Prerequisites ==="

  local velero_pods node_agent bsl_phase test_pods

  velero_pods="$(kubectl get deployment velero -n velero -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")"
  if [[ "$velero_pods" -lt 1 ]]; then
    log "FAIL: Velero deployment not ready ($velero_pods/1 replicas)"
    return 1
  fi
  debug "Velero: ${velero_pods}/1 replicas"

  node_agent="$(kubectl get daemonset node-agent -n velero -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")"
  if [[ "$node_agent" -lt 1 ]]; then
    log "FAIL: Node-agent daemonset not ready ($node_agent pods)"
    return 1
  fi
  debug "Node-agent: ${node_agent} pods"

  bsl_phase="$(kubectl get backupstoragelocation -n velero default -o jsonpath='{.status.phase}' 2>/dev/null || echo "")"
  if [[ "$bsl_phase" != "Available" ]]; then
    log "FAIL: Backup Storage Location not Available ($bsl_phase)"
    return 1
  fi
  debug "BSL: $bsl_phase"

  test_pods="$(kubectl get statefulset "$STATEFULSET" -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "")"
  if [[ -z "$test_pods" || "$test_pods" -lt 1 ]]; then
    log "FAIL: Test workload not running ($STATEFULSET not ready)"
    return 1
  fi
  debug "Test workload: ${test_pods}/1 replicas"

  log "All prerequisites verified"
}

# --- Step 2: Populate data ---
step_populate_data() {
  log "=== Step 2: Populate Test Data ==="

  wait_for_predicate "Pod ${POD_NAME} Running" \
    bash -c "kubectl get pod '$POD_NAME' -n '$NAMESPACE' -o jsonpath='{.status.phase}' 2>/dev/null | grep -q 'Running'"

  log "Inserting marker: $MARKER"

  kubectl exec -n "$NAMESPACE" "$POD_NAME" -- \
    psql -U "$DB_USER" -d "$DB_NAME" -c "DROP TABLE IF EXISTS ${TEST_TABLE};" 2>/dev/null || true

  kubectl exec -n "$NAMESPACE" "$POD_NAME" -- \
    psql -U "$DB_USER" -d "$DB_NAME" -c "
CREATE TABLE ${TEST_TABLE} (
  id SERIAL PRIMARY KEY,
  marker TEXT NOT NULL,
  created_at TIMESTAMP DEFAULT NOW()
);"

  kubectl exec -n "$NAMESPACE" "$POD_NAME" -- \
    psql -U "$DB_USER" -d "$DB_NAME" -c "INSERT INTO ${TEST_TABLE} (marker) VALUES ('${MARKER}');"

  local row_count
  row_count="$(kubectl exec -n "$NAMESPACE" "$POD_NAME" -- \
    psql -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM ${TEST_TABLE} WHERE marker = '${MARKER}';" 2>/dev/null | tr -d ' ')"

  if [[ "${row_count:-0}" -ne 1 ]]; then
    log "FAIL: Data insert verification failed (count: ${row_count:-0})"
    return 1
  fi

  log "Data inserted and verified (marker: $MARKER)"
}

# --- Step 3: Create backup ---
step_create_backup() {
  log "=== Step 3: Create Velero Backup ==="

  log "Creating backup: $BACKUP_NAME (namespace: $NAMESPACE)"
  velero backup create "$BACKUP_NAME" \
    --include-namespaces "$NAMESPACE" \
    --wait \
    --timeout 5m 2>/dev/null || true

  wait_for_velero_phase backup "$BACKUP_NAME" "Completed"

  local vol_snapshots
  vol_snapshots="$(kubectl get backup "$BACKUP_NAME" -o jsonpath='{.status.volumeBackups}' 2>/dev/null | jq 'length' 2>/dev/null || echo "0")"
  debug "Volume snapshots: ${vol_snapshots}"
}

# --- Step 4: Delete workload ---
step_delete_workload() {
  log "=== Step 4: Delete Test Workload ==="

  log "Suspending ArgoCD auto-sync for test-backup"
  kubectl patch application test-backup -n argocd \
    --type='json' \
    -p '[{"op":"remove","path":"/spec/syncPolicy"}]' 2>/dev/null || true

  ARGOCD_SUSPENDED=true

  log "Deleting namespace: $NAMESPACE"
  kubectl delete namespace "$NAMESPACE" --ignore-not-found=true

  wait_for_predicate "Namespace $NAMESPACE deleted" \
    bash -c "! kubectl get namespace '$NAMESPACE' >/dev/null 2>&1"

  log "Namespace deleted"
}

# --- Step 5: Restore ---
step_restore_backup() {
  log "=== Step 5: Restore from Backup ==="

  log "Creating restore: $RESTORE_NAME from $BACKUP_NAME"
  velero restore create "$RESTORE_NAME" \
    --from-backup "$BACKUP_NAME" \
    --wait \
    --timeout 5m 2>/dev/null || true

  wait_for_velero_phase restore "$RESTORE_NAME" "Completed"

  local restore_errors restore_warnings
  restore_errors="$(kubectl get restore "$RESTORE_NAME" -o jsonpath='{.status.errors}' 2>/dev/null || echo "0")"
  restore_warnings="$(kubectl get restore "$RESTORE_NAME" -o jsonpath='{.status.warnings}' 2>/dev/null || echo "0")"
  debug "Restore errors: ${restore_errors}, warnings: ${restore_warnings}"
}

# --- Step 6: Verify restored workload ---
step_verify_restored() {
  log "=== Step 6: Verify Restored Workload ==="

  wait_for_predicate "StatefulSet $STATEFULSET exists" \
    bash -c "kubectl get statefulset '$STATEFULSET' -n '$NAMESPACE' >/dev/null 2>&1"

  wait_for_predicate "StatefulSet $STATEFULSET ready (1/1)" \
    bash -c "[ \"\$(kubectl get statefulset '$STATEFULSET' -n '$NAMESPACE' -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)\" -ge 1 ]"

  wait_for_predicate "Pod ${POD_NAME} Running" \
    bash -c "kubectl get pod '$POD_NAME' -n '$NAMESPACE' -o jsonpath='{.status.phase}' 2>/dev/null | grep -q 'Running'"

  sleep 5
  log "Restored workload is running"
}

# --- Step 7: Verify data integrity ---
step_verify_data() {
  log "=== Step 7: Verify Data Integrity ==="

  local restored_marker
  restored_marker="$(kubectl exec -n "$NAMESPACE" "$POD_NAME" -- \
    psql -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT marker FROM ${TEST_TABLE} LIMIT 1;" 2>/dev/null | tr -d ' \n')"

  if [[ "$restored_marker" == "$MARKER" ]]; then
    log "PASS: Data integrity verified (marker: $restored_marker)"
  else
    log "FAIL: Data integrity mismatch — expected '$MARKER', got '${restored_marker:-empty}'"
    return 1
  fi
}

# --- Step 8: Resume ArgoCD ---
step_resume_argocd() {
  log "=== Step 8: Resume ArgoCD ==="

  kubectl patch application test-backup -n argocd \
    --type='merge' \
    -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}' 2>/dev/null || true

  ARGOCD_SUSPENDED=false
  log "ArgoCD auto-sync resumed"
}

# --- Main execution ---
main() {
  step_prerequisites || return 1
  step_populate_data || return 1
  step_create_backup || return 1
  step_delete_workload || return 1
  step_restore_backup || return 1
  step_verify_restored || return 1
  step_verify_data || return 1
  step_resume_argocd || return 1

  log ""
  log "========================================"
  log "  Phase 0 Final Validation: PASS"
  log "========================================"
  log "Backup:    $BACKUP_NAME"
  log "Restore:   $RESTORE_NAME"
  log "========================================"
}

main
