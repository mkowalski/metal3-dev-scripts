#!/usr/bin/env bash
set -euxo pipefail

scion_dir="$(dirname "$(readlink -f "$0")")"
# shellcheck disable=SC1091
source "${scion_dir}/../common.sh"

# Containers created by configure_scion_as.sh. The seven run_scion()
# containers also get a named "<name>-state" volume; scion-discovery and
# scion-registrar do not.
SCION_STATE_CONTAINERS=(scion-cs-a scion-br-a scion-dispatcher-a scion-cs-b
                        scion-br-b scion-daemon-b scion-sig-b)
for c in "${SCION_STATE_CONTAINERS[@]}" scion-discovery scion-registrar; do
    sudo podman rm -f "$c" || true
done
for c in "${SCION_STATE_CONTAINERS[@]}"; do
    sudo podman volume rm -f "${c}-state" || true
done

# podman.socket was enabled by configure_scion_as.sh for the registrar's
# reload command, but other tooling may rely on it too — leave it enabled.

# Port lists mirror configure_scion_as.sh.
for p in 30041 31000 31002 31020 32000 32002 32020 32056 32256 32856; do
    sudo firewall-cmd --zone=libvirt --permanent --remove-port="${p}/udp" || true
    sudo firewall-cmd --zone=libvirt --remove-port="${p}/udp" || true
done
for p in 31000 32000 8041 8642; do
    sudo firewall-cmd --zone=libvirt --permanent --remove-port="${p}/tcp" || true
    sudo firewall-cmd --zone=libvirt --remove-port="${p}/tcp" || true
done

sudo ip link del scion-remote 2>/dev/null || true
sudo ip link del sigb 2>/dev/null || true   # sig tun should die with the
                                            # container; belt and braces
sudo rm -rf "${WORKING_DIR}/scion"
