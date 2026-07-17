# Matchbox PXE Provisioning — pi-dns

Network-boot provisioning for the Talos homelab cluster. One box (`pi-dns`,
192.168.0.18) serves everything a node needs to rebuild itself from bare
metal: PXE boot chain, Talos kernel/initramfs, per-node machine configs, and
bootstrap Kubernetes manifests. The router keeps normal DHCP; dnsmasq only
answers the PXE portion (proxyDHCP).

## Architecture

```
OptiPlex firmware (F12, UEFI PXE IPv4)
  │  DHCP: IP from router (192.168.0.1) + boot info from dnsmasq (proxyDHCP)
  ▼
ipxe.efi                    ← TFTP from pi-dns (apt-packaged iPXE binary)
  │  re-DHCPs, tagged "ipxe" via option 175
  ▼
boot.ipxe                   ← TFTP; chains to Matchbox
  ▼
http://192.168.0.18:8080/boot.ipxe → /ipxe?mac=<node MAC>
  │  Matchbox matches a group by MAC, renders the profile's iPXE script
  ▼
kernel + initramfs          ← HTTP from /assets (local, no internet needed)
  │  cmdline carries talos.config=…/assets/configs/${mac:hexhyp}.yaml
  │  (${mac:hexhyp} expanded by iPXE on the node, NOT by Matchbox)
  ▼
Talos machined fetches its own config → installs to NVMe → reboots from disk
```

Three actors, three syntaxes — the debugging map:

| Seen on a node | Meaning |
|---|---|
| literal `{{.foo}}` in cmdline | Go template in profile args — Matchbox never renders those; use iPXE vars |
| literal `${mac:hexhyp}` in cmdline | iPXE never executed the script (bad .efi binary / Secure Boot) |
| concrete URL, node unconfigured | config fetch failed — check matchbox log for the GET |

## Node inventory

| Node | IP | MAC (group selector) | Config file (hexhyp) |
|---|---|---|---|
| cp-13 | 192.168.0.13 | 8c:04:ba:9f:38:28 | 8c-04-ba-9f-38-28.yaml |
| cp-15 | 192.168.0.15 | a4:bb:6d:49:06:45 | a4-bb-6d-49-06-45.yaml |
| cp-16 | 192.168.0.16 | 8c:04:ba:9d:f8:f7 | 8c-04-ba-9d-f8-f7.yaml |

Selector form: lowercase + colons. Filename form: lowercase + hyphens
(`tr 'A-Z:' 'a-z-'`).

## Directory layout

```
/var/lib/matchbox/
├── assets/                        # ONLY path-served static tree (/assets/*)
│   ├── kernel-amd64               # Factory kernel (~20 MB)
│   ├── initramfs-amd64.xz         # NB: no "metal" in the asset name
│   ├── configs/
│   │   ├── cp-1{3,5,6}.yaml       # human-named SOURCE OF TRUTH
│   │   └── <mac-hexhyp>.yaml      # copies nodes actually fetch (sync!)
│   └── manifests/
│       ├── gateway-api-crds.yaml  # order matters: CRDs before Cilium
│       └── cilium-install.yaml
├── profiles/talos-cp.json
└── groups/cp-{13,15,16}.json
/var/lib/tftpboot/
├── ipxe.efi  snponly.efi          # from the apt "ipxe" package — file(1) verify!
└── boot.ipxe                      # chains to matchbox; fetched fresh each boot
```

## Hard-won rules (each one cost a debugging session)

1. **`file` every downloaded binary/asset.** boot.ipxe.org once served HTML
   as `ipxe.efi`; firmware silently refuses to exec it — identical symptom to
   Secure Boot. Kernel/initramfs from Factory: verify too.
2. **No HTTPS in the iPXE chain.** iPXE's TLS trust store can't validate
   Factory's ZeroSSL cert (`Operation not permitted`, ipxe.org/410de18f).
   The Pi downloads over HTTPS once; nodes get plain HTTP.
3. **Asset name:** `initramfs-amd64.xz`, not `initramfs-metal-amd64.xz`
   (despite the PXE URL path saying metal-amd64). Wrong name = 400/404.
4. **Static files live under /assets only.** `generic/` is for Matchbox's
   templated endpoints, not path serving — files there 404 by URL.
5. **Profile args are not Go-templated.** `{{.node_id}}` passes through
   literally. Per-node selection = `${mac:hexhyp}` + MAC-named files.
6. **Every served config must use the Factory installer image**
   (`factory.talos.dev/installer/<schematic>:<ver>`) with `wipe: true`.
   Plain ghcr installer strips iscsi-tools → Longhorn breaks.
7. **Configs must descend from the cluster's original secrets bundle.**
   A fresh `gen config` = new secrets = rebuilt nodes can't rejoin.
8. **Copy drift:** nodes fetch MAC-named files. After editing cp-XX.yaml run
   `sync-configs` (in the setup script) or nodes boot stale config.
9. **BIOS per node:** UEFI, Secure Boot OFF, IPv6 PXE disabled, NVMe first
   in boot order (F12 = deliberate rebuild; blank disk auto-falls to PXE).
10. **First Factory request for a schematic+version builds on demand** — can
    hang minutes; cached afterward. `--max-time` + retry, don't panic.

## Operations

**Reprovision one node:** snapshot etcd → remove ghost member if ungraceful →
edit cp-XX.yaml → `sync-configs` → F12 → watch `journalctl -u matchbox -f`.

**Full cluster rebuild:** fix served configs FIRST (extraManifests fire only
at bootstrap) → `talosctl reset --graceful=false --reboot` all three → nodes
PXE-rebuild → `talosctl bootstrap` on ONE node, once → `kubeconfig -f` →
approve kubelet-serving CSRs (until the auto-approver is in the bootstrap
path) → re-apply rebuild-lost state (see below).

**Version bump baseline:** after `talosctl upgrade` of the fleet, re-download
kernel/initramfs at the new version into /assets and bump the install.image
tag in every config (both names). PXE rebuild must always match the fleet.

**Rebuild-lost-state checklist** (cluster state that is NOT in configs/repo
and evaporates on rebuild — move each into the bootstrap path or Flux):
- kubelet-serving CSR approvals → deploy kubelet-serving-cert-approver
- namespace PSA labels (longhorn-system needs
  `pod-security.kubernetes.io/enforce=privileged`; csi-driver-nfs likely too)
- node labels used by any chart's nodeSelector

## Verification

`setup-matchbox.sh verify` runs the full pre-flight curl suite (banner,
assets, per-MAC rendered scripts, per-MAC configs, install-block grep,
manifests). Run it before every first boot after a change.
