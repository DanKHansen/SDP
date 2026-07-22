#cloud-config
packages:
  - curl
  - iptables
  - open-iscsi

write_files:
  - path: /etc/k3s/token
    permissions: "0600"
    content: ${k3s_token}

  - path: /var/lib/rancher/k3s/server/manifests/hcloud-secret.yaml
    permissions: "0644"
    content: |
      apiVersion: v1
      kind: Secret
      metadata:
        name: hcloud
        namespace: kube-system
      type: Opaque
      data:
        token: ${hcloud_token_b64}

  - path: /var/lib/rancher/k3s/server/manifests/hcloud-ccm.yaml
    permissions: "0644"
    content: |
      apiVersion: helm.cattle.io/v1
      kind: HelmChart
      metadata:
        name: hcloud-ccm
        namespace: kube-system
      spec:
        repo: https://charts.hetzner.cloud
        chart: hcloud-cloud-controller-manager
        version: "1.33.0"
        targetNamespace: kube-system
        valuesContent: |
          replicaCount: 1
          rbac:
            create: true
          nodeSelector:
            node-role.kubernetes.io/master: "true"
          tolerations:
            - key: "node-role.kubernetes.io/master"
              operator: "Exists"
              effect: "NoSchedule"
            - key: "node.cloudprovider.kubernetes.io/uninitialized"
              operator: "Equal"
              value: "true"
              effect: "NoSchedule"

  - path: /var/lib/rancher/k3s/server/manifests/01-argocd-namespace.yaml
    permissions: "0644"
    content: |
      apiVersion: v1
      kind: Namespace
      metadata:
        name: argocd
        labels:
          pod-security.kubernetes.io/enforce: restricted

  - path: /var/lib/rancher/k3s/server/manifests/02-argocd.yaml
    permissions: "0644"
    content: |
      apiVersion: helm.cattle.io/v1
      kind: HelmChart
      metadata:
        name: argocd
        namespace: kube-system
      spec:
        repo: https://argoproj.github.io/argo-helm
        chart: argo-cd
        version: "10.1.3"
        targetNamespace: argocd
        valuesContent: |
          global:
            domain: argocd.sdp.local
          server:
            service:
              type: LoadBalancer
            args:
              - --insecure
          redis:
            disabled: false
          controller:
            replicas: 1
          repoServer:
            replicas: 1
          applicationSet:
            replicas: 1

  - path: /opt/sdp/root-application.yaml
    permissions: "0644"
    content: |
      apiVersion: argoproj.io/v1alpha1
      kind: Application
      metadata:
        name: sdp-root
        namespace: argocd
      spec:
        project: default
        source:
          repoURL: https://github.com/DanKHansen/SDP.git
          targetRevision: main
          path: apps/environments/dev
          directory:
            recurse: true
        destination:
          server: https://kubernetes.default.svc
          namespace: argocd
        syncPolicy:
          automated:
            prune: true
            selfHeal: true

runcmd:
  - |
    #!/bin/bash
    set -e
    echo "=== Bootstrapping K3s Server ==="

    export INSTALL_K3S_VERSION="${k3s_version}"
    K3S_TOKEN=$(cat /etc/k3s/token)

    systemctl enable iscsid.service
    systemctl start iscsid.service

    # Bring up all DOWN interfaces
    for iface in $(ip -br link show | awk '$2 == "DOWN" {print $1}'); do
      ip link set "$iface" up
    done
    sleep 3

    # Detect private interface with retry + Netplan fallback
    PRIVATE_IFACE=""
    for i in $(seq 1 30); do
      PRIVATE_IFACE=$(ip -br addr show | grep " 10\." | grep -v 'flannel\|cni\|lo' | awk '{print $1}' | head -n1)
      if [ -n "$PRIVATE_IFACE" ]; then
        break
      fi

      # No 10.x.x.x found yet — try writing Netplan config for guessed private interface
      if [ ! -f /etc/netplan/60-private-network.yaml ]; then
        GUESS_IFACE=$(ip -br link show | awk '$2 == "UP" && $1 != "lo" && $1 != "eth0" {print $1; exit}')
        if [ -n "$GUESS_IFACE" ]; then
          printf 'network:\n  version: 2\n  renderer: networkd\n  ethernets:\n    %s:\n      dhcp4: true\n' "$GUESS_IFACE" > /etc/netplan/60-private-network.yaml
          chmod 600 /etc/netplan/60-private-network.yaml
          netplan apply 2>/dev/null || true
          systemctl restart systemd-networkd 2>/dev/null || true
        fi
      fi
      sleep 2
    done

    if [ -z "$PRIVATE_IFACE" ]; then
      echo "ERROR: Could not detect private interface with 10.x.x.x address."
      ip -br addr show
      exit 1
    fi

    echo "Detected private interface: $PRIVATE_IFACE"

    # Ensure Netplan is configured (write again if not already done above)
    printf 'network:\n  version: 2\n  renderer: networkd\n  ethernets:\n    %s:\n      dhcp4: true\n' "$PRIVATE_IFACE" > /etc/netplan/60-private-network.yaml
    chmod 600 /etc/netplan/60-private-network.yaml
    netplan apply 2>/dev/null || true

    # Wait for IPv4 address on the private interface
    echo "Waiting for private interface to get IPv4..."
    PRIVATE_IP=""
    for i in $(seq 1 30); do
      PRIVATE_IP=$(ip -br addr show "$PRIVATE_IFACE" | grep -oE '10\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
      if [ -n "$PRIVATE_IP" ]; then
        echo "Private IPv4: $PRIVATE_IP"
        break
      fi
      sleep 2
    done

    if [ -z "$PRIVATE_IP" ]; then
      echo "ERROR: Private interface never got an IPv4 address."
      ip -br addr show "$PRIVATE_IFACE"
      exit 1
    fi

    # Get Public IP (exclude private 10.x.x.x range)
    PUBLIC_IP=$(hostname -I | tr ' ' '\n' | grep -v '^10\.' | grep -v '^127\.' | head -1)
    if [ -z "$PUBLIC_IP" ]; then
      echo "ERROR: Could not detect Public IP."
      hostname -I
      exit 1
    fi
    echo "Public IP detected: $PUBLIC_IP"

    # Retry loop for K3s installer download
    echo "Downloading K3s installer..."
    CURL_SUCCESS=false
    for attempt in $(seq 1 5); do
      echo "Attempt $attempt to download K3s installer..."
      if curl -sfL --connect-timeout 30 -o /tmp/k3s-install.sh "${k3s_install_url}"; then
        echo "Download successful."
        CURL_SUCCESS=true
        break
      else
        echo "Download failed. Retrying in 10 seconds..."
        sleep 10
      fi
    done

    if [ "$CURL_SUCCESS" = false ]; then
      echo "ERROR: Failed to download K3s installer after 5 attempts."
      exit 1
    fi

    chmod +x /tmp/k3s-install.sh

    # Run installer
    echo "Installing K3s server..."
    if ! /tmp/k3s-install.sh server \
      --token "$K3S_TOKEN" \
      --cluster-init \
      --advertise-address "$PRIVATE_IP" \
      --tls-san "$PRIVATE_IP" \
      --node-ip "$PUBLIC_IP" \
      --node-external-ip "$PUBLIC_IP" \
      --flannel-external-ip \
      --disable traefik \
      --disable-cloud-controller \
      --write-kubeconfig-mode 644 \
      --flannel-iface="$PRIVATE_IFACE"; then
      echo "ERROR: K3s server installation failed."
      exit 1
    fi

    until kubectl get nodes >/dev/null 2>&1; do
      echo "Waiting for cluster..."
      sleep 5
    done
    echo "K3s Master Ready."

    for i in $(seq 1 30); do
      if kubectl get configmap coredns -n kube-system >/dev/null 2>&1; then
        break
      fi
      sleep 2
    done

    kubectl patch configmap coredns -n kube-system --type merge -p '{"data":{"Corefile":".:53 {\n    errors\n    health\n    ready\n    kubernetes cluster.local in-addr.arpa ip6.arpa {\n      pods insecure\n      fallthrough in-addr.arpa ip6.arpa\n    }\n    hosts /etc/coredns/NodeHosts {\n      ttl 60\n      reload 15s\n      fallthrough\n    }\n    prometheus :9153\n    forward . 8.8.8.8 1.1.1.1\n    cache 30\n    loop\n    reload\n    loadbalance\n    import /etc/coredns/custom/*.override\n}\nimport /etc/coredns/custom/*.server"}}' || echo "CoreDNS patch failed, continuing..."
    kubectl rollout restart deployment coredns -n kube-system
    echo "CoreDNS patched."

    echo "Waiting for CCM..."
    for i in $(seq 1 36); do
      if kubectl get pods -n kube-system -l app.kubernetes.io/name=hcloud-cloud-controller-manager -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q "Running"; then
        echo "CCM Ready."
        break
      fi
      sleep 5
    done

    echo "Waiting for ArgoCD..."
    for i in $(seq 1 36); do
      if kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q "Running"; then
        echo "ArgoCD Ready."
        break
      fi
      sleep 5
    done

    echo "Applying root Application..."
    for i in $(seq 1 36); do
      if kubectl apply -f /opt/sdp/root-application.yaml 2>/dev/null; then
        echo "Root Application applied."
        break
      fi
      sleep 5
    done

    echo "Waiting for Longhorn (via ArgoCD sync)..."
    for i in $(seq 1 36); do
      if kubectl get pods -n longhorn-system -l app.kubernetes.io/name=longhorn-manager -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q "Running"; then
        echo "Longhorn Ready."
        break
      fi
      sleep 5
    done

    echo "Waiting for NGINX Ingress (via ArgoCD sync)..."
    for i in $(seq 1 36); do
      if kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q "Running"; then
        echo "NGINX Ingress Ready."
        break
      fi
      sleep 5
    done

    echo "Bootstrap complete."
    kubectl get pods -A