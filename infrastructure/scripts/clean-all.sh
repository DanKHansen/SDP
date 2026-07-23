#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_DIR="$SCRIPT_DIR/../environments/dev"
TF_VARS="dev.tfvars"

echo "🗑️  Destroying tofu-managed infrastructure..."
(cd "$ENV_DIR" && tofu destroy -var-file="$TF_VARS" -auto-approve) || true

echo "🧹 Removing all LoadBalancers..."
ORPHAN_LBS=$(hcloud load-balancer list -o no-header -o columns=id 2>/dev/null || echo "")
if [[ -n "$ORPHAN_LBS" ]]; then
    while IFS= read -r lb_id; do
        [[ -z "$lb_id" ]] && continue
        hcloud load-balancer delete "$lb_id" && echo "   Deleted LB $lb_id"
    done <<< "$ORPHAN_LBS"
else
    echo "   No LoadBalancers found."
fi

echo "🎉 Cleanup complete."