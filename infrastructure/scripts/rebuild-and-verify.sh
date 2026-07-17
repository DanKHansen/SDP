#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_DIR="$SCRIPT_DIR/../environments/dev"
TF_VARS="dev.tfvars"

# Priority list of Hetzner locations
LOCATIONS=("nbg1" "hel1" "fsn1")

echo "🔄 SDP Rebuild & Verify Cycle (Production-Ready)"
echo "Working directory: $ENV_DIR"

# 1. Destroy (with confirmation if not in CI)
if [[ "${CI:-}" != "true" && "${FORCE_DESTROY:-}" != "1" ]]; then
    read -rp "⚠️  Confirm destroy (y/N)? " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
fi

echo "🗑️  Destroying infrastructure..."
(cd "$ENV_DIR" && tofu destroy -var-file="$TF_VARS" -auto-approve) || true

# 2. Apply with Automatic Location Failover
APPLY_SUCCESS=false
for LOCATION in "${LOCATIONS[@]}"; do
    echo "🏗️  Attempting apply in location: $LOCATION..."

    # Update tfvars temporarily (assuming location is a variable in dev.tfvars)
    # We use sed to replace the location value dynamically
    cp "$ENV_DIR/$TF_VARS" "$ENV_DIR/${TF_VARS}.bak"
    sed -i "s/^location = .*/location = \"$LOCATION\"/" "$ENV_DIR/$TF_VARS"

    # Try to apply
    if (cd "$ENV_DIR" && tofu apply -var-file="$TF_VARS" -auto-approve 2>&1 | tee /tmp/tofu_apply.log); then
        APPLY_SUCCESS=true
        echo "✅ Successfully applied in $LOCATION"
        break
    else
        echo "❌ Apply failed in $LOCATION. Checking error..."

        # Check for specific capacity errors
        if grep -qi "unavailable\|capacity\|insufficient" /tmp/tofu_apply.log; then
            echo "⚠️  Capacity issue detected. Trying next location..."
            mv "$ENV_DIR/${TF_VARS}.bak" "$ENV_DIR/$TF_VARS" # Restore backup for next iteration (though we overwrite anyway)
            continue
        else
            echo "💥 Non-capacity error. Stopping."
            mv "$ENV_DIR/${TF_VARS}.bak" "$ENV_DIR/$TF_VARS" # Restore original
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