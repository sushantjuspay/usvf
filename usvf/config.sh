#!/bin/bash
# ============================================================================
# Deployment Configuration for Ceph + OpenStack Setup
# ============================================================================
# IMPORTANT: Edit these values before running deploy-all.sh
# ============================================================================

# ----------------------------------------------------------------------------
# Node Configuration (EDIT THESE)
# ----------------------------------------------------------------------------
# Control Nodes: Run Ceph MON/MGR + OpenStack control plane services
# For 3-node converged setup: Use same IPs for both control and compute
# For separated setup: Use different IPs for compute nodes
CONTROL_IPS=("192.168.10.11" "192.168.10.12" "192.168.10.13")
CONTROL_NAMES=("hypervisor-1" "hypervisor-2" "hypervisor-3")

# Compute Nodes: Run Ceph OSD + OpenStack compute services
# For 3-node converged: Same as control nodes
# For separated: Add more IPs like ("192.168.10.14" "192.168.10.15" ...)
COMPUTE_IPS=("192.168.10.14" "192.168.10.15")
COMPUTE_NAMES=("hypervisor-4" "hypervisor-5")

# SSH Configuration
SSH_USER="ubuntu"
# CHANGE THIS: Path to SSH private key on deployment host
SSH_KEY="$HOME/usvf/usvf/virtual-dc/config/vdc-dc1/ssh-keys/id_rsa"
# Example: SSH_KEY="$HOME/usvf/usvf/virtual-dc/config/vdc-dc1/ssh-keys/id_rsa"

# Subnet base for this datacenter
SUBNET_BASE="192.168.10"

# ----------------------------------------------------------------------------
# Ceph Configuration (Usually don't need to change)
# ----------------------------------------------------------------------------
CEPH_POOL_SIZE=2                    # Number of replicas (2 for 3-OSD cluster, can increase to 3)
CEPH_POOL_MIN_SIZE=1                # Minimum replicas for I/O
RBD_POOL="rbd_data"                 # RBD pool name
RBD_USER="rbduser"                  # RBD user
RGW_USER="s3user"                   # S3/RadosGW user
RGW_PORT=7480                       # RadosGW port (changed from 8000 to avoid Heat CFN API conflict)

# ----------------------------------------------------------------------------
# OpenStack Configuration (Usually don't need to change)
# ----------------------------------------------------------------------------
VIP="10.100.0.254"                  # OpenStack API VIP (Anycast on all controllers)
KOLLA_CONFIG="/etc/kolla"           # Kolla config directory
KOLLA_VERSION="19.2.0"              # Kolla-Ansible version
OPENSTACK_RELEASE="2024.2"          # OpenStack release

# Loopback IPs for services (one per node, adjust array size based on node count)
# For 3 nodes: 3 IPs, for 5 nodes: 5 IPs, etc.
# If you add more compute nodes, add more IPs here
API_TUNNEL_IPS=("10.1.0.1" "10.1.0.2" "10.1.0.3" "10.1.0.4" "10.1.0.5")

# ----------------------------------------------------------------------------
# Derived Variables (Don't edit these)
# ----------------------------------------------------------------------------
# Combine all unique nodes
ALL_IPS=($(printf '%s\n' "${CONTROL_IPS[@]}" "${COMPUTE_IPS[@]}" | sort -u))
ALL_NAMES=($(printf '%s\n' "${CONTROL_NAMES[@]}" "${COMPUTE_NAMES[@]}" | sort -u))

# Bootstrap uses first control node
BOOTSTRAP_HOST="${CONTROL_IPS[0]}"
BOOTSTRAP_IP="${CONTROL_IPS[0]}"
CEPH_ADMIN_NODE="${CONTROL_NAMES[0]}"
CEPH_ADMIN_IP="${CONTROL_IPS[0]}"

# SSH options with key
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ${SSH_KEY}"
KOLLA_VENV="$HOME/kolla-venv"

# ----------------------------------------------------------------------------
# Validation Function
# ----------------------------------------------------------------------------
validate_config() {
    local errors=0

    # Check SSH_KEY is configured
    if [[ "${SSH_KEY}" == "/path/to/your/ssh-key" ]]; then
        echo -e "\033[0;31m[ERROR]\033[0m SSH_KEY not configured in config.sh"
        echo "Please edit config.sh and set SSH_KEY to your actual SSH private key path"
        errors=$((errors + 1))
    fi

    # Check SSH_KEY file exists
    if [[ ! -f "${SSH_KEY}" ]]; then
        echo -e "\033[0;31m[ERROR]\033[0m SSH_KEY file not found: ${SSH_KEY}"
        echo "Please ensure the SSH private key exists at the specified path"
        errors=$((errors + 1))
    fi

    # Check CONTROL_IPS has at least 1 node
    if [[ ${#CONTROL_IPS[@]} -lt 1 ]]; then
        echo -e "\033[0;31m[ERROR]\033[0m CONTROL_IPS must contain at least 1 IP"
        errors=$((errors + 1))
    fi

    # Check COMPUTE_IPS has at least 1 node
    if [[ ${#COMPUTE_IPS[@]} -lt 1 ]]; then
        echo -e "\033[0;31m[ERROR]\033[0m COMPUTE_IPS must contain at least 1 IP"
        errors=$((errors + 1))
    fi

    # Check arrays have matching lengths
    if [[ ${#CONTROL_IPS[@]} -ne ${#CONTROL_NAMES[@]} ]]; then
        echo -e "\033[0;31m[ERROR]\033[0m CONTROL_IPS and CONTROL_NAMES must have the same length"
        errors=$((errors + 1))
    fi

    if [[ ${#COMPUTE_IPS[@]} -ne ${#COMPUTE_NAMES[@]} ]]; then
        echo -e "\033[0;31m[ERROR]\033[0m COMPUTE_IPS and COMPUTE_NAMES must have the same length"
        errors=$((errors + 1))
    fi

    # Check API_TUNNEL_IPS has enough IPs
    local total_unique_nodes=${#ALL_IPS[@]}
    if [[ ${#API_TUNNEL_IPS[@]} -lt $total_unique_nodes ]]; then
        echo -e "\033[0;33m[WARNING]\033[0m API_TUNNEL_IPS has ${#API_TUNNEL_IPS[@]} IPs but you have $total_unique_nodes unique nodes"
        echo "You may need to add more API_TUNNEL_IPs if nodes are on separate hosts"
    fi

    if [[ $errors -gt 0 ]]; then
        echo ""
        echo "Found $errors error(s) in config.sh. Please fix them before running deployment."
        return 1
    fi

    # Display configuration summary
    echo -e "\033[0;32m[OK]\033[0m Configuration validated successfully"
    echo ""
    echo "Deployment Configuration:"
    echo "  Control Nodes: ${#CONTROL_IPS[@]} (${CONTROL_IPS[*]})"
    echo "  Compute Nodes: ${#COMPUTE_IPS[@]} (${COMPUTE_IPS[*]})"
    echo "  Unique Nodes:  ${#ALL_IPS[@]} (${ALL_IPS[*]})"
    echo "  SSH User:      ${SSH_USER}"
    echo "  SSH Key:       ${SSH_KEY}"
    echo "  VIP:           ${VIP}"
    echo ""

    return 0
}

# ----------------------------------------------------------------------------
# SSH Connectivity Test
# ----------------------------------------------------------------------------
test_ssh_connectivity() {
    echo "Testing SSH connectivity to all nodes..."
    local failed=0

    for ip in "${ALL_IPS[@]}"; do
        echo -n "  Testing $ip... "
        if timeout 5 ssh ${SSH_OPTS} -o ConnectTimeout=3 ${SSH_USER}@"$ip" "hostname" >/dev/null 2>&1; then
            echo -e "\033[0;32mOK\033[0m"
        else
            echo -e "\033[0;31mFAILED\033[0m"
            failed=$((failed + 1))
        fi
    done

    if [[ $failed -gt 0 ]]; then
        echo ""
        echo -e "\033[0;31m[ERROR]\033[0m SSH connectivity test failed for $failed node(s)"
        echo "Please ensure:"
        echo "  1. All nodes are powered on and reachable"
        echo "  2. SSH keys are properly configured"
        echo "  3. Test manually: ssh -i ${SSH_KEY} ${SSH_USER}@<ip> hostname"
        return 1
    fi

    echo -e "\033[0;32m[OK]\033[0m All nodes are reachable via SSH"
    return 0
}
