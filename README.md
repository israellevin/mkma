# mkma.sh - Make a GNU/Linux machine the way I like it

A simple set of scripts to create a minimal bootable GNU/Linux system image that loads entirely into RAM upon boot, with optional persistence layers. Currently based on debian with systemd-sysv, dbus-broker, wayland, pipewire and niri.

## Contents

- `./initramfs_init.sh`: extracts and mounts mkma images into a RAM based overlay filesystem during early boot (as the init script of the initramfs)
- `./mkma.sh`: creates and tests mkma images
- `./persist.sh`: creates a read-only persistence image from selected changes made to the system

## Usage

```shell
sudo ./mkma.sh <optional hostname (default: hostname of the building machine)>
```

The script respects the following environment variables:
- `MKMA_COMPRESSION_LEVEL` (default: `3`) - Compression level for `zstd` compression of the images
- `MKMA_QEMU_TEST` (default: unset) - If set to `1` the script will run the created image in QEMU for testing (note: this will also add a couple of modules to the initramfs image)

The script will create a `base.cpio.zst` file with the configured system, and an `initramfs.cpio.zst` file with the initial filesystem required to extracts the base image into a RAM based overlay filesystem during early boot. If you have `MKMA_QEMU_TEST` set to `1` (highly recommended when testing new configurations) it will then run the created image in QEMU for testing.

To actually boot your machine from the created image you will need to configure your bootloader to boot the current kernel with the generated `initramfs.cpio.zst` file and the following kernel command line options (the script will output the correct values for you):

- `mkma_storage_device` - the device where the `base.cpio.zst` file is stored (e.g. `/dev/nvme0n1p3`)
- `mkma_images_path` - the path where the `base.cpio.zst` file is stored (e.g. `/home/user/mkma_images`)

The full kernel command line will look something like this (replace the values with the ones output by the script):

```shell
linux /boot/vmlinuz-6.16.11-1-liquorix-amd64 root=/dev/nvme0n1p3 mkma_storage_device=/dev/nvme0n1p3 mkma_images_path=/home/user/mkma_images
initrd /home/user/mkma_images/initramfs.cpio.zst
```

The script will also create a `chroot` and an `initramfs` directories which you can chroot into, play with and investigate.

## Persistence

By default, any changes made to the system during runtime are lost when the system is powered off, since the entire system runs from RAM. However, when copying the base image from the storage device into RAM, the initramfs creates an overlay filesystem in RAM so that a copy of the base image remains untouched (overlay lowerdir) and any changes made to the system are written to `/overlay/fresh` (overlay upperdir). This makes it very easy to create a snapshot of selected changes made to the system during runtime and load it automatically on top of the base image during future boots.

```sh
sudo ./persist.sh
```

The script automatically mounts the `mkma_storage_device` specified in the kernel command line and writes a list files and directories that have been changed since boot (the content of the `/overlay/fresh` directory) to a temporary file in its `mkma_images_path` directory. This file is then opened with an editor so that unwanted entries can be deleted. Once the editor is exited the script creates a compressed cpio archive named `persistence.<timestamp>.cpio.zst` in the `mkma_images_path` directory and unmounts the `mkma_storage_device`.

During early boot, right after the base image is loaded into RAM, the init script checks for the existence of a `persistence.*.cpio.zst` files in the same directory, extracting the content of found files on top of the base image one after the other before handing over control to the real init system. This way, any changes saved in the persistence images are automatically applied on top of the base image during boot.

### Considerations

This method concentrates the usage of the storage device and any overhead associated with it to specific moments in time (snapshot creation and loading), which means all the moments in between are pure RAM. It also means that all the moments in between are lost in case of power loss.

This method needs to be used selectively as it loads the entire snapshot into RAM during boot (the current size limit imposed by the initramfs is 50% of the available RAM for the entire root filesystem, but this is easy enough to change),
That's why the current implementation has a manual editing step to remove unwanted entries.

Bottom line: if you want to persist your local environment, a few carefully installed packages and some configuration files, this is the way to go. I may even automate it at some point, use hard coded filters instead of manual editing and run it according to some twisted logic involving time since last snapshot and available resources. If, however, you need to persist larger amounts of data in a more continuous manner, just mount a storage device and use it directly.

And if you find that you need files that are constantly in flux (like databases and caches) to be continuously persisted, then mkma is probably not the right tool for you.
