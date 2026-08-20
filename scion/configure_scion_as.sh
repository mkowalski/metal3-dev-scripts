#!/usr/bin/env bash
set -euxo pipefail

scion_dir="$(dirname "$(readlink -f "$0")")"
# shellcheck disable=SC1091
source "${scion_dir}/../common.sh"
# shellcheck disable=SC1091
source "${scion_dir}/../network.sh"

[[ -n "${EXTERNAL_SUBNET_V4:-}" ]] || \
    { echo "ENABLE_SCION_AS requires an IPv4 external subnet (IP_STACK=v4 or v4v6)" >&2; exit 1; }

# Deploys a local two-AS SCION topology on the host: control services,
# border routers, a remote SCION-IP gateway, a bootstrap discovery server
# and the scion-k8s-operator registrar. Cluster nodes join AS A as SCION
# endhosts via scion-k8s-operator; AS B simulates a remote SCION site.

SCION_DIR="${WORKING_DIR}/scion"
SCION_IMAGE="localhost/scion-infra:${SCION_VERSION}"
SCION_HOST_IP="$(nth_ip "${EXTERNAL_SUBNET_V4}" 1)"
# Underscore forms for service IDs, e.g. 1-ff00:0:110 -> 1-ff00_0_110
SCION_IA_A_US="${SCION_ISD_AS_A//:/_}"
SCION_IA_B_US="${SCION_ISD_AS_B//:/_}"
export SCION_HOST_IP SCION_IA_A_US SCION_IA_B_US

command -v envsubst >/dev/null || sudo dnf install -y gettext

sudo mkdir -p "${SCION_DIR}"/{as-a,as-b,gen}
sudo chown -R "${USER}:${GROUP}" "${SCION_DIR}"

sudo podman build -t "${SCION_IMAGE}" \
    --build-arg "SCION_VERSION=${SCION_VERSION}" \
    --build-arg "SCION_OPERATOR_REF=${SCION_OPERATOR_REF}" \
    "${scion_dir}"

# Explicit variable list so stray $ in templates can never be substituted.
# shellcheck disable=SC2016
scion_subst_vars='${SCION_ISD_AS_A} ${SCION_ISD_AS_B} ${SCION_HOST_IP} ${SCION_IA_A_US} ${SCION_IA_B_US}'
for tpl in testcrypto.topo as-a.topology.json as-b.topology.json; do
    envsubst "${scion_subst_vars}" \
        < "${scion_dir}/topology/${tpl}.tpl" > "${SCION_DIR}/${tpl}"
done
mv "${SCION_DIR}/as-a.topology.json" "${SCION_DIR}/as-a/topology.json"
mv "${SCION_DIR}/as-b.topology.json" "${SCION_DIR}/as-b/topology.json"

# Mint TRC + AS certs/keys (scion-pki testcrypto), then assemble each AS's
# config_dir the way the control service expects (mirrors upstream
# tools/topology/cert.py): TRC into certs/, master keys, topology.json.
if [[ ! -f "${SCION_DIR}/gen/.done" ]]; then
    sudo podman run --rm --replace --name scion-testcrypto \
        -v "${SCION_DIR}:/work:z" "${SCION_IMAGE}" \
        scion-pki testcrypto -t /work/testcrypto.topo -o /work/gen --as-validity 365d
    sudo touch "${SCION_DIR}/gen/.done"
fi

# shellcheck disable=SC2034  # referenced indirectly via ${!src_var}
as_dir_a="gen/AS${SCION_IA_A_US#*-}"   # e.g. gen/ASff00_0_110
# shellcheck disable=SC2034
as_dir_b="gen/AS${SCION_IA_B_US#*-}"
for as in a b; do
    src_var="as_dir_${as}"
    src="${SCION_DIR}/${!src_var}"
    dst="${SCION_DIR}/as-${as}"
    sudo rm -rf "${dst}/crypto"
    sudo cp -r "${src}/crypto" "${dst}/"
    sudo mkdir -p "${dst}/certs" "${dst}/keys"
    sudo cp "${SCION_DIR}"/gen/trcs/*.trc "${dst}/certs/"
    # The control service and border router both require master{0,1}.key
    # to be present in the config_dir.
    for k in master0.key master1.key; do
        [[ -f "${dst}/keys/${k}" ]] || head -c16 /dev/urandom | base64 | sudo tee "${dst}/keys/${k}" >/dev/null
    done
done

# --- service configurations -------------------------------------------------
for as in a b; do
    cat > "${SCION_DIR}/as-${as}/cs.toml" <<EOF
[general]
id = "cs$(var="SCION_IA_${as^^}_US"; echo "${!var}")-1"
config_dir = "/etc/scion"

[trust_db]
connection = "/var/lib/scion/cs.trust.db"
[beacon_db]
connection = "/var/lib/scion/cs.beacon.db"
[path_db]
connection = "/var/lib/scion/cs.path.db"
EOF
    cat > "${SCION_DIR}/as-${as}/br.toml" <<EOF
[general]
id = "br$(var="SCION_IA_${as^^}_US"; echo "${!var}")-1"
config_dir = "/etc/scion"
EOF
done

# AS A also runs a shim dispatcher: it answers SCMP echo/traceroute for the
# host address (the router only forwards them to the endhost port 30041),
# which the control-plane smoke probe and dataplane tests rely on.
cat > "${SCION_DIR}/as-a/dispatcher.toml" <<EOF
[dispatcher]
id = "dispatcher${SCION_IA_A_US}"
underlay_addr = "${SCION_HOST_IP}"
local_udp_forwarding = true
EOF

# AS B extras: scion-daemon + SCION-IP gateway (the "remote site").
cat > "${SCION_DIR}/as-b/daemon.toml" <<EOF
[general]
id = "sd${SCION_IA_B_US}"
config_dir = "/etc/scion"

[sd]
address = "127.0.0.1:32255"

[path_db]
connection = "/var/lib/scion/sd.path.db"
[trust_db]
connection = "/var/lib/scion/sd.trust.db"
EOF

# ctrl/data/probe_addr key names verified against scion v0.15.1
# gateway/config/config.go (Gateway struct toml tags).
cat > "${SCION_DIR}/as-b/sig.toml" <<EOF
[gateway]
id = "sig${SCION_IA_B_US}-1"
traffic_policy_file = "/etc/scion/sig-traffic.json"
ip_routing_policy_file = "/etc/scion/sig-routing.policy"
ctrl_addr = "${SCION_HOST_IP}:32256"
data_addr = "${SCION_HOST_IP}:32056"
probe_addr = "${SCION_HOST_IP}:32856"

[sciond_connection]
address = "127.0.0.1:32255"

[tunnel]
name = "sigb"
EOF

# Traffic policy: prefixes AS B may send toward AS A (the cluster).
# Default: external subnet + OVN-K default cluster network.
CLUSTER_PREFIXES="${SCION_CLUSTER_PREFIXES:-${EXTERNAL_SUBNET_V4},10.128.0.0/14}"
# shellcheck disable=SC2086  # intentional word splitting of the prefix list
nets_json=$(printf '"%s",' ${CLUSTER_PREFIXES//,/ }); nets_json="[${nets_json%,}]"
cat > "${SCION_DIR}/as-b/sig-traffic.json" <<EOF
{ "ConfigVersion": 1, "ASes": { "${SCION_ISD_AS_A}": { "Nets": ${nets_json} } } }
EOF

# Routing policy: advertise the remote prefix to AS A, accept cluster
# prefixes from AS A. Format per gateway/routing/doc.go:
# <action> <from-ia> <to-ia> <prefixes>.
{
    echo "advertise ${SCION_ISD_AS_B} ${SCION_ISD_AS_A} ${SCION_REMOTE_PREFIX}"
    echo "accept    ${SCION_ISD_AS_A} ${SCION_ISD_AS_B} ${CLUSTER_PREFIXES}"
} > "${SCION_DIR}/as-b/sig-routing.policy"

# --- registrar token ---------------------------------------------------------
if [[ -z "${SCION_REGISTRAR_TOKEN}" ]]; then
    if [[ ! -f "${SCION_DIR}/token" ]]; then
        head -c16 /dev/urandom | base64 | tr -d '=+/' | sudo tee "${SCION_DIR}/token" >/dev/null
    fi
    SCION_REGISTRAR_TOKEN="$(sudo cat "${SCION_DIR}/token")"
else
    echo "${SCION_REGISTRAR_TOKEN}" | sudo tee "${SCION_DIR}/token" >/dev/null
fi
sudo chmod 600 "${SCION_DIR}/token"

# --- remote ping target ------------------------------------------------------
# Dummy interface on the host carrying an address from SCION_REMOTE_PREFIX;
# sig-b routes the prefix through its tun.
REMOTE_PING_IP="$(nth_ip "${SCION_REMOTE_PREFIX}" 1)"
sudo ip link add scion-remote type dummy 2>/dev/null || true
sudo ip addr replace "${REMOTE_PING_IP}/${SCION_REMOTE_PREFIX#*/}" dev scion-remote
sudo ip link set scion-remote up

# --- containers ---------------------------------------------------------------
run_scion() { # name entrypoint config-dir extra-args... -- binary-args...
    local name="$1" entry="$2" conf="$3"; shift 3
    local extra=(); while [[ "$1" != "--" ]]; do extra+=("$1"); shift; done; shift
    sudo podman run -d --replace --name "${name}" --net host \
        -v "${conf}:/etc/scion:z" -v "${name}-state:/var/lib/scion" \
        "${extra[@]}" --entrypoint "${entry}" "${SCION_IMAGE}" "$@"
}

run_scion scion-cs-a scion-control "${SCION_DIR}/as-a" -- --config /etc/scion/cs.toml
run_scion scion-br-a scion-router  "${SCION_DIR}/as-a" -- --config /etc/scion/br.toml
run_scion scion-dispatcher-a scion-dispatcher "${SCION_DIR}/as-a" -- --config /etc/scion/dispatcher.toml
run_scion scion-cs-b scion-control "${SCION_DIR}/as-b" -- --config /etc/scion/cs.toml
run_scion scion-br-b scion-router  "${SCION_DIR}/as-b" -- --config /etc/scion/br.toml
run_scion scion-daemon-b scion-daemon "${SCION_DIR}/as-b" -- --config /etc/scion/daemon.toml
run_scion scion-sig-b scion-ip-gateway "${SCION_DIR}/as-b" \
    --privileged -v /dev/net/tun:/dev/net/tun -- --config /etc/scion/sig.toml

# serve-discovery.py argv is GEN TRCS [PORT]; GEN must contain topology.json
# and TRCS the ISD*-B*-S*.trc files — as-a/ and as-a/certs/ match that layout.
# It has no bind-address argument (binds all interfaces); firewalld restricts
# reachability to the libvirt zone.
sudo podman run -d --replace --name scion-discovery --net host \
    -v "${SCION_DIR}/as-a:/data:z" --entrypoint python3 "${SCION_IMAGE}" \
    /usr/local/bin/serve-discovery.py /data /data/certs 8041

# The registrar rewrites as-a's topology.json (adds node SIG entries) and then
# runs -reload-cmd; its systemctl default cannot work in a container, so we
# HUP the control service through the podman REST API over the host socket.
# Mounting the podman socket grants the registrar root-equivalent control of
# the host; acceptable for dev-scripts only.
sudo systemctl enable --now podman.socket
sudo podman run -d --replace --name scion-registrar --net host \
    -v "${SCION_DIR}/as-a:/data:z" \
    -v /run/podman/podman.sock:/run/podman/podman.sock \
    -e "REGISTRAR_TOKEN=${SCION_REGISTRAR_TOKEN}" \
    --entrypoint scion-registrar "${SCION_IMAGE}" \
    -topology /data/topology.json -listen "${SCION_HOST_IP}:8642" \
    -reload-cmd "curl -fsS --unix-socket /run/podman/podman.sock -X POST http://d/containers/scion-cs-a/kill?signal=SIGHUP"

# --- firewall -----------------------------------------------------------------
# Permanent adds are strict (a failure means broken firewalld config); the
# runtime adds get || true because re-adding an active port is a warning-level
# failure on some firewalld versions and the rule is already in effect.
SCION_UDP_PORTS=(30041 31000 31002 31020 32000 32002 32020 32056 32256 32856)
for p in "${SCION_UDP_PORTS[@]}"; do
    sudo firewall-cmd --zone=libvirt --permanent --add-port="${p}/udp"
    sudo firewall-cmd --zone=libvirt --add-port="${p}/udp" || true
done
for p in 31000 32000 8041 8642; do
    sudo firewall-cmd --zone=libvirt --permanent --add-port="${p}/tcp"
    sudo firewall-cmd --zone=libvirt --add-port="${p}/tcp" || true
done

# --- smoke checks --------------------------------------------------------------
# Bounded wait for the discovery server to come up (also covers the other
# containers, which start earlier).
for _ in $(seq 12); do
    curl -fsS "http://${SCION_HOST_IP}:8041/topology" | grep -q "${SCION_ISD_AS_A}" && break
    sleep 5
done
curl -fsS "http://${SCION_HOST_IP}:8041/topology" | grep -q "${SCION_ISD_AS_A}"
# no -f: a 401 status is the expected outcome here
curl -sS -o /dev/null -w '%{http_code}' "http://${SCION_HOST_IP}:8642/v1/sigs" | grep -q 401
curl -fsS -H "Authorization: Bearer ${SCION_REGISTRAR_TOKEN}" "http://${SCION_HOST_IP}:8642/v1/sigs" >/dev/null
for c in scion-cs-a scion-br-a scion-dispatcher-a scion-cs-b scion-br-b scion-daemon-b scion-sig-b scion-discovery scion-registrar; do
    sudo podman inspect -f '{{.State.Running}}' "$c" | grep -q true
done
# NOTE: the sigb tun is NOT checked here on purpose: the gateway creates it
# lazily, on the first routing chain toward a remote gateway, i.e. only once
# a cluster node has registered a SIG in AS A via the registrar.

cat <<EOF
SCION topology ready:
  DISCOVERY_URL=http://${SCION_HOST_IP}:8041
  REGISTRAR_URL=http://${SCION_HOST_IP}:8642
  REGISTRAR_TOKEN=${SCION_REGISTRAR_TOKEN}
  REMOTE_ISD_AS=${SCION_ISD_AS_B}
  REMOTE_PING_IP=${REMOTE_PING_IP}
EOF
