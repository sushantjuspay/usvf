# ⚠️ IMPORTANT: Read Before Running Deployment

## How the Configuration Works

### 1. **config.sh** (YOU MUST EDIT THIS!)
This is the **SINGLE SOURCE OF TRUTH** for all deployment parameters.

**Location**: `/Users/sushantpatrikar/usvf/usvf/config.sh`

**You MUST change these values:**
```bash
# Set your actual node IPs (for 3-node converged setup)
CONTROL_IPS=("192.168.10.11" "192.168.10.12" "192.168.10.13")
COMPUTE_IPS=("192.168.10.11" "192.168.10.12" "192.168.10.13")  # Same for converged

# SET YOUR SSH KEY PATH!
SSH_KEY="/path/to/your/ssh-key"  # ⚠️ CHANGE THIS!
```

### 2. **multinode** (Template File - DO NOT EDIT!)
**Location**: `/Users/sushantpatrikar/usvf/usvf/kolla-ansible/multinode`

This file contains **EXAMPLE/TEMPLATE** values with hardcoded IPs.

**These hardcoded IPs will be IGNORED!**

When you run `./openstack-deploy.sh configs` (or `./deploy-all.sh`), the script will:
1. Read the multinode template
2. **REPLACE** the [control], [compute], [storage] sections with values from `config.sh`
3. Write the new file to `/etc/kolla/multinode`

### 3. **Generated Files** (Auto-created during deployment)
These files are **AUTO-GENERATED** from config.sh:

- `/etc/kolla/multinode` - Generated from template + config.sh
- `/etc/kolla/globals.yml` - Generated from template + config.sh

## What Gets Used When

| File | Used By | Values From |
|------|---------|-------------|
| `config.sh` | All scripts | **YOU EDIT THIS** |
| `multinode` (repo) | openstack-deploy.sh | Template only |
| `/etc/kolla/multinode` | Kolla-Ansible | Auto-generated from config.sh |
| `/etc/kolla/globals.yml` | Kolla-Ansible | Auto-generated from config.sh |

## Example: 3-Node Converged Setup

### What YOU configure in config.sh:
```bash
CONTROL_IPS=("192.168.10.11" "192.168.10.12" "192.168.10.13")
COMPUTE_IPS=("192.168.10.11" "192.168.10.12" "192.168.10.13")  # Same nodes
SSH_KEY="/home/user/.ssh/id_rsa"
```

### What gets GENERATED in /etc/kolla/multinode:
```ini
[control]
control01 ansible_host=192.168.10.11 ansible_user=ubuntu ansible_ssh_private_key_file=/home/user/.ssh/id_rsa api_ip=10.1.0.1 tunnel_ip=10.1.0.1
control02 ansible_host=192.168.10.12 ansible_user=ubuntu ansible_ssh_private_key_file=/home/user/.ssh/id_rsa api_ip=10.1.0.2 tunnel_ip=10.1.0.2
control03 ansible_host=192.168.10.13 ansible_user=ubuntu ansible_ssh_private_key_file=/home/user/.ssh/id_rsa api_ip=10.1.0.3 tunnel_ip=10.1.0.3

[compute]
compute01 ansible_host=192.168.10.11 ansible_user=ubuntu ansible_ssh_private_key_file=/home/user/.ssh/id_rsa api_ip=10.1.0.1 tunnel_ip=10.1.0.1
compute02 ansible_host=192.168.10.12 ansible_user=ubuntu ansible_ssh_private_key_file=/home/user/.ssh/id_rsa api_ip=10.1.0.2 tunnel_ip=10.1.0.2
compute03 ansible_host=192.168.10.13 ansible_user=ubuntu ansible_ssh_private_key_file=/home/user/.ssh/id_rsa api_ip=10.1.0.3 tunnel_ip=10.1.0.3
```

Notice:
- IPs come from `CONTROL_IPS` and `COMPUTE_IPS` in config.sh
- SSH key path comes from `SSH_KEY` in config.sh
- api_ip values come from `API_TUNNEL_IPS` in config.sh

## Example: 5-Node Separated Setup (Future)

### What YOU configure in config.sh:
```bash
CONTROL_IPS=("192.168.10.11" "192.168.10.12" "192.168.10.13")
COMPUTE_IPS=("192.168.10.14" "192.168.10.15")  # Different nodes!
SSH_KEY="/home/user/.ssh/id_rsa"
```

### What gets GENERATED in /etc/kolla/multinode:
```ini
[control]
control01 ansible_host=192.168.10.11 ... api_ip=10.1.0.1 ...
control02 ansible_host=192.168.10.12 ... api_ip=10.1.0.2 ...
control03 ansible_host=192.168.10.13 ... api_ip=10.1.0.3 ...

[compute]
compute01 ansible_host=192.168.10.14 ... api_ip=10.1.0.4 ...
compute02 ansible_host=192.168.10.15 ... api_ip=10.1.0.5 ...
```

## Pre-Deployment Checklist

### 1. Edit config.sh ✅
```bash
cd /Users/sushantpatrikar/usvf/usvf
nano config.sh

# Change:
# - CONTROL_IPS (your actual node IPs)
# - COMPUTE_IPS (same as control for 3-node setup)
# - SSH_KEY (your actual SSH private key path)
# - SSH_USER (if not 'ubuntu')
```

### 2. Verify SSH Keys ✅
```bash
# Test SSH to each node
ssh -i /path/to/your/key ubuntu@192.168.10.11 hostname
ssh -i /path/to/your/key ubuntu@192.168.10.12 hostname
ssh -i /path/to/your/key ubuntu@192.168.10.13 hostname

# If fails, add your public key:
ssh-copy-id -i /path/to/your/key.pub ubuntu@192.168.10.11
ssh-copy-id -i /path/to/your/key.pub ubuntu@192.168.10.12
ssh-copy-id -i /path/to/your/key.pub ubuntu@192.168.10.13
```

### 3. Verify Nodes are Ready ✅
```bash
# All nodes should be:
# - Running Ubuntu 22.04 LTS
# - Reachable from deployment host
# - Have 16GB+ RAM, 8+ CPU cores
# - Have internet connectivity
```

### 4. Run Deployment ✅
```bash
cd /Users/sushantpatrikar/usvf/usvf
./kolla-ansible/deploy-all.sh

# The script will:
# 1. Validate your config.sh
# 2. Test SSH connectivity
# 3. Deploy Ceph (using config.sh values)
# 4. Deploy OpenStack (using auto-generated multinode from config.sh)
# 5. Configure everything
```

## Common Questions

### Q: Why are there hardcoded IPs in the multinode file?
**A**: Those are just **EXAMPLES** in the template. They will be **REPLACED** with values from config.sh when you run the deployment.

### Q: Do I need to edit the multinode file?
**A**: **NO!** Only edit config.sh. The multinode file is auto-generated.

### Q: What if I want to change IPs later?
**A**: Edit config.sh and re-run `./openstack-deploy.sh configs` to regenerate the multinode file.

### Q: How do I know what values are actually being used?
**A**: After running deployment, check `/etc/kolla/multinode` to see the generated file with actual values.

### Q: Can I manually edit /etc/kolla/multinode?
**A**: You CAN, but it's not recommended. Any manual changes will be overwritten next time you run `./openstack-deploy.sh configs`. Always edit config.sh instead.

## Debugging: Check What Will Be Generated

To see what multinode file will be generated (without deploying):

```bash
cd /Users/sushantpatrikar/usvf/usvf

# Edit config.sh first
nano config.sh

# Run just the config generation
./kolla-ansible/openstack-deploy.sh configs

# Check the generated file
cat /etc/kolla/multinode

# Check it has your IPs and SSH key path
grep "ansible_host" /etc/kolla/multinode
grep "ansible_ssh_private_key_file" /etc/kolla/multinode
```

## Summary

✅ **Edit**: `config.sh` (set your IPs and SSH key)
❌ **Don't Edit**: `multinode` template file (just examples)
✅ **Generated**: `/etc/kolla/multinode` (from config.sh)
✅ **Check**: `/etc/kolla/multinode` after running deployment

---

**Ready to deploy?**
```bash
# 1. Edit config.sh
nano /Users/sushantpatrikar/usvf/usvf/config.sh

# 2. Run deployment
cd /Users/sushantpatrikar/usvf/usvf
./kolla-ansible/deploy-all.sh
```
