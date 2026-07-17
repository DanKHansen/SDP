#cloud-config
packages:
  - curl
  - iptables
  - open-iscsi

write_files:
  - path: /etc/k3s/token
    permissions: "0600"
    content: ${k3s_token}

runcmd:
  - |
    #!/bin/bash
    set -e
    echo "=== Bootstrapping K3s Agent ==="

    master_ip="${master_ip}"
    echo "Master IP is $master_ip"

    # Wait for master API to be reachable
    echo "Waiting for master API on port 6443..."
    for i in $(seq 1 30); do
      if nc -z $master_ip 6443 2>/dev/null; then
        echo "Master API reachable. Joining cluster..."
        break
      fi
      echo "Waiting... (Attempt $i/30)"
      sleep 5
    done

    # Start iscsid service (required for Longhorn CSI)
    systemctl enable iscsid.service
    systemctl start iscsid.service

    # Detect the private network interface
    PRIVATE_IFACE=$(ip -br addr show | grep '10\.' | grep -v 'flannel\|cni' | awk '{print $1}' | head -n1)

    if [ -z "$PRIVATE_IFACE" ]; then
        echo "ERROR: Could not detect private network interface. Aborting."
        exit 1
    fi

    echo "Detected private interface: $PRIVATE_IFACE"

    export INSTALL_K3S_VERSION="${k3s_version}"
    K3S_URL="https://${master_ip}:6443"
    K3S_TOKEN=$(cat /etc/k3s/token)

    curl -sfL ${k3s_install_url} | sh -s - agent \
      --token $K3S_TOKEN \
      --server $K3S_URL \
      --flannel-iface=$PRIVATE_IFACE

    echo "K3s Agent joined successfully."