# dev-scripts SCION Topology Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `ENABLE_SCION_AS=true` makes dev-scripts stand up a complete two-AS SCION topology on the hypervisor host (control services, border routers, remote SIG, discovery server, scion-registrar) so the virtualized cluster's nodes can join as SCION endhosts via scion-k8s-operator, per `docs/superpowers/specs/2026-07-24-dev-scripts-scion-topology-design.md` in github.com/mkowalski/scion-k8s-operator.

**Architecture:** FRR-ToR idiom (`bgp/configure_bgp_tor.sh` is the template): env toggle in `common.sh`, feature dir `scion/` invoked from `02_configure_host.sh`, one locally-built container image (`podman build` at configure time, nothing pre-pushed), config rendered into `$WORKING_DIR/scion/`, all services as `--net host` podman containers, firewalld libvirt-zone openings, idempotent cleanup in `host_cleanup.sh`.

**Tech Stack:** bash, podman, scionproto/scion v0.15.0 (binaries built in-image: control, router, daemon, gateway, scion-pki), scion-k8s-operator registrar (built in-image), python3 (discovery server).

**Repo/branch:** fork mkowalski/dev-scripts, branch `scion-topology`. Commit style: follow this repo's history (concise subject, body explaining why); sign-off `-s` + trailer `Assisted-By: Claude Fable 5`.

**Verified upstream facts (scion v0.15.0 — cited so the executor need not re-derive):**
- `scion-pki testcrypto -t <topo> -o <out> --as-validity 365d` is in the release binary (hidden command; `scion-pki/testcrypto/testcrypto.go:55-82`). Input: YAML with only an `ASes` map (`core/voting/authoritative/issuing` bools); `links` ignored (`testcrypto/config.go:27-35`).
- testcrypto output: `<out>/trcs/ISD1-B1-S1.trc`, `<out>/certs/` (flattened), `<out>/ASff00_0_1x0/{crypto/as,crypto/ca,crypto/voting,keys(empty),certs(empty)}`. Post-processing required (mirrors `tools/topology/cert.py:49-72`): copy the TRC into each AS's `certs/`, generate `keys/master{0,1}.key` (`head -c16 /dev/urandom | base64`), drop `topology.json` into the same dir.
- Control service config_dir expectations: `certs/*.trc`, `crypto/as/` (chain+key), optional `crypto/ca/`, `keys/` (`control/trust.go:36-50`, `control/cmd/control/main.go:206`). `general.id` must match a `control_service` key in topology.json.
- Router needs ONLY `topology.json` + a two-line toml (`router/config.go:35-40`); no crypto.
- Gateway (sig-b) requires a running scion-daemon (`sciond_connection.address`), a traffic policy JSON (`{"ConfigVersion":1,"ASes":{"<ia>":{"Nets":[...]}}}`), and an IP routing policy file to advertise prefixes.
- topology.json schema per `private/topology/json/json.go:73-124`: `attributes: ["core"]`, `control_service`/`discovery_service` `{"<id>":{"addr":"ip:port"}}`, `border_routers` with `internal_addr` + `interfaces` (`isd_as`, `link_to: "CORE"`, `mtu`, `underlay: {local, remote}`), `sigs` (`ctrl_addr`, `data_addr`), `dispatched_ports` (string range).

**Port plan (all on the baremetal bridge IP, default 192.168.111.1):**

| Service | AS A (cluster AS) | AS B (remote AS) |
|---|---|---|
| control+discovery service | 31000 | 32000 |
| BR internal_addr | 31002 | 32002 |
| BR inter-AS link (underlay) | 31020 | 32020 |
| scion-daemon (gRPC, loopback) | — | 127.0.0.1:32255 |
| SIG ctrl / data / probe | node agents: 30256/30056/30856 | 32256 / 32056 / 32856 |
| discovery HTTP | 8041 | — |
| registrar HTTP | 8642 | — |

**Files created by this plan:**

```
scion/Dockerfile
scion/serve-discovery.py                  # vendored from scion-k8s-operator
scion/topology/testcrypto.topo.tpl
scion/topology/as-a.topology.json.tpl
scion/topology/as-b.topology.json.tpl
scion/configure_scion_as.sh
scion/cleanup_scion_as.sh
```
Modified: `common.sh`, `config_example.sh`, `02_configure_host.sh`, `host_cleanup.sh`.

---

### Task 1: Config variables and hook points

**Files:**
- Modify: `common.sh` (next to the BGP_TOR block, ~line 722), `config_example.sh` (~line 242), `02_configure_host.sh` (~line 524), `host_cleanup.sh` (~line 91)
- Create: stub `scion/configure_scion_as.sh`, `scion/cleanup_scion_as.sh` (exit 0 placeholders replaced in later tasks, so the hooks never break)

- [ ] **Step 1: common.sh defaults** (append after the BGP_TOR block):

```bash
export ENABLE_SCION_AS=${ENABLE_SCION_AS:-}
export SCION_VERSION=${SCION_VERSION:-v0.15.0}
export SCION_OPERATOR_REF=${SCION_OPERATOR_REF:-main}
export SCION_ISD_AS_A=${SCION_ISD_AS_A:-1-ff00:0:110}
export SCION_ISD_AS_B=${SCION_ISD_AS_B:-1-ff00:0:111}
export SCION_REMOTE_PREFIX=${SCION_REMOTE_PREFIX:-192.168.100.0/24}
export SCION_CLUSTER_PREFIXES=${SCION_CLUSTER_PREFIXES:-}
export SCION_REGISTRAR_TOKEN=${SCION_REGISTRAR_TOKEN:-}
```

(`SCION_CLUSTER_PREFIXES` empty means "derive": external subnet + default OVN-K pod network, computed in Task 5. `SCION_REGISTRAR_TOKEN` empty means "generate".)

- [ ] **Step 2: config_example.sh docs** (append after the BGP_TOR section, same comment style):

```bash
# ENABLE_SCION_AS -
# Deploy a local two-AS SCION topology on the host (control services,
# border routers, a remote SCION-IP gateway, a bootstrap discovery
# server and the scion-k8s-operator registrar), so cluster nodes can
# join the SCION network as endhosts via scion-k8s-operator
# (https://github.com/mkowalski/scion-k8s-operator). The SCION
# infrastructure image is built locally with podman at configure time.
#export ENABLE_SCION_AS=true
#
# scionproto/scion tag to build; must match the version embedded in
# scion-k8s-operator.
#export SCION_VERSION=v0.15.0
#
# scion-k8s-operator git ref for the registrar binary.
#export SCION_OPERATOR_REF=main
#
# ISD-AS numbers for the cluster-side AS and the simulated remote AS.
#export SCION_ISD_AS_A=1-ff00:0:110
#export SCION_ISD_AS_B=1-ff00:0:111
#
# Prefix behind the remote SIG (ping target for SCION dataplane tests).
#export SCION_REMOTE_PREFIX=192.168.100.0/24
```

- [ ] **Step 3: hooks.** `02_configure_host.sh` after the BGP ToR hook:

```bash
if [[ -n "${ENABLE_SCION_AS:-}" ]]; then
    scion/configure_scion_as.sh
fi
```

`host_cleanup.sh` next to the bgp cleanup line:

```bash
scion/cleanup_scion_as.sh || true
```

- [ ] **Step 4: executable stubs** (`#!/usr/bin/env bash`, `set -euxo pipefail`, comment "populated by later plan tasks", exit 0). `chmod +x`.

- [ ] **Step 5: verify + commit.** `bash -n` on all four modified/created scripts; `shellcheck scion/*.sh` clean. Commit: `git commit -s -m "Add ENABLE_SCION_AS toggle and hook points ..."` with the trailer.

---

### Task 2: SCION infrastructure image

**Files:**
- Create: `scion/Dockerfile`, `scion/serve-discovery.py`

- [ ] **Step 1: vendor serve-discovery.py** from
`https://raw.githubusercontent.com/mkowalski/scion-k8s-operator/main/hack/dev-scion-topology/serve-discovery.py`
(keep the shebang; add a header comment: "Vendored from scion-k8s-operator hack/dev-scion-topology/serve-discovery.py — keep in sync manually.").

- [ ] **Step 2: Dockerfile**

```dockerfile
# SCION infrastructure image for the dev-scripts local SCION topology.
# Built locally at configure time; never pushed to a registry.
FROM docker.io/library/golang:1.26 AS scion-build
ARG SCION_VERSION=v0.15.0
RUN git clone --depth 1 -b ${SCION_VERSION} https://github.com/scionproto/scion /src
WORKDIR /src
RUN CGO_ENABLED=0 go build -o /out/scion-control ./control/cmd/control && \
    CGO_ENABLED=0 go build -o /out/scion-router ./router/cmd/router && \
    CGO_ENABLED=0 go build -o /out/scion-daemon ./daemon/cmd/daemon && \
    CGO_ENABLED=0 go build -o /out/scion-ip-gateway ./gateway/cmd/gateway && \
    CGO_ENABLED=0 go build -o /out/scion-pki ./scion-pki/cmd/scion-pki && \
    CGO_ENABLED=0 go build -o /out/scion ./scion/cmd/scion

FROM docker.io/library/golang:1.26 AS registrar-build
ARG SCION_OPERATOR_REF=main
RUN GOBIN=/out go install github.com/mkowalski/scion-k8s-operator/cmd/registrar@${SCION_OPERATOR_REF}

FROM registry.access.redhat.com/ubi9/ubi-minimal
RUN microdnf install -y python3 iproute && microdnf clean all
COPY --from=scion-build /out/ /usr/local/bin/
COPY --from=registrar-build /out/registrar /usr/local/bin/scion-registrar
COPY serve-discovery.py /usr/local/bin/serve-discovery.py
# No ENTRYPOINT: each container picks its binary via podman --entrypoint,
# keeping the scion binary as PID 1 so `podman kill -s HUP` reaches it.
```

Verify the cmd paths against the pinned tag before building (`https://github.com/scionproto/scion/tree/v0.15.0`): `control/cmd/control`, `router/cmd/router`, `daemon/cmd/daemon`, `gateway/cmd/gateway`, `scion-pki/cmd/scion-pki`, `scion/cmd/scion`. Adjust if any differ. `go install .../cmd/registrar@main` requires the operator module to be fetchable — it is public; if the module path errors, use a git clone + `go build ./cmd/registrar` stage instead (note which was needed).

- [ ] **Step 3: build test**

```bash
podman build -t localhost/scion-infra:v0.15.0 \
  --build-arg SCION_VERSION=v0.15.0 --build-arg SCION_OPERATOR_REF=main scion/
podman run --rm localhost/scion-infra:v0.15.0 scion-pki version
podman run --rm localhost/scion-infra:v0.15.0 scion-registrar --help
```

Expected: build succeeds; both commands print sensibly.

- [ ] **Step 4: commit** ("Add locally-built SCION infrastructure image").

---

### Task 3: Topology and crypto templates

**Files:**
- Create: `scion/topology/testcrypto.topo.tpl`, `scion/topology/as-a.topology.json.tpl`, `scion/topology/as-b.topology.json.tpl`

Templates use `${VAR}` placeholders rendered with `envsubst` (part of gettext, present on dev-scripts hosts; add `envsubst` to the deps check in Task 4). Substitution variables: `SCION_ISD_AS_A`, `SCION_ISD_AS_B`, `SCION_HOST_IP` (bridge IP, computed at configure time), plus the fixed port plan from the header.

- [ ] **Step 1: testcrypto.topo.tpl**

```yaml
ASes:
  "${SCION_ISD_AS_A}":
    core: true
    voting: true
    authoritative: true
    issuing: true
  "${SCION_ISD_AS_B}":
    core: true
    voting: true
    authoritative: true
    issuing: true
```

- [ ] **Step 2: as-a.topology.json.tpl** (cluster AS; `sigs` starts EMPTY — the registrar manages node entries; underscore form of the IA is needed in service IDs — computed at render time as `SCION_IA_A_US`, e.g. `1-ff00_0_110`):

```json
{
  "isd_as": "${SCION_ISD_AS_A}",
  "mtu": 1472,
  "dispatched_ports": "1024-65535",
  "attributes": ["core"],
  "control_service": {
    "cs${SCION_IA_A_US}-1": { "addr": "${SCION_HOST_IP}:31000" }
  },
  "discovery_service": {
    "cs${SCION_IA_A_US}-1": { "addr": "${SCION_HOST_IP}:31000" }
  },
  "border_routers": {
    "br${SCION_IA_A_US}-1": {
      "internal_addr": "${SCION_HOST_IP}:31002",
      "interfaces": {
        "1": {
          "underlay": {
            "local": "${SCION_HOST_IP}:31020",
            "remote": "${SCION_HOST_IP}:32020"
          },
          "isd_as": "${SCION_ISD_AS_B}",
          "link_to": "CORE",
          "mtu": 1472
        }
      }
    }
  },
  "sigs": {}
}
```

- [ ] **Step 3: as-b.topology.json.tpl** (remote AS; static `sig` entry):

```json
{
  "isd_as": "${SCION_ISD_AS_B}",
  "mtu": 1472,
  "dispatched_ports": "1024-65535",
  "attributes": ["core"],
  "control_service": {
    "cs${SCION_IA_B_US}-1": { "addr": "${SCION_HOST_IP}:32000" }
  },
  "discovery_service": {
    "cs${SCION_IA_B_US}-1": { "addr": "${SCION_HOST_IP}:32000" }
  },
  "border_routers": {
    "br${SCION_IA_B_US}-1": {
      "internal_addr": "${SCION_HOST_IP}:32002",
      "interfaces": {
        "1": {
          "underlay": {
            "local": "${SCION_HOST_IP}:32020",
            "remote": "${SCION_HOST_IP}:31020"
          },
          "isd_as": "${SCION_ISD_AS_A}",
          "link_to": "CORE",
          "mtu": 1472
        }
      }
    }
  },
  "sigs": {
    "sig${SCION_IA_B_US}-1": {
      "ctrl_addr": "${SCION_HOST_IP}:32256",
      "data_addr": "${SCION_HOST_IP}:32056",
      "probe_addr": "${SCION_HOST_IP}:32856"
    }
  }
}
```

- [ ] **Step 4: validate rendering locally** (no cluster needed): render both with `SCION_HOST_IP=192.168.111.1` etc. via `envsubst`, then `python3 -m json.tool` on both outputs. Expected: valid JSON. (Full schema validation happens when the containers load them in Task 5's smoke checks.)

- [ ] **Step 5: commit** ("Add SCION topology and testcrypto templates").

---

### Task 4: configure_scion_as.sh — rendering and crypto generation

**Files:**
- Modify: `scion/configure_scion_as.sh` (replace stub; this task builds the first half — vars, render, testcrypto, config-dir assembly)

- [ ] **Step 1: script skeleton and rendering** (FRR script conventions: `set -euxo pipefail`, source `../common.sh` + `../network.sh`):

```bash
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

mkdir -p "${SCION_DIR}"/{as-a,as-b,gen}

sudo podman build -t "${SCION_IMAGE}" \
    --build-arg "SCION_VERSION=${SCION_VERSION}" \
    --build-arg "SCION_OPERATOR_REF=${SCION_OPERATOR_REF}" \
    "${scion_dir}"

for tpl in testcrypto.topo as-a.topology.json as-b.topology.json; do
    envsubst < "${scion_dir}/topology/${tpl}.tpl" > "${SCION_DIR}/${tpl}"
done
mv "${SCION_DIR}/as-a.topology.json" "${SCION_DIR}/as-a/topology.json"
mv "${SCION_DIR}/as-b.topology.json" "${SCION_DIR}/as-b/topology.json"
```

NOTE on `envsubst`: call it with an explicit variable list
(`envsubst '${SCION_ISD_AS_A} ${SCION_ISD_AS_B} ${SCION_HOST_IP} ${SCION_IA_A_US} ${SCION_IA_B_US}'`)
so stray `$` in templates can never be eaten.

- [ ] **Step 2: crypto generation + config-dir assembly** (append):

```bash
# Mint TRC + AS certs/keys (scion-pki testcrypto), then assemble each AS's
# config_dir the way the control service expects (mirrors upstream
# tools/topology/cert.py): TRC into certs/, master keys, topology.json.
if [[ ! -f "${SCION_DIR}/gen/.done" ]]; then
    sudo podman run --rm --replace --name scion-testcrypto \
        -v "${SCION_DIR}:/work:z" "${SCION_IMAGE}" \
        scion-pki testcrypto -t /work/testcrypto.topo -o /work/gen --as-validity 365d
    sudo touch "${SCION_DIR}/gen/.done"
fi

as_dir_a="gen/AS${SCION_IA_A_US#*-}"   # e.g. gen/ASff00_0_110
as_dir_b="gen/AS${SCION_IA_B_US#*-}"
for as in a b; do
    src_var="as_dir_${as}"
    src="${SCION_DIR}/${!src_var}"
    dst="${SCION_DIR}/as-${as}"
    sudo cp -r "${src}/crypto" "${dst}/"
    sudo mkdir -p "${dst}/certs" "${dst}/keys"
    sudo cp "${SCION_DIR}"/gen/trcs/*.trc "${dst}/certs/"
    for k in master0.key master1.key; do
        [[ -f "${dst}/keys/${k}" ]] || head -c16 /dev/urandom | base64 | sudo tee "${dst}/keys/${k}" >/dev/null
    done
done
```

CAUTION for the executor: the `gen/AS...` directory name derives from the AS
number only (e.g. `ASff00_0_110` for `1-ff00:0:110`) — verify the exact name
testcrypto produced (`ls ${SCION_DIR}/gen`) and fix the `as_dir_*` derivation
if the `1-` prefix handling differs.

- [ ] **Step 3: verify on the dev host**: run the script fragment manually (or the whole script with later parts still stubbed): `${SCION_DIR}/as-a/` contains `topology.json`, `certs/ISD1-B1-S1.trc`, `crypto/as/`, `keys/master0.key`. `bash -n`, shellcheck clean.

- [ ] **Step 4: commit** ("scion: render topologies and generate trust material").

---

### Task 5: configure_scion_as.sh — service configs and containers

**Files:**
- Modify: `scion/configure_scion_as.sh` (second half)

- [ ] **Step 1: per-binary configs** (heredocs, FRR style; append to the script):

```bash
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
nets_json=$(printf '"%s",' ${CLUSTER_PREFIXES//,/ }); nets_json="[${nets_json%,}]"
cat > "${SCION_DIR}/as-b/sig-traffic.json" <<EOF
{ "ConfigVersion": 1, "ASes": { "${SCION_ISD_AS_A}": { "Nets": ${nets_json} } } }
EOF

# Routing policy: advertise the remote prefix to AS A, accept cluster
# prefixes from AS A (format: <action> <from-ia> <to-ia> <prefixes>).
{
    echo "advertise ${SCION_ISD_AS_B} ${SCION_ISD_AS_A} ${SCION_REMOTE_PREFIX}"
    echo "accept    ${SCION_ISD_AS_A} ${SCION_ISD_AS_B} ${CLUSTER_PREFIXES}"
} > "${SCION_DIR}/as-b/sig-routing.policy"
```

- [ ] **Step 2: registrar token, dummy interface, containers** (append):

```bash
# --- registrar token ---------------------------------------------------------
if [[ -z "${SCION_REGISTRAR_TOKEN}" ]]; then
    if [[ ! -f "${SCION_DIR}/token" ]]; then
        head -c16 /dev/urandom | base64 | tr -d '=+/' | sudo tee "${SCION_DIR}/token" >/dev/null
    fi
    SCION_REGISTRAR_TOKEN="$(sudo cat "${SCION_DIR}/token")"
else
    echo "${SCION_REGISTRAR_TOKEN}" | sudo tee "${SCION_DIR}/token" >/dev/null
fi

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
run_scion scion-cs-b scion-control "${SCION_DIR}/as-b" -- --config /etc/scion/cs.toml
run_scion scion-br-b scion-router  "${SCION_DIR}/as-b" -- --config /etc/scion/br.toml
run_scion scion-daemon-b scion-daemon "${SCION_DIR}/as-b" -- --config /etc/scion/daemon.toml
run_scion scion-sig-b scion-ip-gateway "${SCION_DIR}/as-b" \
    --privileged -v /dev/net/tun:/dev/net/tun -- --config /etc/scion/sig.toml

sudo podman run -d --replace --name scion-discovery --net host \
    -v "${SCION_DIR}/as-a:/data:z" --entrypoint python3 "${SCION_IMAGE}" \
    /usr/local/bin/serve-discovery.py /data /data/certs 8041

sudo podman run -d --replace --name scion-registrar --net host \
    -v "${SCION_DIR}/as-a:/data:z" \
    -v /run/podman/podman.sock:/run/podman/podman.sock \
    -e "REGISTRAR_TOKEN=${SCION_REGISTRAR_TOKEN}" \
    --entrypoint scion-registrar "${SCION_IMAGE}" \
    --topology /data/topology.json --listen :8642 \
    --reload-cmd "curl -fsS --unix-socket /run/podman/podman.sock -X POST http://d/containers/scion-cs-a/kill?signal=SIGHUP"
```

TWO EXECUTOR DECISIONS embedded above — verify and adjust:
1. **serve-discovery.py argument layout**: the vendored script takes
   `GEN TRCS [PORT]` where GEN contains `topology.json` and TRCS contains
   `ISD*-B*-S*.trc` files. We pass `/data` (as-a dir) and `/data/certs`.
   Confirm against the vendored script's argv handling.
2. **Registrar reload from inside a container**: the registrar container
   cannot run `podman kill` directly. The plan uses the podman REST API over
   the host socket (`podman.socket` must be enabled:
   `sudo systemctl enable --now podman.socket`; add that line before the
   run). The registrar's `--reload-cmd` is exec'd with space-splitting —
   verify curl is present in ubi-minimal (it is: curl-minimal) and that the
   registrar's naive space-split tolerates this command (no quotes needed
   here). SIMPLER FALLBACK if this fights: run the registrar binary
   directly on the host (extract from image:
   `sudo podman cp $(sudo podman create ${SCION_IMAGE}):/usr/local/bin/scion-registrar /usr/local/bin/`)
   as a systemd transient unit (`systemd-run`) with
   `--reload-cmd "podman kill -s HUP scion-cs-a"`. Pick whichever works
   first, document the choice in the script comment.

- [ ] **Step 3: firewalld + smoke checks + handoff** (append):

```bash
# --- firewall -----------------------------------------------------------------
SCION_UDP_PORTS=(31000 31002 31020 32000 32002 32020 32056 32256 32856)
for p in "${SCION_UDP_PORTS[@]}"; do
    sudo firewall-cmd --zone=libvirt --permanent --add-port="${p}/udp"
    sudo firewall-cmd --zone=libvirt --add-port="${p}/udp"
done
for p in 31000 32000 8041 8642; do
    sudo firewall-cmd --zone=libvirt --permanent --add-port="${p}/tcp"
    sudo firewall-cmd --zone=libvirt --add-port="${p}/tcp"
done

# --- smoke checks --------------------------------------------------------------
sleep 5
curl -fsS "http://${SCION_HOST_IP}:8041/topology" | grep -q "${SCION_ISD_AS_A}"
curl -fsS -o /dev/null -w '%{http_code}' "http://${SCION_HOST_IP}:8642/v1/sigs" | grep -q 401
curl -fsS -H "Authorization: Bearer ${SCION_REGISTRAR_TOKEN}" "http://${SCION_HOST_IP}:8642/v1/sigs" >/dev/null
for c in scion-cs-a scion-br-a scion-cs-b scion-br-b scion-daemon-b scion-sig-b scion-discovery scion-registrar; do
    sudo podman inspect -f '{{.State.Running}}' "$c" | grep -q true
done
ip link show sigb >/dev/null   # sig-b tun exists in host netns

cat <<EOF
SCION topology ready:
  DISCOVERY_URL=http://${SCION_HOST_IP}:8041
  REGISTRAR_URL=http://${SCION_HOST_IP}:8642
  REGISTRAR_TOKEN=${SCION_REGISTRAR_TOKEN}
  REMOTE_ISD_AS=${SCION_ISD_AS_B}
  REMOTE_PING_IP=${REMOTE_PING_IP}
EOF
```

Note the SCION control-service/BR ports (31000/32000) speak QUIC/gRPC over
UDP *and* TCP variants depending on component — the port list above opens
both where ambiguous; trim after observing real traffic (`ss -ulpn`).

- [ ] **Step 4: full run on the dev host**: `ENABLE_SCION_AS=true scion/configure_scion_as.sh` twice (idempotency). All smoke checks pass. Then the two-AS control-plane check: `sudo podman run --rm --net host -v ${WORKING_DIR}/scion/as-b:/etc/scion:z --entrypoint scion localhost/scion-infra:v0.15.0 ping --sciond 127.0.0.1:32255 ${SCION_ISD_AS_A},${SCION_HOST_IP}` — expect SCMP echo replies (proves beaconing + BR forwarding between the ASes). Iterate until green; this step is where topology/config mistakes surface.

- [ ] **Step 5: commit** ("scion: run the two-AS topology, discovery and registrar").

---

### Task 6: cleanup_scion_as.sh

**Files:**
- Modify: `scion/cleanup_scion_as.sh` (replace stub)

- [ ] **Step 1: implement** (mirrors `bgp/cleanup_bgp_tor.sh`, tolerant of absence):

```bash
#!/usr/bin/env bash
set -euxo pipefail

scion_dir="$(dirname "$(readlink -f "$0")")"
# shellcheck disable=SC1091
source "${scion_dir}/../common.sh"

for c in scion-cs-a scion-br-a scion-cs-b scion-br-b scion-daemon-b \
         scion-sig-b scion-discovery scion-registrar; do
    sudo podman rm -f "$c" || true
    sudo podman volume rm -f "${c}-state" || true
done

for p in 31000 31002 31020 32000 32002 32020 32056 32256 32856; do
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
```

- [ ] **Step 2: verify**: configure → cleanup → configure again on the dev host; second configure fully green (no leftover interfaces/ports/volumes). `bash -n` + shellcheck.

- [ ] **Step 3: commit** ("scion: idempotent teardown").

---

### Task 7: End-to-end handoff validation and PR prep

**Files:**
- Modify: none new (fixes as discovered)

- [ ] **Step 1: consumer flow.** With a dev-scripts cluster up and the topology configured: deploy scion-k8s-operator into the cluster (`oc apply -k config/manifests` from that repo, images pushed to the dev-scripts local registry), apply a ScionNetwork using the handoff values, then run that repo's `test/e2e/e2e_test.sh` with `DISCOVERY_URL/REGISTRAR_URL/REGISTRAR_TOKEN/REMOTE_ISD_AS/REMOTE_PING_IP` from the handoff block. This is the first live execution of the operator's dataplane; expect iteration — fix root causes in whichever repo owns them (topology/plumbing here; agent/operator bugs get fixed and committed in scion-k8s-operator).
- [ ] **Step 2: record results.** Update scion-k8s-operator `docs/known-gaps.md` (retire the live-run items that now pass; add anything newly discovered). Commit there separately.
- [ ] **Step 3: PR prep in the fork.** `git log --oneline` review; squash fixups if messy; push `scion-topology` to `origin` (mkowalski/dev-scripts). Do NOT open an upstream PR without explicit approval.

---

## Self-review notes

- **Spec coverage**: toggle/config vars (T1), locally-built image incl.
  registrar + discovery (T2), templated topologies + testcrypto (T3-4),
  seven+ containers/firewall/smoke/handoff (T5), dummy-interface ping target
  (T5), idempotent cleanup (T6), consumer-flow validation (T7). Spec's
  "seven containers" is actually **eight** (scion-daemon-b was discovered
  during research: the stock gateway requires a sciond) — spec deviation to
  note in the spec when implementing.
- **Executor verification points** (marked in tasks): scionproto cmd paths at
  the tag (T2), `go install` of the registrar module (T2), testcrypto output
  dir naming (T4), serve-discovery argv layout (T5), registrar reload
  mechanism — podman socket vs host systemd-run fallback (T5), sig.toml key
  names for ctrl/data/probe addrs (T5 — verify against
  `gateway/config/config.go:100-110`; the gateway may derive some addrs from
  topology.json `sigs` instead of its toml — if so, drop them from sig.toml),
  UDP/TCP port trim (T5).
- **Biggest risk concentration**: Task 5 Step 4 (live two-AS bring-up) —
  deliberately structured as an iterate-until-green step with the `scion
  ping` control-plane probe before any cluster involvement.
