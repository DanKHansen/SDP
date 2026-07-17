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

    # Detect the private network interface robustly
    # 1. Try common Hetzner private interface names first
    PRIVATE_IFACE=""
    for IFACE in eth1 enp1s1 ens18; do
      if ip link show "$IFACE" &>/dev/null; then
        # Check if it has an IP in the 10.x.x.x range (private network)
        if ip addr show "$IFACE" | grep -q 'inet 10\.'; then
          PRIVATE_IFACE="$IFACE"
          break
        fi
      fi
    done

    # 2. Fallback: If still not found, try to find any interface with a 10.x.x.x IP (excluding loopback, flannel, cni)
    if [ -z "$PRIVATE_IFACE" ]; then
      PRIVATE_IFACE=$(ip -br addr show | grep 'inet 10\.' | grep -v 'flannel\|cni\|lo' | awk '{print $1}' | head -n1)
    fi

    if [ -z "$PRIVATE_IFACE" ]; then
      echo "ERROR: Could not detect private network interface. Available interfaces:"
      ip -br addr show
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