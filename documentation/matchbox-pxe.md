For each node it needs to update the mac, but only one node needs to have the extra manifets


* You also need to run `talosctl -n $CONTROL_PLANE_1 bootstrap`, which will bootstrap the first node. The endpoint needs to be it's ip address for it 
to automatically work correctly
* To forcefully restart the cluster, `talosctl -n $CONTROL_PLANE_1,$CONTROL_PLANE_2,$CONTROL_PLANE_3 reset --graceful=false --reboot`
* Due to a control plane setting `k get csr -o name | xargs kubectl certificate approve` needs to be ran
* Also since I'm running all control planes `k get node -o name | xargs -I {} kubectl taint node {} node-role.kubernetes.io/control-plane:NoSchedule-`


# Runbook — Option 2: Matchbox as the Provisioning File Server (As-Built)

**Goal:** Matchbox on the Pi serves *everything a node needs to provision
itself*: PXE boot assets, per-node Talos machine configs, and bootstrap
Kubernetes manifests. F12 → PXE → node boots, fetches its own config by MAC,
installs, joins the cluster. No `apply-config` step. Reboot-to-reprovision.

> **Design note (learned the hard way):** Matchbox's Go-template engine
> (`{{.metadata}}`) applies ONLY to Ignition/Butane/generic *config templates*
> — it does **not** render profile boot `args`. A `{{.node_id}}` placed in
> kernel args passes through literally onto the kernel cmdline and Talos tries
> to fetch a URL containing mustaches. Per-node config selection is instead
> done with **iPXE variables** (`${mac:hexhyp}`), expanded client-side by iPXE
> at boot. Also: Matchbox serves static files ONLY under `/assets` — files
> under `generic/` are NOT path-addressable (404) and everything we host lives
> in the assets tree.

**Environment (as-built):**

| Item | Value |
|---|---|
| Matchbox host | `pi-dns` — `192.168.0.18:8080` |
| Talos | `v1.13.5` |
| Schematic (full) | `613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245` |
| dnsmasq proxyDHCP | unchanged from Option 1 |

**Node inventory (MACs confirmed via `ip neigh`):**

| Node | IP | MAC (selector form) | Config filename (hexhyp form) |
|---|---|---|---|
| cp-13 | 192.168.0.13 | `8c:04:ba:9f:38:28` | `8c-04-ba-9f-38-28.yaml` |
| cp-15 | 192.168.0.15 | `a4:bb:6d:49:06:45` | `a4-bb-6d-49-06-45.yaml` |
| cp-16 | 192.168.0.16 | `8c:04:ba:9d:f8:f7` | `8c-04-ba-9d-f8-f7.yaml` |

Selector form = lowercase + colons (group JSON). Filename form = lowercase +
hyphens (what `${mac:hexhyp}` expands to). Convert:
`echo "8C:04:BA:9F:38:28" | tr 'A-Z:' 'a-z-'`

---

## 1. Directory layout (as-built)

```
/var/lib/matchbox/
├── assets/                        # THE static file tree (served at /assets/*)
│   ├── kernel-amd64               # Talos kernel (Factory, ~20 MB)
│   ├── initramfs-amd64.xz         # note: NO "metal" in the name
│   ├── configs/                   # per-node machine configs, MAC-named
│   │   ├── cp-13.yaml             # human-named originals (source of truth)
│   │   ├── 8c-04-ba-9f-38-28.yaml # MAC-named copies (what nodes fetch)
│   │   └── ...
│   └── manifests/                 # bootstrap K8s manifests (extraManifests)
│       ├── gateway-api-crds.yaml
│       └── cilium-install.yaml
├── profiles/talos-cp.json         # WHAT to boot (shared by all CP nodes)
└── groups/cp-{13,15,16}.json      # WHO gets the profile, matched by MAC
```

## 2. Install Matchbox (unchanged)

Binary from https://github.com/poseidon/matchbox/releases (arm64 on the Pi),
`matchbox` user, systemd unit with `-address=0.0.0.0:8080
-data-path=/var/lib/matchbox -assets-path=/var/lib/matchbox/assets`.
Verify with `matchbox -version` and `curl -s http://localhost:8080` (banner).
Retire any python http.server from Option 1.

## 3. Stage files

```bash
# Assets (from Option 1, already file-verified)
sudo mv /var/lib/tftpboot/assets/{kernel-amd64,initramfs-amd64.xz} /var/lib/matchbox/assets/

# Per-node configs: keep cp-XX.yaml as source of truth, cp to MAC names
cd /var/lib/matchbox/assets/configs
sudo cp cp-13.yaml 8c-04-ba-9f-38-28.yaml
sudo cp cp-15.yaml a4-bb-6d-49-06-45.yaml
sudo cp cp-16.yaml 8c-04-ba-9d-f8-f7.yaml

# Manifests
# gateway-api-crds.yaml, cilium-install.yaml into assets/manifests/

sudo chown -R matchbox:matchbox /var/lib/matchbox
```

**Copy-drift warning:** nodes fetch the MAC-named files. After editing any
`cp-XX.yaml`, re-run its `cp` line (or script it) — otherwise PXE serves stale
config.

Config requirements (every file, both names):

```yaml
machine:
  install:
    disk: /dev/nvme0n1
    wipe: true
    image: factory.talos.dev/installer/613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245:v1.13.5
cluster:
  extraManifests:                       # order matters: CRDs before Cilium
    - http://192.168.0.18:8080/assets/manifests/gateway-api-crds.yaml
    - http://192.168.0.18:8080/assets/manifests/cilium-install.yaml
```

- Plain `ghcr.io/siderolabs/installer` strips extensions (broke Longhorn once).
- Configs must descend from the cluster's original secrets bundle — never a
  fresh `gen config`.
- Served over plain HTTP: contains cluster secrets, acceptable on trusted LAN
  only.

## 4. Profile (the working version)

```json
{
  "id": "talos-cp",
  "name": "Talos control plane v1.13.5",
  "boot": {
    "kernel": "/assets/kernel-amd64",
    "initrd": ["/assets/initramfs-amd64.xz"],
    "args": [
      "initrd=initramfs-amd64.xz",
      "init_on_alloc=1",
      "slab_nomerge",
      "pti=on",
      "console=tty0",
      "printk.devkmsg=on",
      "talos.platform=metal",
      "talos.config=http://192.168.0.18:8080/assets/configs/${mac:hexhyp}.yaml"
    ]
  }
}
```

`${mac:hexhyp}` is iPXE syntax — it appears LITERALLY in Matchbox's rendered
output (correct!) and is expanded to the node's own hyphenated MAC by iPXE on
the machine. Do NOT use `{{.node_id}}` here — wrong templating engine, wrong
actor.

## 5. Groups (one per node, MAC selector)

```json
{
  "id": "cp-15",
  "name": "OptiPlex 192.168.0.15",
  "profile": "talos-cp",
  "selector": { "mac": "a4:bb:6d:49:06:45" }
}
```

(No metadata needed — config selection happens via `${mac:hexhyp}`, not group
metadata.) `sudo systemctl restart matchbox` after any profile/group edit.

## 6. Chain-load from dnsmasq

`/var/lib/tftpboot/boot.ipxe` (fetched fresh each boot, no restarts):

```
#!ipxe
dhcp
chain http://192.168.0.18:8080/boot.ipxe
```

## 7. Pre-flight curl suite (run before every first boot of a change)

```bash
curl -s http://192.168.0.18:8080                                    # banner
curl -sI http://192.168.0.18:8080/assets/kernel-amd64 | head -1     # 200
curl -sI http://192.168.0.18:8080/assets/initramfs-amd64.xz | head -1
curl -s  http://192.168.0.18:8080/boot.ipxe                         # chain script

for m in 8c:04:ba:9f:38:28 a4:bb:6d:49:06:45 8c:04:ba:9d:f8:f7; do
  echo "=== $m ==="; curl -s "http://192.168.0.18:8080/ipxe?mac=${m}"
done   # rendered script per node; ${mac:hexhyp} literal = CORRECT; 404 = selector mismatch

for f in 8c-04-ba-9f-38-28 a4-bb-6d-49-06-45 8c-04-ba-9d-f8-f7; do
  echo -n "$f: "; curl -so /dev/null -w "%{http_code}\n" \
    "http://192.168.0.18:8080/assets/configs/${f}.yaml"
done   # three 200s

curl -s http://192.168.0.18:8080/assets/configs/a4-bb-6d-49-06-45.yaml \
  | grep -A4 'install:'   # right node, right install block, Factory image
```

## 8. Boot / reprovision loop

1. `talosctl -n <healthy-cp> etcd snapshot ./etcd-$(date +%F).snap`
2. Ghost member? `talosctl -n <healthy-cp> etcd members` → `remove-member`.
3. One node at a time; F12 → UEFI PXE IPv4.
4. Watch `journalctl -u matchbox -f`: GET /boot.ipxe → /ipxe?mac= → kernel →
   initramfs → /assets/configs/<mac>.yaml. Node console: boots → auto-applies
   → Installing → reboots from NVMe.
5. Verify: `get extensions` (iscsi-tools present), `etcd members` = 3,
   `kubectl get nodes` Ready.

## How the chain actually works (three actors)

1. **Matchbox** (server, request time): matches group by MAC, assembles the
   iPXE script from the profile verbatim. No arg templating.
2. **iPXE** (node, script execution): expands `${mac:hexhyp}` etc., downloads
   kernel/initramfs over HTTP, boots the kernel with the now-concrete cmdline.
3. **Talos machined** (initramfs, early boot): reads `/proc/cmdline`, sees
   `talos.platform=metal` + `talos.config=<URL>`, fetches the URL, applies it
   as its machine config — same code path as `apply-config` from there on.

Debug map: literal `{{...}}` on a node = wrong templating engine in profile;
literal `${...}` on a node = iPXE never executed the script; concrete URL but
unconfigured node = the fetch failed (matchbox log shows no GET).

## Upgrades and the PXE baseline

`talosctl upgrade` (rolling, `--preserve` semantics, Factory image) remains
the way to upgrade RUNNING nodes — PXE reprovision is a wipe-and-rebuild, not
an in-place upgrade. But the PXE baseline must be kept in lockstep so rebuilds
match the cluster:

```bash
# For each new Talos version V:
S=613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245
sudo curl -fLo /var/lib/matchbox/assets/kernel-amd64 \
  "https://factory.talos.dev/image/${S}/${V}/kernel-amd64"
sudo curl -fLo /var/lib/matchbox/assets/initramfs-amd64.xz \
  "https://factory.talos.dev/image/${S}/${V}/initramfs-amd64.xz"
file /var/lib/matchbox/assets/kernel-amd64        # verify, always
# update install.image tag in every config (cp-XX + MAC copies)
# update the version string in the profile name for sanity
```

A node PXE-rebuilt after this comes up at the new baseline directly.

## Troubleshooting quick table

| Symptom | Cause | Fix |
|---|---|---|
| Node cmdline shows literal `{{.node_id}}` | Go template in profile args (not rendered there) | Use `${mac:hexhyp}`; templates only work in Ignition/generic config templates |
| 404 on `/generic/configs/...` | Matchbox doesn't path-serve generic/ | Host static files under `/assets/...` |
| 404 on `/ipxe?mac=...` | Group selector mismatch | Lowercase, colon-separated MAC in group JSON; restart matchbox |
| Node fetches sibling's config | Wrong cp-XX copied to a MAC name | `grep hostname` each MAC-named file against the inventory table |
| Stale config served after edit | Edited cp-XX.yaml but not the MAC copy | Re-run the cp; consider a sync script |
| Node comes back missing extensions | ghcr installer in the served config | Factory `install.image`, verify `get extensions` |
| Bootstrap stalls on extraManifests | URL still points at dead /generic/ path, or Matchbox down | curl every extraManifests URL; they live under /assets/manifests/ |
| Ghost etcd member blocks rejoin | Ungraceful wipe | `etcd members` → `remove-member` |
| Reprovision on every reboot | NIC above NVMe | NVMe first; F12 = deliberate |

## Air-gap graduation

- [x] Boot assets, configs, manifests all local under one tree
- [ ] `install.image` → zot-mirrored installer
- [ ] Cluster images → registry mirrors → zot
- [ ] Zarf-package: matchbox + dnsmasq + iPXE binaries + /var/lib/matchbox
- [ ] Replace Factory/GitHub pulls with controlled sync
- [ ] Grep everything for factory.talos.dev / ghcr.io / github.com
