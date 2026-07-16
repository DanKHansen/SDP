#cloud-config
packages:
  - curl
  - iptables

write_files:
  # 1. Write the K3s join token
  - path: /etc/k3s/token
    permissions: "0600"
    content: ${k3s_token}

  # 2. Write the Hetzner Cloud Secret (Base64 encoded token)
  #    The CCM chart expects a secret named 'hcloud' with key 'token'
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
            - key: "node.cloudprovider.kubernetes.io/uninitialized"
              operator: "Equal"
              value: "true"
              effect: "NoSchedule"
          valuesContent: |
            replicaCount: 1
            rbac:
              create: true

  # 4. Write the ArgoCD HelmChart manifest
  - path: /var/lib/rancher/k3s/server/manifests/argocd.yaml
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

runcmd:
  - |
    #!/bin/bash
    set -e
    echo "=== Bootstrapping K3s Server with Hetzner CCM & ArgoCD ==="

    export INSTALL_K3S_VERSION="${k3s_version}"
    K3S_TOKEN=$(cat /etc/k3s/token)
    MY_IP=$(hostname -I | awk '{print $1}')

    # Install K3s Server with external cloud provider flags
    # --disable-cloud-controller: Disable built-in CCM (we use Hetzner's)
    # --kubelet-arg=cloud-provider=external: Tell kubelet to use external CCM
    curl -sfL ${k3s_install_url} | sh -s - server \
      --token $K3S_TOKEN \
      --cluster-init \
      --advertise-address $MY_IP \
      --tls-san $MY_IP \
      --disable traefik \
      --disable-cloud-controller \
      --kubelet-arg=cloud-provider=external \
      --write-kubeconfig-mode 644

    # Wait for K3s to be ready
    until kubectl get nodes >/dev/null 2>&1; do
      echo "Waiting for K3s cluster to be ready..."
      sleep 5
    done

    echo "K3s Master Ready. Waiting for CCM and ArgoCD..."

    # Wait for CCM to be ready (max 2 mins)
    echo "Checking CCM status..."
    for i in $(seq 1 24); do
      if kubectl get pods -n kube-system -l app=hcloud-cloud-controller-manager >/dev/null 2>&1; then
        echo "Hetzner CCM detected."
        break
      fi
      echo "Waiting for CCM... ($i/24)"
      sleep 5
    done

    # Wait for ArgoCD to be ready (max 2 mins)
    echo "Checking ArgoCD status..."
    for i in $(seq 1 24); do
      if kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server >/dev/null 2>&1; then
        echo "ArgoCD server detected."
        break
      fi
      echo "Waiting for ArgoCD... ($i/24)"
      sleep 5
    done

    echo "Bootstrap complete. CCM and ArgoCD should be starting."