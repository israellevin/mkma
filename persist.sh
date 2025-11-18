#!/bin/sh -e
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

mountpoint="$(mktemp -d /mnt/mkma_persist.XXXXXX)"
mount "$storage_device" "$mountpoint"
mkma_dir="$mountpoint/$images_path"

persist_list="$mkma_dir/persist_list.txt"
persist_file="$mkma_dir/persistence.$(date +%Y%m%d_%H%M%S).cpio.zst"

cd /overlay/fresh
find . -mount > "$persist_list"
vi "$persist_list"
persist_count=$(wc -l < "$persist_list")
pv -ls "$persist_count" "$persist_list" | cpio -o --format=newc | zstd -T0 -19 > "$persist_file"
echo "Persistence snapshot saved to '$persist_file' and will be used on next boot."

umount "$mountpoint"
rmdir "$mountpoint"
rm "$persist_list"
