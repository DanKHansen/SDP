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

    # Terraform variable (lowercase, passed from main.tf)
    MASTER_IP="${master_ip}"

    # Wait for master API
    for i in $(seq 1 30); do
      if nc -z $MASTER_IP 6443 2>/dev/null; then
        echo "Master API reachable."
        break
      fi
      sleep 5
    done

    systemctl enable iscsid.service
    systemctl start iscsid.service

    # Bring up all DOWN interfaces
    for iface in $(ip -br link show | awk '$2 == "DOWN" {print $1}'); do
      ip link set "$iface" up
    done
    sleep 3

    # Detect private interface (Shell variable)
    PRIVATE_IFACE=""
    for i in $(seq 1 30); do
      PRIVATE_IFACE=$(ip -br addr show | grep ' 10\.' | grep -v 'flannel\|cni\|lo' | awk '{print $1}' | head -n1)
      if [ -n "$PRIVATE_IFACE" ]; then
        break
      fi
    
      # If no IP found, ensure netplan config exists and restart networkd
      if [ ! -f /etc/netplan/60-private-network.yaml ]; then
        # Guess the interface name (enp7s0 is standard on Hetzner)
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

    # Write netplan config dynamically (Shell variable $PRIVATE_IFACE)
    printf 'network:\n  version: 2\n  renderer: networkd\n  ethernets:\n    %s:\n      dhcp4: true\n' "$PRIVATE_IFACE" > /etc/netplan/60-private-network.yaml
    chmod 600 /etc/netplan/60-private-network.yaml
    netplan apply 2>/dev/null || true

    # Install K3s
    export INSTALL_K3S_VERSION="${k3s_version}"
    K3S_URL="https://${master_ip}:6443"
    K3S_TOKEN=$(cat /etc/k3s/token)

    # Run curl in a subshell to capture exit code properly in dash
    (curl -sfL ${k3s_install_url} | sh -s - agent \
      --token "$K3S_TOKEN" \
      --server "$K3S_URL" \
      --flannel-iface="$PRIVATE_IFACE") || {
      echo "ERROR: K3s agent installation failed."
      exit 1
    }

    echo "K3s Agent joined successfully."