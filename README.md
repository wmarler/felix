# Felix

A Flatcar Container Linux host, managed as code: the whole machine is described by a
[Butane](https://coreos.github.io/butane/) config plus a handful of files in `src/`, so it can
be destroyed and recreated at whim.

Felix can be brought up in two ways:

1. **Live image** (`run_felix.sh`) — boot the stock Flatcar QEMU disk image locally with the
   generated Ignition config. Quick to iterate on; nothing persists beyond the `.img` file.
2. **Permanent install** (`install_felix.sh`) — install Flatcar onto an LVM volume on a remote
   libvirt hypervisor, with three additional block devices mounted at `/var/lib/docker`,
   `/var/lib/containerd` and `/mnt/appdata`.

Both start from the same Ignition config.

## Layout

| Path | Purpose |
|------|---------|
| `src/felix.yaml` | Butane config: filesystems, files, systemd units, users |
| `src/*.service`, `src/*.conf`, `src/*.yaml` | Files referenced from `felix.yaml` via `local:` |
| `src/felix.secrets` | **Git-ignored.** Values substituted for `@@NAME@@` placeholders in `src/` |
| `run_felix.sh` | Build `felix.ign`; optionally boot the local QEMU live image |
| `install_felix.sh` | Build `felix.ign`; create the installer VM on a remote hypervisor |
| `felix.config` | **Git-ignored.** Settings for both scripts (bridge, MAC, hypervisor, disks, SSH target…) |
| `felix.config.sample` | Template for `felix.config` |
| `flatcar_production_qemu.sh` | Flatcar's stock QEMU wrapper (used by `run_felix.sh`) |

## Configuration

Both scripts source `felix.config` from the repository root. Start from the template:

```bash
cp felix.config.sample felix.config
```

It is plain bash with three sections:

| Section | Variables | Used by |
|---------|-----------|---------|
| **Global** | `HOST_BRIDGE`, `GUEST_MAC` | both |
| **install_felix.sh** | `HYPERVISOR_USER`, `HYPERVISOR_HOST`, `LIBVIRT_URI` (optional), `VM_NAME`, `VM_RAM`, `VM_VCPUS`, `OS_DISK`, `APPDATA_DISK`, `CONTAINERD_DISK`, `DOCKER_DISK`, `ISO_PATH`, `IGNITION_URL` (optional) | permanent install |
| **run_felix.sh** | `SSH_TARGET`, `SSH_KEY`, `QEMU_IMAGE` / `QEMU_IMAGE_VANILLA` (optional) | live image |

`GUEST_MAC` must match the `MACAddress=` line in `src/network.config` or the static IP will not be
applied; `install_felix.sh` warns if they differ. `HOST_BRIDGE` is a bridge on the local machine for
`run_felix.sh` and on the hypervisor for `install_felix.sh` — in both cases it must carry the subnet
from `src/network.config`.

Either script accepts `--config FILE` to use a different file.

## Secrets

Create `src/felix.secrets` (not committed). It is a bash associative array; every `@@KEY@@`
in any file under `src/` is replaced by the matching value before Butane runs:

```bash
# src/felix.secrets
declare -A SECRETS

SECRETS["ADGUARD_PASSWORD_HASH"]='$2a$12$4...'
SECRETS["ADGUARD_PASSWORD_PLAINTEXT"]='...'
SECRETS["VRRP_PASSWORD"]='...'
SECRETS["LAPTOP_PUBLIC_KEY"]='ssh-ed25519 AAAA...'
...
```

If you clone this, adjust the placeholder names in `src/felix.yaml` and friends to match your
own secrets.

## Building the Ignition config

```bash
./run_felix.sh --ignition-only
```

Copies `src/` to `staging/`, injects secrets, runs Butane (`quay.io/coreos/butane` via Docker,
`--strict`) and writes `felix.ign`. No root required. Both scripts do this step automatically.

## Mode 1: live image (`run_felix.sh`)

Fetch the stock QEMU image once and keep a pristine copy:

```bash
wget -O flatcar_production_qemu_image.img.vanilla \
  https://stable.release.flatcar-linux.net/amd64-usr/current/flatcar_production_qemu_image.img
```

Fill in the **run_felix.sh** section of `felix.config` (`SSH_TARGET` is the `user@ip` the script
polls until the VM is up; `SSH_KEY` is the private key for it). Then, as **actual root** (not
`sudo` — the QEMU bridge helper needs the real root environment):

```bash
./run_felix.sh
```

It builds `felix.ign`, offers to reset the working image from `.vanilla` (and creates it if
missing), boots the VM headless on `HOST_BRIDGE` with `GUEST_MAC`, tails the serial console to
`felix.log`, and waits until `SSH_TARGET` answers.

Note: Ignition only runs on the **first** boot of a given image. That means if you `run_felix.sh`,
once, then shut the machine down, then `run_felix.sh` again, the machine will start back up in
the state it was when you shut it down. To re-provision, answer `Y` to "Fresh Image?"; this
will replace the working `.img` with a new vanilla copy that is then updated via ignition.

### Data disks in live mode

`src/felix.yaml` expects three extra block devices (see [Disks](#disks) below). So that the same
Ignition config works unchanged, `run_felix.sh` creates three sparse qcow2 images under
`disks/` (`appdata.qcow2`, `containerd.qcow2`, `docker.qcow2`, `DATA_DISK_SIZE` each, default
1G) and attaches them with the same virtio serials the permanent install uses. Inside the VM
they appear as `/dev/disk/by-id/virtio-appdata` etc., and Ignition formats and mounts them.

They are deliberately **not** reset by "Fresh Image?" — that mirrors a reinstall, where the OS
disk is rewritten but appdata survives. A second prompt, "Reset data disks?", lets you wipe them
(default: no). `disks/` is git-ignored. Requires `qemu-img` (package `qemu-utils`).

## Persistent systemd units (`link-appdata-services.service`)

Felix separates **OS state** (root disk, reinstalled with Flatcar) from **long-lived services**
that should outlive a reinstall. Extra unit files live on the appdata volume, not in Ignition on
the root disk.

Ignition (in `src/felix.yaml`) creates `/mnt/appdata/systemd-units/` and installs
`link-appdata-services.service` on the root filesystem. That unit is enabled at boot and runs
once per boot:

1. Wait until `/mnt/appdata` is mounted (`RequiresMountsFor=/mnt/appdata`).
2. Wait until Docker is up (`After=docker.service`, `Wants=docker.service`).
3. For every `*.service` file in `/mnt/appdata/systemd-units/`, run
   `systemctl enable --now` on the **absolute path** (link into `/etc/systemd/system`, enable,
   start). This is idempotent across reboots.

You can add or change container services **without** editing `src/felix.yaml` or rebuilding
Ignition: copy a unit file onto the running host (or onto the appdata disk from the hypervisor)
under `/mnt/appdata/systemd-units/`, then reboot or run
`systemctl enable --now /mnt/appdata/systemd-units/your.service`. On the next Felix reinstall,
keep the same appdata block device; those unit files remain on the disk and are picked up again
on first boot.

The repo seeds one example: Ignition writes `adguard2.service` into
`/mnt/appdata/systemd-units/` from `src/adguard2.service` (with `overwrite: true` so reinstall
still works). AdGuard’s compose and config sit under `/mnt/appdata/adguard2/`. Other stacks can
follow the same pattern—unit on appdata, working directory and volumes on appdata or other data
disks—while `keepalived.service` is ordered `After=adguard2.service` via a drop-in in
`felix.yaml`.

## Mode 2: permanent install (`install_felix.sh`)

### Topology

- **Client** (where you run `install_felix.sh`): needs `virt-install`, `ssh`, Docker.
- **Hypervisor**: needs libvirtd/QEMU and SSH only. `virt-install` is *not* required there, which
  matters for headless hosts where it pulls in GUI dependencies.

`install_felix.sh` runs `virt-install` on the client with `--connect qemu+ssh://USER@HOST/system`,
so all disk and ISO paths in `felix.config` are paths **on the hypervisor**.

### Disks

Four block devices are attached, each tagged with a virtio serial. The serials are what
`src/felix.yaml` uses to find them, so they are fixed in the script:

| `felix.config` | serial | guest device | mounted at |
|----------------|--------|--------------|------------|
| `OS_DISK` | `felix` | `/dev/disk/by-id/virtio-felix` (`/dev/vda`) | root (via `flatcar-install`) |
| `APPDATA_DISK` | `appdata` | `/dev/disk/by-id/virtio-appdata` | `/mnt/appdata` |
| `CONTAINERD_DISK` | `containerd` | `/dev/disk/by-id/virtio-containerd` | `/var/lib/containerd` |
| `DOCKER_DISK` | `docker` | `/dev/disk/by-id/virtio-docker` | `/var/lib/docker` |

The three data disks are formatted ext4 (only if empty — `wipe_filesystem: false`) and mounted by
Ignition on first boot. `/mnt/appdata` is meant to survive reinstalls; see
[Persistent systemd units](#persistent-systemd-units-link-appdata-servicesservice) for how
services on that disk are enabled at boot.

### Steps

1. On the hypervisor: create the four LVs and download the ISO:
   ```bash
   wget -O /var/lib/libvirt/images/flatcar_production_iso_image.iso \
     https://stable.release.flatcar-linux.net/amd64-usr/current/flatcar_production_iso_image.iso
   ```
2. On the client: fill in the **Global** and **install_felix.sh** sections of `felix.config`.
3. Run it:
   ```bash
   ./install_felix.sh            # builds felix.ign, then virt-install
   ./install_felix.sh --dry-run  # just print the virt-install command
   ```
4. **Publish `felix.ign`** somewhere the installer VM can fetch it (nginx on the hypervisor, an
   object store, anything `curl` can reach). This is deliberately outside the scope of this
   repository; the scripts only write the file locally. Set `IGNITION_URL` in `felix.config`
   to have the next-steps text print the right URL.
5. Open the installer console and run `flatcar-install`. `virt-install` does not apply
   Ignition itself — `flatcar-install -i` embeds it on the OS disk and it runs on the first boot
   from that disk:
   ```bash
   virsh --connect qemu+ssh://USER@HOST/system console VM_NAME

   # inside the live ISO:
   curl -fsSL http://.../felix.ign -o /tmp/felix.ign
   sudo flatcar-install -d /dev/disk/by-id/virtio-felix -C stable -i /tmp/felix.ign
   sudo reboot
   ```

Exit `virsh console` with `Ctrl+]`. If you watch the VM in virt-manager instead, use its
*text/serial* console view — the VM has no graphics device, so the default graphical view is black.

### Reinstalling

Re-run `install_felix.sh` after `virsh destroy` / `virsh undefine` on the old domain. Reuse the
same `APPDATA_DISK` volume. On first boot, Ignition replaces the AdGuard unit, compose file, and
`AdGuardHome.yaml` (`overwrite: true` in `src/felix.yaml`) even when that disk already has data;
AdGuard runtime files under `/mnt/appdata/adguard2/work/` are not defined in Ignition and are
left unchanged.
