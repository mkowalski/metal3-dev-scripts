# Optional LLDP top-of-rack switch emulation for dev-scripts

Date: 2026-07-21
Status: approved

## Problem

Cluster nodes deployed by dev-scripts never see any LLDP neighbor: the
libvirt Linux bridges do not forward the link-local scoped LLDP group
address (`01:80:C2:00:00:0E`) between ports, and NetworkManager >= 1.59.1
filters LLDP frames sourced by the local interface (NM commit
`9a79eba502`), so nodes cannot even hear themselves anymore.

This breaks LLDP consumers on OpenShift lanes running on dev-scripts. The
primary consumer is the kubernetes-nmstate LLDP e2e test
(`LLDP configuration with nmpolicy`), which since
nmstate/kubernetes-nmstate#1549 requires every node to report an inbound
LLDP neighbor with system name `lldp-switch` on the primary NIC. Upstream
solves this for kubevirtci with `cluster/lldpd-switch.sh`; dev-scripts has
no equivalent.

## Solution

Emulate a production top-of-rack switch on the hypervisor: run `lldpd`
(from EPEL, already enabled by `01_install_requirements.sh`) as a host
systemd service, bound to the libvirt tap devices (`vnet*`) that are the
per-VM bridge ports.

Delivery does not involve bridge forwarding: a frame transmitted on a tap
device is delivered straight to the fd owner (qemu) and injected into the
VM NIC, so nodes receive LLDPDUs inbound exactly like from a real switch
port. No `group_fwd_mask` change is needed.

lldpd tracks interface add/remove via netlink, so taps created later (VMs
boot in `06_create_cluster.sh`) or recreated on node reboot are picked up
automatically. Hooking at `02_configure_host.sh` (before VMs exist) is
therefore safe.

## Components

Mirrors the `ENABLE_BGP_TOR` precedent (`bgp/`):

- `lldp/configure_lldp_tor.sh`
  - `sudo dnf -y install lldpd`
  - write `/etc/lldpd.d/lldp-tor.conf`:
    - `configure lldp tx-interval 5` (fast neighbor appearance for tests)
    - `configure system hostname ${LLDP_TOR_SYSTEM_NAME}`
    - `configure system interface pattern vnet*` (only libvirt taps, never
      physical host NICs)
  - `systemctl enable --now lldpd`, restart if already running so the
    config is applied
- `lldp/cleanup_lldp_tor.sh`
  - `systemctl disable --now lldpd || true`, remove the drop-in config;
    tolerant of absence so it can run unconditionally from
    `host_cleanup.sh`. The package stays installed.
- `02_configure_host.sh`: run `lldp/configure_lldp_tor.sh` at the end when
  `ENABLE_LLDP_TOR` is set
- `host_cleanup.sh`: run `lldp/cleanup_lldp_tor.sh` unconditionally
- `common.sh`:
  - `export ENABLE_LLDP_TOR=${ENABLE_LLDP_TOR:-}`
  - `export LLDP_TOR_SYSTEM_NAME=${LLDP_TOR_SYSTEM_NAME:-lldp-switch}`
- `config_example.sh`: documented, commented-out example

## Error handling

`set -euxo pipefail` like the bgp scripts. Configure fails loudly (dnf or
systemctl errors abort host setup, but only when the feature is opted in).
Cleanup is best-effort.

## Trade-offs

Host-package approach (chosen over a podman container): simpler runtime,
but the config lives in host-global `/etc/lldpd.d/` rather than
`$WORKING_DIR`, the daemon is a host service, and cleanup does not
uninstall the package.

Wildcard `vnet*` pattern transmits on all libvirt taps (baremetal and
provisioning networks). Harmless: all are virtual, and consumers only
check the NICs they care about.

## Verification

- shellcheck on the new scripts
- Functional verification requires a dev-scripts host:
  - hypervisor: `lldpcli show statistics ports` shows tx on `vnet*`
  - node: NM reports an `lldp-switch` neighbor on the baremetal NIC
