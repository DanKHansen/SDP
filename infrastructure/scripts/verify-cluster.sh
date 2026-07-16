#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}🚀 Starting SDP Cluster Verification...${NC}"

# 1. Get the Master IP from the last apply output or env var
# If you haven't exported it, we'll try to grab it from the state or prompt
if [ -z "$MASTER_IP" ]; then
    # Try to extract from tofu state if available, otherwise prompt
    echo "Detecting Master IP..."
    # Simple heuristic: try to get the first IP from the last known state or prompt
    # For now, let's just ask the user or assume they know the IP from the apply output
    read -p "Enter Master Public IP (from tofu apply output): " MASTER_IP
fi

echo "Targeting Master: $MASTER_IP"

# 2. Wait for K3s to be ready (kubectl accessible)
echo -e "${YELLOW}⏳ Waiting for K3s cluster to be ready...${NC}"
MAX_WAIT=300
COUNT=0
while ! ssh -o StrictHostKeyChecking=no root@$MASTER_IP "kubectl get nodes >/dev/null 2>&1"; do
    echo -n "."
    sleep 5
    COUNT=$((COUNT+5))
    if [ $COUNT -ge $MAX_WAIT ]; then
        echo -e "\n${RED}❌ Timeout waiting for K3s cluster.${NC}"
        exit 1
    fi
done
echo -e "\n${GREEN}✅ K3s cluster is responsive.${NC}"

# 3. Wait for Nodes to be Ready
echo -e "${YELLOW}⏳ Waiting for all nodes to reach Ready status...${NC}"
ssh -o StrictHostKeyChecking=no root@$MASTER_IP "kubectl wait --for=condition=Ready nodes --all --timeout=300s"
echo -e "${GREEN}✅ All nodes are Ready.${NC}"

# 4. Verify Hetzner CCM
echo -e "${YELLOW}⏳ Checking Hetzner Cloud Controller Manager...${NC}"
ssh -o StrictHostKeyChecking=no root@$MASTER_IP "kubectl wait --for=condition=Available deployment/hcloud-cloud-controller-manager -n kube-system --timeout=300s"
echo -e "${GREEN}✅ Hetzner CCM is running.${NC}"

# 5. Verify ArgoCD
echo -e "${YELLOW}⏳ Checking ArgoCD Server...${NC}"
ssh -o StrictHostKeyChecking=no root@$MASTER_IP "kubectl wait --for=condition=Available deployment/argocd-server -n argocd --timeout=300s"
echo -e "${GREEN}✅ ArgoCD Server is running.${NC}"

# 6. Final Summary
echo ""
echo -e "${GREEN}🎉 SUCCESS! SDP Cluster Verification Complete.${NC}"
echo "----------------------------------------"
ssh -o StrictHostKeyChecking=no root@$MASTER_IP "kubectl get nodes"
echo ""
echo "ArgoCD Status:"
ssh -o StrictHostKeyChecking=no root@$MASTER_IP "kubectl get pods -n argocd"
echo ""
echo "Hetzner CCM Status:"
ssh -o StrictHostKeyChecking=no root@$MASTER_IP "kubectl get pods -n kube-system -l app=hcloud-cloud-controller-manager"
echo ""
echo -e "${YELLOW}💡 Tip: Run 'ssh root@$MASTER_IP' to access the cluster.${NC}"