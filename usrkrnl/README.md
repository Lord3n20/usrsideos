# usrkrnl

The UsrsideOS kernel: **built for exactly one machine**, minimal, fast to boot,
a little more responsive, and without initramfs or bootloader.

usrkrnl is upstream Linux stable (version: `KVER` in [`setup`](setup)) plus:

| Change | Effect |
|---|---|
| [BORE](https://github.com/CachyOS/kernel-patches) scheduler ([`patches/`](patches/)) | interactive tasks win over background load (desktop stays smooth while compiling) |
| clang + ThinLTO, `-march=native` | a few percent faster in kernel-heavy work |
| `HZ_1000`, full preemption, `NO_HZ_IDLE` | low latency without the overhead of `NO_HZ_FULL` |
| no debug info, no BTF (and so no sched_ext) | faster build, far less memory (pahole was OOM-killed on 8 GB), smaller tree |
| localmodconfig per machine | only the drivers your hardware actually uses |
| root disk + filesystem drivers built in, microcode embedded, command line compiled in | boots directly from UEFI (EFI stub), no initramfs, no bootloader |

There is no generic binary and no kernel fork: this folder only holds the config
fragment ([`usrkrnl.config`](usrkrnl.config)), the patches and the `setup` script.

## Requirements

- x86_64 with UEFI, root filesystem on a plain GPT partition
  (no LUKS/LVM/RAID: those need an initramfs)
- Any distribution (package hints for Arch, Void and Gentoo built in; sudo or doas):
  `clang lld llvm make bc flex bison perl pahole cpio`, openssl + libelf headers, `zstd curl efibootmgr`,
  optionally `dkms` for out-of-tree drivers (nvidia, ...); on Gentoo `emerge @module-rebuild` is run instead

## Usage

```sh
# plug in and use every device you need first (USB sticks, dock, eGPU, webcam ...)
usrkrnl/setup --bootnext
reboot
```

`setup` downloads Linux `KVER` from kernel.org (checked against kernel.org's
sha256sums), applies `patches/*.patch` and keeps the tree in
`~/.local/src/usrkrnl/linux-KVER` (`USRKRNL_SRC` changes the place, `--tree DIR`
uses an existing patched tree). Then it takes the config of the running kernel,
reduces it to the modules in use, applies `usrkrnl.config`, builds the drivers of
your root disk into the kernel, embeds the CPU microcode and your current kernel
command line, builds (one job per thread, at most one per GiB of available memory), installs modules (+ DKMS) and copies the image to
`ESP/EFI/usrkrnl/vmlinuz-usr.efi`.

It also copies the image to `ESP/EFI/BOOT/BOOTX64.EFI`, the path the firmware
starts when its boot entries are gone (BIOS reset), but only if nothing else is
there or the file is an earlier copy of its own (checksum in
`ESP/EFI/usrkrnl/bootx64.sha256`).

A UEFI boot entry is created but **not** added to the boot order.
`--bootnext` boots it once; if that fails, the next reboot uses your old kernel.
When it works, make it the default (UsrsideOS does this with `usrkrnl-confirm`):

```sh
sudo efibootmgr -o XXXX,<old order>   # XXXX = the usrkrnl entry
```

Other options: `--config-only`, `--no-install`, `--base FILE`, `--modules FILE`,
`--extra FRAGMENT`, `--label NAME`, `--cmdline "ARGS"`, `--reminimize`, `--tree DIR`
(see `usrkrnl/setup --help`).

### Modules you need later

Every run remembers all loaded modules in `~/.config/usrkrnl/modules`
(and reads `~/.config/modprobed.db` if you use modprobed-db), so a device that
was used once stays supported. Missing something? Boot your old kernel, use the
device, run `usrkrnl/setup --reminimize` again.

## Updating to a new kernel

Raise `KVER` in `setup`, check that `patches/` still apply (new BORE version from
CachyOS if not), commit. On each machine: `git pull && usrkrnl/setup`.
Old trees in `~/.local/src/usrkrnl` can be deleted once the new kernel boots.

## Battery and performance

Measured expectations, not guarantees: BORE gives the most noticeable gain
(responsiveness under load). Native + ThinLTO add a few percent in kernel-heavy
workloads. `NO_HZ_IDLE` instead of `NO_HZ_FULL` saves a little overhead. Battery
life stays the same or gets slightly better. `HZ_1000` costs well under 1 %.

## Credits

- Linux kernel: Linus Torvalds and all contributors (GPL-2.0)
- BORE: Masahito Suzuki, packaged by CachyOS (Piotr Gorski, Peter Jung)
