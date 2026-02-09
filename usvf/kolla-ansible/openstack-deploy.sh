#!/bin/bash
# =============================================================================
# OpenStack Deployment Script with Kolla-Ansible and External Ceph
# =============================================================================
#
# This script deploys OpenStack using Kolla-Ansible with an existing Ceph cluster
# as the storage backend.
#
# Prerequisites:
#   - Ceph cluster already deployed
#   - SSH access from deployment host to all nodes (configured in config.sh)
#   - Pools already created: images, volumes, vms, backups
#
# Architecture:
#   - Flexible: Control and compute nodes configured via config.sh
#   - Supports both converged and separated deployments
#
# Usage:
#   ./openstack-deploy.sh
#
# =============================================================================

set -e  # Exit on error

# Source centralized configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$(dirname "$SCRIPT_DIR")/config.sh"
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: config.sh not found at $CONFIG_FILE"
    echo "Please create config.sh based on the template"
    exit 1
fi
source "$CONFIG_FILE"

# =============================================================================
# Configuration Variables
# =============================================================================

# Subnet base (REQUIRED - use --subnet=192.168.10 or --subnet=192.168.11)
SUBNET_BASE=""

# Parse command line arguments
for arg in "$@"; do
    case $arg in
        --subnet=*)
            SUBNET_BASE="${arg#*=}"
            SUBNET_BASE="${SUBNET_BASE%.0/24}"
            SUBNET_BASE="${SUBNET_BASE%.0}"
            shift
            ;;
        --help|-h)
            echo "Usage: $0 --subnet=<subnet_base> [phase]"
            echo "  Example: $0 --subnet=192.168.10          # full deploy on dc1"
            echo "  Example: $0 --subnet=192.168.11          # full deploy on dc2"
            echo "  Example: $0 --subnet=192.168.11 bootstrap # bootstrap only on dc2"
            exit 0
            ;;
    esac
done

# Validate subnet is provided
# if [ -z "$SUBNET_BASE" ]; then
#     echo "ERROR: --subnet is required"
#     echo "Usage: $0 --subnet=192.168.10   # for dc1"
#     echo "       $0 --subnet=192.168.11   # for dc2"
#     exit 1
# fi

# Configuration from config.sh
# Note: All variables are now loaded from centralized config.sh
# KOLLA_VENV, KOLLA_CONFIG, VIP, KOLLA_VERSION, OPENSTACK_RELEASE, SSH_USER, SSH_KEY, SSH_OPTS

# Controller and compute nodes from config.sh
CONTROLLERS=("${CONTROL_IPS[@]}")
CONTROLLER_NAMES=("${CONTROL_NAMES[@]}")
COMPUTES=("${COMPUTE_IPS[@]}")
COMPUTE_NAMES=("${COMPUTE_NAMES[@]}")
ALL_NODES=("${ALL_IPS[@]}")

# Ceph admin node (first control node)
CEPH_ADMIN_NODE="${CONTROL_NAMES[0]}"
CEPH_ADMIN_IP="${CONTROL_IPS[0]}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# =============================================================================
# Helper Functions
# =============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_section() {
    echo ""
    echo "============================================================================="
    echo -e "${GREEN}$1${NC}"
    echo "============================================================================="
    echo ""
}

run_on_node() {
    local node=$1
    shift
    # Use SSH_OPTS from config.sh (includes SSH key)
    ssh ${SSH_OPTS} ${SSH_USER}@${node} "$@"
}

run_on_node_sudo() {
    local node=$1
    shift
    # Use SSH_OPTS from config.sh (includes SSH key)
    ssh ${SSH_OPTS} ${SSH_USER}@${node} "sudo $@"
}

wait_for_apt_lock() {
    local host=$1
    local max_wait=300
    local interval=5
    local elapsed=0

    while [ $elapsed -lt $max_wait ]; do
        if run_on_node "$host" "sudo bash -c '
            ! fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 &&
            ! fuser /var/lib/dpkg/lock >/dev/null 2>&1 &&
            ! fuser /var/lib/apt/lists/lock >/dev/null 2>&1 &&
            ! fuser /var/cache/apt/archives/lock >/dev/null 2>&1
        '"; then
            return 0
        fi

        sleep $interval
        elapsed=$((elapsed + interval))
    done

    return 1
}

# ---------------------------------------------------------------------------
# clean_ssh_known_hosts: Remove stale SSH host keys for all hypervisors
# This is needed when VMs are destroyed and recreated with new SSH keys
# ---------------------------------------------------------------------------
clean_ssh_known_hosts() {
    log_info "Cleaning SSH known_hosts for all hypervisors..."

    # Remove old keys for all nodes
    for ip in "${CONTROLLERS[@]}" "${COMPUTES[@]}"; do
        ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$ip" 2>/dev/null || true
    done

    # Accept new keys with StrictHostKeyChecking=accept-new
    for ip in "${CONTROLLERS[@]}" "${COMPUTES[@]}"; do
        ssh ${SSH_OPTS} -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 ${SSH_USER}@"$ip" 'echo OK' 2>/dev/null || true
    done

    log_success "SSH known_hosts cleaned and new keys accepted"
}

# ---------------------------------------------------------------------------
# ensure_docker_running: Make Docker work on a node regardless of current state
# Handles: docker not installed, docker failed, docker.socket masked, etc.
# ---------------------------------------------------------------------------
ensure_docker_running() {
    local node=$1
    run_on_node "$node" "sudo bash -c '
        if ! command -v docker &>/dev/null; then
            echo \"Docker not installed on \$(hostname), skipping\"
            exit 0
        fi
        # Reset any failed state
        systemctl reset-failed docker 2>/dev/null || true
        # Unmask socket (kolla-ansible sometimes masks it)
        systemctl unmask docker.socket 2>/dev/null || true
        # Apply systemd drop-in so Docker can always restart cleanly
        mkdir -p /etc/systemd/system/docker.service.d
        cat > /etc/systemd/system/docker.service.d/kolla-ceph-compat.conf << DROPEOF
[Unit]
After=docker.socket
[Service]
ExecStartPre=/bin/bash -c \"systemctl unmask docker.socket 2>/dev/null; systemctl start docker.socket 2>/dev/null; true\"
DROPEOF
        systemctl daemon-reload
        # Start socket then service
        systemctl start docker.socket 2>/dev/null || true
        systemctl start docker 2>/dev/null || true
        if systemctl is-active --quiet docker; then
            echo \"Docker OK on \$(hostname)\"
        else
            echo \"Docker FAILED on \$(hostname) - attempting full restart\" >&2
            rm -f /var/run/docker.pid 2>/dev/null || true
            systemctl restart docker
        fi
    '" 2>/dev/null
}

# ---------------------------------------------------------------------------
# ensure_ceph_running: Start all Ceph daemons on a node
# Handles: daemons stopped from previous bootstrap, target not started, etc.
# ---------------------------------------------------------------------------
ensure_ceph_running() {
    local node=$1
    run_on_node "$node" "sudo bash -c '
        # Unmask in case it was masked
        systemctl unmask ceph.target 2>/dev/null || true
        # Start the ceph target
        systemctl start ceph.target 2>/dev/null || true
        # Start all ceph-related targets (ceph-<fsid>.target)
        for tgt in \$(systemctl list-unit-files --type=target --all --no-legend 2>/dev/null | grep \"ceph-\" | awk \"{print \\\$1}\"); do
            systemctl unmask \"\$tgt\" 2>/dev/null || true
            systemctl start \"\$tgt\" 2>/dev/null || true
        done
    '" 2>/dev/null
}

# ---------------------------------------------------------------------------
# ensure_all_healthy: Bring Docker + Ceph to a healthy state on all nodes
# Call this before any phase that depends on working Docker or Ceph.
# ---------------------------------------------------------------------------
ensure_all_healthy() {
    log_info "Ensuring Docker and Ceph are running on all nodes..."
    for node in "${ALL_NODES[@]}"; do
        ensure_docker_running "$node"
        ensure_ceph_running "$node"
    done
    # Give Ceph daemons a moment to form quorum
    sleep 5
}

# ---------------------------------------------------------------------------
# stop_all_ceph: Aggressively stop every Ceph daemon + container on a node
# Used before bootstrap so Docker can restart without Ceph blocking it.
# ---------------------------------------------------------------------------
stop_all_ceph() {
    local node=$1
    run_on_node "$node" "sudo bash -c '
        # Stop ceph targets
        for tgt in \$(systemctl list-units --type=target --all --no-legend 2>/dev/null | grep \"ceph\" | awk \"{print \\\$1}\"); do
            systemctl stop \"\$tgt\" 2>/dev/null || true
        done
        systemctl stop ceph.target 2>/dev/null || true
        # Stop every individual ceph service unit
        for svc in \$(systemctl list-units --type=service --all --no-legend 2>/dev/null | grep \"ceph\" | awk \"{print \\\$1}\"); do
            systemctl stop \"\$svc\" 2>/dev/null || true
        done
        sleep 2
        # Kill any remaining ceph containers
        if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
            docker ps -q --filter name=ceph | xargs -r docker stop --time=5 2>/dev/null || true
            docker ps -q --filter name=ceph | xargs -r docker kill 2>/dev/null || true
        fi
    '" 2>/dev/null
}

# ---------------------------------------------------------------------------
# nuke_ceph_containers: Remove ALL ceph containers + mask ceph.target
# This is needed before kolla-ansible bootstrap because:
#   1. Kolla masks docker.socket, installs docker, then starts docker
#   2. When docker starts, it tries to restore containers with restart=always
#   3. Ceph containers (managed by cephadm) have restart=always
#   4. If ceph containers fail to start (resources unavailable), docker crashes
# Solution: Remove ceph containers entirely before bootstrap. cephadm will
# recreate them when we unmask and start ceph.target afterward.
# ---------------------------------------------------------------------------
nuke_ceph_containers() {
    local node=$1
    log_info "Removing ceph containers and masking ceph.target on $node..."
    run_on_node "$node" "sudo bash -c '
        # 1. Mask ceph.target so systemd wont restart ceph during docker changes
        systemctl mask ceph.target 2>/dev/null || true

        # 2. Stop all ceph systemd units (targets + template services)
        for unit in \$(systemctl list-units --type=target --all --no-legend 2>/dev/null | grep \"ceph\" | awk \"{print \\\$1}\"); do
            systemctl stop \"\$unit\" 2>/dev/null || true
            systemctl mask \"\$unit\" 2>/dev/null || true
        done
        for svc in \$(systemctl list-units --type=service --all --no-legend 2>/dev/null | grep \"ceph\" | awk \"{print \\\$1}\"); do
            systemctl stop \"\$svc\" 2>/dev/null || true
        done
        systemctl stop ceph.target 2>/dev/null || true
        sleep 2

        # 3. If docker is running, remove ALL ceph containers
        #    (cephadm will recreate them - state is on disk, not in containers)
        if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
            # Change restart policy first so docker wont try to restart them
            docker ps -aq --filter name=ceph 2>/dev/null | xargs -r docker update --restart=no 2>/dev/null || true
            # Force remove all ceph containers
            docker ps -aq --filter name=ceph 2>/dev/null | xargs -r docker rm -f 2>/dev/null || true
        fi

        # 4. Stop docker completely and clean up stale state
        systemctl stop docker 2>/dev/null || true
        systemctl stop docker.socket 2>/dev/null || true
        rm -f /var/run/docker.pid 2>/dev/null || true

        # 5. Unmask docker (in case left from previous failed bootstrap)
        systemctl unmask docker.service 2>/dev/null || true
        systemctl unmask docker.socket 2>/dev/null || true
        systemctl reset-failed docker 2>/dev/null || true
        systemctl daemon-reload

        # 6. Restore Docker systemd override (from ceph-cluster-setup)
        mkdir -p /etc/systemd/system/docker.service.d
        cat > /etc/systemd/system/docker.service.d/override.conf << OVERRIDE
[Service]
Type=notify
NotifyAccess=main
OVERRIDE
        systemctl daemon-reload

        # 7. Start docker clean (no ceph containers to restore)
        systemctl start docker.socket 2>/dev/null || true
        systemctl start docker

        if systemctl is-active --quiet docker; then
            echo \"Docker clean-started OK on \$(hostname)\"
        else
            echo \"Docker FAILED to start on \$(hostname)\" >&2
            journalctl -xeu docker.service --no-pager -n 20 >&2
            exit 1
        fi
    '"
}

# ---------------------------------------------------------------------------
# restore_ceph_after_bootstrap: Unmask ceph.target, let cephadm recreate containers
# ---------------------------------------------------------------------------
restore_ceph_after_bootstrap() {
    local node=$1
    log_info "Restoring Ceph on $node..."
    run_on_node "$node" "sudo bash -c '
        # Unmask all ceph targets
        systemctl unmask ceph.target 2>/dev/null || true
        for tgt in \$(systemctl list-unit-files --type=target --all --no-legend 2>/dev/null | grep \"ceph-\" | awk \"{print \\\$1}\"); do
            systemctl unmask \"\$tgt\" 2>/dev/null || true
            systemctl enable \"\$tgt\" 2>/dev/null || true
        done

        # Re-enable the ceph template service (ceph-<fsid>@.service)
        for svc in \$(systemctl list-unit-files --type=service --all --no-legend 2>/dev/null | grep \"ceph-\" | awk \"{print \\\$1}\"); do
            systemctl enable \"\$svc\" 2>/dev/null || true
        done

        # Start ceph targets - this triggers cephadm to recreate containers
        systemctl start ceph.target 2>/dev/null || true
        for tgt in \$(systemctl list-unit-files --type=target --all --no-legend 2>/dev/null | grep \"ceph-\" | awk \"{print \\\$1}\"); do
            systemctl start \"\$tgt\" 2>/dev/null || true
        done

        # Also directly ask cephadm to adopt/redeploy if available
        if command -v cephadm &>/dev/null; then
            FSID=\$(ls /var/lib/ceph/ 2>/dev/null | head -1)
            if [ -n \"\$FSID\" ]; then
                echo \"Triggering cephadm to redeploy daemons (fsid=\$FSID)...\"
                cephadm ls 2>/dev/null | python3 -c \"
import sys,json
for d in json.load(sys.stdin):
    print(d.get(\\\"name\\\",\\\"\\\"))
\" 2>/dev/null | while read name; do
                    [ -z \"\$name\" ] && continue
                    cephadm adopt --style legacy --name \"\$name\" 2>/dev/null || \
                    cephadm deploy --fsid \"\$FSID\" --name \"\$name\" 2>/dev/null || true
                done
            fi
        fi
    '" 2>/dev/null
}

# ---------------------------------------------------------------------------
# destroy_kolla: Remove ALL Kolla containers from all nodes (fresh start)
# This is the nuclear option - removes all OpenStack containers + volumes
# ---------------------------------------------------------------------------
destroy_kolla() {
    log_section "Destroying stale Kolla deployment on all nodes"

    source "$KOLLA_VENV/bin/activate" 2>/dev/null || true

    # Try kolla-ansible destroy first (graceful)
    if [ -f "$KOLLA_CONFIG/multinode" ]; then
        log_info "Running kolla-ansible destroy (graceful cleanup)..."
        cd "$KOLLA_CONFIG"
        kolla-ansible destroy -i multinode --yes-i-really-really-mean-it 2>/dev/null || true
    fi

    # Then manually clean up any leftovers on every node
    log_info "Manually cleaning up containers on all nodes..."
    for node in "${ALL_NODES[@]}"; do
        log_info "Cleaning $node..."
        run_on_node "$node" "sudo bash -c '
            # Stop and remove all kolla containers
            docker ps -a --filter \"label=kolla_version\" -q 2>/dev/null | xargs -r docker rm -f 2>/dev/null || true
            # Also catch containers by name pattern
            docker ps -a --format \"{{.Names}}\" 2>/dev/null | grep -E \"^(kolla_|nova_|neutron_|cinder_|glance_|keystone_|horizon_|heat_|mariadb|rabbitmq|memcached|haproxy|proxysql|fluentd|cron|kolla|openvswitch|ovn)\" | xargs -r docker rm -f 2>/dev/null || true
            # Remove kolla volumes
            docker volume ls -q 2>/dev/null | grep -E \"^(kolla_|mariadb|rabbitmq)\" | xargs -r docker volume rm -f 2>/dev/null || true
            # Clean up kolla log directories but keep the base
            rm -rf /var/log/kolla/* 2>/dev/null || true
            # Clean up libvirt directories kolla creates
            rm -rf /var/lib/docker/volumes/kolla_* 2>/dev/null || true
        '" 2>/dev/null || true
    done

    log_success "Stale deployment destroyed on all nodes"
}

# Fix config file formatting (remove leading tabs/spaces that break INI parsing)
# Ceph's cephadm shell generates ceph.conf with tab indentation, but Kolla's
# oslo.config parser doesn't accept leading whitespace in INI files
fix_config_formatting() {
    local file=$1
    log_info "Fixing formatting in $file..."
    # Remove leading tabs
    sed -i 's/^\t//g' "$file"
    # Remove leading spaces
    sed -i 's/^[[:space:]]*\([^[:space:]]\)/\1/g' "$file"
    # Ensure no trailing whitespace
    sed -i 's/[[:space:]]*$//' "$file"
}

# =============================================================================
# Phase 1: Install Kolla-Ansible on Deployment Host
# =============================================================================

install_kolla_ansible() {
    log_section "Phase 1: Installing Kolla-Ansible on Deployment Host"

    # Clean SSH known_hosts first (in case VMs were destroyed and recreated)
    clean_ssh_known_hosts

    log_info "Installing system dependencies..."
    sudo apt update
    sudo apt install -y python3-dev libffi-dev gcc libssl-dev python3-venv git

    log_info "Creating Python virtual environment..."
    if [ ! -d "$KOLLA_VENV" ]; then
        python3 -m venv "$KOLLA_VENV"
    fi
    

    log_info "Activating virtual environment and installing packages..."
    source "$KOLLA_VENV/bin/activate"

    pip install -U pip
    pip install "ansible>=8,<10"
    pip install "kolla-ansible==${KOLLA_VERSION}"
    pip install python-openstackclient

    log_info "Installing Ansible dependencies..."
    kolla-ansible install-deps

    log_info "Creating Kolla config directory..."
    sudo mkdir -p "$KOLLA_CONFIG"
    sudo chown $USER:$USER "$KOLLA_CONFIG"

    log_info "Copying example configs..."
    cp -r "$KOLLA_VENV/share/kolla-ansible/etc_examples/kolla/"* "$KOLLA_CONFIG/"

    log_info "Generating passwords..."
    kolla-genpwd

    log_success "Kolla-Ansible installation complete!"
}

# =============================================================================
# Phase 2: Create Ceph Users for OpenStack
# =============================================================================

create_ceph_users() {
    log_section "Phase 2: Creating Ceph Pools and Users for OpenStack"

    # Ceph must be running for this phase
    ensure_all_healthy

    run_on_node_sudo $CEPH_ADMIN_IP "cephadm shell -- ceph config set global mon_max_pg_per_osd 500 || true"
    log_info "Creating Ceph pools on ${CEPH_ADMIN_NODE}..."

    # Create pools for OpenStack services
    # Using default PG count - Ceph will auto-tune with pg_autoscaler
    log_info "Creating 'images' pool for Glance..."
    run_on_node_sudo $CEPH_ADMIN_IP "cephadm shell -- ceph osd pool create images 32 || true"
    run_on_node_sudo $CEPH_ADMIN_IP "cephadm shell -- ceph osd pool set images pg_autoscale_mode on || true"
    run_on_node_sudo $CEPH_ADMIN_IP "cephadm shell -- rbd pool init images || true"

    log_info "Creating 'volumes' pool for Cinder..."
    run_on_node_sudo $CEPH_ADMIN_IP "cephadm shell -- ceph osd pool create volumes 32 || true"
    run_on_node_sudo $CEPH_ADMIN_IP "cephadm shell -- ceph osd pool set volumes pg_autoscale_mode on || true"
    run_on_node_sudo $CEPH_ADMIN_IP "cephadm shell -- rbd pool init volumes || true"

    log_info "Creating 'vms' pool for Nova..."
    run_on_node_sudo $CEPH_ADMIN_IP "cephadm shell -- ceph osd pool create vms 32 || true"
    run_on_node_sudo $CEPH_ADMIN_IP "cephadm shell -- ceph osd pool set vms pg_autoscale_mode on || true"
    run_on_node_sudo $CEPH_ADMIN_IP "cephadm shell -- rbd pool init vms || true"

    log_info "Creating 'backups' pool for Cinder Backup..."
    run_on_node_sudo $CEPH_ADMIN_IP "cephadm shell -- ceph osd pool create backups 32 || true"
    run_on_node_sudo $CEPH_ADMIN_IP "cephadm shell -- ceph osd pool set backups pg_autoscale_mode on || true"
    run_on_node_sudo $CEPH_ADMIN_IP "cephadm shell -- rbd pool init backups || true"

    log_info "Verifying pools..."
    run_on_node_sudo $CEPH_ADMIN_IP "cephadm shell -- ceph osd pool ls"

    log_success "Ceph pools created!"

    log_info "Creating Ceph users on ${CEPH_ADMIN_NODE}..."

    # Create users using cephadm shell and capture output
    # The key is to pipe the output to the HOST filesystem, not inside the container

    log_info "Creating client.glance user..."
    run_on_node_sudo $CEPH_ADMIN_IP "cephadm shell -- ceph auth get-or-create client.glance \
        mon 'profile rbd' \
        osd 'profile rbd pool=images' \
        mgr 'profile rbd pool=images'" > /tmp/ceph.client.glance.keyring

    log_info "Creating client.cinder user..."
    run_on_node_sudo $CEPH_ADMIN_IP "cephadm shell -- ceph auth get-or-create client.cinder \
        mon 'profile rbd' \
        osd 'profile rbd pool=volumes, profile rbd pool=vms, profile rbd-read-only pool=images' \
        mgr 'profile rbd pool=volumes, profile rbd pool=vms'" > /tmp/ceph.client.cinder.keyring

    log_info "Creating client.cinder-backup user..."
    run_on_node_sudo $CEPH_ADMIN_IP "cephadm shell -- ceph auth get-or-create client.cinder-backup \
        mon 'profile rbd' \
        osd 'profile rbd pool=backups' \
        mgr 'profile rbd pool=backups'" > /tmp/ceph.client.cinder-backup.keyring

    log_info "Creating client.nova user..."
    run_on_node_sudo $CEPH_ADMIN_IP "cephadm shell -- ceph auth get-or-create client.nova \
        mon 'profile rbd' \
        osd 'profile rbd pool=vms, profile rbd pool=volumes, profile rbd-read-only pool=images' \
        mgr 'profile rbd pool=vms'" > /tmp/ceph.client.nova.keyring

    log_info "Fetching ceph.conf..."
    run_on_node_sudo $CEPH_ADMIN_IP "cat /etc/ceph/ceph.conf" > /tmp/ceph.conf

    # Fix ceph.conf formatting (remove tabs that cause parsing errors)
    # Ceph's cephadm generates ceph.conf with tab indentation like:
    #   [global]
    #   	fsid = ...
    # But Kolla's oslo.config INI parser fails with:
    #   "Unexpected continuation line: '\tfsid = ...'"
    fix_config_formatting /tmp/ceph.conf

    log_success "Ceph users created and keyrings exported!"

    # Display keyrings for verification
    log_info "Verifying keyrings..."
    echo "--- client.glance ---"
    cat /tmp/ceph.client.glance.keyring
    echo "--- client.cinder ---"
    cat /tmp/ceph.client.cinder.keyring
    echo "--- client.cinder-backup ---"
    cat /tmp/ceph.client.cinder-backup.keyring
    echo "--- client.nova ---"
    cat /tmp/ceph.client.nova.keyring
}

# =============================================================================
# Helper Functions for Configuration Generation
# =============================================================================

generate_multinode_inventory() {
    log_info "Generating multinode inventory from template..."

    local template="$SCRIPT_DIR/multinode"
    local output="$KOLLA_CONFIG/multinode"

    if [[ ! -f "$template" ]]; then
        log_error "Template multinode file not found at: $template"
        exit 1
    fi

    # Generate header
    cat > "$output" << 'EOF'
# OpenStack Multinode Inventory
# Auto-generated from config.sh
# DO NOT EDIT - regenerate by running openstack-deploy.sh configs

[control]
EOF

    # Generate [control] section
    for i in "${!CONTROLLERS[@]}"; do
        local idx=$((i+1))
        printf "control%02d ansible_host=%s ansible_user=%s ansible_become=true ansible_ssh_private_key_file=%s api_ip=%s tunnel_ip=%s\n" \
            "$idx" "${CONTROLLERS[$i]}" "$SSH_USER" "$SSH_KEY" "${API_TUNNEL_IPS[$i]}" "${API_TUNNEL_IPS[$i]}" >> "$output"
    done

    # Generate [network] section
    echo "" >> "$output"
    echo "[network]" >> "$output"
    for i in "${!CONTROLLERS[@]}"; do
        local idx=$((i+1))
        printf "control%02d\n" "$idx" >> "$output"
    done

    # Generate [compute] section
    echo "" >> "$output"
    echo "[compute]" >> "$output"
    for i in "${!COMPUTES[@]}"; do
        local idx=$((i+1))
        # For API IP: if compute is same as control, reuse the API IP, otherwise assign new
        local api_idx=$i
        # Check if this compute IP exists in CONTROLLERS
        local found_in_control=false
        for j in "${!CONTROLLERS[@]}"; do
            if [[ "${COMPUTES[$i]}" == "${CONTROLLERS[$j]}" ]]; then
                api_idx=$j
                found_in_control=true
                break
            fi
        done
        # If not found in controllers, assign new API IP (after control IPs)
        if [[ "$found_in_control" == "false" ]]; then
            api_idx=$((${#CONTROLLERS[@]} + i))
        fi

        printf "compute%02d ansible_host=%s ansible_user=%s ansible_become=true ansible_ssh_private_key_file=%s api_ip=%s tunnel_ip=%s\n" \
            "$idx" "${COMPUTES[$i]}" "$SSH_USER" "$SSH_KEY" "${API_TUNNEL_IPS[$api_idx]}" "${API_TUNNEL_IPS[$api_idx]}" >> "$output"
    done

    # Generate [monitoring] section
    echo "" >> "$output"
    echo "[monitoring]" >> "$output"
    echo "control01" >> "$output"

    # Generate [storage] section
    echo "" >> "$output"
    echo "[storage]" >> "$output"
    for i in "${!COMPUTES[@]}"; do
        local idx=$((i+1))
        printf "compute%02d\n" "$idx" >> "$output"
    done

    # Append the rest from template (all the [children] sections)
    echo "" >> "$output"
    sed -n '/^\[deployment\]/,$p' "$template" >> "$output"

    log_success "Generated multinode inventory at $output"
}

generate_globals_yml() {
    log_info "Generating globals.yml from template..."

    local template="$SCRIPT_DIR/globals.yml"
    local output="$KOLLA_CONFIG/globals.yml"

    if [[ ! -f "$template" ]]; then
        log_error "Template globals.yml file not found at: $template"
        exit 1
    fi

    # Copy template
    cp "$template" "$output"

    # Update VIP if different from template
    sed -i'' -e "s|kolla_internal_vip_address:.*|kolla_internal_vip_address: \"$VIP\"|" "$output"

    # Update OpenStack release if different
    sed -i'' -e "s|openstack_release:.*|openstack_release: \"$OPENSTACK_RELEASE\"|" "$output"

    # Remove backup files created by sed on macOS
    rm -f "${output}-e" 2>/dev/null || true

    log_success "Generated globals.yml at $output"
}

# =============================================================================
# Phase 3: Setup Kolla Configuration Files
# =============================================================================

setup_kolla_configs() {
    log_section "Phase 3: Setting Up Kolla Configuration Files"

    # Generate multinode and globals.yml from templates
    generate_multinode_inventory
    generate_globals_yml

    # Copy ansible.cfg to Kolla config directory
    log_info "Copying ansible.cfg to $KOLLA_CONFIG..."
    if [ -f "$SCRIPT_DIR/ansible.cfg" ]; then
        cp "$SCRIPT_DIR/ansible.cfg" "$KOLLA_CONFIG/ansible.cfg"
        log_success "ansible.cfg copied (disables host key checking)"
    else
        log_warning "ansible.cfg not found in $SCRIPT_DIR, creating default..."
        cat > "$KOLLA_CONFIG/ansible.cfg" << 'EOF'
[defaults]
host_key_checking = False
gathering = smart
fact_caching = jsonfile
fact_caching_connection = /tmp/ansible_facts
fact_caching_timeout = 3600
stdout_callback = yaml
deprecation_warnings = False
inventory = /etc/kolla/multinode

[ssh_connection]
pipelining = True
ssh_args = -o ControlMaster=auto -o ControlPersist=60s -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
EOF
        log_success "Default ansible.cfg created"
    fi

    # Create directory structure for Ceph configs
    log_info "Creating config directory structure..."
    mkdir -p "$KOLLA_CONFIG/config/glance"
    mkdir -p "$KOLLA_CONFIG/config/cinder/cinder-volume"
    mkdir -p "$KOLLA_CONFIG/config/cinder/cinder-backup"
    mkdir -p "$KOLLA_CONFIG/config/nova"

    # Helper to safely copy if source exists
    safe_copy() {
        src=$1
        dest=$2
        if [ -f "$src" ]; then
            log_info "Copying $src to $dest..."
            cp "$src" "$dest"
        else
            log_warning "Source $src missing. Assuming it's already in place."
        fi
    }

    # Copy ceph.conf to all service directories
    log_info "Copying ceph.conf to service directories..."
    safe_copy /tmp/ceph.conf "$KOLLA_CONFIG/config/glance/"
    safe_copy /tmp/ceph.conf "$KOLLA_CONFIG/config/cinder/"
    safe_copy /tmp/ceph.conf "$KOLLA_CONFIG/config/nova/"

    # Copy keyrings to appropriate directories
    log_info "Copying keyrings to service directories..."
    safe_copy /tmp/ceph.client.glance.keyring "$KOLLA_CONFIG/config/glance/"
    safe_copy /tmp/ceph.client.cinder.keyring "$KOLLA_CONFIG/config/cinder/cinder-volume/"
    safe_copy /tmp/ceph.client.cinder-backup.keyring "$KOLLA_CONFIG/config/cinder/cinder-backup/"
    safe_copy /tmp/ceph.client.cinder.keyring "$KOLLA_CONFIG/config/cinder/cinder-backup/"
    safe_copy /tmp/ceph.client.nova.keyring "$KOLLA_CONFIG/config/nova/"
    safe_copy /tmp/ceph.client.cinder.keyring "$KOLLA_CONFIG/config/nova/"

    # Fix formatting of all Ceph config files (remove tabs/spaces that break INI parsing)
    log_info "Fixing formatting of all Ceph config files..."
    for conf_file in $(find "$KOLLA_CONFIG/config" -name "ceph.conf" -o -name "*.keyring" 2>/dev/null); do
        fix_config_formatting "$conf_file"
    done

    log_success "Kolla configuration files ready!"
}

# OLD inline generation removed - now using generate functions above
# The following large heredoc sections were removed:
# - globals.yml generation (lines 634-718)
# - multinode generation (lines 722-1351)

__REMOVED_OLD_INLINE_CONFIG_GENERATION() {
    # This function is never called - it's just to mark where the old code was
    # Old code removed: inline cat > globals.yml << EOF (lines 634-718)
    # Old code removed: inline cat > multinode << EOF (lines 722-1351)
    true
}

# The actual end of setup_kolla_configs was after line 1351
# Below this should be the verify and other sections

# Continuing with the rest of the script...


# =============================================================================
# Phase 4: Setup VIP on Controllers
# =============================================================================

setup_vip() {
    log_section "Phase 4: Setting Up Anycast VIP on Controllers"

    for i in "${!CONTROLLERS[@]}"; do
        node="${CONTROLLERS[$i]}"
        name="${CONTROLLER_NAMES[$i]}"
        log_info "Configuring VIP on $name ($node)..."

        # Add VIP to lo1 interface
        run_on_node_sudo $node "ip addr add ${VIP}/32 dev lo1 2>/dev/null || true"

        # Verify
        if run_on_node $node "ip addr show lo1 | grep -q $VIP"; then
            log_success "VIP configured on $name"
        else
            log_warning "VIP may already exist or failed on $name"
        fi
    done

    # Add route on deployment host
    log_info "Adding route to VIP on deployment host..."
    sudo ip route add ${VIP}/32 via ${CONTROLLERS[0]} 2>/dev/null || true

    log_success "VIP setup complete!"
}

# =============================================================================
# Phase 5: Install Ceph Client on All Nodes
# =============================================================================

install_ceph_client() {
    log_section "Phase 5: Installing Ceph Client on All Nodes"
    log_info "Waiting for apt locks..."
    for host in "${ALL_NODES[@]}"; do
        echo -n "Checking APT locks on $host... "

        if wait_for_apt_lock "$host"; then
            echo "ready"
        else
            echo "FAILED (lock held too long)"
            exit 1
        fi
    done


    for node in "${ALL_NODES[@]}"; do
        log_info "Installing ceph-common on $node..."
        run_on_node "$node" "sudo bash -c 'apt update && apt install -y ceph-common python3-rbd'"
    done

    log_success "Ceph client installed on all nodes!"
}

# =============================================================================
# Phase 6: Run Kolla-Ansible Bootstrap
# =============================================================================

run_bootstrap() {
    log_section "Phase 6: Running Kolla-Ansible Bootstrap"

    # ---------------------------------------------------------------
    # Step 0: Check if Ceph cluster is actually installed and running
    # ---------------------------------------------------------------
    local ceph_exists=false
    log_info "Checking if Ceph cluster is installed..."
    # Check if Docker exists AND has Ceph containers (not just /var/lib/ceph directory)
    if run_on_node "${CONTROLLERS[0]}" "command -v docker >/dev/null 2>&1 && docker ps -a --filter name=ceph 2>/dev/null | grep -q ceph" 2>/dev/null; then
        log_info "Ceph cluster detected (has running/stopped containers) - will manage during bootstrap"
        ceph_exists=true
    else
        log_info "No Ceph cluster detected (fresh nodes or no containers) - bootstrap will only handle Docker"
        ceph_exists=false
    fi

    # ---------------------------------------------------------------
    # Step 1: NUKE ceph containers if Ceph exists
    # ---------------------------------------------------------------
    if [ "$ceph_exists" = true ]; then
        log_info "Removing ceph containers and cleaning docker on all nodes..."
        for node in "${ALL_NODES[@]}"; do
            nuke_ceph_containers "$node"
        done
        sleep 3
    fi

    # ---------------------------------------------------------------
    # Step 2: Run bootstrap with retry
    # ---------------------------------------------------------------
    source "$KOLLA_VENV/bin/activate"
    cd "$KOLLA_CONFIG"

    local bootstrap_success=false
    local max_retries=2

    for retry in $(seq 0 $max_retries); do
        log_info "Running bootstrap-servers (attempt $((retry + 1))/$((max_retries + 1)))..."

        if kolla-ansible bootstrap-servers -i multinode; then
            bootstrap_success=true
            log_success "Bootstrap completed successfully!"
            break
        fi

        log_warning "Bootstrap attempt $((retry + 1)) failed"

        if [ $retry -lt $max_retries ]; then
            log_info "Recovering nodes before retry..."
            if [ "$ceph_exists" = true ]; then
                for node in "${ALL_NODES[@]}"; do
                    nuke_ceph_containers "$node"
                done
            fi
            sleep 10
        fi
    done

    if [ "$bootstrap_success" = false ]; then
        log_error "Bootstrap failed after $((max_retries + 1)) attempts"
        log_error "Check logs: ssh ubuntu@${CONTROLLERS[0]} 'sudo journalctl -xeu docker --no-pager -n 50'"
        exit 1
    fi

    # ---------------------------------------------------------------
    # Step 3: Restore Ceph if it existed before bootstrap
    # ---------------------------------------------------------------
    if [ "$ceph_exists" = true ]; then
        log_info "Restoring Ceph on all nodes (cephadm will recreate containers)..."
        for node in "${ALL_NODES[@]}"; do
            restore_ceph_after_bootstrap "$node"
        done

        # Wait for Ceph quorum (cephadm needs to recreate containers)
        log_info "Waiting for Ceph cluster to form quorum (this may take a minute)..."
        sleep 30

        # Verify Ceph
        log_info "Verifying Ceph cluster health..."
        local ceph_ok=false
        for attempt in 1 2 3 4 5; do
            if run_on_node_sudo "$CEPH_ADMIN_IP" "cephadm shell -- ceph -s" 2>/dev/null; then
                ceph_ok=true
                break
            fi
            log_warning "Ceph not ready yet (attempt $attempt/5), waiting 15s..."
            sleep 15
        done

        if [ "$ceph_ok" = false ]; then
            log_error "Ceph cluster failed to recover after bootstrap"
            log_error "Check: ssh ubuntu@${CEPH_ADMIN_IP} 'sudo cephadm shell -- ceph -s'"
            exit 1
        fi

        log_success "Bootstrap complete - Docker and Ceph both healthy!"
    else
        log_success "Bootstrap complete - Docker is healthy!"
        log_info "Next step: Install Ceph cluster before continuing OpenStack deployment"
    fi
}

# =============================================================================
# Phase 7: Run Kolla-Ansible Prechecks
# =============================================================================

run_prechecks() {
    log_section "Phase 7: Running Kolla-Ansible Prechecks"

    ensure_all_healthy

    source "$KOLLA_VENV/bin/activate"
    cd "$KOLLA_CONFIG"

    log_info "Running prechecks..."
    kolla-ansible prechecks -i multinode

    log_success "Prechecks passed!"
}

# =============================================================================
# Phase 8: Run Kolla-Ansible Deploy
# =============================================================================

run_deploy() {
    log_section "Phase 8: Running Kolla-Ansible Deploy"

    ensure_all_healthy

    source "$KOLLA_VENV/bin/activate"
    cd "$KOLLA_CONFIG"

    local max_attempts=3
    for attempt in $(seq 1 $max_attempts); do
        log_info "Starting OpenStack deployment (attempt $attempt/$max_attempts)..."

        if kolla-ansible deploy -i multinode; then
            log_success "Deployment complete!"
            return 0
        fi

        log_warning "Deploy attempt $attempt failed - checking if MariaDB recovery is needed..."

        # Check if MariaDB cluster is broken (common after interrupted deploys)
        local mariadb_broken=false
        for ctrl in "${CONTROLLERS[@]}"; do
            if run_on_node "$ctrl" "sudo docker ps -a --format '{{.Names}} {{.Status}}' 2>/dev/null | grep mariadb | grep -qi 'exited\|dead'" 2>/dev/null; then
                mariadb_broken=true
                break
            fi
        done

        if [ "$mariadb_broken" = true ] && [ $attempt -lt $max_attempts ]; then
            log_info "MariaDB cluster appears broken - running mariadb-recovery..."
            kolla-ansible mariadb-recovery -i multinode 2>&1 || true
            sleep 10
            ensure_all_healthy
            log_info "MariaDB recovery done, retrying deploy..."
        elif [ $attempt -lt $max_attempts ]; then
            log_info "Waiting before retry..."
            ensure_all_healthy
            sleep 15
        fi
    done

    log_error "Deploy failed after $max_attempts attempts"
    exit 1
}

# =============================================================================
# Phase 9: Run Post-Deploy
# =============================================================================

run_post_deploy() {
    log_section "Phase 9: Running Post-Deploy"

    source "$KOLLA_VENV/bin/activate"
    cd "$KOLLA_CONFIG"

    log_info "Running post-deploy..."
    kolla-ansible post-deploy -i multinode

    log_success "Post-deploy complete!"
}

# =============================================================================
# Phase 10: Configure RadosGW Keystone Integration
# =============================================================================
# WHY: By default RGW uses its own auth. For OpenStack Swift integration:
# 1. RGW needs Keystone credentials to validate user tokens
# 2. Swift endpoints must have /swift prefix (RGW expects this path)
# Without this: `openstack container list` returns 401 Unauthorized

configure_rgw_keystone() {
    log_section "Phase 10: Configuring RadosGW Keystone Integration"

    source "$KOLLA_VENV/bin/activate"
    source "$KOLLA_CONFIG/admin-openrc.sh"

    # Check if RGW is deployed
    local rgw_found=false
    for node in "${ALL_NODES[@]}"; do
        if run_on_node "$node" "sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -q rgw" 2>/dev/null; then
            rgw_found=true
            break
        fi
    done

    if [ "$rgw_found" = false ]; then
        log_warning "No RadosGW containers found - skipping Keystone integration"
        return 0
    fi

    # Step 1: Create Keystone user for RGW (service account to validate tokens)
    log_info "Creating Keystone service user for RadosGW..."
    local RGW_KEYSTONE_PASSWORD="rgw_keystone_$(openssl rand -hex 8)"

    if ! openstack user show rgw &>/dev/null; then
        openstack user create --domain default --password "$RGW_KEYSTONE_PASSWORD" rgw
        openstack role add --project service --user rgw admin
        log_success "Keystone user 'rgw' created"
    else
        openstack user set --password "$RGW_KEYSTONE_PASSWORD" rgw
        log_info "Keystone user 'rgw' exists - password updated"
    fi

    # Step 2: Remove any existing client.rgw overrides (they take precedence over global)
    log_info "Clearing any existing client.rgw Keystone overrides..."
    run_on_node_sudo "${CEPH_ADMIN_IP}" "cephadm shell -- bash -c '
        ceph config rm client.rgw rgw_keystone_admin_password 2>/dev/null || true
        ceph config rm client.rgw rgw_keystone_admin_user 2>/dev/null || true
        ceph config rm client.rgw rgw_keystone_admin_project 2>/dev/null || true
        ceph config rm client.rgw rgw_keystone_admin_domain 2>/dev/null || true
        ceph config rm client.rgw rgw_keystone_accepted_roles 2>/dev/null || true
        ceph config rm client.rgw rgw_keystone_accepted_admin_roles 2>/dev/null || true
        ceph config rm client.rgw rgw_keystone_api_version 2>/dev/null || true
        ceph config rm client.rgw rgw_keystone_url 2>/dev/null || true
        ceph config rm client.rgw rgw_swift_account_in_url 2>/dev/null || true
        ceph config rm client.rgw rgw_s3_auth_use_keystone 2>/dev/null || true
    '" 2>/dev/null || true

    # Step 3: Configure RGW with Keystone settings (global section)
    log_info "Configuring RadosGW with Keystone authentication..."
    run_on_node_sudo "${CEPH_ADMIN_IP}" "cephadm shell -- bash -c '
        ceph config set global rgw_keystone_url http://${VIP}:5000
        ceph config set global rgw_keystone_api_version 3
        ceph config set global rgw_keystone_admin_user rgw
        ceph config set global rgw_keystone_admin_password ${RGW_KEYSTONE_PASSWORD}
        ceph config set global rgw_keystone_admin_project service
        ceph config set global rgw_keystone_admin_domain default
        ceph config set global rgw_keystone_accepted_roles admin,member,_member_,reader
        ceph config set global rgw_keystone_accepted_admin_roles admin
        ceph config set global rgw_swift_account_in_url true
        ceph config set global rgw_s3_auth_use_keystone true
    '"
    log_success "RadosGW Keystone config applied"

    # Step 4: Restart RGW daemons (find the actual service name dynamically)
    log_info "Restarting RadosGW daemons..."
    local rgw_service
    rgw_service=$(run_on_node_sudo "${CEPH_ADMIN_IP}" "cephadm shell -- ceph orch ls 2>/dev/null | grep '^rgw' | awk '{print \$1}'" 2>/dev/null | head -1)
    if [ -n "$rgw_service" ]; then
        run_on_node_sudo "${CEPH_ADMIN_IP}" "cephadm shell -- ceph orch restart $rgw_service" 2>/dev/null || true
        log_info "Restarted service: $rgw_service"
    else
        log_warning "Could not find RGW service name - manual restart may be needed"
    fi
    sleep 20

    # Step 5: Fix Swift endpoints (add /swift prefix)
    log_info "Updating Swift endpoints with /swift prefix..."
    local swift_endpoints
    swift_endpoints=$(openstack endpoint list --service swift -f value -c ID 2>/dev/null || true)

    if [ -n "$swift_endpoints" ]; then
        for endpoint_id in $swift_endpoints; do
            local current_url
            current_url=$(openstack endpoint show "$endpoint_id" -f value -c url 2>/dev/null)
            if [[ "$current_url" != *"/swift/"* ]] && [[ "$current_url" == *"/v1/"* ]]; then
                local new_url="${current_url/\/v1\//\/swift\/v1\/}"
                openstack endpoint set --url "$new_url" "$endpoint_id"
                log_info "  Updated endpoint: $new_url"
            fi
        done
        log_success "Swift endpoints updated"
    else
        log_warning "No Swift endpoints found"
    fi

    # Step 6: Verify
    log_info "Verifying RadosGW Keystone integration..."
    sleep 5
    if openstack container list &>/dev/null; then
        log_success "RadosGW Keystone integration working!"
    else
        log_warning "Swift API test failed - may need manual verification"
    fi
}

# =============================================================================
# Phase 11: Verify Deployment
# =============================================================================

verify_deployment() {
    log_section "Phase 11: Verifying Deployment"

    source "$KOLLA_VENV/bin/activate"
    source "$KOLLA_CONFIG/admin-openrc.sh"

    log_info "Testing OpenStack CLI..."
    openstack service list

    log_info "Testing Ceph connectivity from cinder_volume..."
    ssh ${SSH_OPTS} ${SSH_USER}@${COMPUTES[0]} "sudo docker exec cinder_volume ceph -s --id cinder"

    # Get Horizon password
    ADMIN_PASS=$(grep keystone_admin_password "$KOLLA_CONFIG/passwords.yml" | awk '{print $2}')

    log_success "Deployment verified!"
    echo ""
    echo "============================================================================="
    echo -e "${GREEN}OpenStack Deployment Complete!${NC}"
    echo "============================================================================="
    echo ""
    echo "Horizon Dashboard: http://${VIP}"
    echo "Username: admin"
    echo "Password: $ADMIN_PASS"
    echo ""
    echo "To use OpenStack CLI:"
    echo "  source $KOLLA_VENV/bin/activate"
    echo "  source $KOLLA_CONFIG/admin-openrc.sh"
    echo "  openstack service list"
    echo ""
}

# =============================================================================
# Main Execution
# =============================================================================

main() {
    echo "============================================================================="
    echo -e "${GREEN}OpenStack Deployment with Kolla-Ansible and Ceph${NC}"
    echo "============================================================================="
    echo ""
    echo "Configuration from: $CONFIG_FILE"
    echo "  - Control Nodes: ${#CONTROLLERS[@]} (${CONTROLLERS[*]})"
    echo "  - Compute Nodes: ${#COMPUTES[@]} (${COMPUTES[*]})"
    if [ "${CONTROLLERS[*]}" == "${COMPUTES[*]}" ]; then
        echo "  - Architecture:  Converged (same nodes for control and compute)"
    else
        echo "  - Architecture:  Separated (different control and compute nodes)"
    fi
    echo "  - VIP:           ${VIP}"
    echo "  - Kolla dir:     ${KOLLA_CONFIG}"
    echo ""

    # Run all phases (each is idempotent / safe to re-run)
    install_kolla_ansible
    create_ceph_users
    setup_kolla_configs
    setup_vip
    install_ceph_client
    run_bootstrap
    run_prechecks
    run_deploy
    run_post_deploy
    configure_rgw_keystone
    verify_deployment
}

# Allow running individual phases
case "${1:-}" in
    install)
        install_kolla_ansible
        ;;
    ceph-users)
        create_ceph_users
        ;;
    configs)
        setup_kolla_configs
        ;;
    vip)
        setup_vip
        ;;
    ceph-client)
        install_ceph_client
        ;;
    bootstrap)
        run_bootstrap
        ;;
    prechecks)
        run_prechecks
        ;;
    deploy)
        run_deploy
        ;;
    destroy)
        destroy_kolla
        ;;
    fresh)
        destroy_kolla
        run_bootstrap
        run_prechecks
        run_deploy
        run_post_deploy
        verify_deployment
        ;;
    post-deploy)
        run_post_deploy
        ;;
    rgw-keystone)
        configure_rgw_keystone
        ;;
    verify)
        verify_deployment
        ;;
    *)
        main
        ;;
esac
