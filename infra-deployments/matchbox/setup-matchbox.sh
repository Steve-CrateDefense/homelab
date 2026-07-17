#!/usr/bin/env bash
# setup-matchbox.sh — stand up / maintain the Matchbox PXE provisioning stack on pi-dns
#
# Usage:
#   sudo ./setup-matchbox.sh install      # full install (idempotent)
#   sudo ./setup-matchbox.sh assets       # (re)download kernel/initramfs for $TALOS_VERSION
#   sudo ./setup-matchbox.sh render       # write profile/group/boot.ipxe/dnsmasq from vars below
#   sudo ./setup-matchbox.sh sync-configs # cp-XX.yaml -> MAC-named copies
#   ./setup-matchbox.sh verify            # pre-flight curl suite (no sudo needed)
#   sudo ./setup-matchbox.sh all          # install + assets + render + sync + verify
set -euo pipefail

# ─── Environment (edit here on version bumps / node changes) ────────────────
MATCHBOX_VER="v0.11.0"
MATCHBOX_ARCH="arm64"                      # amd64 if not on the Pi
HOST_IP="192.168.0.18"
HTTP_PORT="8080"
SUBNET="192.168.0.0"                       # proxyDHCP subnet
TALOS_VERSION="v1.13.5"
SCHEMATIC="613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245"

# node_id -> MAC (colon form; hexhyp derived automatically)
declare -A NODES=(
  [13]="8c:04:ba:9f:38:28"
  [15]="a4:bb:6d:49:06:45"
  [16]="8c:04:ba:9d:f8:f7"
)

MB_DIR="/var/lib/matchbox"
TFTP_DIR="/var/lib/tftpboot"
BASE_URL="http://${HOST_IP}:${HTTP_PORT}"

# ─── helpers ────────────────────────────────────────────────────────────────
log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
hexhyp() { echo "$1" | tr 'A-Z:' 'a-z-'; }

verify_file_type() {  # verify_file_type <path> <grep-pattern> — rule #1: never trust a download
  local t; t=$(file -b "$1")
  echo "$1: $t"
  echo "$t" | grep -qi "$2" || die "$1 is not '$2' (got: $t) — refusing to serve garbage"
  echo "$t" | grep -qi html && die "$1 is an HTML page, not a real file"
}

# ─── install: matchbox binary, user, dirs, systemd, dnsmasq+ipxe pkgs ───────
cmd_install() {
  log "Installing packages (dnsmasq, ipxe)"
  apt-get update -qq && apt-get install -y -qq dnsmasq ipxe curl file

  if ! command -v matchbox >/dev/null || ! matchbox -version 2>/dev/null | grep -q "${MATCHBOX_VER#v}"; then
    log "Installing matchbox ${MATCHBOX_VER} (${MATCHBOX_ARCH})"
    local tgz="matchbox-${MATCHBOX_VER}-linux-${MATCHBOX_ARCH}.tar.gz"
    curl -fL -o "/tmp/${tgz}" \
      "https://github.com/poseidon/matchbox/releases/download/${MATCHBOX_VER}/${tgz}"
    tar -xzf "/tmp/${tgz}" -C /tmp
    install -m 0755 "/tmp/matchbox-${MATCHBOX_VER}-linux-${MATCHBOX_ARCH}/matchbox" /usr/local/bin/matchbox
    verify_file_type /usr/local/bin/matchbox "ELF"
  else
    log "matchbox ${MATCHBOX_VER} already installed"
  fi

  id matchbox &>/dev/null || useradd -U -M -s /usr/sbin/nologin matchbox
  mkdir -p "${MB_DIR}"/{assets/configs,assets/manifests,profiles,groups} "${TFTP_DIR}"

  log "Staging iPXE binaries from the apt package (never boot.ipxe.org — see README rule #1)"
  cp /usr/lib/ipxe/ipxe.efi /usr/lib/ipxe/snponly.efi "${TFTP_DIR}/"
  verify_file_type "${TFTP_DIR}/ipxe.efi" "EFI application"

  log "Writing matchbox systemd unit"
  cat > /etc/systemd/system/matchbox.service <<EOF
[Unit]
Description=Matchbox network boot + provisioning file service
After=network-online.target
Wants=network-online.target

[Service]
User=matchbox
ExecStart=/usr/local/bin/matchbox \\
  -address=0.0.0.0:${HTTP_PORT} \\
  -data-path=${MB_DIR} \\
  -assets-path=${MB_DIR}/assets \\
  -log-level=debug
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now matchbox
  chown -R matchbox:matchbox "${MB_DIR}"
  curl -sf "http://localhost:${HTTP_PORT}" | grep -q matchbox || die "matchbox banner check failed"
  log "matchbox up on :${HTTP_PORT}"
}

# ─── assets: Talos kernel/initramfs for TALOS_VERSION (Pi does HTTPS once) ──
cmd_assets() {
  log "Downloading Talos ${TALOS_VERSION} assets for schematic ${SCHEMATIC:0:8}…"
  warn "First request per schematic+version can hang several minutes (Factory on-demand build)"
  cd "${MB_DIR}/assets"
  curl -fL --retry 3 --max-time 600 -o kernel-amd64 \
    "https://factory.talos.dev/image/${SCHEMATIC}/${TALOS_VERSION}/kernel-amd64"
  # NB: asset is initramfs-amd64.xz — no "metal" (README rule #3)
  curl -fL --retry 3 --max-time 600 -o initramfs-amd64.xz \
    "https://factory.talos.dev/image/${SCHEMATIC}/${TALOS_VERSION}/initramfs-amd64.xz"
  verify_file_type kernel-amd64 "kernel"
  verify_file_type initramfs-amd64.xz "XZ compressed"
  chown matchbox:matchbox kernel-amd64 initramfs-amd64.xz
  log "Assets staged. Remember: install.image tag in every config must match ${TALOS_VERSION}."
}

# ─── render: profile, groups, boot.ipxe, dnsmasq config from NODES map ──────
cmd_render() {
  log "Writing profile talos-cp (\${mac:hexhyp} selection — iPXE expands it, NOT matchbox)"
  cat > "${MB_DIR}/profiles/talos-cp.json" <<EOF
{
  "id": "talos-cp",
  "name": "Talos control plane ${TALOS_VERSION}",
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
      "talos.config=${BASE_URL}/assets/configs/\${mac:hexhyp}.yaml"
    ]
  }
}
EOF

  for n in "${!NODES[@]}"; do
    log "Writing group cp-${n} (selector ${NODES[$n]})"
    cat > "${MB_DIR}/groups/cp-${n}.json" <<EOF
{
  "id": "cp-${n}",
  "name": "OptiPlex 192.168.0.${n}",
  "profile": "talos-cp",
  "selector": { "mac": "${NODES[$n]}" }
}
EOF
  done

  log "Writing ${TFTP_DIR}/boot.ipxe (chain to matchbox)"
  cat > "${TFTP_DIR}/boot.ipxe" <<EOF
#!ipxe
dhcp
chain ${BASE_URL}/boot.ipxe
EOF

  log "Writing dnsmasq proxyDHCP config"
  cat > /etc/dnsmasq.d/pxe-proxy.conf <<EOF
# proxyDHCP for Talos PXE — router keeps real DHCP
port=0                              # DNS off (Pi-hole owns 53)
dhcp-range=${SUBNET},proxy
enable-tftp
tftp-root=${TFTP_DIR}
log-dhcp
dhcp-match=set:ipxe,175
dhcp-boot=tag:!ipxe,ipxe.efi
dhcp-boot=tag:ipxe,boot.ipxe
dhcp-vendorclass=set:efi64,PXEClient:Arch:00007
dhcp-vendorclass=set:efi64,PXEClient:Arch:00009
pxe-service=tag:efi64,tag:!ipxe,x86-64_EFI,"Boot Talos (iPXE)",ipxe.efi
EOF

  chown -R matchbox:matchbox "${MB_DIR}"
  systemctl restart matchbox dnsmasq
  systemctl enable dnsmasq >/dev/null 2>&1 || true
  log "Rendered + services restarted"
}

# ─── sync-configs: cp-XX.yaml (source of truth) -> MAC-named copies ─────────
cmd_sync_configs() {
  cd "${MB_DIR}/assets/configs"
  local missing=0
  for n in "${!NODES[@]}"; do
    local src="cp-${n}.yaml" dst; dst="$(hexhyp "${NODES[$n]}").yaml"
    if [[ ! -f "$src" ]]; then warn "MISSING ${src} — place your rendered machine config here"; missing=1; continue; fi
    grep -q "factory.talos.dev/installer/${SCHEMATIC}" "$src" \
      || warn "${src}: install.image is NOT the Factory installer (README rule #6 — extensions will be stripped!)"
    grep -q "wipe: true" "$src" || warn "${src}: wipe is not true — ESP may not be rewritten cleanly"
    cp -f "$src" "$dst"
    log "synced ${src} -> ${dst}"
  done
  chown matchbox:matchbox ./*.yaml 2>/dev/null || true
  [[ $missing -eq 0 ]] || warn "Some sources missing; nodes for those MACs will 404 at boot"
}

# ─── verify: the pre-flight curl suite ──────────────────────────────────────
cmd_verify() {
  local fail=0
  chk() { # chk <desc> <url> [expect_code]
    local code; code=$(curl -so /dev/null -w '%{http_code}' --max-time 10 "$2" || echo 000)
    if [[ "$code" == "${3:-200}" ]]; then log "OK   $1 ($code)"; else warn "FAIL $1 -> $code ($2)"; fail=1; fi
  }
  chk "matchbox banner"    "${BASE_URL}"
  chk "kernel"             "${BASE_URL}/assets/kernel-amd64"
  chk "initramfs"          "${BASE_URL}/assets/initramfs-amd64.xz"
  chk "chain script"       "${BASE_URL}/boot.ipxe"
  for n in "${!NODES[@]}"; do
    local mac="${NODES[$n]}" hh; hh=$(hexhyp "${NODES[$n]}")
    chk "ipxe render cp-${n}"  "${BASE_URL}/ipxe?mac=${mac}"
    chk "config cp-${n}"       "${BASE_URL}/assets/configs/${hh}.yaml"
    # rendered script must carry the literal iPXE variable (rule #5)
    curl -s "${BASE_URL}/ipxe?mac=${mac}" | grep -q 'mac:hexhyp' \
      && log "OK   cp-${n} script uses \${mac:hexhyp}" \
      || { warn "FAIL cp-${n} rendered script missing \${mac:hexhyp}"; fail=1; }
    # install block sanity on the served config
    curl -s "${BASE_URL}/assets/configs/${hh}.yaml" | grep -q "factory.talos.dev/installer/${SCHEMATIC}" \
      && log "OK   cp-${n} config carries Factory installer" \
      || { warn "FAIL cp-${n} served config missing Factory installer image"; fail=1; }
  done
  for m in "${MB_DIR}"/assets/manifests/*.yaml; do
    [[ -e "$m" ]] || { warn "no manifests staged in assets/manifests"; break; }
    chk "manifest $(basename "$m")" "${BASE_URL}/assets/manifests/$(basename "$m")"
  done
  [[ $fail -eq 0 ]] && log "ALL CHECKS PASSED — safe to F12" || die "verification failed — fix before booting a node"
}

# ─── main ───────────────────────────────────────────────────────────────────
case "${1:-}" in
  install)       cmd_install ;;
  assets)        cmd_assets ;;
  render)        cmd_render ;;
  sync-configs)  cmd_sync_configs ;;
  verify)        cmd_verify ;;
  all)           cmd_install; cmd_assets; cmd_render; cmd_sync_configs; cmd_verify ;;
  *) grep '^#   ' "$0" | sed 's/^#   //'; exit 1 ;;
esac
