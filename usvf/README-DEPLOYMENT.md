# One-Click OpenStack + Ceph Deployment Guide

This guide walks you through deploying a complete OpenStack cloud with Ceph storage backend using the automated deployment scripts.

## Architecture

The deployment supports two modes:

### 1. Converged Architecture (3 nodes)
**Current default configuration**
- All 3 nodes run both control plane and compute services
- Ceph: MON, MGR, and OSD on all 3 nodes
- OpenStack: Control services + Nova compute on all 3 nodes
- Better resource utilization for smaller deployments
- **Advantages**: Fewer machines, better Ceph redundancy (3 OSDs vs 2)

### 2. Separated Architecture (5+ nodes)
**For future expansion**
- 3 control nodes: Ceph MON/MGR + OpenStack control services
- 2+ compute nodes: Ceph OSD + Nova compute
- Better isolation between control and data plane
- **Advantages**: Easier to scale compute independently

## Prerequisites

### Hardware Requirements
- **Minimum per node**: 8 CPU cores, 16GB RAM, 100GB disk
- **Recommended per node**: 16 CPU cores, 32GB RAM, 200GB+ disk
- Additional disk for Ceph OSD (optional but recommended)

### Software Requirements
- Ubuntu 22.04 LTS on all nodes
- SSH access from deployment host to all nodes
- Internet connectivity on all nodes
- Python 3.8+ on deployment host

### Network Requirements
- All nodes on same network subnet (default: 192.168.10.0/24)
- Nodes can reach each other
- Deployment host can reach all nodes

## Quick Start

### Step 1: Edit Configuration

```bash
cd /Users/sushantpatrikar/usvf/usvf
nano config.sh
```

**Required changes:**
```bash
# For 3-node converged setup:
CONTROL_IPS=("192.168.10.11" "192.168.10.12" "192.168.10.13")
COMPUTE_IPS=("192.168.10.11" "192.168.10.12" "192.168.10.13")  # Same as control

# SSH Configuration - MUST CHANGE!
SSH_KEY="/path/to/your/ssh-private-key"
SSH_USER="ubuntu"
```

**For future 5-node separated setup:**
```bash
CONTROL_IPS=("192.168.10.11" "192.168.10.12" "192.168.10.13")
COMPUTE_IPS=("192.168.10.14" "192.168.10.15")  # Different nodes
```

### Step 2: Verify SSH Access

```bash
# Test SSH to all nodes
ssh -i /path/to/your/key ubuntu@192.168.10.11 hostname
ssh -i /path/to/your/key ubuntu@192.168.10.12 hostname
ssh -i /path/to/your/key ubuntu@192.168.10.13 hostname
```

If SSH fails:
```bash
# Add your public key to each node
ssh-copy-id -i /path/to/your/key.pub ubuntu@192.168.10.11
```

### Step 3: Run Deployment

```bash
cd /Users/sushantpatrikar/usvf/usvf
./kolla-ansible/deploy-all.sh
```

The script will:
1. Validate configuration and SSH connectivity
2. Deploy Ceph cluster (MON, MGR, OSD, RGW, pools)
3. Install Kolla-Ansible and dependencies
4. Deploy OpenStack services
5. Configure Ceph as backend for Glance, Cinder, Nova
6. Run verification tests

**Expected runtime**: 30-45 minutes

### Step 4: Access Your Cloud

After deployment completes:

**Horizon Dashboard:**
```
URL: http://10.100.0.254
Username: admin
Password: (displayed at end of deployment)
```

**OpenStack CLI:**
```bash
source ~/kolla-venv/bin/activate
source /etc/kolla/admin-openrc.sh
openstack service list
```

**Ceph Status:**
```bash
ssh -i /path/to/key ubuntu@192.168.10.11 "sudo ceph -s"
```

## Configuration Files

### config.sh
Centralized configuration file for all deployment parameters:
- Node IPs and hostnames
- SSH credentials
- Ceph settings (pool sizes, users, ports)
- OpenStack settings (VIP, versions)

### multinode (generated)
Ansible inventory file for Kolla-Ansible, generated from config.sh:
- Lists all control and compute nodes
- Sets SSH credentials per node
- Configures service placement

### globals.yml (generated)
Kolla-Ansible global configuration, generated from template:
- OpenStack services to enable
- Ceph integration settings
- Networking configuration

## Running Individual Phases

For debugging or re-running specific phases:

### Ceph Only
```bash
cd /Users/sushantpatrikar/usvf/usvf/virtual-dc/scripts
./ceph-cluster-setup.sh
```

### OpenStack Only (Ceph must be deployed first)
```bash
cd /Users/sushantpatrikar/usvf/usvf/kolla-ansible
./openstack-deploy.sh install    # Install Kolla-Ansible
./openstack-deploy.sh ceph-users # Create Ceph users
./openstack-deploy.sh configs    # Generate configs
./openstack-deploy.sh vip        # Setup VIP
./openstack-deploy.sh ceph-client # Install Ceph client
./openstack-deploy.sh bootstrap  # Bootstrap nodes
./openstack-deploy.sh prechecks  # Run prechecks
./openstack-deploy.sh deploy     # Deploy OpenStack
./openstack-deploy.sh post-deploy # Post-deploy
./openstack-deploy.sh verify     # Verify deployment
```

### Deploy Specific Phase
```bash
./kolla-ansible/deploy-all.sh phase4  # Run only phase 4 (Ceph installation)
```

## Troubleshooting

### SSH Connection Fails

**Problem**: Cannot SSH to nodes

**Solution**:
```bash
# Check if SSH key has correct permissions
chmod 600 /path/to/your/ssh-key

# Test SSH manually
ssh -v -i /path/to/your/ssh-key ubuntu@192.168.10.11

# Check if public key is in authorized_keys
ssh -i /path/to/your/ssh-key ubuntu@192.168.10.11 "cat ~/.ssh/authorized_keys"
```

### Configuration Validation Fails

**Problem**: `config.sh` validation errors

**Solution**:
```bash
# Source config and run validation
source config.sh
validate_config
```

Common issues:
- `SSH_KEY` not changed from default `/path/to/your/ssh-key`
- SSH key file doesn't exist
- Array lengths don't match (CONTROL_IPS vs CONTROL_NAMES)

### Ceph Deployment Fails

**Problem**: OSDs don't deploy or cluster not healthy

**Solution**:
```bash
# Check Ceph status
ssh -i /path/to/key ubuntu@192.168.10.11 "sudo cephadm shell -- ceph -s"

# Check OSD deployment
ssh -i /path/to/key ubuntu@192.168.10.11 "sudo cephadm shell -- ceph orch ps"

# Check for disk space (OSDs need 5GB+ free space)
ssh -i /path/to/key ubuntu@192.168.10.11 "df -h"
```

### OpenStack Deployment Fails

**Problem**: Kolla-Ansible deploy fails

**Solution**:
```bash
# Check Docker status on nodes
ssh -i /path/to/key ubuntu@192.168.10.11 "sudo systemctl status docker"

# Check Kolla logs
ssh -i /path/to/key ubuntu@192.168.10.11 "sudo docker logs <container-name>"

# Re-run prechecks
cd /Users/sushantpatrikar/usvf/usvf/kolla-ansible
./openstack-deploy.sh prechecks
```

### MariaDB Cluster Broken

**Problem**: MariaDB containers fail to start

**Solution**:
```bash
cd /Users/sushantpatrikar/usvf/usvf/kolla-ansible
source ~/kolla-venv/bin/activate
kolla-ansible mariadb-recovery -i /etc/kolla/multinode
```

## Cleanup and Redeployment

### Clean OpenStack Only (Keep Ceph)
```bash
cd /Users/sushantpatrikar/usvf/usvf/kolla-ansible
./openstack-deploy.sh destroy
```

### Clean Everything (Nuclear Option)
```bash
# Destroy OpenStack
cd /Users/sushantpatrikar/usvf/usvf/kolla-ansible
./openstack-deploy.sh destroy

# Destroy Ceph (run on each node)
ssh -i /path/to/key ubuntu@192.168.10.11 "sudo cephadm rm-cluster --fsid \$(sudo cephadm ls | jq -r '.[0].fsid') --force"

# Clean Docker
ssh -i /path/to/key ubuntu@192.168.10.11 "sudo docker system prune -af"
```

## Expanding Your Deployment

### Adding Compute Nodes

1. Edit `config.sh`:
   ```bash
   COMPUTE_IPS=("192.168.10.11" "192.168.10.12" "192.168.10.13" "192.168.10.14" "192.168.10.15")
   COMPUTE_NAMES=("hypervisor-1" "hypervisor-2" "hypervisor-3" "hypervisor-4.example" "hypervisor-5.example")
   ```

2. Re-run Ceph phases to add OSD nodes:
   ```bash
   cd /Users/sushantpatrikar/usvf/usvf/virtual-dc/scripts
   # Ceph will automatically add new nodes with 'osd' label
   ./ceph-cluster-setup.sh
   ```

3. Re-generate OpenStack configs and redeploy:
   ```bash
   cd /Users/sushantpatrikar/usvf/usvf/kolla-ansible
   ./openstack-deploy.sh configs
   ./openstack-deploy.sh deploy
   ```

### Increasing Ceph Replication

After adding more OSDs (e.g., going from 3 to 5 OSDs):

```bash
ssh -i /path/to/key ubuntu@192.168.10.11 "sudo ceph osd pool set images size 3"
ssh -i /path/to/key ubuntu@192.168.10.11 "sudo ceph osd pool set volumes size 3"
ssh -i /path/to/key ubuntu@192.168.10.11 "sudo ceph osd pool set vms size 3"
ssh -i /path/to/key ubuntu@192.168.10.11 "sudo ceph osd pool set backups size 3"
```

## Important Files and Paths

| File | Location | Purpose |
|------|----------|---------|
| config.sh | `/Users/sushantpatrikar/usvf/usvf/` | Central configuration |
| deploy-all.sh | `/Users/sushantpatrikar/usvf/usvf/kolla-ansible/` | Main deployment script |
| ceph-cluster-setup.sh | `/Users/sushantpatrikar/usvf/usvf/virtual-dc/scripts/` | Ceph deployment |
| openstack-deploy.sh | `/Users/sushantpatrikar/usvf/usvf/kolla-ansible/` | OpenStack deployment |
| multinode | `/etc/kolla/multinode` | Ansible inventory (generated) |
| globals.yml | `/etc/kolla/globals.yml` | Kolla config (generated) |
| admin-openrc.sh | `/etc/kolla/admin-openrc.sh` | OpenStack credentials |
| ceph.conf | `/etc/ceph/ceph.conf` | Ceph configuration |

## Support and Documentation

### Logs Location
- **Kolla-Ansible**: `/var/log/kolla/` on each node
- **Ceph**: `sudo cephadm shell -- ceph log last 100`
- **Docker**: `sudo docker logs <container-name>`

### Useful Commands
```bash
# List all OpenStack containers
sudo docker ps | grep kolla

# Check all Ceph daemons
ssh -i /path/to/key ubuntu@192.168.10.11 "sudo cephadm shell -- ceph orch ps"

# Check OpenStack services
source ~/kolla-venv/bin/activate && source /etc/kolla/admin-openrc.sh
openstack service list
openstack compute service list
openstack network agent list

# Check Ceph status
ssh -i /path/to/key ubuntu@192.168.10.11 "sudo ceph -s"
ssh -i /path/to/key ubuntu@192.168.10.11 "sudo ceph osd tree"
ssh -i /path/to/key ubuntu@192.168.10.11 "sudo ceph df"
```

### Official Documentation
- [Kolla-Ansible Documentation](https://docs.openstack.org/kolla-ansible/latest/)
- [Ceph Documentation](https://docs.ceph.com/)
- [OpenStack Documentation](https://docs.openstack.org/)

## Performance Tuning

### For Converged (3-node) Setup
- Ensure nodes have sufficient resources (32GB RAM recommended)
- Use separate disks for Ceph OSDs
- Monitor resource usage: `htop`, `iotop`

### For Separated Setup
- Control nodes: Can be smaller (16GB RAM)
- Compute nodes: Need more resources based on VM workload
- Ceph OSD nodes: Prioritize disk I/O and network bandwidth

## Security Considerations

- Change default passwords after deployment
- Configure firewall rules
- Use TLS/SSL for production deployments
- Regularly update OpenStack and Ceph versions
- Monitor security advisories

## Next Steps

After successful deployment:

1. **Create Networks**:
   ```bash
   openstack network create --external --provider-network-type flat \
     --provider-physical-network physnet1 external
   openstack subnet create --network external --subnet-range 192.168.10.0/24 \
     --gateway 192.168.10.1 --ip-version 4 external-subnet
   ```

2. **Create Flavors**:
   ```bash
   openstack flavor create --ram 2048 --disk 20 --vcpus 2 m1.small
   openstack flavor create --ram 4096 --disk 40 --vcpus 4 m1.medium
   ```

3. **Upload Images**:
   ```bash
   wget https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64.img
   openstack image create --disk-format qcow2 --file focal-server-cloudimg-amd64.img ubuntu-20.04
   ```

4. **Launch Test VM**:
   ```bash
   openstack server create --flavor m1.small --image ubuntu-20.04 \
     --network external test-vm
   ```

---

**Questions or Issues?**
- Check troubleshooting section above
- Review deployment logs
- Consult official OpenStack/Ceph documentation
