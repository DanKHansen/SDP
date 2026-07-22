# --- K3s Server Flags (MASTER ONLY) ---
# --flannel-external-ip: SERVER ONLY — invalid on agent
# --node-external-ip: Valid on both server and agent
# --flannel-iface: Valid on both
# --node-ip: Valid on both
# --kubelet-arg=cloud-provider=external: Valid on both

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

    # NOW wait for master API (interface is up, so this should work)
    echo "Waiting for Master API at $MASTER_IP:6443..."
    for i in $(seq 1 30); do
      if nc -z $MASTER_IP 6443 2>/dev/null; then
        echo "Master API reachable."
        break
      fi
      sleep 5
    done

    # Retry loop for K3s installer download
    export INSTALL_K3S_VERSION="${k3s_version}"
    K3S_URL="https://$MASTER_IP:6443"
    K3S_TOKEN=$(cat /etc/k3s/token)

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

    # Get Public IP (exclude private 10.x.x.x range)
    PUBLIC_IP=$(hostname -I | tr ' ' '\n' | grep -v '^10\.' | grep -v '^127\.' | head -1)
    if [ -z "$PUBLIC_IP" ]; then
      echo "ERROR: Could not detect Public IP."
      hostname -I
      exit 1
    fi
    echo "Public IP detected: $PUBLIC_IP"

    # Install K3s agent (with --flannel-external-ip for Hetzner CCM compatibility)
    echo "Installing K3s agent..."
    if ! /tmp/k3s-install.sh agent \
      --token "$K3S_TOKEN" \
      --server "$K3S_URL" \
      --flannel-iface="$PRIVATE_IFACE" \
      --node-ip "$PUBLIC_IP" \
      --node-external-ip "$PUBLIC_IP" \
      --kubelet-arg=cloud-provider=external; then
      echo "ERROR: K3s agent installation failed."
      exit 1
    fi

    echo "K3s Agent joined successfully."