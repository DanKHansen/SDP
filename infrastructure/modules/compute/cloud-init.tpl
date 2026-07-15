#cloud-config
packages:
  - curl
  - iptables
  - dnsutils # Added for getent/nslookup reliability

write_files:
  - path: /etc/k3s/token
    permissions: "0600"
    content: ${k3s_token}

runcmd:
  - |
    #!/bin/bash
    set -e

    MASTER_HOST="sdp-node-0"
    MY_IP=$(hostname -I | awk '{print $1}')

    if [ "${node_index}" -eq 0 ]; then
      echo "=== Bootstrapping K3s Server ==="

      export INSTALL_K3S_VERSION="${k3s_version}"
      K3S_TOKEN=$(cat /etc/k3s/token)

      # Install and Start Server
      # The install script handles starting the service
      curl -sfL ${k3s_install_url} | sh -s - server \
        --token $K3S_TOKEN \
        --cluster-init \
        --advertise-address $MY_IP \
        --tls-san $MASTER_HOST \
        --disable traefik \
        --write-kubeconfig-mode 644

      # Wait for cluster to be ready
      until kubectl get nodes >/dev/null 2>&1; do
        echo "Waiting for cluster to be ready..."
        sleep 5
      done

      echo "Server Ready. Waiting for agents..."

    else
      echo "=== Bootstrapping K3s Agent ==="

      # Wait for Master to be resolvable
      MAX_WAIT=180 # Increased slightly for safety
      COUNT=0
      while ! getent hosts $MASTER_HOST >/dev/null; do
        echo "Waiting for $MASTER_HOST to be resolvable (Attempt $((COUNT/5)))..."
        sleep 5
        COUNT=$((COUNT+5))
        if [ $COUNT -ge $MAX_WAIT ]; then
          echo "Timeout waiting for Master node. Aborting."
          exit 1
        fi
      done

      MASTER_IP=$(getent hosts $MASTER_HOST | awk '{ print $1 }')
      echo "Master found at $MASTER_IP"

      export INSTALL_K3S_VERSION="${k3s_version}"
      K3S_URL="https://${MASTER_IP}:6443"
      K3S_TOKEN=$(cat /etc/k3s/token)

      curl -sfL ${k3s_install_url} | sh -s - agent \
        --token $K3S_TOKEN \
        --server $K3S_URL

      echo "Agent joined."
    fi