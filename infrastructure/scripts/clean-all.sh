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

# Parse arguments
VERBOSE=false
while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--verbose) VERBOSE=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

echo -e "${YELLOW}🗑️  Destroying tofu-managed infrastructure...${NC}"
set +e
if [[ "$VERBOSE" == "true" ]]; then
    (cd "$ENV_DIR" && tofu destroy -var-file="$TF_VARS" -auto-approve)
else
    (cd "$ENV_DIR" && tofu destroy -var-file="$TF_VARS" -auto-approve >/dev/null 2>&1)
fi
TOFU_RC=$?
set -e

if [[ "$TOFU_RC" -ne 0 ]]; then
    echo -e "${RED}⚠️  Tofu destroy completed with warnings or partial cleanup.${NC}"
fi

echo -e "${YELLOW}🧹 Removing all LoadBalancers...${NC}"
ORPHAN_LBS=$(hcloud load-balancer list -o no-header -o columns=id 2>/dev/null || echo "")
if [[ -n "$ORPHAN_LBS" ]]; then
    while IFS= read -r lb_id; do
        [[ -z "$lb_id" ]] && continue
        hcloud load-balancer delete "$lb_id" && echo -e "   ${GREEN}Deleted LB $lb_id${NC}"
    done <<< "$ORPHAN_LBS"
else
    echo "   No LoadBalancers found."
fi

echo -e "${GREEN}🎉 Cleanup complete.${NC}"