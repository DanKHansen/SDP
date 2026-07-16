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
    echo "=== Bootstrapping K3s Agent ==="

    MASTER_IP="${master_ip}"
    echo "Master IP is $MASTER_IP"

    # Wait for master API to be reachable (quick check)
    echo "Waiting for master API on port 6443..."
    for i in $(seq 1 30); do
      if nc -z $MASTER_IP 6443 2>/dev/null; then
        echo "Master API reachable. Joining cluster..."
        break
      fi
      echo "Waiting... (Attempt $i/30)"
      sleep 5
    done

    export INSTALL_K3S_VERSION="${k3s_version}"
    K3S_URL="https://${MASTER_IP}:6443"
    K3S_TOKEN=$(cat /etc/k3s/token)

    curl -sfL ${k3s_install_url} | sh -s - agent \
      --token $K3S_TOKEN \
      --server $K3S_URL

    echo "K3s Agent joined successfully."