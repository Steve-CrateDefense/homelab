# Runbook — Option 1: PXE Boot Talos via dnsmasq proxyDHCP + Local HTTP Assets

**Goal:** Network-boot the three OptiPlex nodes into Talos maintenance mode with
zero changes to the router's DHCP. The router keeps assigning IPs; dnsmasq (on
the Pi) supplies only the PXE boot info, and the Pi serves the Talos kernel and
initramfs over plain HTTP.

> **Revision note (as-built):** The original plan chained iPXE directly to the
> Image Factory over HTTPS. That fails in practice — iPXE's limited TLS trust
> store cannot validate Factory's ZeroSSL certificate
> (`Could not boot image: Operation not permitted — ipxe.org/410de18f`).
> The working design: **the Pi downloads boot assets from Factory over HTTPS
> once (Pi's curl validates fine), then serves them to nodes over plain HTTP.**
> This is also the correct shape for Matchbox (Option 2) and the air-gapped
> build, so nothing here is throwaway.

**Environment (as-built values):**

| Item | Value |
|---|---|
| Subnet | `192.168.0.0/24` |
| Router (DHCP) | `192.168.0.1` (untouched) |
| proxyDHCP + asset host | `pi-dns` — `192.168.0.18` (wired, always-on) |
| Talos version | `v1.13.5` |
| Factory schematic (full) | `613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245` |
| Nodes | OptiPlex Micro ×3 — `192.168.0.13`, `.15`, `.16` |
| Asset HTTP port | `8000` |

---

## 1. Prep the OptiPlex BIOS (each node, one-time)

1. F2 into BIOS setup.
2. **Boot mode: UEFI**, **Secure Boot: Disabled** (iPXE binaries and Factory
   images with extensions are unsigned — Secure Boot rejects them *silently*:
   the file downloads over TFTP and simply never executes).
3. **Disable the IPv6 network stack / IPv6 PXE.** Dell lists PXE IPv4 and IPv6
   as separate boot entries; with IPv6 enabled the node may try IPv6 first,
   time out, and waste minutes per boot. Nothing in this setup speaks IPv6.
   (System Configuration → Integrated NIC → *Enabled w/ PXE*, IPv4 only.)
4. Optional but recommended: disable **SupportAssist / Pre-boot System
   Performance Check** so failed boots retry instead of detouring into a
   five-minute hardware diagnostic.
5. Boot sequence: **NVMe first, NIC second.** Trigger PXE on demand with the
   one-time boot menu (**F12** → the entry explicitly labeled *IPv4*). This
   prevents accidental reprovisioning on routine reboots; PXE becomes the
   automatic fallback only when the disk is blank (e.g., after `talosctl reset`).

## 2. Install dnsmasq on the Pi

```bash
sudo apt update && sudo apt install -y dnsmasq
```

> **Pi-hole conflict warning:** Pi-hole embeds its own dnsmasq (`pihole-FTL`).
> Do not run a second dnsmasq bound to port 53. The config below sets `port=0`
> (DNS disabled) so they coexist — dnsmasq here does only TFTP + proxyDHCP.
> A failed start with `exit-code` is usually this collision:
> check `sudo ss -ulnp | grep -E ':67|:69|:53'`.

## 3. Stage iPXE binaries — use the apt package, verify everything

**Lesson learned:** fetching `ipxe.efi` from boot.ipxe.org returned an **HTML
page** instead of the binary (9 KB "EFI file" that firmware silently refused to
execute — same symptom as Secure Boot). The distro package is deterministic and
also air-gap friendly:

```bash
sudo apt install -y ipxe
sudo mkdir -p /var/lib/tftpboot
sudo cp /usr/lib/ipxe/ipxe.efi /usr/lib/ipxe/snponly.efi /var/lib/tftpboot/

# ALWAYS verify — this catches the HTML-instead-of-binary failure:
file /var/lib/tftpboot/*.efi
# Must say: PE32+ executable (EFI application) x86-64
# If it says "HTML document" the file is garbage — do not serve it.
```

Note: `snponly.efi` (uses the firmware's own network stack) is a good fallback
if full `ipxe.efi` has NIC driver trouble. Either works on the OptiPlex i219
NICs; the as-built config serves whichever is named in the dnsmasq config —
keep the filename consistent everywhere.

## 4. Download Talos boot assets to the Pi (HTTPS happens here, once)

```bash
sudo mkdir -p /var/lib/tftpboot/assets && cd /var/lib/tftpboot/assets
S=613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245
V=v1.13.5

sudo curl -fLO "https://factory.talos.dev/image/${S}/${V}/kernel-amd64"
sudo curl -fLO "https://factory.talos.dev/image/${S}/${V}/initramfs-amd64.xz"

file kernel-amd64 initramfs-amd64.xz   # Linux kernel + XZ compressed data
ls -la                                  # kernel ≈ 20 MB; initramfs larger
```

**Asset-name gotcha:** the initramfs is `initramfs-amd64.xz` — **no `metal`**
in the name, even though the PXE *path* uses `metal-amd64`. The wrong name
returns HTTP 400/404. Verify with:
`curl -sI "https://factory.talos.dev/image/${S}/${V}/initramfs-amd64.xz" | head -1`

**First-request build delay:** Factory builds schematic+version assets on
demand. The very first request for a combination can hang for several minutes
while the build runs (subsequent requests are cached and instant). Use
`--max-time` and retry rather than assuming failure. Always use `curl -f` so
HTTP errors fail loudly instead of saving an error page to disk.

## 5. Serve the assets over HTTP

Quick-and-dirty (fine for tinkering):

```bash
cd /var/lib/tftpboot/assets && sudo python3 -m http.server 8000
```

Persistent version (systemd unit so it survives reboots):

```bash
sudo tee /etc/systemd/system/pxe-assets.service > /dev/null <<'EOF'
[Unit]
Description=HTTP server for Talos PXE assets
After=network-online.target
Wants=network-online.target

[Service]
WorkingDirectory=/var/lib/tftpboot/assets
ExecStart=/usr/bin/python3 -m http.server 8000
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl enable --now pxe-assets
curl -sI http://192.168.0.18:8000/kernel-amd64 | head -1   # want 200
```

(Option 2 replaces this with Matchbox serving the same directory.)

## 6. Create the iPXE boot script (boots from local HTTP, not Factory)

```bash
sudo tee /var/lib/tftpboot/boot.ipxe > /dev/null <<'EOF'
#!ipxe
dhcp
kernel http://192.168.0.18:8000/kernel-amd64 initrd=initramfs-amd64.xz init_on_alloc=1 slab_nomerge pti=on console=tty0 printk.devkmsg=on talos.platform=metal
initrd http://192.168.0.18:8000/initramfs-amd64.xz
boot
EOF
```

The initramfs filename appears **twice** — the `initrd=` kernel argument and
the `initrd http://...` fetch line. Both must match the real filename exactly;
a mismatch shows up as a 404 in the HTTP server log while the kernel fetch
succeeds.

`boot.ipxe` is fetched fresh on every boot — edits take effect immediately, no
service restarts needed.

## 7. Configure dnsmasq (proxyDHCP mode)

```bash
sudo tee /etc/dnsmasq.d/pxe-proxy.conf > /dev/null <<'EOF'
# --- proxyDHCP for Talos PXE (router keeps real DHCP) ---
port=0                              # disable DNS entirely (Pi-hole owns 53)
dhcp-range=192.168.0.0,proxy        # proxy mode on this subnet
enable-tftp
tftp-root=/var/lib/tftpboot
log-dhcp                            # verbose logs while tinkering

# Tag clients that already run iPXE (so we don't chainload forever)
dhcp-match=set:ipxe,175

# First pass: firmware PXE client -> hand it iPXE
dhcp-boot=tag:!ipxe,ipxe.efi

# Second pass: iPXE client -> hand it the boot script over TFTP
dhcp-boot=tag:ipxe,boot.ipxe

# UEFI client-architecture matching (guarded so it can't re-serve iPXE to iPXE)
dhcp-vendorclass=set:efi64,PXEClient:Arch:00007
dhcp-vendorclass=set:efi64,PXEClient:Arch:00009
pxe-service=tag:efi64,tag:!ipxe,x86-64_EFI,"Boot Talos (iPXE)",ipxe.efi
EOF

sudo systemctl restart dnsmasq
sudo systemctl enable dnsmasq
journalctl -u dnsmasq -f     # keep open during boot tests
```

Healthy startup lines to look for:
`started ... DNS disabled` / `DHCP, proxy on subnet 192.168.0.0` /
`TFTP root is /var/lib/tftpboot`. The `resolvconf ... Link lo is loopback`
message is harmless noise.

## 8. Boot a node

1. **etcd first:** with a 3-node control plane, only one node down at a time.
   Snapshot before any reprovision:
   `talosctl -n <healthy-cp> etcd snapshot ./etcd-$(date +%F).snap`
2. F12 → select the **UEFI PXE IPv4** entry explicitly.
3. Expected sequence across the three consoles:

   **dnsmasq log:** firmware `PXEClient` discover → tagged `efi64` → offered
   `ipxe.efi` → TFTP sends it (an `error 8 User aborted` followed by two `sent`
   lines is NORMAL — firmware probes file size, aborts, re-downloads) → a new
   DHCP round with `user class: iPXE` and `tags: ipxe` → offered `boot.ipxe` →
   TFTP sends it.

   **HTTP server log:** `GET /kernel-amd64 200` → `GET /initramfs-amd64.xz 200`.

   **Node console:** iPXE banner → link up → script runs → both downloads with
   progress → Talos kernel messages → **maintenance mode with IP displayed**.

## 9. Apply config

```bash
talosctl -n <node-ip> get disks --insecure      # confirm nvme0n1 visible
talosctl apply-config --insecure \
  --nodes <node-ip> \
  --file controlplane-<node>.yaml
```

Config must have (all three lessons from the reset incident):

```yaml
machine:
  install:
    disk: /dev/nvme0n1          # or diskSelector: {type: nvme}
    wipe: true                  # clean ESP -> NVMe reappears in boot menu
    image: factory.talos.dev/installer/613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245:v1.13.5
```

**Never** use plain `ghcr.io/siderolabs/installer` — it installs vanilla Talos
and silently strips the extensions (iscsi-tools, util-linux-tools). This broke
Longhorn on two nodes once already. Verify after every install/upgrade:
`talosctl -n <node> get extensions` → must list iscsi-tools, util-linux-tools,
and the schematic ID.

Watch console: Maintenance → **Installing** (bootloader written) → Booting.
Then confirm rejoin:

```bash
talosctl -n <healthy-cp> etcd members    # back to 3 healthy
kubectl get nodes                        # node Ready
```

If a wiped node's old etcd member lingers, remove it before rejoining:
`talosctl -n <healthy-cp> etcd remove-member <id>`

---

## Troubleshooting quick table (as-built, expanded)

| Symptom | Cause found / likely | Fix |
|---|---|---|
| `.efi` file downloads via TFTP but never executes, no error, firmware loops back to PXE | The "binary" is an HTML error page (boot.ipxe.org served a web page), **or** Secure Boot silently rejecting unsigned binary | `file /var/lib/tftpboot/*.efi` — must be PE32+; use the apt `ipxe` package; confirm Secure Boot disabled |
| Node PXE-boots over IPv6 and times out | Dell firmware tries the IPv6 PXE entry first | Disable IPv6 NIC stack in BIOS; pick the explicit IPv4 entry at F12 |
| iPXE: `Could not boot image: Operation not permitted (ipxe.org/410de18f)` at the Factory URL | iPXE TLS trust store can't validate Factory's ZeroSSL cert | Don't chain HTTPS — serve kernel/initramfs locally over HTTP (this runbook's design) |
| Kernel GET returns 200 but initramfs 404s | Wrong asset name — it's `initramfs-amd64.xz`, not `initramfs-metal-amd64.xz` | Fix the name in BOTH places in boot.ipxe |
| Factory URL hangs for minutes | First-request on-demand build for this schematic+version | Wait it out with `--max-time 180`, retry; cached afterward |
| `error 8 User aborted the transfer` in TFTP log | Firmware size-probe, not an error | Ignore — the subsequent `sent` lines are the real transfer |
| dnsmasq fails to start (`exit-code`) | Port collision with pihole-FTL | `port=0` in config; `ss -ulnp` to find the conflict |
| No PXE offer at all in dnsmasq log | Broadcasts not reaching the Pi / wrong subnet in `dhcp-range` | Same L2 segment; verify `dhcp-range=192.168.0.0,proxy` |
| Everything PXE-loops on normal reboots | NIC above NVMe in boot order | NVMe first; F12 for on-demand PXE |
| Node boots Talos but unconfigured | Expected — Option 1 always lands in maintenance mode | `apply-config`; automation is Option 2 (Matchbox) |
| `Unknown command verb` from random CLI | Typing into the wrong terminal during a 10-tab debugging session | Coffee |

## Relationship to Option 2 / air-gap

Everything here carries forward: dnsmasq config is unchanged; the assets
directory becomes Matchbox's `/assets`; the only change is `boot.ipxe`
chaining to Matchbox (which serves per-node machine configs keyed by MAC)
instead of embedding one static kernel line. The HTTPS-once-then-local-HTTP
pattern established here IS the air-gap architecture — later, the "HTTPS once"
step is replaced by a Zarf-packaged sync.
