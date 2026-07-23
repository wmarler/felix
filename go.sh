#!/usr/bin/env bash

if (( EUID != 0)); then
  echo "Must be run as root"
  exit 1
fi

if [ -n "$SUDO_USER" ]; then
  echo "Must be run as actual root -- NOT sudo"
  exit 1
fi

if ! [ -f flatcar_production_qemu_image.img ]; then
  echo "No flatcar image! You need to download it with 'wget -o flatcar_production_qemu_image.img.vanilla https://stable.release.flatcar-linux.net/amd64-usr/current/flatcar_production_qemu_image.img' and then copy that to flatcar_production_qemu_image.img (see README.md)"
  exit 1
fi

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
docker run --rm -v ./staging:/workspace quay.io/coreos/butane:release --files-dir /workspace --strict /workspace/felix.yaml > felix.ign 

rm -rf staging

read -r -p "Fresh Image? (Y/n)" -r -n 1  fresh
fresh=${fresh:-Y}

if [[ $fresh =~ [Yy] ]]; then 
  rm flatcar_production_qemu_image.img && cp flatcar_production_qemu_image.img.vanilla flatcar_production_qemu_image.img
  echo "Existing image replaced with vanilla"
fi

echo "Starting live image (logging to felix.log)"
# ./flatcar_production_qemu.sh -i felix.ign -- -nographic -netdev tap,id=tap0,br=br0,helper=/usr/lib/qemu/qemu-bridge-helper -device virtio-net-pci,netdev=tap0,mac=FE:ED:FA:CE:F0:0D
rm -f felix.log
./flatcar_production_qemu.sh -i felix.ign -- \
    -display none \
    -serial file:felix.log \
    -netdev tap,id=tap0,br=br0,helper=/usr/lib/qemu/qemu-bridge-helper \
    -device virtio-net-pci,netdev=tap0,mac=FE:ED:FA:CE:F0:0D \
    < /dev/null &
while [ ! -f felix.log ]; do
  sleep 0.5;
done
tail -f felix.log &
TAIL_PID=$!
until ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o BatchMode=yes -i /home/osmc/.ssh/id_ed25519 core@10.10.1.12 true 2>/dev/null; do
  sleep 5
done
kill $TAIL_PID
wait $TAIL_PID 2>/dev/null
echo ""
echo "Felix is up!"
echo "   ssh -i /home/osmc/.ssh/id_ed25519 core@10.10.1.12"
