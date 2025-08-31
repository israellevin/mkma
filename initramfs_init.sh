#!/bin/sh

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
for arg in $(cat /proc/cmdline); do
    case "$arg" in
        mkma_images_device=*)
            mkma_images_device="${arg#mkma_images_device=}"
            ;;
        mkma_images_path=*)
            images_path="${arg#mkma_images_path=/}"
            ;;
    esac
done

overlay_dir=/overlay
info Mounting mkma tmpfs for mkma overlay on "$overlay_dir"
mkdir -p "$overlay_dir"
mount -t tmpfs -o size=8G tmpfs "$overlay_dir" || \
    emergency Could not mount tmpfs on "'$overlay_dir'"

mount_dir=/mnt
info Mounting mkma images device "'$mkma_images_device'" on "$mount_dir"
mkdir -p "$mount_dir"
modprobe nvme
modprobe crc32c_generic
modprobe ext4
modprobe virtio_blk || true  # Just for qemu testing.
modprobe virtio_pci || true  # Just for qemu testing.
mount "$mkma_images_device" "$mount_dir" || \
    emergency Could not mount mkma images device "'$mkma_images_device'" on "'$mount_dir'"
images_dir="$mount_dir/$images_path"

base_dir=/overlay/base
info Copying mkma base image data from "'$images_dir'" to "'$base_dir'"
mkdir -p "$base_dir"
cd "$base_dir"

set -o pipefail  # Supported by bysybox sh.
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

persistence_script="$base_dir/sbin/persist"
info Creating persistance script in "$persistence_script"
fresh_dir=/overlay/fresh
cat > "$persistence_script" <<EOIF
#!/bin/sh
persist_list=/tmp/mkma.persist.list
persist_file="\$PWD/persistence.\$(date +%Y-%m-%d-%H:%M).cpio.zst"

cd "$fresh_dir"
find . -mount > \$persist_list
vi \$persist_list
pv -ls \$(wc -l \$persist_list | cut -d' ' -f1) \$persist_list | cpio -o --format=newc | zstd -T0 -19 > \
    "\$persist_file"
EOIF
chmod +x "$persistence_script"

info Mounting mkma overlayfs
work_dir=/overlay/work
merge_dir=/overlay/merge
mkdir -p "$fresh_dir" "$work_dir" "$merge_dir"
modprobe overlay || \
    emergency Could not load overlay module
mount -t overlay overlay -o lowerdir="$base_dir",upperdir="$fresh_dir",workdir="$work_dir" "$merge_dir" || \
    emergency "Could not mount overlayfs on '$merge_dir' with lower='$base_dir', upper='$fresh_dir', work='$work_dir'"

bind_dir="$merge_dir/overlay"
info Binding mkma overlay to merge directory in "$bind_dir"
mkdir -p "$bind_dir"
mount --bind "$overlay_dir" "$bind_dir" || \
    error "Could not bind mount '$merge_dir' to '$bind_dir' - overlay will not be accessible from new root"

info Moving to mkma root on "$merge_dir"
exec run-init "$merge_dir" /lib/systemd/systemd || \
    emergency Failed pivot to systemd on "$merge_dir"
