#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_DIR="$SCRIPT_DIR/../environments/dev"
TF_VARS="dev.tfvars"

echo "🔄 SDP Rebuild & Verify Cycle"
echo "Working directory: $ENV_DIR"

# 1. Destroy (with confirmation if not in CI)
if [[ "${CI:-}" != "true" && "${FORCE_DESTROY:-}" != "1" ]]; then
    read -rp "⚠️  Confirm destroy (y/N)? " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
fi

echo "🗑️  Destroying infrastructure..."
(cd "$ENV_DIR" && tofu destroy -auto-approve)

# 2. Apply
echo "🏗️  Applying new infrastructure..."
(cd "$ENV_DIR" && tofu apply -var-file="$TF_VARS" -auto-approve)

# 3. Extract Master IP
echo "🔍 Extracting Master IP..."
MASTER_IP=$(cd "$ENV_DIR" && tofu output -raw server_public_ips | jq -r '.[0]')
[[ -z "$MASTER_IP" || "$MASTER_IP" == "null" ]] && { echo "❌ Failed to extract Master IP"; exit 1; }
export MASTER_IP
echo "Master IP: $MASTER_IP"

# 4. Wait for SSH readiness (avoid race condition)
echo "⏳ Waiting for SSH access..."
until ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@"$MASTER_IP" "echo 'SSH ready'" >/dev/null 2>&1; do
    sleep 2
done

# 5. Run verification
echo "✅ Running verification..."
"$SCRIPT_DIR/verify-cluster.sh"

echo "🎉 Rebuild cycle complete."