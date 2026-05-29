# infra-proxmox

Small bash scripts that wrap `qm` / `pvesm` to create and destroy QEMU VMs on a Proxmox host from a single env file.

The VM layout is opinionated: UEFI (OVMF) + q35, virtio-scsi-single, a system disk and a `/nix` disk on local storage, and a `/work` disk on an NFS storage — i.e. shaped for a NixOS guest, though nothing in the scripts is NixOS-specific.

## Status

Experimental, built primarily for the author's own deployment. Contributions and audit are welcome; no promises about stability, API compatibility, or support.

## Requirements

- Run on a Proxmox VE host (the scripts call `qm`, `pvesm`, `ip`)
- An ISO already uploaded to an ISO-capable storage
- A local block storage, an NFS storage, and a network bridge already configured

## Layout

```
lib/
  common.sh             # shared validation helpers
  create-qemu-vm.sh     # create a VM from an env file
  destroy-qemu-vm.sh    # destroy a VM (and its disks) from an env file
  run-one-shot-on-vm.sh # wake an idle guest, run one systemd unit, shut down
```

## Usage

### 1. Write an env file

Create a file like `myvm.env` (suggested suffix `*.local.env` is gitignored):

```sh
# Identity (VMID must be >= 100)
VMID=900
NAME=example-vm

# Image source
ISO_STORAGE=local
ISO_FILE=example.iso

# Network
BRIDGE=vmbr0

# Storages
LOCAL_DISK_STORAGE=local-lvm
NFS_STORAGE=nfs-share

# CPU / memory
CORES=4              # cores per socket
CPUUNITS=1000
MEMORY_MB=8192
BALLOON_MB=2048      # must be <= MEMORY_MB

# Disks (GiB)
SYSTEM_DISK_GB=32
NIX_DISK_GB=64
WORK_DISK_GB=128

# Optional
SOCKETS=1                          # default 1
ONBOOT=0                           # default 0 (1 = autostart on host boot)
STARTUP_ORDER=50                   # only used when ONBOOT=1
DISPLAY_MODE=std                   # std (default) | serial — see "Boot and install"
VM_DESCRIPTION="example VM"
VM_TAGS="example,managed"

# Optional InfiniBand SR-IOV VF passthrough (hostpci1). Set to a PVE
# resource-mapping pool name to give the guest a real IB HCA — the only
# way onto an IPoIB-only fabric (IPoIB is not bridgeable). The pool must
# have a free VF or the VM fails to start. The guest configures the
# fabric address/MTU/mode itself.
IB_VF_MAPPING=mellanox-ib          # default unset (no IB passthrough)
```

Inside the guest, the three data disks expose stable IDs based on the
`serial=` tag, so partitioning can refer to:

```
/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_system
/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_nix
/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_work
```

### 2. Create the VM

```sh
./lib/create-qemu-vm.sh ./myvm.env
```

The script validates the env, checks that the storages / ISO / bridge exist, prints the plan, and asks for confirmation (`yes`) before calling `qm`. On failure it prints inspection and cleanup hints.

### 3. Boot and install

`DISPLAY_MODE` controls how you drive the guest during install:

- `std` (default) — emulated VGA + USB tablet. Open the Proxmox Web UI noVNC
  console for the VM. This is what works out of the box with stock distro
  installer ISOs (including the NixOS minimal ISO).
- `serial` — no VGA, no tablet, drive via `qm terminal`. Only works if the
  ISO/image is preconfigured for serial console (kernel `console=ttyS0,…`,
  bootloader serial output, serial-getty enabled). The stock NixOS minimal
  ISO is not: its GRUB menu and default boot entry don't emit on serial, so
  `qm terminal` stays blank.

```sh
qm start 900
# DISPLAY_MODE=std:    open the Proxmox Web UI noVNC console
# DISPLAY_MODE=serial: qm terminal 900
```

After the guest OS is installed, switch boot order off the ISO and detach it:

```sh
qm set 900 --boot "order=scsi0"
qm set 900 --delete ide2
```

Once the installed guest has serial console configured, you can flip the VM
to headless and use `qm terminal` from then on:

```sh
qm set 900 --vga serial0 --tablet 0
qm terminal 900
```

### 4. Destroy

```sh
./lib/destroy-qemu-vm.sh ./myvm.env
```

Requires typing `destroy <VMID>` to confirm. If the VM is running, it is first asked to shut down gracefully (`SHUTDOWN_TIMEOUT_S` seconds, default 60; falls back to a hard stop on timeout), then destroyed with `--purge --destroy-unreferenced-disks 1`. Leftover volumes on the configured storages are listed at the end.

### 5. One-shot job on an idle VM

```sh
./lib/run-one-shot-on-vm.sh <VMID> <UNIT> <SSH_HOST> [SSH_USER]
```

Use case: a VM that is normally powered off, hosts a periodic workload
(e.g. the NixOS installer-ISO builder), and self-shuts down via a
`systemctl --no-block poweroff` at the end of its build script.

The script: starts the guest if it isn't running, waits up to
`START_TIMEOUT_S=180` seconds for SSH at `SSH_HOST` (typically a static
address declared in the guest's NixOS config), invokes
`systemctl start --wait <UNIT>` over SSH, then issues `qm shutdown`
(graceful, with `STOP_TIMEOUT_S=60` fallback to hard stop). If the
guest powered itself off mid-unit, ssh's 255 exit is treated as success
provided the unit didn't fail before the poweroff.

```sh
# Typical wiring from a systemd timer on the Proxmox host:
ExecStart=/path/to/infra-proxmox/lib/run-one-shot-on-vm.sh <VMID> <unit> <ssh-host>
```

## Non-interactive use

Both scripts honor environment variables that replace the confirmation prompt:

```sh
CONFIRM=yes ./lib/create-qemu-vm.sh ./myvm.env
DESTROY_TOKEN='destroy 900' ./lib/destroy-qemu-vm.sh ./myvm.env
```

The destroy token intentionally includes the VMID so that the env var cannot be left set in a shell and accidentally apply to a different VM.

## License

[AGPL-3.0-or-later](./LICENSE).
