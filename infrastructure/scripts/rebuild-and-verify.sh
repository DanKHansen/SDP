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

# Clear stale SSH keys for this IP (silent)
ssh-keygen -R "$MASTER_IP" >/dev/null 2>&1 || true

echo "Targeting Master: $MASTER_IP"

# Helper function for SSH — suppress known_hosts modifications
ssh_cmd() {
    ssh -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 \
        root@"$MASTER_IP" "$1"
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

# 3. Wait for Nodes to be Ready (Individual Check)
echo -e "${YELLOW}⏳ Waiting for all nodes to reach Ready status...${NC}"
MAX_WAIT=420  # Increased from 300 to 420 seconds (7 mins)
COUNT=0
ALL_READY=false

while [ "$COUNT" -lt "$MAX_WAIT" ]; do
    # Get list of nodes and their statuses
    NODE_STATUS=$(ssh_cmd "kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}:{.status.conditions[?(@.type==\"Ready\")].status}{\"\\n\"}{end}'" 2>/dev/null || echo "")

    # Check if all nodes are Ready
    if echo "$NODE_STATUS" | grep -q ":False\|:Unknown"; then
        # Not all ready yet
        echo -n "."
        COUNT=$((COUNT+5))
    else
        ALL_READY=true
        break
    fi
    sleep 5
done

if [ "$ALL_READY" = true ]; then
    echo -e "\n${GREEN}✅ All nodes are Ready.${NC}"
else
    echo -e "\n${RED}❌ Timeout waiting for nodes to be Ready.${NC}"
    ssh_cmd "kubectl get nodes" || true
    exit 1
fi

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
    # Debug info
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

# 6. Verify Longhorn (With Retry Loop - DaemonSet Check)
echo -e "${YELLOW}⏳ Checking Longhorn Manager...${NC}"
LONGHORN_READY=false
for _ in $(seq 1 60); do
    # Check DaemonSet status: desiredNumberScheduled == numberReady
    STATUS=$(ssh_cmd "kubectl get daemonset longhorn-manager -n longhorn-system -o jsonpath='{.status.numberReady}/{.status.desiredNumberScheduled}' 2>/dev/null" || echo "")
    if [ "$STATUS" == "3/3" ]; then
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
    ssh_cmd "kubectl describe daemonset longhorn-manager -n longhorn-system" || true
    exit 1
fi

# 7. Verify NGINX Ingress (With Retry Loop)
echo -e "${YELLOW}⏳ Checking NGINX Ingress Controller...${NC}"
NGINX_READY=false
for _ in $(seq 1 60); do
    # Check deployment status: desiredReplicas == availableReplicas
    STATUS=$(ssh_cmd "kubectl get deployment ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.readyReplicas}/{.status.replicas}' 2>/dev/null" || echo "")
    if [ "$STATUS" == "2/2" ]; then
        NGINX_READY=true
        break
    fi
    echo -n "."
    sleep 5
done

if [ "$NGINX_READY" = true ]; then
    echo -e "\n${GREEN}✅ NGINX Ingress Controller is running.${NC}"
else
    echo -e "\n${RED}❌ Timeout waiting for NGINX Ingress Controller.${NC}"
    # Debug info
    ssh_cmd "kubectl get pods -n ingress-nginx" || true
    ssh_cmd "kubectl describe deployment ingress-nginx-controller -n ingress-nginx" || true
    exit 1
fi

# 8. Verify LoadBalancer External IP
echo -e "${YELLOW}⏳ Checking LoadBalancer External IP...${NC}"
LB_READY=false
for _ in $(seq 1 30); do
    EXTERNAL_IP=$(ssh_cmd "kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null" || echo "")
    if [ -n "$EXTERNAL_IP" ] && [ "$EXTERNAL_IP" != "<pending>" ]; then
        LB_READY=true
        echo "LoadBalancer IP: $EXTERNAL_IP"
        break
    fi
    echo -n "."
    sleep 5
done

if [ "$LB_READY" = true ]; then
    echo -e "\n${GREEN}✅ LoadBalancer provisioned.${NC}"
else
    echo -e "\n${RED}❌ Timeout waiting for LoadBalancer.${NC}"
    ssh_cmd "kubectl get svc ingress-nginx-controller -n ingress-nginx" || true
    exit 1
fi

# 9. Verify ArgoCD Root Application Sync Status
echo -e "${YELLOW}⏳ Checking ArgoCD Root Application sync status...${NC}"
ROOT_APP_SYNCED=false
for _ in $(seq 1 30); do
    SYNC_STATUS=$(ssh_cmd "kubectl get application sdp-root -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null" || echo "")
    HEALTH_STATUS=$(ssh_cmd "kubectl get application sdp-root -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null" || echo "")
    if [ "$SYNC_STATUS" == "Synced" ] && [ "$HEALTH_STATUS" == "Healthy" ]; then
        ROOT_APP_SYNCED=true
        echo "Root Application: Synced + Healthy"
        break
    fi
    echo -n "."
    sleep 10
done

if [ "$ROOT_APP_SYNCED" = true ]; then
    echo -e "\n${GREEN}✅ ArgoCD Root Application synced.${NC}"
else
    echo -e "\n${RED}❌ Timeout waiting for ArgoCD Root Application sync.${NC}"
    # Debug info
    ssh_cmd "kubectl get application sdp-root -n argocd -o yaml" || true
    ssh_cmd "kubectl get application sdp-root -n argocd --show-operation" || true
    exit 1
fi

# Final Summary
echo ""
echo "=== VERIFICATION SUMMARY ==="
[[ "$CCM_READY" == "true" ]] && echo "✅ Hetzner CCM: OK" || echo "❌ Hetzner CCM: FAILED"
[[ "$ARGOCD_READY" == "true" ]] && echo "✅ ArgoCD: OK" || echo "❌ ArgoCD: FAILED"
[[ "$LONGHORN_READY" == "true" ]] && echo "✅ Longhorn: OK" || echo "❌ Longhorn: FAILED"
[[ "$NGINX_READY" == "true" ]] && echo "✅ NGINX Ingress: OK" || echo "❌ NGINX Ingress: FAILED"
[[ "$LB_READY" == "true" ]] && echo "✅ LoadBalancer: OK" || echo "❌ LoadBalancer: FAILED"
[[ "$ROOT_APP_SYNCED" == "true" ]] && echo "✅ Root Application: OK" || echo "❌ Root Application: FAILED"

if [[ "$CCM_READY" == "true" && "$ARGOCD_READY" == "true" && "$LONGHORN_READY" == "true" && "$NGINX_READY" == "true" && "$LB_READY" == "true" && "$ROOT_APP_SYNCED" == "true" ]]; then
    echo -e "${GREEN}🎉 All systems operational.${NC}"
    exit 0
else
    echo -e "${RED}Some checks failed. Review logs.${NC}"
    exit 1
fi