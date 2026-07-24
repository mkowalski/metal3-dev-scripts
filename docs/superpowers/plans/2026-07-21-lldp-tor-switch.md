# LLDP ToR Switch Emulation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Optional (`ENABLE_LLDP_TOR`) emulation of a top-of-rack LLDP switch on the dev-scripts hypervisor so cluster nodes receive LLDP neighbors on their NICs.

**Architecture:** Run `lldpd` (EPEL) as a host systemd service bound to the libvirt `vnet*` tap devices (per-VM bridge ports). Tap xmit delivers frames straight into the VM NIC, so no bridge `group_fwd_mask` change is needed. Config/cleanup scripts mirror the `bgp/` ENABLE_BGP_TOR precedent.

**Tech Stack:** bash, lldpd, systemd, dnf/EPEL.

Spec: `docs/superpowers/specs/2026-07-21-lldp-tor-switch-design.md`
Branch: `lldp-tor-switch` (based on `upstream/master`).
All work in `/home/kmateusz/git/github.com/dev-scripts`.

---

### Task 1: configure and cleanup scripts

**Files:**
- Create: `lldp/configure_lldp_tor.sh` (mode 0755)
- Create: `lldp/cleanup_lldp_tor.sh` (mode 0755)

- [ ] **Step 1: Write `lldp/configure_lldp_tor.sh`**

```bash
#!/usr/bin/env bash
set -euxo pipefail

lldp_dir="$(dirname "$(readlink -f "$0")")"
# shellcheck disable=SC1091
source "${lldp_dir}/../common.sh"

# Emulate a production top-of-rack LLDP switch for the cluster VMs.
#
# The libvirt bridges do not forward the link-local scoped LLDP group
# address (01:80:C2:00:00:0E) between ports, and NetworkManager >= 1.59.1
# filters LLDP frames sourced by the local interface, so cluster nodes
# never see any LLDP neighbor. Run lldpd on the hypervisor bound to the
# libvirt tap devices (vnet*): a frame transmitted on a tap is delivered
# straight to the VM NIC (no bridge forwarding involved), so each node
# receives LLDPDUs inbound exactly like from a real switch port.
#
# lldpd tracks interface add/remove via netlink, so taps created when the
# VMs boot later (or recreated on node reboot) are picked up automatically.

sudo dnf -y install lldpd

# tx-interval 5: fast neighbor appearance for tests.
# interface pattern vnet*: only libvirt taps, never physical host NICs.
sudo tee /etc/lldpd.d/lldp-tor.conf <<EOF
configure lldp tx-interval 5
configure system hostname ${LLDP_TOR_SYSTEM_NAME}
configure system interface pattern vnet*
EOF

sudo systemctl enable --now lldpd
# Re-apply the configuration if lldpd was already running
sudo systemctl restart lldpd

echo "LLDP ToR switch emulation running: system name ${LLDP_TOR_SYSTEM_NAME}, interfaces vnet*"
```

- [ ] **Step 2: Write `lldp/cleanup_lldp_tor.sh`**

```bash
#!/usr/bin/env bash
set -euxo pipefail

# Tears down the optional LLDP ToR switch emulation deployed by
# configure_lldp_tor.sh. Tolerant of a missing service / config so it can
# run unconditionally from host_cleanup.sh. The lldpd package stays
# installed.

sudo systemctl disable --now lldpd || true

sudo rm -f /etc/lldpd.d/lldp-tor.conf
```

- [ ] **Step 3: Make executable and syntax-check**

Run: `chmod +x lldp/configure_lldp_tor.sh lldp/cleanup_lldp_tor.sh && bash -n lldp/configure_lldp_tor.sh && bash -n lldp/cleanup_lldp_tor.sh && shellcheck lldp/*.sh`
Expected: no output, exit 0 (shellcheck may be skipped if not installed — state so).

### Task 2: wire into host configure/cleanup and configuration

**Files:**
- Modify: `common.sh` (end of file, after `export ENABLE_CAPI_E2E=...`)
- Modify: `02_configure_host.sh` (end of file, after the `PERSISTENT_IMAGEREG` block)
- Modify: `host_cleanup.sh` (end of file, after the nfsshare removal)
- Modify: `config_example.sh` (end of file)

- [ ] **Step 1: Append to `common.sh`**

```bash

# Optional LLDP top-of-rack switch emulation on the libvirt tap devices
# (see config_example.sh)
export ENABLE_LLDP_TOR=${ENABLE_LLDP_TOR:-}
export LLDP_TOR_SYSTEM_NAME=${LLDP_TOR_SYSTEM_NAME:-lldp-switch}
```

- [ ] **Step 2: Append to `02_configure_host.sh`**

```bash

# Optionally emulate a top-of-rack LLDP switch towards the cluster VMs
if [[ -n "${ENABLE_LLDP_TOR:-}" ]]; then
    lldp/configure_lldp_tor.sh
fi
```

- [ ] **Step 3: Append to `host_cleanup.sh`**

```bash

# Remove the optional LLDP ToR switch emulation
lldp/cleanup_lldp_tor.sh
```

- [ ] **Step 4: Append to `config_example.sh`**

```bash

# ENABLE_LLDP_TOR -
# Emulate a top-of-rack LLDP switch on the hypervisor: run lldpd bound to
# the libvirt tap devices (vnet*) so cluster nodes receive LLDPDUs inbound
# on their NICs, exactly like from a real switch port. Consumed e.g. by the
# kubernetes-nmstate LLDP e2e tests, which expect a neighbor with system
# name "lldp-switch" on the primary NIC.
# Default is unset.
#
#export ENABLE_LLDP_TOR=true
#
# Advertised LLDP system name (default lldp-switch):
#export LLDP_TOR_SYSTEM_NAME=lldp-switch
```

- [ ] **Step 5: Syntax-check modified scripts**

Run: `bash -n common.sh 02_configure_host.sh host_cleanup.sh config_example.sh`
Expected: no output, exit 0.

### Task 3: commit

- [ ] **Step 1: Review and commit**

Run: `git status --porcelain` — expect only the 6 files above (the spec/plan docs stay uncommitted).

```bash
git add lldp/ common.sh 02_configure_host.sh host_cleanup.sh config_example.sh
git commit -s -m 'Add optional top-of-rack LLDP switch emulation

ENABLE_LLDP_TOR runs lldpd on the hypervisor bound to the libvirt tap
devices (vnet*). Frames transmitted on a tap are delivered straight into
the VM NIC, so cluster nodes receive LLDPDUs inbound exactly like from a
production top-of-rack switch, without any bridge group_fwd_mask change.

Needed because the libvirt bridges do not forward the link-local scoped
LLDP group address between ports and NetworkManager >= 1.59.1 filters
locally-sourced LLDP frames, so nodes otherwise never see any LLDP
neighbor. Primary consumer is the kubernetes-nmstate LLDP e2e test, which
expects an "lldp-switch" neighbor on the primary NIC
(nmstate/kubernetes-nmstate#1549). The advertised system name is
configurable; teardown is wired into host_cleanup.

Assisted-By: Claude Fable 5' 
```

## Verification notes

Functional verification requires a dev-scripts hypervisor (not available in
this session) — state as unverified. On a live host:
- `lldpcli show statistics ports` shows tx on `vnet*`
- on a node: NM LLDP neighbor `lldp-switch` on the baremetal NIC
