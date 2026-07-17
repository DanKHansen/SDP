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

  - path: /var/lib/rancher/k3s/server/manifests/03-longhorn-system-namespace.yaml
    permissions: "0644"
    content: |
      apiVersion: v1
      kind: Namespace
      metadata:
        name: longhorn-system
        labels:
          pod-security.kubernetes.io/enforce: privileged

  - path: /var/lib/rancher/k3s/server/manifests/04-longhorn.yaml
    permissions: "0644"
    content: |
      apiVersion: helm.cattle.io/v1
      kind: HelmChart
      metadata:
        name: longhorn
        namespace: kube-system
      spec:
        repo: https://charts.longhorn.io
        chart: longhorn
        version: "1.12.0"
        targetNamespace: longhorn-system
        valuesContent: |
          persistence:
            defaultClass: true
            defaultClassReplicaCount: 3
          defaultSettings:
            defaultDataPath: /var/lib/longhorn
            replicaSoftAntiAffinity: false
            storageMinimalAvailablePercentage: 25

runcmd:
  - |
    #!/bin/bash
    set -e
    echo "=== Bootstrapping K3s Server ==="

    export INSTALL_K3S_VERSION="${k3s_version}"
    K3S_TOKEN=$(cat /etc/k3s/token)
    MY_IP=$(hostname -I | awk '{print $1}')

    systemctl enable iscsid.service
    systemctl start iscsid.service

    # Bring up all DOWN interfaces
    for iface in $(ip -br link show | awk '$2 == "DOWN" {print $1}'); do
      ip link set "$iface" up
    done
    sleep 3

    # Detect private interface
    PRIVATE_IFACE=""
    for i in $(seq 1 30); do
      PRIVATE_IFACE=$(ip -br addr show | grep ' 10\.' | grep -v 'flannel\|cni\|lo' | awk '{print $1}' | head -n1)
      if [ -n "$PRIVATE_IFACE" ]; then
        break
      fi
    
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
      echo "ERROR: Could not detect private network interface."
      ip -br addr show
      exit 1
    fi

    echo "Detected private interface: $PRIVATE_IFACE"

    printf 'network:\n  version: 2\n  renderer: networkd\n  ethernets:\n    %s:\n      dhcp4: true\n' "$PRIVATE_IFACE" > /etc/netplan/60-private-network.yaml
    chmod 600 /etc/netplan/60-private-network.yaml
    netplan apply 2>/dev/null || true

    # Download installer script first (separates download from execution)
    echo "Downloading K3s installer..."
    if ! curl -sfL -o /tmp/k3s-install.sh ${k3s_install_url}; then
      echo "ERROR: Failed to download K3s installer."
      exit 1
    fi
    chmod +x /tmp/k3s-install.sh

    # Run installer
    echo "Installing K3s server..."
    if ! /tmp/k3s-install.sh server \
      --token "$K3S_TOKEN" \
      --cluster-init \
      --advertise-address "$MY_IP" \
      --tls-san "$MY_IP" \
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

    echo "Waiting for Longhorn..."
    for i in $(seq 1 36); do
      if kubectl get pods -n longhorn-system -l app.kubernetes.io/name=longhorn-manager -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q "Running"; then
        echo "Longhorn Ready."
        break
      fi
      sleep 5
    done

    echo "Bootstrap complete."
    kubectl get pods -A