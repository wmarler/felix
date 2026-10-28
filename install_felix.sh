#!/usr/bin/env bash
#
# Create a Flatcar installer VM on a remote libvirt hypervisor.
#
# virt-install runs on THIS machine and talks to libvirt over qemu+ssh://.
# The hypervisor itself only needs libvirtd/QEMU and SSH. All disk and ISO
# paths come from felix.config and refer to paths on the hypervisor.
#
# This boots the Flatcar ISO with the OS disk plus three data disks attached.
# It does NOT run flatcar-install for you; see the "next steps" it prints.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CONFIG_FILE="${SCRIPT_DIR}/felix.config"
DRY_RUN=0
BUILD_IGNITION=1

# Disk serials. These become /dev/disk/by-id/virtio-<serial> inside the guest
# and MUST match the devices in src/felix.yaml -> storage.filesystems.
SERIAL_OS="felix"
SERIAL_APPDATA="appdata"
SERIAL_CONTAINERD="containerd"
SERIAL_DOCKER="docker"

usage() {
  cat <<'EOF'
Usage: install_felix.sh [options]

  --config FILE     Config file to source [default: ./felix.config]
  --skip-ignition   Do not rebuild felix.ign first (default: runs ./run_felix.sh --ignition-only)
  --dry-run         Print the virt-install command instead of running it
  -h, --help        Show this help

Copy felix.config.sample to felix.config and edit it before running.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      CONFIG_FILE=$2
      shift 2
      ;;
    --skip-ignition)
      BUILD_IGNITION=0
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

[[ -f "$CONFIG_FILE" ]] || die "missing ${CONFIG_FILE} — copy felix.config.sample to felix.config and edit it"

# shellcheck disable=SC1090
source "$CONFIG_FILE"

for var in HYPERVISOR_USER HYPERVISOR_HOST VM_NAME OS_DISK APPDATA_DISK CONTAINERD_DISK DOCKER_DISK ISO_PATH HOST_BRIDGE GUEST_MAC; do
  [[ -n "${!var:-}" ]] || die "${var} is not set in ${CONFIG_FILE}"
done

VM_RAM="${VM_RAM:-4096}"
VM_VCPUS="${VM_VCPUS:-1}"
LIBVIRT_URI="${LIBVIRT_URI:-qemu+ssh://${HYPERVISOR_USER}@${HYPERVISOR_HOST}/system}"

# Warn if the MAC doesn't match what Ignition's networkd unit matches on.
if [[ -f src/network.config ]]; then
  ign_mac=$(sed -n 's/^MACAddress=//p' src/network.config | head -1)
  if [[ -n "$ign_mac" && "${ign_mac,,}" != "${GUEST_MAC,,}" ]]; then
    echo "warning: GUEST_MAC (${GUEST_MAC}) != MACAddress in src/network.config (${ign_mac}); the static IP will not apply" >&2
  fi
fi

if [[ "$BUILD_IGNITION" == 1 && "$DRY_RUN" == 0 ]]; then
  ./run_felix.sh --ignition-only
  echo ""
fi

cmd=(
  virt-install
  --connect "$LIBVIRT_URI"
  --name "$VM_NAME"
  --ram "$VM_RAM" --vcpus "$VM_VCPUS"
  --os-variant=linux2024
  --disk "path=${OS_DISK},format=raw,bus=virtio,serial=${SERIAL_OS}"
  --disk "path=${APPDATA_DISK},format=raw,bus=virtio,serial=${SERIAL_APPDATA}"
  --disk "path=${CONTAINERD_DISK},format=raw,bus=virtio,serial=${SERIAL_CONTAINERD}"
  --disk "path=${DOCKER_DISK},format=raw,bus=virtio,serial=${SERIAL_DOCKER}"
  --cdrom "$ISO_PATH"
  --network "bridge=${HOST_BRIDGE},model=virtio,mac=${GUEST_MAC}"
  --graphics=none
  --console pty,target_type=virtio
  --boot cdrom,hd
  --noautoconsole
)

if [[ "$DRY_RUN" == 1 ]]; then
  printf '%q ' "${cmd[@]}"
  echo ""
  exit 0
fi

command -v virt-install >/dev/null 2>&1 || die "virt-install not found on this machine (install the virt-install / virtinst package)"

echo "Creating ${VM_NAME} on ${LIBVIRT_URI} ..."
"${cmd[@]}"

ign_hint="${IGNITION_URL:-http://<where-you-published-felix.ign>/felix.ign}"

cat <<EOF

Installer VM "${VM_NAME}" is booting the Flatcar ISO.

Next steps:
  1. Publish felix.ign somewhere the VM can reach (nginx, S3, ...). This script does not do that.
  2. Open the console:
       virsh --connect '${LIBVIRT_URI}' console '${VM_NAME}'
  3. Inside the live ISO:
       curl -fsSL '${ign_hint}' -o /tmp/felix.ign
       sudo flatcar-install -d /dev/disk/by-id/virtio-${SERIAL_OS} -C stable -i /tmp/felix.ign
  4. When it finishes: sudo reboot   (boots from disk; Ignition runs once and
     formats/mounts the appdata, containerd and docker disks)
EOF
