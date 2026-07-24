#!/usr/bin/env bash
set -euxo pipefail

scion_dir="$(dirname "$(readlink -f "$0")")"
# shellcheck disable=SC1091
source "${scion_dir}/../common.sh"
# shellcheck disable=SC1091
source "${scion_dir}/../network.sh"

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

# --- (continued in later plan tasks) ---
