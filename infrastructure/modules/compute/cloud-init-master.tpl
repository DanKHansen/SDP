#cloud-config
packages:
  - curl
  - iptables

write_files:
  - path: /etc/k3s/token
    permissions: "0600"
    content: ${k3s_token}

runcmd:
  - |
    #!/bin/bash
    set -e
    echo "=== Bootstrapping K3s Server ==="

    export INSTALL_K3S_VERSION="${k3s_version}"
    K3S_TOKEN=$(cat /etc/k3s/token)
    MY_IP=$(hostname -I | awk '{print $1}')

    curl -sfL ${k3s_install_url} | sh -s - server \
      --token $K3S_TOKEN \
      --cluster-init \
      --advertise-address $MY_IP \
      --tls-san $MY_IP \
      --disable traefik \
      --write-kubeconfig-mode 644

    # Wait for cluster to be ready
    until kubectl get nodes >/dev/null 2>&1; do
      echo "Waiting for cluster to be ready..."
      sleep 5
    done

    echo "K3s Master Ready. Waiting for agents..."