# Changelog

## 2026-02-05

### Fixes

#### 1. 409 Docker Container Conflict (Converged Setup)
**Problem:** When using same IPs for control and compute nodes (3-node converged setup), Ansible treated them as 6 separate hosts instead of 3, causing Docker container name conflicts (409 errors) during handler execution.

**Root Cause:** The `[compute]` section in multinode inventory created `compute01 ansible_host=192.168.10.11` even when `control01` already had that IP.

**Solution:** Modified `generate_multinode_inventory()` in `openstack-deploy.sh` to detect converged nodes and output host references instead of new definitions.

**Files Changed:**
- `usvf/kolla-ansible/openstack-deploy.sh` (lines 614-672)

**Before:**
```ini
[compute]
compute01 ansible_host=192.168.10.11 ...  # Duplicate!
```

**After:**
```ini
[compute]
control01  # Reference only
```

---

#### 2. Ceph Public Network Support (Production DC)
**Purpose:** Separate client↔Ceph traffic from management network for production datacenter deployments.

**Solution:** Added optional `CEPH_PUBLIC_NETWORK` configuration variable. When set, Ceph client traffic uses the specified network. When empty, single-network behavior is preserved (backward compatible).

**Files Changed:**
- `usvf/config.sh` - Added `CEPH_PUBLIC_NETWORK` variable
- `usvf/virtual-dc/scripts/ceph-cluster-setup.sh` - Added `configure_ceph_networks()` function

**Usage:**
```bash
# Single network (default - backward compatible)
CEPH_PUBLIC_NETWORK=""

# Separate Ceph public network
CEPH_PUBLIC_NETWORK="10.20.0.0/24"
```

**Verification:**
```bash
ceph config get global public_network
```

---

### Previous Fixes (Same Day)

1. **docker.io vs docker-ce conflict** - Kolla bootstrap installs docker-ce; ceph script tried docker.io+ceph-common together. Fixed by checking for docker-ce first.

2. **run_ceph_cmd double-ceph** - Callers passed `run_ceph_cmd ceph orch ...` but function prepended `ceph`. Fixed by stripping leading `ceph ` from args.

3. **Phase 9 pipe race condition** - `run_ceph_cmd ... | ssh tee` truncated file before ceph read it. Fixed by capturing to variable first.

4. **wait_for_apt typo** - Function named `wait_for_apt_lock` but called as `wait_for_apt`. Fixed naming.

5. **cinder_cluster_name** - Required when multiple nodes run cinder-volume. Added `cinder_cluster_name: "ceph"` to globals.yml.

6. **RGW startup** - cephadm RGW daemons may start in stopped/unknown state. Manual `ceph orch daemon redeploy` fixes it.

---

## Port Assignments

| Service | Port | Notes |
|---------|------|-------|
| RGW | 7480 | Changed from 8000 to avoid Heat CFN API conflict |
| RGW HAProxy | 6780 | Frontend for load balancing |
| Heat CFN API | 8000 | Default port |
