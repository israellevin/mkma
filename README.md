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
