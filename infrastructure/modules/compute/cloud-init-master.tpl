#cloud-config
packages:
  - curl
  - iptables
  - open-iscsi

write_files:
  # 1. Write the K3s join token
  - path: /etc/k3s/token
    permissions: "0600"
    content: ${k3s_token}

  # 2. Write the Hetzner Cloud Secret (Base64 encoded token)
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

  # 3. Write the Hetzner CCM HelmChart manifest
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
        tolerations:
          - key: "node-role.kubernetes.io/master"
            operator: "Exists"
            effect: "NoSchedule"
          - key: "node.cloudprovider.kubernetes.io/uninitialized"
            operator: "Equal"
            value: "true"
            effect: "NoSchedule"
        valuesContent: |
          replicaCount: 1
          rbac:
            create: true
          nodeSelector:
            node-role.kubernetes.io/master: "true"

  # 4. Create ArgoCD Namespace
  - path: /var/lib/rancher/k3s/server/manifests/01-argocd-namespace.yaml
    permissions: "0644"
    content: |
      apiVersion: v1
      kind: Namespace
      metadata:
        name: argocd
        labels:
          pod-security.kubernetes.io/enforce: restricted

  # 5. Write the ArgoCD HelmChart manifest
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

  # 6. Create Longhorn Namespace
  - path: /var/lib/rancher/k3s/server/manifests/03-longhorn-system-namespace.yaml
    permissions: "0644"
    content: |
      apiVersion: v1
      kind: Namespace
      metadata:
        name: longhorn-system
        labels:
          pod-security.kubernetes.io/enforce: privileged

  # 7. Write the Longhorn HelmChart manifest
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
    echo "=== Bootstrapping K3s Server with Hetzner CCM, ArgoCD & Longhorn ==="

    export INSTALL_K3S_VERSION="${k3s_version}"
    K3S_TOKEN=$(cat /etc/k3s/token)
    MY_IP=$(hostname -I | awk '{print $1}')

    # Start iscsid service (required for Longhorn CSI)
    systemctl enable iscsid.service
    systemctl start iscsid.service

    # Detect the private network interface (the one with 10.x.x.x IP, excluding overlay)
    PRIVATE_IFACE=$(ip -br addr show | grep '10\.' | grep -v 'flannel\|cni' | awk '{print $1}' | head -n1)

    if [ -z "$PRIVATE_IFACE" ]; then
        echo "ERROR: Could not detect private network interface. Aborting."
        exit 1
    fi

    echo "Detected private interface: $PRIVATE_IFACE"

    # Install K3s Server
    curl -sfL ${k3s_install_url} | sh -s - server \
      --token $K3S_TOKEN \
      --cluster-init \
      --advertise-address $MY_IP \
      --tls-san $MY_IP \
      --disable traefik \
      --disable-cloud-controller \
      --write-kubeconfig-mode 644 \
      --flannel-iface=$PRIVATE_IFACE

    # Wait for K3s to be ready
    until kubectl get nodes >/dev/null 2>&1; do
      echo "Waiting for cluster to be ready..."
      sleep 5
    done
    echo "K3s Master Ready."

    # Wait for CoreDNS ConfigMap to exist before patching
    echo "Waiting for CoreDNS ConfigMap..."
    for i in $(seq 1 30); do
      if kubectl get configmap coredns -n kube-system >/dev/null 2>&1; then
        echo "CoreDNS ConfigMap found."
        break
      fi
      echo "Waiting... ($i/30)"
      sleep 2
    done

    # Patch CoreDNS to use public DNS
    echo "Patching CoreDNS to use public DNS..."
    kubectl patch configmap coredns -n kube-system --type merge -p '{"data":{"Corefile":".:53 {\n    errors\n    health\n    ready\n    kubernetes cluster.local in-addr.arpa ip6.arpa {\n      pods insecure\n      fallthrough in-addr.arpa ip6.arpa\n    }\n    hosts /etc/coredns/NodeHosts {\n      ttl 60\n      reload 15s\n      fallthrough\n    }\n    prometheus :9153\n    forward . 8.8.8.8 1.1.1.1\n    cache 30\n    loop\n    reload\n    loadbalance\n    import /etc/coredns/custom/*.override\n}\nimport /etc/coredns/custom/*.server"}}' || {
      echo "Warning: CoreDNS patch failed, but continuing..."
    }
    kubectl rollout restart deployment coredns -n kube-system
    echo "CoreDNS patched and restarted."

    # Wait for CCM to be ready
    echo "Checking CCM status..."
    for i in $(seq 1 36); do
      if kubectl get pods -n kube-system -l app.kubernetes.io/name=hcloud-cloud-controller-manager -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q "Running"; then
        echo "Hetzner CCM is Running."
        break
      fi
      echo "Waiting for CCM... ($i/36)"
      sleep 5
    done

    # Wait for ArgoCD to be ready
    echo "Checking ArgoCD status..."
    for i in $(seq 1 36); do
      if kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q "Running"; then
        echo "ArgoCD Server is Running."
        break
      fi
      echo "Waiting for ArgoCD... ($i/36)"
      sleep 5
    done

    # Wait for Longhorn to be ready
    echo "Checking Longhorn status..."
    for i in $(seq 1 36); do
      if kubectl get pods -n longhorn-system -l app.kubernetes.io/name=longhorn-manager -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q "Running"; then
        echo "Longhorn Manager is Running."
        break
      fi
      echo "Waiting for Longhorn... ($i/36)"
      sleep 5
    done

    echo "Bootstrap complete. Verifying final status..."
    kubectl get pods -A