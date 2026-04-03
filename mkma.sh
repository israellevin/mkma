#!/bin/bash -Ee

mkline() {
    local file="$1"
    shift
    local line="$*"
    [ ! -d "$(dirname "$file")" ] && mkdir -p "$(dirname "$file")"
    [ ! -f "$file" ] && touch "$file"
    grep -q "^$line" "$file" || echo "$line" >> "$file"
}

mksys() {
    local host_name="$1"
    rm -rf ./lib/modules || true
    mkdir -p ./lib/modules
    cp -a --parents /lib/modules/"$(uname -r)" .
    echo "$host_name" > ./etc/hostname
    mkline ./etc/pam.d/su auth sufficient pam_rootok.so
    mkline ./etc/hosts "127.0.0.1 localhost"
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
apt install -y $packages || exit 1
apt clean
update-rc.d -f docker disable 2>/dev/null || true
EOF
    mkline ./etc/locale.gen "en_US.UTF-8 UTF-8"
    chroot . locale-gen || true
}

mkconfig() {
    # Remap damn copilot key as ctrl.
    cat > ./etc/keyd/default.conf <<'EOF'
[ids]
*
[main]
leftshift+leftmeta+f23 = layer(control)
EOF
    # Use uv to install Brave's adblocker Python bindings for qutebrowser (without `python3-pip`).
    chroot . <<'EOF'
if ! python3 -c 'import adblock' >/dev/null 2>&1; then
    uv_version="$(curl -fsSL https://astral.sh/uv/install.sh | grep APP_VERSION= | cut -d'"' -f2)"
    uv_base_url=https://releases.astral.sh/github/uv/releases/download
    curl -fsSL "$uv_base_url/$uv_version/uv-x86_64-unknown-linux-gnu.tar.gz" | \
        tar xz --strip-components=1 -C /tmp/
    /tmp/uv pip install --system --break-system-packages --no-cache-dir adblock
    rm -f /tmp/uv*
fi
EOF
    # Configure turnstile and fit it to POSIX shell.
    sed -i ./etc/turnstile/turnstiled.conf \
        -e 's|^backend =.*|backend = runit|' \
        -e 's|^manage_rundir =.*|manage_rundir = yes|'
    sed -i ./usr/libexec/turnstile/runit \
        -e 's|^exec pause$|exec sleep infinity|'
}

mkniri() {
    rm -rf niri-helpers
    git clone https://github.com/israellevin/niri-helpers.git --depth=1
    pushd niri-helpers
    mkniri_cmd=(
        ./mkniri.sh
        --repo https://github.com/israellevin/niri.git
        --branch focus-ignores-click
    )

    # The mkniri.sh script uses docker and this script is ususally run with sudo,
    # so to avoid messing up docker permissions we may need this little dance.
    if [ "$SUDO_USER" ] && [ "$(id -u)" -ne 0 ]; then
        mkdir build
        chown -R "$SUDO_USER" build
        sudo -u "$SUDO_USER" "${mkniri_cmd[@]}"
    else
        "${mkniri_cmd[@]}"
    fi

    cd ..
    mkdir -p ./usr/share/doc/ned/
    mv ./niri-helpers/build/ned_examples/ ./usr/share/doc/ned/examples/
    mv ./niri-helpers/{niriu.sh,/build/*} ./usr/local/bin/.
    rm -rf niri-helpers
    popd
}

mkuser() {
    local user="$1"
    chroot . <<EOF
set -e
groupadd -rf wheel
useradd --create-home --user-group --shell "\$(type -p bash)" -G \
    audio,bluetooth,clock,docker,input,plugdev,render,sudo,video,wheel "$user"
passwd -d root
passwd -d "$user"
su -c '
    git clone https://github.com/israellevin/dotfiles.git ~/src/dotfiles
    sh -e ~/src/dotfiles/install.sh --non-interactive
' "$user"
EOF
    # Passwordless su.
    echo auth sufficient pam_wheel.so trust >> ./etc/pam.d/su
    # Autologin on tty1.
    sed -e "s/^exec chpst -P getty /exec chpst -P getty -a '$user' /" -i ./etc/sv/getty-tty1/run
    # User services for dbus and pipewire.
    local service_directory="./home/$user/.config/service"
    mkdir -p "$service_directory"/{dbus,pipewire}/supervise
    cat > "$service_directory/dbus/check" <<'EOF'
#!/bin/sh
exec dbus-send --bus="unix:path=$XDG_RUNTIME_DIR/bus" / org.freedesktop.DBus.Peer.Ping > /dev/null 2>&1
EOF
    cat > "$service_directory/dbus/run" <<'EOF'
#!/bin/sh
: "${DBUS_SESSION_BUS_ADDRESS:=unix:path=/run/user/$(id -u)/bus}"
[ -d "$TURNSTILE_ENV_DIR" ] && echo "$DBUS_SESSION_BUS_ADDRESS" > \
    "$TURNSTILE_ENV_DIR"/DBUS_SESSION_BUS_ADDRESS
exec chpst -e "$TURNSTILE_ENV_DIR" \
    dbus-daemon --session --nofork --nopidfile --address="$DBUS_SESSION_BUS_ADDRESS"
EOF
    cat > "$service_directory/pipewire/run" <<'EOF'
#!/bin/sh -e
: "${XDG_RUNTIME_DIR:=/run/user/$(id -u)}"
[ -d "$TURNSTILE_ENV_DIR" ] && echo "$XDG_RUNTIME_DIR" > "$TURNSTILE_ENV_DIR"/XDG_RUNTIME_DIR
exec chpst -e "$TURNSTILE_ENV_DIR" /usr/bin/pipewire
EOF
    chmod +x "$service_directory/"{dbus,pipewire}/*
    chroot . chown -R "$user:$user" "$service_directory"
    # Configure pipewire to launch wireplumber (still debating pipewire-pulse).
    mkdir -p "./home/$user/.config/pipewire/pipewire.conf.d"
    echo 'context.exec = [ { path = "/usr/bin/wireplumber" args = "" } ]' > \
        "./home/$user/.config/pipewire/pipewire.conf.d/10-wireplumber.conf"
    chroot . chown -R "$user:$user" "./home/$user/.config/pipewire"
}

mkchroot() {
    local chroot_dir="$1"
    local host_name="$2"
    local packages=("${@:3}")

    if [ -d "$chroot_dir" ]; then
        echo using existing chroot >&2
    else
        mkdir -p "$chroot_dir"
        debootstrap --verbose --variant=minbase --components=main,contrib,non-free,non-free-firmware testing "$chroot_dir"
    fi
    pushd "$chroot_dir"
    mksys "$host_name"

    # Mount `/proc` for installations.
    mount --bind /proc "$chroot_dir/proc"
    # shellcheck disable=SC2064  # We want this to resolve now.
    trap "umount '$chroot_dir/proc'" EXIT

    mkapt "${packages[@]}"
    mkconfig
    if [ -x ./usr/local/bin/niri ]; then
        echo using existing niri >&2
    else
        mkniri
    fi
    if [ -d ./home/i ]; then
        echo using existing user >&2
    else
        mkuser i
    fi

    umount ./proc
    trap - EXIT
    popd
}

mkcpio() {
    local base_dir="$1"
    local level=$2
    pushd "$base_dir" > /dev/null 2>&1
    find . -mount -print0 | pv -0 -l -s "$(find . | wc -l)" | cpio -o --null --format=newc | zstd -T0 "-$level"
    popd > /dev/null 2>&1
}

mkinitramfs() {
    local initramfs_dir="$1"
    local init_file="$2"
    local modules="$3"
    local binaries="$4"

    rm -rf "$initramfs_dir" || true
    mkdir -p "$initramfs_dir"
    pushd "$initramfs_dir"

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
    cd ..

    cp "$init_file" ./init
    chmod +x ./init
    popd
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

    local linux_command_line='console=tty console=ttyS0 earlyprintk=tty earlyprintk=ttyS0 root=/dev/ram0 /init'
    linux_command_line+=' video=virtio_gpu'
    linux_command_line+=' mkma_storage_device=/dev/vda'
    linux_command_line+=" mkma_images_path=$images_dir"
    linux_command_line+=" mkma_images_path=$images_dir"


    qemu-system-x86_64 \
        -m "$ramdisk_size" \
        -kernel "$kernel_image" \
        -initrd "$initramfs_image" \
        -append "$linux_command_line" \
        -drive file="$qemu_disk,format=raw,if=virtio,cache=none" \
        -enable-kvm \
        -serial mon:stdio \
        -netdev 'user,id=mynet0' \
        -device 'e1000,netdev=mynet0' \
        -audiodev 'pipewire,id=audio0' \
        -device 'ich9-intel-hda' \
        -device 'hda-duplex,audiodev=audio0' \
        -display 'gtk,gl=on' \
        -device 'virtio-vga-gl'
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

    local packages=(
        # Base system (avoid accidentally installing systemd or something like that).
        runit-init systemctl systemd-standalone-sysusers
        # Hardware support for my laptop.
        firmware-intel-* firmware-iwlwifi firmware-sof-signed intel-lpmd intel-media-va-driver-non-free intel-microcode
        # Hardware tuning and performance.
        keyd kmod irqbalance numad
        # System administration.
        linux-perf pciutils psmisc strace sudo usbutils
        # CLI environment.
        bash-completion bc bsdextrautils git jq less locales man moreutils pv ripgrep socat vim zoxide
        # Terminal utils.
        chafa console-setup git-delta tmux
        # Archive, compression and cryptography tools.
        cpio gpg openssl unrar unzip zstd
        # Networking infrastructure.
        ca-certificates dhcpcd iproute2 netbase
        # Networking tools.
        aria2 curl iputils-ping iwd openssh-server rfkill rsync sshfs w3m wget
        # Media tools.
        bluez ffmpeg mpv pipewire-audio yt-dlp
        # Build tools.
        build-essential debootstrap docker.io docker-cli
        # Session support.
        libseat1 seatd
        # Wayland support.
        libgles2 libinput10 libliftoff0 libwayland-server0 xdg-desktop-portal-wlr xwayland
        # GUI tools.
        cliphist fonts-noto-color-emoji fonts-noto-core foot firefox-esr fnott grim
        libnotify-bin qutebrowser slurp wl-clipboard wlsunset wmenu ydotool
    )
    if [ "$MKMA_QEMU_TEST" ]; then
        initramfs_modules+=(virtio_pci virtio_blk)
    fi

    mkchroot "$chroot_dir" "$host_name" "${packages[@]}"
    cp -a "$persist_script" "$chroot_dir/sbin/persist.sh"
    mkcpio "$chroot_dir" "$MKMA_COMPRESSION_LEVEL" > "$base_image"

    mkinitramfs "$initramfs_dir" "$initramfs_init_file" "${initramfs_modules[*]}" "${initramfs_binaries[*]}"
    mkcpio "$initramfs_dir" "$MKMA_COMPRESSION_LEVEL" > "$initramfs_image"

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
