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
