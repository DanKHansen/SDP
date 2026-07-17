#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}🚀 Starting SDP Cluster Verification...${NC}"

# 1. Get the Master IP
if [ -z "$MASTER_IP" ]; then
    echo "Detecting Master IP..."
    read -rp "Enter Master Public IP (from tofu apply output): " MASTER_IP
fi

# Clear stale SSH keys for this IP
ssh-keygen -R "$MASTER_IP" 2>/dev/null || true

echo "Targeting Master: $MASTER_IP"

# Helper function for SSH
ssh_cmd() {
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@"$MASTER_IP" "$1"
}

# 2. Wait for K3s to be ready (kubectl accessible)
echo -e "${YELLOW}⏳ Waiting for K3s cluster to be ready...${NC}"
MAX_WAIT=300
COUNT=0
while ! ssh_cmd "kubectl get nodes >/dev/null 2>&1"; do
    echo -n "."
    sleep 5
    COUNT=$((COUNT+5))
    if [ "$COUNT" -ge "$MAX_WAIT" ]; then
        echo -e "\n${RED}❌ Timeout waiting for K3s cluster.${NC}"
        exit 1
    fi
done
echo -e "\n${GREEN}✅ K3s cluster is responsive.${NC}"

# 3. Wait for Nodes to be Ready
echo -e "${YELLOW}⏳ Waiting for all nodes to reach Ready status...${NC}"
if ! ssh_cmd "kubectl wait --for=condition=Ready nodes --all --timeout=300s" 2>/dev/null; then
    echo -e "${RED}❌ Timeout waiting for nodes to be Ready.${NC}"
    exit 1
fi
echo -e "${GREEN}✅ All nodes are Ready.${NC}"

# 4. Verify Hetzner CCM (With Retry Loop)
echo -e "${YELLOW}⏳ Checking Hetzner Cloud Controller Manager...${NC}"
CCM_READY=false
for _ in $(seq 1 60); do
    # Check if deployment exists AND has available replicas
    STATUS=$(ssh_cmd "kubectl get deployment hcloud-cloud-controller-manager -n kube-system -o jsonpath='{.status.availableReplicas}' 2>/dev/null" || echo "")
    if [ "$STATUS" == "1" ]; then
        CCM_READY=true
        break
    fi
    echo -n "."
    sleep 5
done

if [ "$CCM_READY" = true ]; then
    echo -e "\n${GREEN}✅ Hetzner CCM is running.${NC}"
else
    echo -e "\n${RED}❌ Timeout waiting for Hetzner CCM.${NC}"
    ssh_cmd "kubectl describe deployment hcloud-cloud-controller-manager -n kube-system" || true
    exit 1
fi

# 5. Verify ArgoCD (With Retry Loop)
echo -e "${YELLOW}⏳ Checking ArgoCD Server...${NC}"
ARGOCD_READY=false
for _ in $(seq 1 60); do
    # Check if deployment exists AND has available replicas
    STATUS=$(ssh_cmd "kubectl get deployment argocd-server -n argocd -o jsonpath='{.status.availableReplicas}' 2>/dev/null" || echo "")
    if [ "$STATUS" == "1" ]; then
        ARGOCD_READY=true
        break
    fi
    echo -n "."
    sleep 5
done

if [ "$ARGOCD_READY" = true ]; then
    echo -e "\n${GREEN}✅ ArgoCD Server is running.${NC}"
else
    echo -e "\n${RED}❌ Timeout waiting for ArgoCD Server.${NC}"
    # Debug info
    ssh_cmd "kubectl get pods -n argocd" || true
    ssh_cmd "kubectl describe deployment argocd-server -n argocd" || true
    exit 1
fi

# 6. Verify Longhorn (With Retry Loop)
echo -e "${YELLOW}⏳ Checking Longhorn Manager...${NC}"
LONGHORN_READY=false
for _ in $(seq 1 60); do
    # Check if deployment exists AND has available replicas
    STATUS=$(ssh_cmd "kubectl get deployment longhorn-manager -n longhorn-system -o jsonpath='{.status.availableReplicas}' 2>/dev/null" || echo "")
    if [ "$STATUS" == "1" ]; then
        LONGHORN_READY=true
        break
    fi
    echo -n "."
    sleep 5
done

if [ "$LONGHORN_READY" = true ]; then
    echo -e "\n${GREEN}✅ Longhorn Manager is running.${NC}"
else
    echo -e "\n${RED}❌ Timeout waiting for Longhorn Manager.${NC}"
    # Debug info
    ssh_cmd "kubectl get pods -n longhorn-system" || true
    ssh_cmd "kubectl describe deployment longhorn-manager -n longhorn-system" || true
    exit 1
fi

# Final Summary
echo ""
echo "=== VERIFICATION SUMMARY ==="
[[ "$CCM_READY" == "true" ]] && echo "✅ Hetzner CCM: OK" || echo "❌ Hetzner CCM: FAILED"
[[ "$ARGOCD_READY" == "true" ]] && echo "✅ ArgoCD: OK" || echo "❌ ArgoCD: FAILED"
[[ "$LONGHORN_READY" == "true" ]] && echo "✅ Longhorn: OK" || echo "❌ Longhorn: FAILED"

if [[ "$CCM_READY" == "true" && "$ARGOCD_READY" == "true" && "$LONGHORN_READY" == "true" ]]; then
    echo -e "${GREEN}All systems operational.${NC}"
    exit 0
else
    echo -e "${RED}Some checks failed. Review logs.${NC}"
    exit 1
fi