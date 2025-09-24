#!/bin/sh
# shellcheck disable=SC3040  # Supported by bysybox sh.

mkdir -p /dev
mount -t devtmpfs devtmpfs /dev

_log() {
    level=$1
    shift
    message="$(date) [mkma.sh init]: $*"
    echo "<$level>$message" > /dev/kmsg
}
info() { _log 6 "Info: $*"; }
error() { _log 3 "Error: $*"; }
emergency() { _log 2 "Emergency: $*"; /bin/sh; }

info Starting mkma init process

info Getting mkma parameters
mkdir -p /proc
mount -t proc proc /proc
# shellcheck disable=SC2013  # Reading words, not lines.
for arg in $(cat /proc/cmdline); do
    case "$arg" in
        mkma_storage_device=*)
            storage_device="${arg#mkma_storage_device=}"
            ;;
        mkma_images_path=*)
            images_path="${arg#mkma_images_path=/}"
    esac
done

mount_dir=/mnt
overlay_dir=/overlay
base_dir=$overlay_dir/base
work_dir=$overlay_dir/work
fresh_dir=$overlay_dir/fresh
merge_dir=$overlay_dir/merge
bind_dir=$merge_dir/overlay

info Mounting mkma tmpfs for mkma overlay on "$overlay_dir"
mkdir -p "$overlay_dir"
mount -t tmpfs -o size=8G tmpfs "$overlay_dir" || \
    emergency Could not mount tmpfs on "'$overlay_dir'"

info Creating mkma base directory on "$base_dir"
mkdir -p "$base_dir"
cd "$base_dir" || \
    emergency Could not change directory to "'$base_dir'"

info Mounting mkma images device "'$storage_device'" on "$mount_dir"
mkdir -p "$mount_dir"
modprobe nvme
modprobe crc32c_generic
modprobe ext4
modprobe virtio_blk || true  # Just for qemu testing.
modprobe virtio_pci || true  # Just for qemu testing.
mount "$storage_device" "$mount_dir" || \
    emergency Could not mount mkma images device "'$storage_device'" on "'$mount_dir'"
images_dir="$mount_dir/$images_path"


set -o pipefail

info Copying mkma base image data from "'$images_dir'" to "'$base_dir'"
pv -pterab "$images_dir"/base.cpio.zst | zstd -dcfT0 | cpio -id || \
    emergency Could not copy base image data from "'$images_dir'" to "'$base_dir'"

info Checking for mkma persistence images on "'$images_dir'"
for image in "$images_dir"/persistence.*.cpio.zst; do
    if [ -f "$image" ]; then
        info Copying mkma persistence image data from "'$image'" to "'$base_dir'"
        pv -pterab "$image" | zstd -dcfT0 | cpio -id || \
            error Could not copy persistence image data from "'$image'"
    fi
done

set +o pipefail

umount /mnt
umount /proc

info Mounting mkma overlayfs
mkdir -p "$fresh_dir" "$work_dir" "$merge_dir"
modprobe overlay || \
    emergency Could not load overlay module
mount -t overlay overlay -o lowerdir="$base_dir",upperdir="$fresh_dir",workdir="$work_dir" "$merge_dir" || \
    emergency "Could not mount overlayfs on '$merge_dir' with lower='$base_dir', upper='$fresh_dir', work='$work_dir'"

info Binding mkma overlay to merge directory in "$bind_dir"
mkdir -p "$bind_dir"
mount --bind "$overlay_dir" "$bind_dir" || \
    error "Could not bind mount '$merge_dir' to '$bind_dir' - overlay will not be accessible from new root"

info Moving to mkma root on "$merge_dir"
exec run-init "$merge_dir" /lib/systemd/systemd || \
    emergency Failed pivot to systemd on "$merge_dir"
