#!/bin/bash -e

mkcleancd() {
    [ -d "$1" ] && rm -rf "$1"
    mkdir -p "$1"
    cd "$1"
}

mkline() {
    local file="$1"
    shift
    local line="$*"
    [ ! -d "$(dirname "$file")" ] && mkdir -p "$(dirname "$file")"
    [ ! -f "$file" ] && touch "$file"
    grep -q "^$line" "$file" || echo "$line" >> "$file"
}

mkchroot() {
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

    mkline ./etc/pam.d/su auth sufficient pam_rootok.so
    mkline ./etc/hosts "127.0.0.1 $host_name"
}

mkapt() {
    local packages="$*"

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
systemctl enable iwd.service
EOF

    # Fucking copilot key (now that keyd is installed).
    cat > ./etc/keyd/default.conf <<'EOF'
[ids]
*
[main]
leftshift+leftmeta+f23 = layer(control)
EOF

    mkline ./etc/locale.gen "en_US.UTF-8 UTF-8"
    chroot . locale-gen || true
}

mkdwl() {
    curl https://raw.githubusercontent.com/israellevin/dwl/refs/heads/master/Dockerfile > Dockerfile
    # If run with sudo and not with root, make sure not to screw up docker file permissions.
    ${SUDO_USER:+sudo -u "$SUDO_USER"} docker build -t dwl-builder .
    ${SUDO_USER:+sudo -u "$SUDO_USER"} docker run --rm --name dwl-builder -dp 80:8000 dwl-builder
    chroot . sh -c 'curl localhost | tar -xC / && ldconfig'
    rm Dockerfile
}

mkuser() {
    chroot . <<'EOF'
groupadd wheel
userdel --remove i
set -e
useradd --create-home --user-group --shell "$(type -p bash)" -G \
    audio,bluetooth,clock,docker,plugdev,render,sudo,video,wheel i
passwd -d root
passwd -d i
su -c '
    false
    set -e
    git clone https://github.com/israellevin/dotfiles.git ~/src/dotfiles
    sh -e ~/src/dotfiles/install.sh --non-interactive
' i
EOF
    echo auth sufficient pam_wheel.so trust >> ./etc/pam.d/su
    reset  # The installation script runs vim and messes up the terminal.
}

mksession() {
    mkdir -p ./etc/systemd/system/getty@tty1.service.d
    cat > ./etc/systemd/system/getty@tty1.service.d/override.conf <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin i --noreset --noclear - ${TERM}
Type=simple
EOF
}

mkcpio() {
    local level=$1
    find . -mount -print0 | pv -0 -l -s "$(find . | wc -l)" | cpio -o --null --format=newc | zstd -T0 "-$level"
}

mkinitramfs() {
    local initramfs_dir="$1"
    local init_file="$2"
    local modules="$3"
    local binaries="$4"

    mkcleancd "$initramfs_dir"

    for required_module in $modules; do
        for dependency in $(modprobe --show-depends "$required_module" | grep -Po '^insmod \K.*$'); do
            mkdir -p ".$(dirname "$dependency")"
            cp -au --parents "$dependency" .
        done
    done
    depmod -m "$(realpath ./lib/modules)"

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

    cp "$init_file" ./init
    chmod +x ./init
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
        -append "console=tty root=/dev/ram0 init=/init mkma_storage_device=/dev/vda mkma_images_path=$images_dir"
        -netdev 'user,id=mynet0'
        -device 'e1000,netdev=mynet0'
        -drive file="$qemu_disk,format=raw,if=virtio,cache=none"
        -enable-kvm
    )

    if [ "$MKMA_QEMU_DRI" ]; then
        qemu_options+=(
            -vga virtio
            -display 'sdl,gl=on'
        )
    fi

    qemu-system-x86_64 "${qemu_options[@]}"
}

mkma() {
    local host_name="${1:-$(hostname)}"
    local chroot_dir="$PWD/chroot"
    local initramfs_dir="$PWD/initramfs"
    local initramfs_init_file="$PWD/initramfs_init.sh"
    local persist_script="$PWD/persist.sh"
    local initramfs_image="$PWD/init.cpio.zst"
    local base_image="$PWD/base.cpio.zst"
    local qemu_disk="$PWD/qemu.disk.raw"
    local initramfs_binaries=(busybox pv zstd)
    local initramfs_modules=(ext4 nvme overlay pci)
    local base_packages=(coreutils dbus-broker systemd-sysv udev util-linux)
    local packages=("${base_packages[@]}"
        # Hardware support for my laptop.
        firmware-intel-* firmware-iwlwifi firmware-sof-signed intel-lpmd intel-media-va-driver-non-free intel-microcode
        # System utilities.
        kmod irqbalance numad systemd-timesyncd
        # Common utilities.
        bc bsdextrautils bsdutils jq linux-perf mawk moreutils pciutils psmisc pv sed sudo ripgrep usbutils
        # CLI environment.
        bash bash-completion chafa console-setup git git-delta keyd less locales man mc tmux vim
        # Compression and archive tools.
        cpio gzip tar unrar unzip zstd
        # Networking infrastructure.
        ca-certificates dhcpcd5 iproute2 netbase
        # Networking tools.
        aria2 curl iputils-ping iwd openssh-server rfkill rsync sshfs w3m wget
        # Development tools.
        debootstrap docker.io docker-cli make python3-pip python3-venv shellcheck
        # Media tools.
        bluez ffmpeg mpv pipewire-audio yt-dlp
        # Session support.
        dbus-bin dbus-user-session libseat1 polkitd rtkit
        # Wayland support.
        libgles2 libinput10 libliftoff0 libwayland-server0 xdg-desktop-portal xdg-desktop-portal-wlr
        # X support.
        libxcb-composite0 libxcb-errors0 libxcb-ewmh2 libxcb-icccm4 libxcb-render-util0
        libxcb-render0 libxcb-res0 libxcb-xinput0 xwayland
        # GUI tools.
        cliphist fonts-noto-color-emoji fonts-noto-core foot firefox grim slurp wl-clipboard wlsunset wlrctl wmenu
    )
    if [ "$MKMA_QEMU_TEST" ]; then
        initramfs_modules+=(virtio_pci virtio_blk)
        if [ "$MKMA_QEMU_DRI" ]; then
            packages+=(mesa-utils libgl1-mesa-dri)
        fi
    fi

    # Allow keeping the chroot between runs for faster testing.
    if [ -f "$chroot_dir/sbin/init" ]; then
        cd "$chroot_dir"
        echo chroot already exists >&2
    else
        mkcleancd "$chroot_dir"
        mkchroot "${base_packages[@]}"
    fi

    mksys "$host_name"
    cp -a "$persist_script" ./sbin/persist.sh

    # Mount `/proc` for installations.
    mount --bind /proc ./proc
    trap 'umount ./proc' EXIT INT TERM HUP

    mkapt "${packages[@]}"
    mkdwl
    # Allow keeping the user between runs for faster testing.
    if [ -f ./home/i/src/dotfiles/install.sh ]; then
        echo user already exists >&2
    else
        mkuser
    fi
    mksession

    umount ./proc
    trap - EXIT INT TERM HUP

    mkcpio "$MKMA_COMPRESSION_LEVEL" > "$base_image"

    mkinitramfs "$initramfs_dir" "$initramfs_init_file" "${initramfs_modules[*]}" "${initramfs_binaries[*]}"

    mkcpio "$MKMA_COMPRESSION_LEVEL" > "$initramfs_image"

    if [ "$MKMA_QEMU_TEST" ]; then
        echo Testing mkma on QEMU...
        test_on_qemu "/boot/vmlinuz-$(uname -r)" "$initramfs_image" "$(dirname "$base_image")" "$qemu_disk" 16G
    fi

    echo "kernel: /boot/vmlinuz-$(uname -r)"
    echo initramfs: "$initramfs_image"
    echo parameters: "mkma_storage_device=$(df "$base_image" | grep -o '/dev/[^ ]*') mkma_images_path=$(dirname "$base_image")"
}

# Allow sourcing of functions for manual runs.
(return 0 2>/dev/null) || mkma "$@"
