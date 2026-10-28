#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CONFIG_FILE="${SCRIPT_DIR}/felix.config"
IGNITION_ONLY=0

usage() {
  cat <<'EOF'
Usage: run_felix.sh [options]

  --config FILE     Config file to source [default: ./felix.config]
  --ignition-only   Build felix.ign from src/ and exit (no root, no VM).
  -h, --help        Show this help.

With no options, builds felix.ign and starts the local Flatcar QEMU image (must run as root).
Copy felix.config.sample to felix.config and edit it before running.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      CONFIG_FILE=$2
      shift 2
      ;;
    --ignition-only)
      IGNITION_ONLY=1
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

# The config is only needed to boot the VM; --ignition-only works without it.
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
elif [[ "$IGNITION_ONLY" != 1 ]]; then
  echo "Missing ${CONFIG_FILE} — copy felix.config.sample to felix.config and edit it" >&2
  exit 1
fi

if [[ ! -f src/felix.secrets ]]; then
  echo "Missing src/felix.secrets (see README.md)" >&2
  exit 1
fi

# shellcheck disable=SC1091
source src/felix.secrets

echo "Preparing staging directory"
rm -rf staging
cp -r src staging

echo "Injecting secrets ..."
# TODO There's an optimization here to only substitute where needed.
for key in "${!SECRETS[@]}"; do
  value="${SECRETS[$key]}"
  find staging -type f -exec sed -i "s|@@${key}@@|${value}|g" {} +
done

echo "Compiling ignition file ..."
docker run --rm -v ./staging:/workspace quay.io/coreos/butane:release \
  --files-dir /workspace --strict /workspace/felix.yaml > felix.ign

rm -rf staging

if [[ "$IGNITION_ONLY" == 1 ]]; then
  echo "Wrote felix.ign"
  exit 0
fi

for var in HOST_BRIDGE GUEST_MAC SSH_TARGET SSH_KEY; do
  if [[ -z "${!var:-}" ]]; then
    echo "${var} is not set in ${CONFIG_FILE}" >&2
    exit 1
  fi
done
QEMU_IMAGE="${QEMU_IMAGE:-flatcar_production_qemu_image.img}"
QEMU_IMAGE_VANILLA="${QEMU_IMAGE_VANILLA:-flatcar_production_qemu_image.img.vanilla}"
DATA_DISK_DIR="${DATA_DISK_DIR:-disks}"
DATA_DISK_SIZE="${DATA_DISK_SIZE:-10G}"

# Data disk serials. These become /dev/disk/by-id/virtio-<serial> inside the
# guest and MUST match src/felix.yaml -> storage.filesystems (and install_felix.sh).
DATA_DISK_SERIALS=(appdata containerd docker)

if (( EUID != 0 )); then
  echo "Must be run as root"
  exit 1
fi

if [ -n "$SUDO_USER" ]; then
  echo "Must be run as actual root -- NOT sudo"
  exit 1
fi

if ! [ -f "$QEMU_IMAGE_VANILLA" ]; then
  echo "No flatcar image! You need to download it with 'wget -O ${QEMU_IMAGE_VANILLA} https://stable.release.flatcar-linux.net/amd64-usr/current/flatcar_production_qemu_image.img' (see README.md)"
  exit 1
fi

read -r -p "Fresh Image? (Y/n)" -r -n 1 fresh
echo ""
fresh=${fresh:-Y}

if [[ $fresh =~ [Yy] ]] || ! [ -f "$QEMU_IMAGE" ]; then
  rm -f "$QEMU_IMAGE" && cp "$QEMU_IMAGE_VANILLA" "$QEMU_IMAGE"
  echo "Existing image replaced with vanilla"
fi

# Data disks: the live image mirrors the permanent install, where the OS disk
# is reinstalled but appdata/containerd/docker persist. So they are kept across
# "Fresh Image" unless explicitly reset.
mkdir -p "$DATA_DISK_DIR"
existing_data_disks=0
for serial in "${DATA_DISK_SERIALS[@]}"; do
  [ -f "${DATA_DISK_DIR}/${serial}.qcow2" ] && existing_data_disks=1
done
if [[ "$existing_data_disks" == 1 ]]; then
  read -r -p "Reset data disks (${DATA_DISK_SERIALS[*]})? (y/N)" -r -n 1 reset_data
  echo ""
  if [[ ${reset_data:-N} =~ [Yy] ]]; then
    for serial in "${DATA_DISK_SERIALS[@]}"; do
      rm -f "${DATA_DISK_DIR}/${serial}.qcow2"
    done
    echo "Data disks removed"
  fi
fi

command -v qemu-img >/dev/null 2>&1 || { echo "qemu-img not found (install qemu-utils)" >&2; exit 1; }
extra_disk_args=()
for serial in "${DATA_DISK_SERIALS[@]}"; do
  disk="${DATA_DISK_DIR}/${serial}.qcow2"
  if ! [ -f "$disk" ]; then
    qemu-img create -q -f qcow2 "$disk" "$DATA_DISK_SIZE"
    echo "Created ${disk} (${DATA_DISK_SIZE}, sparse)"
  fi
  extra_disk_args+=(-d "${disk},serial=${serial}")
done

echo "Starting live image (logging to felix.log)"
rm -f felix.log
./flatcar_production_qemu.sh -i felix.ign -I "$QEMU_IMAGE" "${extra_disk_args[@]}" -- \
  -display none \
  -serial file:felix.log \
  -netdev "tap,id=tap0,br=${HOST_BRIDGE},helper=/usr/lib/qemu/qemu-bridge-helper" \
  -device "virtio-net-pci,netdev=tap0,mac=${GUEST_MAC}" \
  < /dev/null &
while [ ! -f felix.log ]; do
  sleep 0.5
done
tail -f felix.log &
TAIL_PID=$!
until ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o BatchMode=yes -i "$SSH_KEY" "$SSH_TARGET" true 2>/dev/null; do
  sleep 5
done
kill $TAIL_PID
wait $TAIL_PID 2>/dev/null
echo ""
echo "Felix is up!"
echo "   ssh -i ${SSH_KEY} ${SSH_TARGET}"
