#!/bin/bash -Ee

# mkzolo.sh - Make a zolo machine: a mkma image that boots straight into a
# running zOS engine (https://github.com/ZoloAi/zOS, `pip install zolo-os`).
#
# Purely additive: sources mkma.sh for its primitives (mkfile/mkline/mksys/
# mkcpio/mkinitramfs) and changes none of them. The result is the same
# boot-into-RAM contract as mkma — immutable base, overlay in RAM, selective
# persistence — with the zolo runtime baked into the base image and a demo
# app served by systemd from first boot. A private cloud in the only honest
# sense of the word: your server, your RAM, no accounts, no website.
#
# Layering doctrine (matches mkma's own persistence advice): the ENGINE is
# immutable and lives in the base image; app DATA (sqlite, "files constantly
# in flux") does not belong in the RAM overlay — mount a real storage device
# for any app whose data must survive power-off. The demo app keeps no data,
# so the image stays pure.
#
# Usage (build in a separate directory from a plain mkma build — the image
# file names are shared with mkma.sh on purpose, initramfs_init.sh expects
# them):
#
#     sudo ./mkzolo.sh <optional hostname (default: zolo)>
#
# Respected environment variables:
# - MKMA_COMPRESSION_LEVEL (default: 3)  - zstd level for the images
# - MKMA_QEMU_TEST         (default: unset) - if 1, boot the image headless
#   in QEMU and verify the zolo engine actually serves HTTP from RAM
# - ZOLO_VERSION           (default: latest from PyPI) - zolo-os version pin

. "$(dirname "$0")/mkma.sh"

ZOLO_PYTHON=3.13

mkapt_zolo() {
    # Lean server set — no GUI, no wifi, no laptop firmware. dhcpcd for DHCP
    # on wired/cloud NICs; openssh-server enables itself on install.
    local packages="$*"
    mkfile ./etc/apt/apt.conf <<'EOF'
APT::Install-Recommends "0";
APT::Install-Suggests "0";
EOF
    chroot . <<EOF
export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y $packages || exit 1
apt clean
systemctl enable dhcpcd.service
EOF
    mkline ./etc/locale.gen "en_US.UTF-8 UTF-8"
    chroot . locale-gen || true
}

mkzolouser() {
    # Plain passwordless user, same autologin ergonomics as mkma's mkuser but
    # without the personal dotfiles — swap in mkuser from mkma.sh if you want
    # the full treatment.
    local user="$1"
    chroot . <<EOF
set -e
groupadd -rf wheel
useradd --create-home --user-group --shell "\$(type -p bash)" -G sudo,wheel "$user"
passwd -d root
passwd -d "$user"
EOF
    mkline ./etc/pam.d/su auth sufficient pam_wheel.so trust
    mkfile ./etc/systemd/system/getty@tty1.service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $user --noreset --noclear - \${TERM}
Type=simple
EOF
}

mkzolo_runtime() {
    # zolo needs CPython ${ZOLO_PYTHON}; debian testing's python3 moves, so use a
    # uv-managed interpreter pinned in /opt — the same uv trick mkma's
    # mkconfig already uses, kept permanently at /usr/local/bin/uv.
    local user="$1"
    local version_pin="${ZOLO_VERSION:+==$ZOLO_VERSION}"
    chroot . <<EOF
set -e
if [ ! -x /usr/local/bin/uv ]; then
    uv_version="\$(curl -fsSL https://astral.sh/uv/install.sh | grep APP_VERSION= | cut -d'"' -f2)"
    uv_base_url=https://releases.astral.sh/github/uv/releases/download
    curl -fsSL "\$uv_base_url/\$uv_version/uv-x86_64-unknown-linux-gnu.tar.gz" | \
        tar xz --strip-components=1 -C /usr/local/bin/
    rm -f /usr/local/bin/uvx
fi
export UV_PYTHON_INSTALL_DIR=/opt/uv/python
uv python install $ZOLO_PYTHON
uv venv --python $ZOLO_PYTHON /opt/zolo
uv pip install --python /opt/zolo/bin/python --no-cache-dir zolo-os$version_pin
ln -sf /opt/zolo/bin/z /usr/local/bin/z
ln -sf /opt/zolo/bin/zolo /usr/local/bin/zolo
# Provision the zGuard engine binaries into the user's data dir at BUILD
# time, so first boot needs no network and no ceremony.
su -c 'z patch' "$user"
EOF
}

mkzolo_app() {
    # The smallest possible zOS app (zolo's own golden zHello), baked in and
    # served by systemd from boot. Replace the app directory with your own
    # and repoint the unit — the engine doesn't care.
    local user="$1"
    local app_dir="./home/$user/zhello"

    mkfile "$app_dir/zSpark.zhello.zolo" <<'EOF'
# .zolo — NOT YAML: string-first, no quotes needed, indentation-only nesting.

zSpark:
    title:     Hello World
    zMode:     zBifrost
    zLog:      INFO
    zLogPath:  @.logs
    zVaFolder: @.zViews
    zVaFile:   zUI.zhello
    zBlock:    zVaF
    zServer:
        enabled: true

zInfo:
    description: Golden reference — smallest possible zOS app
    tags: [zH1, zText]
    author: zAgents
EOF

    mkfile "$app_dir/zViews/zUI.zhello.zolo" <<'EOF'
# .zolo — NOT YAML: string-first, no quotes needed, indentation-only nesting.

zMeta:
    zNavBar: false

zVaF:
    zH1:
        label: Hello World
        color: PRIMARY

    zText:
        content: A minimal zOS app, served from RAM.

    ~Greeting_Actions*: [Say_Hello, Say_Goodbye]

    Say_Hello:
        zModal:
            zH2:
                label: Hello, Zolo!
            zText:
                content: Greetings from a mkma machine.

    Say_Goodbye:
        zModal:
            zH2:
                label: Goodbye, Zolo!
            zText:
                content: Power off and I was never here. Persist me and I was.
EOF

    chroot . chown -R "$user:$user" "/home/$user/zhello"

    mkfile ./etc/systemd/system/zolo-hello.service <<EOF
[Unit]
Description=zolo demo app (zHello)
After=network.target

[Service]
User=$user
WorkingDirectory=/home/$user/zhello
# Bind beyond loopback: this is a server image — the app should be reachable
# from the LAN (and from QEMU's hostfwd during the build test). The spark
# stays silent on hosts, so these env floors apply (zOS config cascade:
# spark king -> env floor -> loopback default).
Environment=HTTP_HOST=0.0.0.0
Environment=WEBSOCKET_HOST=0.0.0.0
ExecStart=/usr/local/bin/z zSpark.zhello.zolo
Restart=on-failure
# Console too, so the engine's ready banner and port announcement are
# visible on the serial console (and in the QEMU test log).
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF
    chroot . systemctl enable zolo-hello.service
}

mkchroot_zolo() {
    local chroot_dir="$1"
    local host_name="$2"
    local user="$3"
    local packages=("${@:4}")

    if [ -d "$chroot_dir" ]; then
        echo using existing chroot >&2
    else
        mkdir -p "$chroot_dir"
        debootstrap --verbose --variant=minbase --components=main,contrib,non-free,non-free-firmware testing "$chroot_dir"
    fi
    pushd "$chroot_dir"
    mksys "$host_name"

    mount --bind /proc "$chroot_dir/proc"
    # shellcheck disable=SC2064  # We want this to resolve now.
    trap "umount '$chroot_dir/proc'" EXIT

    mkapt_zolo "${packages[@]}"
    if [ -d "./home/$user" ]; then
        echo using existing user >&2
    else
        mkzolouser "$user"
    fi
    if [ -x ./opt/zolo/bin/z ]; then
        echo using existing zolo runtime >&2
    else
        mkzolo_runtime "$user"
    fi
    mkzolo_app "$user"

    umount ./proc
    trap - EXIT
    popd
}

test_zolo_on_qemu() {
    # Headless twin of mkma's test_on_qemu: serial console to a log file, no
    # display, no audio, KVM only when actually available (TCG otherwise, so
    # it runs on cloud build hosts too). PASSES only when the engine inside
    # the RAM-booted guest answers real HTTP through the forwarded port.
    local kernel_image="$1"
    local initramfs_image="$2"
    local images_dir="$3"
    local qemu_disk="$4"
    local ramdisk_size="$5"
    local serial_log="$6"

    if [ ! -f "$qemu_disk" ]; then
        qemu-img create -f raw "$qemu_disk" "$ramdisk_size"
        mkfs.ext4 -F "$qemu_disk"
    fi
    mkdir -p ./mnt
    mount "$qemu_disk" ./mnt
    cp --parents "$images_dir/"*.zst ./mnt/.
    umount ./mnt
    rmdir ./mnt

    local linux_command_line='console=ttyS0 earlyprintk=ttyS0 root=/dev/ram0 /init'
    linux_command_line+=' mkma_storage_device=/dev/vda'
    linux_command_line+=" mkma_images_path=$images_dir"

    local kvm_flags=()
    [ -w /dev/kvm ] && kvm_flags=(-enable-kvm -cpu host)

    : > "$serial_log"
    qemu-system-x86_64 \
        -m "$ramdisk_size" \
        "${kvm_flags[@]}" \
        -kernel "$kernel_image" \
        -initrd "$initramfs_image" \
        -append "$linux_command_line" \
        -drive "file=$qemu_disk,format=raw,if=virtio,cache=none" \
        -serial "file:$serial_log" \
        -display none \
        -netdev 'user,id=mynet0,hostfwd=tcp:127.0.0.1:18080-:8080' \
        -device 'e1000,netdev=mynet0' &
    local qemu_pid=$!
    # shellcheck disable=SC2064  # We want this to resolve now.
    trap "kill $qemu_pid 2>/dev/null || true" EXIT

    echo "Waiting for the zolo engine to come up inside QEMU (log: $serial_log)..."
    local deadline=$((SECONDS + 1200)) verdict=FAIL
    while [ "$SECONDS" -lt "$deadline" ]; do
        if curl -sf -o /dev/null --max-time 5 http://127.0.0.1:18080/; then
            verdict=PASS
            break
        fi
        kill -0 "$qemu_pid" 2>/dev/null || break
        sleep 5
    done

    kill "$qemu_pid" 2>/dev/null || true
    trap - EXIT
    echo "zolo QEMU test: $verdict"
    grep -a 'zServer Ready\|\[zOS\]' "$serial_log" | tail -5 || true
    [ "$verdict" = PASS ]
}

mkzolo() {
    local host_name="${1:-zolo}"
    local user=i
    local chroot_dir="$PWD/chroot"
    local initramfs_dir="$PWD/initramfs"
    local initramfs_init_file="$(dirname "$0")/initramfs_init.sh"
    local persist_script="$(dirname "$0")/persist.sh"
    local initramfs_image="$PWD/init.cpio.zst"
    local base_image="$PWD/base.cpio.zst"
    local qemu_disk="$PWD/qemu.disk.raw"
    local serial_log="$PWD/qemu.serial.log"
    local initramfs_binaries=(busybox pv zstd)
    local initramfs_modules=(ext4 nvme overlay pci)

    local packages=(
        # Base system choices (just to avoid debian defaults).
        dbus-broker systemd-sysv
        # System administration.
        kmod pciutils psmisc sudo
        # CLI environment.
        bash-completion git less locales man-db pv vim
        # Archive and compression tools.
        cpio unzip zstd
        # Networking.
        ca-certificates curl dhcpcd iproute2 iputils-ping netbase openssh-server rsync wget
    )
    if [ "$MKMA_QEMU_TEST" ]; then
        initramfs_modules+=(virtio_pci virtio_blk)
    fi

    mkchroot_zolo "$chroot_dir" "$host_name" "$user" "${packages[@]}"
    cp -a "$persist_script" "$chroot_dir/sbin/persist.sh"
    mkcpio "$chroot_dir" "${MKMA_COMPRESSION_LEVEL:-3}" > "$base_image"

    mkinitramfs "$initramfs_dir" "$initramfs_init_file" "${initramfs_modules[*]}" "${initramfs_binaries[*]}"
    mkcpio "$initramfs_dir" "${MKMA_COMPRESSION_LEVEL:-3}" > "$initramfs_image"

    if [ "$MKMA_QEMU_TEST" ]; then
        echo Testing zolo mkma image on QEMU...
        test_zolo_on_qemu "/boot/vmlinuz-$(uname -r)" "$initramfs_image" "$(dirname "$base_image")" "$qemu_disk" 8G "$serial_log"
    fi

    echo "kernel: /boot/vmlinuz-$(uname -r)"
    echo initramfs: "$initramfs_image"
    echo parameters: "mkma_storage_device=$(df "$base_image" | grep -o '/dev/[^ ]*') mkma_images_path=$(dirname "$base_image")"
    echo "after boot: the demo app serves on the machine's port 8080 (http://<host>:8080)"
}

# Allow sourcing of functions for manual runs.
(return 0 2>/dev/null) || mkzolo "$@"
