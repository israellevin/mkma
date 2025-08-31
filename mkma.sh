#!/bin/bash -e

mkcleancd() {
    [ -d "$1" ] && rm -rf "$1"
    mkdir -p "$1"
    cd "$1"
}

mkchroot() {
    local chroot_dir="$1"
    shift

    if [ -f "$chroot_dir/sbin/init" ]; then
        cd "$chroot_dir"
    else
        mkcleancd "$chroot_dir"
    fi

    [ -e ./sbin/init ] && { echo chroot already exists >&2; return 1; }
    local packages; packages="$(echo "$@" | tr ' ' ',')"
    local suit=unstable
    local variant=minbase
    local components=main,contrib,non-free,non-free-firmware
    local extra_suits=stable
    local mirror=http://deb.debian.org/debian
    [ "$packages" ] && packages="--include=$packages"
    debootstrap --verbose --variant=$variant --components=$components --extra-suites=$extra_suits "$packages" \
        $suit . $mirror
}

mksys() {
    local host_name="$1"
    rm -rf ./lib/modules || true
    mkdir -p ./lib/modules
    cp -a --parents /lib/modules/"$(uname -r)" .

    systemd-firstboot --root . --reset
    systemd-firstboot --root . --force --copy --hostname="$host_name"

    insert_if_not_exists() {
        local file="$1"
        shift
        local line="$*"
        grep -q "^$line" "$file" || echo "$line" >> "$file"
    }

    insert_if_not_exists ./etc/pam.d/su auth sufficient pam_rootok.so
    insert_if_not_exists ./etc/hosts "127.0.0.1 $host_name"
    insert_if_not_exists ./etc/locale.gen "en_US.UTF-8 UTF-8"

    chroot . locale-gen || true
}

mkapt() {
    local packages="$*"

    mkdir -p ./fake
    for binary in initctl invoke-rc.d restart start stop start-stop-daemon service; do
        ln -s --backup ./bin/true ./fake/$binary
    done

    mkdir -p ./etc/apt
    cat > ./etc/apt/apt.conf <<'EOF'
APT::Install-Recommends "0";
APT::Install-Suggests "0";
EOF

    chroot . <<EOF
export PATH="/fake:\$PATH"
export DEBIAN_FRONTEND=noninteractive
apt update
apt --fix-broken install -y  # Sometimes debootstrap leaves broken packages.
apt install -y $packages || exit 1
apt clean
systemctl disable bluetooth
systemctl enable iwd
EOF

    rm -rf ./fake
}

mkdwl() {
    curl https://raw.githubusercontent.com/israellevin/dwl/refs/heads/master/Dockerfile > Dockerfile
    docker build -t dwl-builder .
    rm Dockerfile
    docker run --rm --name dwl-builder -dp 80:8000 dwl-builder
    chroot . sh -c 'curl localhost | tar -xC /'
}

mkuser() {
    [ -e ./home/i/src/dotfiles ] && { echo user already exists >&2; return 1; }
    echo auth sufficient pam_wheel.so trust >> ./etc/pam.d/su
    if [ -w ./etc/locale.gen ]; then
        echo en_US.UTF-8 UTF-8 > ./etc/locale.gen
        chroot . locale-gen || true
    fi

    chroot . <<'EOF'
groupadd audio
groupadd video
groupadd wheel
groupadd sudo
userdel --remove i
set -e
useradd --create-home --user-group --shell "$(type -p bash)" -G audio,video,wheel,sudo i
passwd -d root
passwd -d i
su -c '
    false
    set -e
    git clone https://github.com/israellevin/dotfiles.git ~/src/dotfiles
    sh -e ~/src/dotfiles/install.sh --non-interactive
' i
EOF

    reset  # The installation script runs vim and messes up the terminal.
}

mksession() {
    chroot . su -c 'mkdir -p ~/.config/systemd/user' i
    cat > ./home/i/.config/systemd/user/dwl.service <<'EOF'
[Unit]
Description=dwl
After=basic.target
ConditionPathExists=/dev/dri/renderD128

[Service]
ExecStart=/home/i/bin/dwlaunch.sh

[Install]
WantedBy=default.target
EOF

    # Allow user services to run without login, giving us a dwl auto-login.
    mkdir -p ./var/lib/systemd/linger
    touch ./var/lib/systemd/linger/i
    chroot . su -c 'systemctl --user enable dwl' i
}

mkcpio() {
    local level=$1
    find . -mount -print0 | pv -0 -l -s "$(find . | wc -l)" | cpio -o --null --format=newc | zstd -T0 "-$level"
}

mkinit() {
    # Consider moving to a separate file.
    cat <<'EOF' > ./init
#!/bin/sh

mkdir -p /dev
mount -t devtmpfs devtmpfs /dev

_log() {
    level=$1
    shift
    message="$(date) [mkma.sh init]: $@"
    echo "<$level>$message" > /dev/kmsg
}
info() { _log 6 "Info: $@"; }
error() { _log 3 "Error: $@"; }
emergency() { _log 2 "Emergency: $@"; /bin/sh; }

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
EOF

    chmod +x ./init
}

mkinitramfs() {
    local initramfs_dir="$1"
    local modules="$2"
    local binaries="$3"

    mkcleancd "$initramfs_dir"

    cp -a --parents /lib/modules/"$(uname -r)"/modules.dep .
    for required_module in $modules; do
        for dependency in $(modprobe --show-depends "$required_module" | grep -Po '^insmod \K.*$'); do
            mkdir -p ".$(dirname "$dependency")"
            cp -au --parents "$dependency" .
        done
    done

    mkdir -p ./bin
    for binary in $binaries; do
        binary="$(type -p "$binary")"
        cp -a "$binary" ./bin/.
        for library in $(ldd "$binary" 2> /dev/null | grep -o '/[^ ]*'); do
            cp -auL --parents "$library" .
        done
    done

    cd ./bin
    for applet in $(./busybox --list | grep -v busybox); do
        ln -s ./busybox "./$applet"
    done
    cd -

    mkinit
}

test_on_qemu() {
    local kernel_image="$1"
    local initramfs_image="$2"
    local images_dir="$3"
    local qemu_disk="$4"
    local ramdisk_size="$5"

    if [ ! -f "$qemu_disk" ]; then
        qemu-img create -f raw "$qemu_disk" "$ramdisk_size"
        mkfs.ext4 -F "$qemu_disk"
    fi
    mkdir -p ./mnt
    mount "$qemu_disk" ./mnt
    cp --parents "$images_dir/"*.zst ./mnt/.
    umount ./mnt
    rmdir ./mnt

    qemu_options=(
        -m "$ramdisk_size"
        -kernel "$kernel_image"
        -initrd "$initramfs_image"
        -append "console=tty root=/dev/ram0 init=/init mkma_images_device=/dev/vda mkma_images_path=$images_dir"
        -netdev 'user,id=mynet0'
        -device 'e1000,netdev=mynet0'
        -drive file="$qemu_disk,format=raw,if=virtio,cache=none"
        -enable-kvm
    )

    if [ "$MKMA_QEMU_VGA" ]; then
        qemu_options+=(
            -vga virtio
            -display 'sdl,gl=on'
        )
    fi

    qemu-system-x86_64 "${qemu_options[@]}"
}

mkma() {
    local host_name="${1:-$(hostname)}"
    local chroot_dir; chroot_dir="$(realpath ./chroot)"
    local initramfs_dir; initramfs_dir="$(realpath ./initramfs)"
    local base_image="$PWD/base.cpio.zst"
    local initramfs_image="$PWD/init.cpio.zst"
    local qemu_disk="$PWD/qemu.disk.raw"
    local initramfs_binaries=(busybox pv zstd)
    local initramfs_modules=(ext4 nvme overlay pci)
    local base_packages=(coreutils dbus dbus-broker dbus-user-session klibc-utils kmod systemd-sysv udev util-linux)
    local packages=("${base_packages[@]}"
        # Hardware support for my laptop.
        firmware-intel-* firmware-iwlwifi firmware-sof-signed intel-lpmd intel-media-va-driver-non-free intel-microcode
        # Common utilities.
        bc bsdextrautils bsdutils jq linux-perf mawk moreutils pciutils psmisc pv sed sudo ripgrep usbutils
        # CLI environment.
        bash bash-completion chafa console-setup git git-delta less locales man mc tmux vim
        # Compression and archive tools.
        cpio gzip tar unrar unzip zstd
        # Networking infrastructure.
        ca-certificates dhcpcd5 iproute2 netbase
        # Networking tools.
        aria2 curl iputils-ping iwd openssh-server rsync sshfs w3m wget
        # Development tools.
        debootstrap docker.io docker-cli make python3-pip python3-venv shellcheck
        # Media tools.
        bluez ffmpeg mpv pipewire-audio yt-dlp
        # Wayland support.
        libgles2 libinput10 libliftoff0 libseat1 libwayland-server0 seatd xdg-desktop-portal xdg-desktop-portal-wlr
        # X support.
        libxcb-composite0 libxcb-errors0 libxcb-ewmh2 libxcb-icccm4 libxcb-render-util0
        libxcb-render0 libxcb-res0 libxcb-xinput0 xwayland
        # GUI tools.
        cliphist foot firefox grim slurp wl-clipboard wlsunset wlrctl wmenu
        # GUI fonts.
        fonts-noto fonts-noto-color-emoji

    )
    if [ "$MKMA_QEMU_TEST" ]; then
        initramfs_modules+=(virtio_pci virtio_blk)
        if [ "$MKMA_QEMU_VGA" ]; then
            packages+=(mesa-utils libgl1-mesa-dri)
        fi
    fi

    mkchroot "$chroot_dir" "${base_packages[@]}" || true  # Allow re-running without breaking existing chroot.
    mksys "$host_name"

    # Mount `/proc` for installations.
    mount --bind /proc ./proc
    trap 'umount ./proc' EXIT INT TERM HUP

    mkapt "${packages[@]}"
    mkdwl
    mkuser || true  # Allow re-running without breaking existing user.
    mksession

    umount ./proc
    trap - EXIT INT TERM HUP

    mkcpio "$MKMA_COMPRESSION_LEVEL" > "$base_image"

    mkinitramfs "$initramfs_dir" "${initramfs_modules[*]}" "${initramfs_binaries[*]}"

    mkcpio "$MKMA_COMPRESSION_LEVEL" > "$initramfs_image"

    if [ "$MKMA_QEMU_TEST" ]; then
        echo Testing mkma on QEMU...
        test_on_qemu "/boot/vmlinuz-$(uname -r)" "$initramfs_image" "$(dirname "$base_image")" "$qemu_disk" 8G
    fi

    echo "kernel: /boot/vmlinuz-$(uname -r)"
    echo initramfs: "$initramfs_image"
    echo parameters: "mkma_images_device=$(df "$base_image" | grep -o '/dev/[^ ]*') mkma_images_path=$(dirname "$base_image")"
}

# Allow sourcing of functions for manual runs.
(return 0 2>/dev/null) || mkma "$@"
