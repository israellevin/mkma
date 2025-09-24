# mkma.sh - Make a GNU/Linux machine the way I like it

Currently this is a debian, systemd, into-RAM bootable image.

- `./initramfs_init.sh` is an init script which loads mkma images into RAM upon boot.
- `./mkma.sh` is a script to create and test mkma base images and initramfs images.

The script respects the following environment variables:
- `MKMA_COMPRESSION_LEVEL` (default: `3`) - Compression level for `zstd` compression of the images
- `MKMA_QEMU_TEST` (default: unset) - If set to `1` the script will run the created image in QEMU for testing (note: this will add a couple of modules to the initramfs image)
- `MKMA_QEMU_VGA` (default: unset) - If set to `1` the script will run QEMU with a VGA display instead of serial console (note: this will add a couple of debian packages to the base image)

## Usage

```bash
sudo ./mkma.sh <optional hostname (default: hostname of the building machine)>
```

The script will create a `base.cpio.zst` file with the configured system, and an `initramfs.cpio.zst` file with the initial filesystem for booting into RAM. To boot into the created image you will need to configure your bootloader to boot the current kernel with the generated `initramfs.cpio.zst` file and the following kernel command line options:

- `mkma_storage_device` - the device where the `base.cpio.zst` file is stored (e.g. `/dev/nvme0n1p3`)
- `mkma_images_path` - the path where the `base.cpio.zst` file is stored (e.g. `/home/user/mkma_images`)

For `/etc/default/grub` you would add something like this:

```
GRUB_CMDLINE_LINUX_DEFAULT="mkma_images_device=/dev/... mkma_images_path=/home/..."
```

Then run `sudo update-grub` and reboot.

The script will also create a `chroot` directory and an `initramfs` directory which you can play with and investigate.

If you use the `MKMA_QEMU_TEST` environment variable the script will also run the created image in QEMU for testing and will also create a `qemu.disk.raw` file with a raw disk image for QEMU.

## Persistence

Before booting into the system, the init script creates an overlay filesystem in RAM on top of the base image, isolating any changes made to the system from the base image. These changes are written to the `/overlay/fresh` directory in RAM, and - by default - are lost when the system is powered off.

However, there are two types of persistence that can easily be implemented - manual persistence, which allows me to pick specific changes and select them to be loaded into the base (read-only) directory of the overlay, and automatic  persistence, which consists of mounting additional overlay layers on top of any directory I want to be persistent.

### Read-only persistence

Since all changes from the base system are written to the `/overlay/fresh` directory, I can easily pick and choose which changes I want to be persistent by creating a cpio archive of the selected files and directories in the `/overlay/fresh` directory, and then placing that archive in the same directory as the `base.cpio.zst` file.

```sh
#!/bin/sh
persist_list=/tmp/mkma.persist.list
persist_file="\$PWD/persistence.\$(date +%Y-%m-%d.%H:%M).cpio.zst"
cd "$fresh_dir"
find . -mount > \$persist_list
vi \$persist_list
pv -ls \$(wc -l \$persist_list | cut -d' ' -f1) \$persist_list | cpio -o --format=newc | zstd -T0 -19 > "\$persist_file"
```

During early boot, right after the base image is loaded into RAM, the init script will check for the existence of a `persistence.*.cpio.zst` files in the same directory as the `base.cpio.zst` file. Any such files will be loaded into RAM on top of the base image, one after the other.


### Automatic persistence

For directories that I want to be automatically persistent, I create additional overlay.

```sh
#!/bin/sh

for directory in etc home opt usr var; do
    mountpoint="/$directory"
    lower="/mnt/home/user/mkma_persistence/$directory/lower"
    upper="/mnt/home/user/mkma_persistence/$directory/upper"
    work="/mnt/home/user/mkma_persistence/$directory/work"

    mkdir -p "$lower" "$upper" "$work"

    mount --bind "/$directory" "$lower"

    mount -t overlay overlay -o lowerdir="$lower",upperdir="$upper",workdir="$work" "$mountpoint"
done
```

Mounting `/usr` and even `/etc` at a late stage could cause issues, so perhaps this is best done as an early service, as soon as `/mnt` is mounted, but on my minimal system it seems to work fine.
