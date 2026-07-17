#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_DIR="$SCRIPT_DIR/../environments/dev"
TF_VARS="dev.tfvars"

# Priority list of Hetzner locations
LOCATIONS=("nbg1" "hel1" "fsn1")

echo "🔄 SDP Rebuild & Verify Cycle (Production-Ready)"
echo "Working directory: $ENV_DIR"

# 1. Initial Destroy (with confirmation if not in CI)
if [[ "${CI:-}" != "true" && "${FORCE_DESTROY:-}" != "1" ]]; then
    read -rp "⚠️  Confirm initial destroy (y/N)? " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
fi

echo "🗑️  Destroying any existing infrastructure..."
(cd "$ENV_DIR" && tofu destroy -var-file="$TF_VARS" -auto-approve) || true

APPLY_SUCCESS=false
LAST_LOCATION=""

# 2. Apply with Automatic Location Failover
for LOCATION in "${LOCATIONS[@]}"; do
    echo "🏗️  Attempting apply in location: $LOCATION..."

    # Update tfvars temporarily
    cp "$ENV_DIR/$TF_VARS" "$ENV_DIR/${TF_VARS}.bak"
    sed -i "s/^location = .*/location = \"$LOCATION\"/" "$ENV_DIR/$TF_VARS"

    # CRITICAL: If location changed from previous attempt, force a full destroy
    # to recreate the network and firewall in the new region.
    if [[ "$LOCATION" != "$LAST_LOCATION" && -n "$LAST_LOCATION" ]]; then
        echo "⚠️  Location changed from $LAST_LOCATION to $LOCATION. Forcing full destroy to recreate network..."
        (cd "$ENV_DIR" && tofu destroy -var-file="$TF_VARS" -auto-approve) || true
    fi
    LAST_LOCATION="$LOCATION"

    # Try to apply
    echo "🔨 Running tofu apply..."
    if (cd "$ENV_DIR" && tofu apply -var-file="$TF_VARS" -auto-approve 2>&1 | tee /tmp/tofu_apply.log); then
        APPLY_SUCCESS=true
        echo "✅ Successfully applied in $LOCATION"
        break
    else
        echo "❌ Apply failed in $LOCATION. Checking error..."

        # Check for specific capacity or resource_unavailable errors
        if grep -qi "unavailable\|capacity\|insufficient\|cannot move" /tmp/tofu_apply.log; then
            echo "⚠️  Capacity or resource conflict detected. Will try next location."
            # Restore backup (though we overwrite in next loop anyway)
            mv "$ENV_DIR/${TF_VARS}.bak" "$ENV_DIR/$TF_VARS"
            continue
        else
            echo "💥 Non-recoverable error. Stopping."
            cat /tmp/tofu_apply.log
            mv "$ENV_DIR/${TF_VARS}.bak" "$ENV_DIR/$TF_VARS"
            exit 1
        fi
    fi
done

if [[ "$APPLY_SUCCESS" != "true" ]]; then
    echo "💥 All locations exhausted. Deployment failed."
    exit 1
fi

# 3. Extract Master IP
echo "🔍 Extracting Master IP..."
MASTER_IP=$(cd "$ENV_DIR" && tofu output -json server_public_ips | jq -r '.[0]')
[[ -z "$MASTER_IP" || "$MASTER_IP" == "null" ]] && { echo "❌ Failed to extract Master IP"; exit 1; }
export MASTER_IP
echo "Master IP: $MASTER_IP"

# 4. Wait for SSH readiness
echo "⏳ Waiting for SSH access..."
until ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@"$MASTER_IP" "echo 'SSH ready'" >/dev/null 2>&1; do
    sleep 2
done

# 5. Run verification
echo "✅ Running verification..."
"$SCRIPT_DIR/verify-cluster.sh"

echo "🎉 Rebuild cycle complete."