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
