#!/bin/bash -e

# Headless finishing pass + pack the rootfs tar that x-chip-tools flashes:
#   - compile boot/boot.cmd -> /boot/boot.scr (u-boot loads zImage + dtb)
#   - point tce at the live CorePure repo + ship the onboot extension list
#   - start sshd from bootlocal
#   - pack build/rootfs -> $OUT

HERE=$(cd "$(dirname "$0")/.." && pwd); cd "$HERE"
source ./config.env
if [ "${PUBLIC_IMAGE:-0}" != 1 ] && [ -f "$SECRETS_ENV" ]; then
    # shellcheck disable=SC1090
    source "$SECRETS_ENV"
fi

if [ "${PUBLIC_IMAGE:-0}" = 1 ]; then
    REQUIRE_WIFI_CONFIG=0
    REQUIRE_AUTHORIZED_KEYS=0
    SSH_PASSWORD_AUTH=1
    AUTHORIZED_KEYS_SOURCE=
    WIFI_SSID=
    WIFI_PSK=
fi

if [ -z "${SSH_PASSWORD_AUTH:-}" ]; then
    if [ "${REQUIRE_AUTHORIZED_KEYS:-1}" = 0 ]; then
        SSH_PASSWORD_AUTH=1
    else
        SSH_PASSWORD_AUTH=0
    fi
fi
case "$SSH_PASSWORD_AUTH" in
    0|1) ;;
    *) echo "ERROR: SSH_PASSWORD_AUTH must be 0 or 1" >&2; exit 1 ;;
esac

if [ -z "${FAKEROOTKEY:-}" ]; then
    if [ "${ROOTFS_FORCE_FAKEROOT:-0}" = 1 ]; then
        if command -v fakeroot >/dev/null 2>&1; then
            exec fakeroot -- env ROOTFS_FORCE_FAKEROOT=0 "$0" "$@"
        fi
        echo "ERROR: ROOTFS_FORCE_FAKEROOT=1 but fakeroot is not installed" >&2
        exit 1
    fi
    if [ "$(id -u)" != 0 ]; then
        if command -v fakeroot >/dev/null 2>&1; then
            exec fakeroot -- "$0" "$@"
        fi
        echo "ERROR: rootfs assembly needs root or fakeroot to preserve ownership and device nodes" >&2
        echo "Use 'make container-build' or install fakeroot before running this script locally." >&2
        exit 1
    fi
fi

need_root() {
    if [ "$(id -u)" = 0 ]; then
        "$@"
    elif sudo -n true 2>/dev/null; then
        sudo "$@"
    elif [ "$1" = chown ]; then
        "$@" 2>/dev/null || true
    else
        "$@"
    fi
}
resolve_path() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *)  printf '%s\n' "$HERE/$1" ;;
    esac
}

RFS="$HERE/build/rootfs"
MKIMAGE=${MKIMAGE:-mkimage}
if ! command -v "$MKIMAGE" >/dev/null 2>&1; then
    if [ -x "$HERE/result/bin/mkimage" ]; then
        MKIMAGE="$HERE/result/bin/mkimage"
    else
        echo "need u-boot-tools (mkimage)" >&2
        exit 1
    fi
fi

validate_rootfs_base() {
    local missing=0 required
    for required in bin/busybox sbin/init init etc/inittab etc/init.d/tc-config; do
        if [ ! -e "$RFS/$required" ]; then
            echo "ERROR: build/rootfs is not a complete CorePure rootfs; missing /$required" >&2
            missing=1
        fi
    done
    [ "$missing" = 0 ] || {
        echo "Run 'make base' again before assembling the rootfs." >&2
        exit 1
    }
}

validate_rootfs_base
[ -f "$RFS/boot/zImage" ] || { echo "run 'make kernel' first (no /boot/zImage)" >&2; exit 1; }

replace_colon_record() {
    local file=$1 mode=$2 key=$3 line=$4 tmp
    tmp=$(mktemp)
    if [ -f "$file" ]; then
        need_root awk -F: -v key="$key" '$1 != key' "$file" >"$tmp"
    fi
    printf '%s\n' "$line" >>"$tmp"
    need_root install -m "$mode" "$tmp" "$file"
    rm -f "$tmp"
}

install_text() {
    local mode=$1 dest=$2 tmp
    tmp=$(mktemp)
    cat >"$tmp"
    need_root install -m "$mode" "$tmp" "$dest"
    rm -f "$tmp"
}

ssh_shadow_password() {
    local salt
    if [ "$SSH_PASSWORD_AUTH" != 1 ]; then
        printf ''
        return 0
    fi
    if [ -n "${SSH_PASSWORD_HASH:-}" ]; then
        case "$SSH_PASSWORD_HASH" in
            *:*) echo "ERROR: SSH_PASSWORD_HASH must not contain ':'" >&2; exit 1 ;;
        esac
        printf '%s' "$SSH_PASSWORD_HASH"
        return 0
    fi
    if [ -z "${SSH_PASSWORD:-}" ]; then
        echo "ERROR: SSH_PASSWORD must be non-empty when SSH_PASSWORD_AUTH=1" >&2
        exit 1
    fi
    if ! command -v openssl >/dev/null 2>&1; then
        echo "ERROR: openssl is required to hash SSH_PASSWORD" >&2
        exit 1
    fi
    salt=${SSH_PASSWORD_SALT:-}
    if [ -z "$salt" ]; then
        salt=$(openssl rand -base64 18 2>/dev/null | tr -dc 'A-Za-z0-9./' | head -c 16)
        [ -n "$salt" ] || salt="xchip$(date +%s)"
    fi
    printf '%s\n' "$SSH_PASSWORD" | openssl passwd -6 -salt "$salt" -stdin
}

create_static_dev_nodes() {
    need_root install -d "$RFS/dev" "$RFS/dev/input" "$RFS/dev/net" "$RFS/dev/pts" "$RFS/dev/shm" "$RFS/dev/usb"

    make_node() {
        local path=$1 mode=$2 type=$3 major=$4 minor=$5
        if [ ! -c "$path" ]; then
            need_root rm -f "$path"
            if ! need_root mknod -m "$mode" "$path" "$type" "$major" "$minor"; then
                echo "WARN: could not create ${path#$RFS} static device node; relying on devtmpfs" >&2
            fi
        fi
    }

    make_node "$RFS/dev/console" 0600 c 5 1
    make_node "$RFS/dev/null" 0666 c 1 3
    make_node "$RFS/dev/zero" 0666 c 1 5
    make_node "$RFS/dev/full" 0666 c 1 7
    make_node "$RFS/dev/random" 0666 c 1 8
    make_node "$RFS/dev/urandom" 0666 c 1 9
    make_node "$RFS/dev/tty" 0666 c 5 0
    make_node "$RFS/dev/tty0" 0600 c 4 0
    make_node "$RFS/dev/tty1" 0600 c 4 1
    make_node "$RFS/dev/ttyS0" 0600 c 4 64
    make_node "$RFS/dev/net/tun" 0666 c 10 200
}

normalize_rootfs_metadata() {
    create_static_dev_nodes

    need_root chown -R 0:0 "$RFS"
    if [ -d "$RFS/home/$SSH_USER" ]; then
        need_root chown -R "$SSH_UID:$SSH_GID" "$RFS/home/$SSH_USER"
    fi

    [ -e "$RFS/bin/busybox.suid" ] && {
        need_root chown 0:0 "$RFS/bin/busybox.suid"
        need_root chmod 4755 "$RFS/bin/busybox.suid"
    }
    [ -e "$RFS/usr/bin/sudo" ] && {
        need_root chown 0:0 "$RFS/usr/bin/sudo"
        need_root chmod 4755 "$RFS/usr/bin/sudo"
    }

    [ -e "$RFS/etc/shadow" ] && {
        need_root chown 0:0 "$RFS/etc/shadow"
        need_root chmod 600 "$RFS/etc/shadow"
    }
    [ -e "$RFS/etc/sudoers" ] && {
        need_root chown 0:0 "$RFS/etc/sudoers"
        need_root chmod 440 "$RFS/etc/sudoers"
    }
    [ -e "$RFS/etc/sudoers.d/$SSH_USER" ] && {
        need_root chown 0:0 "$RFS/etc/sudoers.d/$SSH_USER"
        need_root chmod 440 "$RFS/etc/sudoers.d/$SSH_USER"
    }

    if [ -d "$RFS/home/$SSH_USER/.ssh" ]; then
        need_root chown -R "$SSH_UID:$SSH_GID" "$RFS/home/$SSH_USER/.ssh"
        need_root chmod 700 "$RFS/home/$SSH_USER/.ssh"
        [ -e "$RFS/home/$SSH_USER/.ssh/authorized_keys" ] && \
            need_root chmod 600 "$RFS/home/$SSH_USER/.ssh/authorized_keys"
    fi
    if [ -d "$RFS/root/.ssh" ]; then
        need_root chown -R 0:0 "$RFS/root/.ssh"
        need_root chmod 700 "$RFS/root/.ssh"
        [ -e "$RFS/root/.ssh/authorized_keys" ] && \
            need_root chmod 600 "$RFS/root/.ssh/authorized_keys"
    fi
}

install_early_debug() {
    install_text 0755 "$RFS/opt/x-chip-early-debug.sh" <<'EOF'
#!/bin/sh
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
LOG=/opt/x-chip-early-debug.log
exec >>"$LOG" 2>&1
echo "=== x-chip-early-debug $(date 2>/dev/null || true) ==="

mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
mkdir -p /dev/pts 2>/dev/null || true
if ! grep -q ' /dev/pts ' /proc/mounts 2>/dev/null; then
    mount -t devpts devpts /dev/pts -o mode=620,ptmxmode=666 2>/dev/null || \
        mount -t devpts devpts /dev/pts 2>/dev/null || true
fi

modprobe libcomposite 2>/dev/null || true
mkdir -p /sys/kernel/config 2>/dev/null || true
if ! grep -q ' /sys/kernel/config ' /proc/mounts 2>/dev/null; then
    mount -t configfs none /sys/kernel/config 2>/dev/null || true
fi

[ -d /sys/kernel/config/usb_gadget ] || {
    echo "WARN: usb gadget configfs not available"
    exit 0
}

G=/sys/kernel/config/usb_gadget/xchip_early
if [ -e "$G/UDC" ]; then
    current="$(cat "$G/UDC" 2>/dev/null || true)"
    [ -n "$current" ] && exit 0
fi

mkdir -p "$G" "$G/strings/0x409" "$G/configs/c.1/strings/0x409" 2>/dev/null || exit 0
echo 0x1d6b > "$G/idVendor" 2>/dev/null || true
echo 0x0104 > "$G/idProduct" 2>/dev/null || true
echo 0x0100 > "$G/bcdDevice" 2>/dev/null || true
echo 0x0200 > "$G/bcdUSB" 2>/dev/null || true
echo xchip-early > "$G/strings/0x409/serialnumber" 2>/dev/null || true
echo NTC > "$G/strings/0x409/manufacturer" 2>/dev/null || true
echo "CHIP TinyCore early debug" > "$G/strings/0x409/product" 2>/dev/null || true
echo "USB early debug network" > "$G/configs/c.1/strings/0x409/configuration" 2>/dev/null || true
echo 250 > "$G/configs/c.1/MaxPower" 2>/dev/null || true

FUNC=
if mkdir -p "$G/functions/rndis.usb0" 2>/dev/null; then
    FUNC=rndis.usb0
elif mkdir -p "$G/functions/ecm.usb0" 2>/dev/null; then
    FUNC=ecm.usb0
else
    echo "WARN: no RNDIS/ECM gadget function available"
    exit 0
fi

echo de:ad:be:ef:54:01 > "$G/functions/$FUNC/dev_addr" 2>/dev/null || true
echo de:ad:be:ef:54:02 > "$G/functions/$FUNC/host_addr" 2>/dev/null || true
[ -e "$G/configs/c.1/$FUNC" ] || ln -s "$G/functions/$FUNC" "$G/configs/c.1/$FUNC" 2>/dev/null || true

UDC="$(ls /sys/class/udc 2>/dev/null | head -n 1)"
[ -n "$UDC" ] && echo "$UDC" > "$G/UDC" 2>/dev/null || true

i=0
while [ "$i" -lt 10 ]; do
    [ -e /sys/class/net/usb0 ] && break
    i=$((i + 1))
    sleep 1
done

if [ -e /sys/class/net/usb0 ]; then
    ifconfig usb0 192.168.82.1 netmask 255.255.255.0 up 2>/dev/null || true
    echo "USB early debug network ready on 192.168.82.1"
else
    echo "WARN: usb0 did not appear"
fi
EOF

    if [ -f "$RFS/etc/init.d/rcS" ] && ! grep -q 'x-chip early debug' "$RFS/etc/init.d/rcS"; then
        local tmp
        tmp=$(mktemp)
        awk '
            { print }
            $0 == "/bin/mount -a" {
                print ""
                print "# --- x-chip early debug ---"
                print "/opt/x-chip-early-debug.sh &"
            }
        ' "$RFS/etc/init.d/rcS" >"$tmp"
        need_root install -m755 "$tmp" "$RFS/etc/init.d/rcS"
        rm -f "$tmp"
    fi
}

install_runtime_identity() {
    local shadow_password
    need_root install -d "$RFS/etc" "$RFS/etc/sysconfig" "$RFS/home" "$RFS/opt"
    [ -f "$RFS/etc/passwd" ] || echo 'root:x:0:0:root:/root:/bin/sh' | need_root tee "$RFS/etc/passwd" >/dev/null
    [ -f "$RFS/etc/group" ] || echo 'root:x:0:' | need_root tee "$RFS/etc/group" >/dev/null
    [ -f "$RFS/etc/shadow" ] || echo 'root:*:19000:0:99999:7:::' | need_root tee "$RFS/etc/shadow" >/dev/null

    replace_colon_record "$RFS/etc/group" 0644 "$SSH_USER" \
        "$SSH_USER:x:$SSH_GID:"
    for group in \
        staff:50 \
        adm:4 \
        dialout:20 \
        audio:29 \
        video:44 \
        plugdev:46 \
        users:100 \
        netdev:101 \
        input:102 \
        render:103 \
        bluetooth:104 \
        gpio:105 \
        i2c:106 \
        spi:107; do
        replace_colon_record "$RFS/etc/group" 0644 "${group%%:*}" \
            "${group%%:*}:x:${group##*:}:$SSH_USER"
    done
    replace_colon_record "$RFS/etc/passwd" 0644 "$SSH_USER" \
        "$SSH_USER:x:$SSH_UID:$SSH_GID:CHIP User:/home/$SSH_USER:/bin/sh"
    shadow_password=$(ssh_shadow_password)
    replace_colon_record "$RFS/etc/shadow" 0600 "$SSH_USER" \
        "$SSH_USER:$shadow_password:19000:0:99999:7:::"

    echo "$CHIP_HOSTNAME" | need_root tee "$RFS/etc/hostname" >/dev/null
    echo "$SSH_USER" | need_root tee "$RFS/etc/sysconfig/tcuser" >/dev/null
    install_text 0644 "$RFS/etc/hosts" <<EOF
127.0.0.1	localhost
127.0.1.1	$CHIP_HOSTNAME

::1		localhost ip6-localhost ip6-loopback
ff02::1		ip6-allnodes
ff02::2		ip6-allrouters
EOF

    need_root install -d -m700 "$RFS/home/$SSH_USER/.ssh" "$RFS/root/.ssh"
    local keys_src=
    if [ -f "$AUTHORIZED_KEYS_SOURCE" ]; then
        keys_src=$AUTHORIZED_KEYS_SOURCE
    elif [ -f "$HOME/.ssh/pocket.pub" ]; then
        keys_src=$HOME/.ssh/pocket.pub
    elif [ -f "$HOME/.ssh/id_ed25519.pub" ]; then
        keys_src=$HOME/.ssh/id_ed25519.pub
    fi

    if [ -n "$keys_src" ]; then
        need_root install -m600 "$keys_src" "$RFS/home/$SSH_USER/.ssh/authorized_keys"
        need_root install -m600 "$keys_src" "$RFS/root/.ssh/authorized_keys"
    else
        if [ "${REQUIRE_AUTHORIZED_KEYS:-1}" = 1 ]; then
            echo "ERROR: no authorized_keys source found" >&2
            echo "Set AUTHORIZED_KEYS_SOURCE or create ~/.ssh/pocket.pub before building." >&2
            exit 1
        fi
        echo "WARN: no authorized_keys source found; SSH login will need manual setup" >&2
        need_root install -m600 /dev/null "$RFS/home/$SSH_USER/.ssh/authorized_keys"
        need_root install -m600 /dev/null "$RFS/root/.ssh/authorized_keys"
    fi
    need_root chown -R "$SSH_UID:$SSH_GID" "$RFS/home/$SSH_USER"
    need_root chmod 700 "$RFS/root/.ssh"

    need_root install -d "$RFS/etc/sudoers.d"
    install_text 0440 "$RFS/etc/sudoers.d/$SSH_USER" <<EOF
$SSH_USER ALL=(ALL) NOPASSWD: ALL
EOF
    need_root touch "$RFS/etc/sudoers"
    need_root grep -Eq "^$SSH_USER[[:space:]]+ALL=\\(ALL\\)[[:space:]]+NOPASSWD:[[:space:]]*ALL" "$RFS/etc/sudoers" 2>/dev/null || \
        echo "$SSH_USER ALL=(ALL) NOPASSWD: ALL" | need_root tee -a "$RFS/etc/sudoers" >/dev/null
}

install_os_branding() {
    local version_id
    version_id=${TINYCORE_VERSION%%.*}
    install_text 0644 "$RFS/etc/os-release" <<EOF
NAME="PocketCHIP TinyCore"
VERSION="$TINYCORE_VERSION"
ID=pocketchip-tinycore
ID_LIKE=tinycore
VERSION_ID=$version_id
PRETTY_NAME="PocketCHIP TinyCore $TINYCORE_VERSION"
ANSI_COLOR="0;34"
HOME_URL="$PROJECT_REPO_URL"
BUG_REPORT_URL="$PROJECT_REPO_URL/issues"
EOF

    install_text 0644 "$RFS/etc/issue" <<EOF
PocketCHIP TinyCore $TINYCORE_VERSION \n \l

EOF

    install_text 0644 "$RFS/etc/motd" <<EOF
PocketCHIP TinyCore $TINYCORE_VERSION
EOF
}

install_runtime_mounts() {
    need_root install -d -m1777 "$RFS/tmp"
    need_root install -d -m0755 "$RFS/run" "$RFS/var/run" "$RFS/etc/udev/rules.d"
    need_root install -d -m0775 "$RFS/var/lock"

    install_text 0644 "$RFS/etc/fstab" <<'EOF'
# /etc/fstab
proc            /proc        proc    defaults          0       0
sysfs           /sys         sysfs   defaults          0       0
devpts          /dev/pts     devpts  defaults          0       0
tmpfs           /dev/shm     tmpfs   defaults          0       0
tmpfs           /tmp         tmpfs   mode=1777,nosuid,nodev 0 0
tmpfs           /run         tmpfs   mode=0755,nosuid,nodev 0 0
tmpfs           /var/run     tmpfs   mode=0755,nosuid,nodev 0 0
tmpfs           /var/lock    tmpfs   mode=0775,nosuid,nodev 0 0
EOF

    if [ -f "$RFS/tmp/98-tc.rules" ]; then
        need_root install -m0644 "$RFS/tmp/98-tc.rules" "$RFS/etc/udev/rules.d/98-tc.rules"
    else
        install_text 0644 "$RFS/etc/udev/rules.d/98-tc.rules" <<'EOF'
KERNEL=="ram*", SUBSYSTEM=="block", GOTO="tc.rules_end"
KERNEL=="loop*", SUBSYSTEM=="block", GOTO="tc.rules_end"
ACTION=="add",		SUBSYSTEM=="block",	RUN+="/bin/sh -c '/usr/sbin/rebuildfstab'"
ACTION=="remove",	SUBSYSTEM=="block",	RUN+="/bin/sh -c '/usr/sbin/rebuildfstab'"
LABEL="tc.rules_end"
EOF
    fi
}

install_console_config() {
    install_text 0755 "$RFS/opt/x-chip-autologin.sh" <<'EOF'
#!/bin/sh
exec /bin/login -f @SSH_USER@
EOF
    need_root sed -i "s/@SSH_USER@/$SSH_USER/g" "$RFS/opt/x-chip-autologin.sh"

    install_text 0755 "$RFS/opt/x-chip-tty1-getty.sh" <<'EOF'
#!/bin/sh
READY=/dev/shm/x-chip/console-ready
WAITED=0
while [ ! -e "$READY" ] && [ "$WAITED" -lt 30 ]; do
	sleep 1
	WAITED=$((WAITED + 1))
done

exec </dev/tty1 >/dev/tty1 2>&1
stty sane echo icanon isig icrnl opost onlcr 2>/dev/null || true

if [ -w /dev/tty1 ]; then
	printf '\033c\033[2J\033[H' 2>/dev/null || true
	printf 'PocketCHIP TinyCore ready - kernel %s\n\n' "$(uname -r)" 2>/dev/null || true
	if [ ! -e "$READY" ]; then
		printf 'Boot runtime is still running; see /opt/x-chip-boot.log\n\n' 2>/dev/null || true
	fi
fi

exec /sbin/getty -n -l /opt/x-chip-autologin.sh 38400 tty1
EOF
    replace_colon_record "$RFS/etc/inittab" 0644 tty1 \
        'tty1::respawn:/opt/x-chip-tty1-getty.sh'
    replace_colon_record "$RFS/etc/inittab" 0644 ttyS0 \
        'ttyS0::respawn:/sbin/getty -L 115200 ttyS0 vt100'
}

patch_tinycore_tce_setup() {
    local file="$RFS/usr/bin/tce-setup" tmp
    [ -f "$file" ] || return 0
    if grep -q 'MOUNTPOINT="/tmp"; TCE_DIR="tce"' "$file"; then
        tmp=$(mktemp)
        sed 's/MOUNTPOINT="\/tmp"; TCE_DIR="tce"/MOUNTPOINT=""; TCE_DIR="tce"/' "$file" >"$tmp"
        need_root install -m755 "$tmp" "$file"
        rm -f "$tmp"
    fi
}

patch_tinycore_tc_config() {
    local file="$RFS/etc/init.d/tc-config" tmp
    [ -f "$file" ] || return 0

    tmp=$(mktemp)
    awk '{
        if ($0 == "/sbin/udevadm settle") {
            print "/sbin/udevadm settle --timeout=5 >/dev/null 2>&1 || true"
        } else if ($0 ~ /^[[:space:]]*wait \$fstab_pid[[:space:]]*$/) {
            print "[ -n \"${fstab_pid:-}\" ] && wait \"$fstab_pid\" || true"
        } else {
            print
        }
    }' "$file" >"$tmp"
    need_root install -m755 "$tmp" "$file"
    rm -f "$tmp"
}

write_wifi_config() {
    if [ -z "${WIFI_SSID:-}" ]; then
        if [ "${REQUIRE_WIFI_CONFIG:-1}" = 1 ]; then
            echo "ERROR: WIFI_SSID is not set" >&2
            echo "Copy secrets.env.example to secrets.env and set WIFI_SSID/WIFI_PSK, or build with REQUIRE_WIFI_CONFIG=0." >&2
            exit 1
        fi
        return 0
    fi
    if [ -z "${WIFI_PSK:-}" ]; then
        if [ "${REQUIRE_WIFI_CONFIG:-1}" = 1 ]; then
            echo "ERROR: WIFI_SSID is set but WIFI_PSK is missing" >&2
            echo "Set WIFI_PSK in secrets.env, or build with REQUIRE_WIFI_CONFIG=0." >&2
            exit 1
        fi
        echo "WARN: WIFI_SSID set but WIFI_PSK missing; WiFi config not written" >&2
        return 0
    fi

    local ssid_quoted psk_quoted
    ssid_quoted=$(printf '%s' "$WIFI_SSID" | sed 's/\\/\\\\/g; s/"/\\"/g')
    psk_quoted=$(printf '%s' "$WIFI_PSK" | sed 's/\\/\\\\/g; s/"/\\"/g')
    need_root install -d "$RFS/etc"
    install_text 0600 "$RFS/etc/wpa_supplicant.conf" <<EOF
ctrl_interface=/var/run/wpa_supplicant
update_config=0
country=$WIFI_COUNTRY

network={
	ssid="$ssid_quoted"
	psk="$psk_quoted"
	key_mgmt=WPA-PSK
}
EOF
}

install_board_runtime_config() {
    need_root install -d "$RFS/etc/modprobe.d"
    install_text 0644 "$RFS/etc/modprobe.d/r8723bs.conf" <<'EOF'
options r8723bs rtw_power_mgnt=0 rtw_ips_mode=0
EOF
    need_root touch "$RFS/etc/modprobe.conf"
    need_root grep -qxF 'options r8723bs rtw_power_mgnt=0 rtw_ips_mode=0' "$RFS/etc/modprobe.conf" 2>/dev/null || \
        echo 'options r8723bs rtw_power_mgnt=0 rtw_ips_mode=0' | need_root tee -a "$RFS/etc/modprobe.conf" >/dev/null
}

validate_pocketchip_bkeymap() {
    local map=$1 normal_prefix special_prefix
    normal_prefix=$(od -An -tx1 -j264 -N16 "$map" | tr -d ' \n')
    [ "$normal_prefix" = "021b0031003200330034003500360037" ] || {
        echo "ERROR: generated PocketCHIP keymap is missing the normal US key entries" >&2
        return 1
    }
    special_prefix=$(od -An -tx1 -j816 -N10 "$map" | tr -d ' \n')
    [ "$special_prefix" = "0b7b007d005b005d007c" ] || {
        echo "ERROR: generated PocketCHIP keymap is missing Fn/AltGr special entries" >&2
        return 1
    }
}

install_keymap() {
    local keymap_src keymap_base keymap_bin keymap_err
    keymap_src=$(resolve_path "$KEYMAP_SOURCE")
    [ -f "$keymap_src" ] || {
        echo "ERROR: keymap source not found: $keymap_src" >&2
        return 1
    }
    keymap_base="$HERE/build/linux-$KERNEL_VERSION/drivers/tty/vt/defkeymap.map"
    [ -f "$keymap_base" ] || {
        echo "ERROR: base console keymap not found: $keymap_base" >&2
        return 1
    }
    command -v loadkeys >/dev/null || {
        echo "ERROR: loadkeys missing on build host; cannot build complete PocketCHIP keymap" >&2
        return 1
    }

    keymap_bin=$(mktemp)
    keymap_err=$(mktemp)
    # pocketchip.kmap is a loadkeys overlay, not a complete map. Always merge it
    # with the kernel's default Linux console map before converting to BusyBox
    # loadkmap format; compiling the overlay alone breaks normal keys.
    if ! loadkeys -q -b "$keymap_base" "$keymap_src" >"$keymap_bin" 2>"$keymap_err"; then
        echo "ERROR: PocketCHIP keymap conversion failed" >&2
        sed 's/^/ERROR: loadkeys: /' "$keymap_err" >&2 || true
        rm -f "$keymap_bin" "$keymap_err"
        return 1
    fi
    validate_pocketchip_bkeymap "$keymap_bin" || {
        rm -f "$keymap_bin" "$keymap_err"
        return 1
    }
    need_root install -d "$RFS/usr/share/kmap"
    need_root install -m644 "$keymap_src" "$RFS/usr/share/kmap/pocketchip.loadkeys"
    need_root install -m644 "$keymap_bin" "$RFS/usr/share/kmap/pocketchip.kmap"
    rm -f "$keymap_bin" "$keymap_err"
}

install_keyboard_debug_tools() {
    need_root install -d "$RFS/usr/local/bin"
    install_text 0755 "$RFS/usr/local/bin/x-chip-keyboard-status" <<'EOF'
#!/bin/sh
echo "== modules =="
lsmod | grep -E '(^tca8418_keypad|^matrix_keymap|^sun4i_ts)' || true

echo
echo "== input devices =="
cat /proc/bus/input/devices 2>/dev/null | awk '
	/^I: / { block=$0 "\n"; keep=0; next }
	/^$/ {
		if (keep) print block
		block=""
		keep=0
		next
	}
	{
		block=block $0 "\n"
		if ($0 ~ /Name=.*tca8418/ || $0 ~ /Name=.*1c25000.rtp/) keep=1
	}
	END { if (keep) print block }
'

echo
echo "== keymap =="
ls -l /usr/share/kmap/pocketchip.* 2>/dev/null || true
if [ -r /var/log/loadkmap.log ]; then
	echo
	echo "== loadkmap log =="
	cat /var/log/loadkmap.log
fi

echo
echo "== tty console =="
cat /proc/consoles 2>/dev/null || true
cat /proc/sys/kernel/printk 2>/dev/null || true
EOF
}

install_hardware_debug_tools() {
    need_root install -d "$RFS/usr/local/bin"
    need_root install -d "$RFS/usr/local/etc/x-chip"
    need_root install -d "$RFS/usr/local/share/x-chip"
    install_text 0644 "$RFS/usr/local/etc/x-chip/display.conf" <<EOF
LCD_BRIGHTNESS=${LCD_BRIGHTNESS:-6}
EOF
    install_text 0644 "$RFS/usr/local/etc/x-chip/wifi.conf" <<'EOF'
X_CHIP_WIFI_CLIENT_DRIVER=rtl8723bs
X_CHIP_WIFI_SCAN_DRIVER=rtl8812au
EOF

    install_text 0755 "$RFS/usr/local/bin/x-chip-audio-status" <<'EOF'
#!/bin/sh
echo "== ALSA cards =="
cat /proc/asound/cards 2>/dev/null || true

echo
echo "== ALSA devices =="
cat /proc/asound/devices 2>/dev/null || true

echo
echo "== modules =="
lsmod | grep -E '(^snd|sun4i|simple_card)' || true

echo
echo "== aplay =="
command -v aplay >/dev/null 2>&1 && aplay -l 2>/dev/null || true

echo
echo "== mixer =="
command -v amixer >/dev/null 2>&1 && amixer scontrols 2>/dev/null || true
EOF

    install_text 0755 "$RFS/usr/local/bin/x-chip-power-status" <<'EOF'
#!/bin/sh
echo "== power supply =="
for p in /sys/class/power_supply/*; do
	[ -e "$p" ] || continue
	echo "-- ${p##*/}"
	for f in type status present online capacity voltage_now current_now temp; do
		[ -r "$p/$f" ] && printf '%s=%s\n' "$f" "$(cat "$p/$f" 2>/dev/null)"
	done
done

echo
echo "== cpufreq =="
for c in /sys/devices/system/cpu/cpu*/cpufreq; do
	[ -d "$c" ] || continue
	echo "-- ${c%/cpufreq}"
	for f in scaling_governor scaling_cur_freq scaling_min_freq scaling_max_freq; do
		[ -r "$c/$f" ] && printf '%s=%s\n' "$f" "$(cat "$c/$f" 2>/dev/null)"
	done
done

echo
echo "== thermal =="
for z in /sys/class/thermal/thermal_zone*; do
	[ -d "$z" ] || continue
	printf '%s ' "${z##*/}"
	[ -r "$z/type" ] && printf '%s ' "$(cat "$z/type" 2>/dev/null)"
	[ -r "$z/temp" ] && printf 'temp=%s' "$(cat "$z/temp" 2>/dev/null)"
	printf '\n'
done
EOF

    install_text 0755 "$RFS/usr/local/bin/x-chip-term-hold" <<'EOF'
#!/bin/sh

if [ "$#" -eq 0 ]; then
	echo "Usage: x-chip-term-hold COMMAND [ARG...]"
	echo
	echo "Press enter to close."
	read _ || true
	exit 2
fi

"$@"
status=$?

echo
if [ "$status" -ne 0 ]; then
	echo "Command exited with status $status"
fi
echo "Press enter to close."
read _ || true
exit 0
EOF

    install_text 0755 "$RFS/usr/local/bin/x-chip-status" <<'EOF'
#!/bin/sh

first_wifi_iface() {
	for iface_path in /sys/class/net/wlan* /sys/class/net/wlp*; do
		[ -e "$iface_path" ] || continue
		printf '%s\n' "${iface_path##*/}"
		return 0
	done
	return 1
}

read_one() {
	[ -r "$1" ] && sed -n '1p' "$1" 2>/dev/null
}

show_power() {
	bat=
	for p in /sys/class/power_supply/*; do
		[ -e "$p" ] || continue
		type=$(read_one "$p/type")
		[ "$type" = Battery ] && { bat=$p; break; }
	done
	if [ -n "$bat" ]; then
		cap=$(read_one "$bat/capacity")
		status=$(read_one "$bat/status")
		printf 'Battery: %s%% %s\n' "${cap:-?}" "${status:-unknown}"
	else
		echo "Battery: not found"
	fi
	usb=?
	ac=?
	[ -r /sys/class/power_supply/axp20x-usb/online ] && usb=$(read_one /sys/class/power_supply/axp20x-usb/online)
	[ -r /sys/class/power_supply/axp20x-ac/online ] && ac=$(read_one /sys/class/power_supply/axp20x-ac/online)
	printf 'Power: USB=%s AC=%s\n' "$usb" "$ac"
}

show_wifi() {
	iface=$(first_wifi_iface 2>/dev/null || true)
	if [ -z "$iface" ]; then
		echo "WiFi: no interface"
		return
	fi
	ip4=
	if command -v ip >/dev/null 2>&1; then
		ip4=$(ip addr show "$iface" 2>/dev/null | sed -n 's/^[[:space:]]*inet \([^ ]*\).*/\1/p' | head -n 1)
	elif command -v ifconfig >/dev/null 2>&1; then
		ip4=$(ifconfig "$iface" 2>/dev/null | sed -n 's/.*inet addr:\([^ ]*\).*/\1/p; s/.*inet \([0-9.][0-9.]*\).*/\1/p' | head -n 1)
	fi
	link=$(iw dev "$iface" link 2>/dev/null)
	ssid=$(printf '%s\n' "$link" | sed -n 's/^[[:space:]]*SSID: //p' | head -n 1)
	signal=$(printf '%s\n' "$link" | sed -n 's/^[[:space:]]*signal: //p' | head -n 1)
	[ -n "$ssid" ] || ssid=disconnected
	printf 'WiFi: %s %s\n' "$iface" "$ssid"
	[ -n "$ip4" ] && printf 'IP: %s\n' "$ip4"
	[ -n "$signal" ] && printf 'Signal: %s\n' "$signal"
}

show_display() {
	bl=
	for p in /sys/class/backlight/*; do
		[ -d "$p" ] || continue
		bl=$p
		break
	done
	if [ -n "$bl" ]; then
		cur=$(read_one "$bl/brightness")
		max=$(read_one "$bl/max_brightness")
		printf 'Brightness: %s/%s\n' "${cur:-?}" "${max:-?}"
	fi
}

show_cpu() {
	temp=
	for z in /sys/class/thermal/thermal_zone*; do
		[ -r "$z/temp" ] || continue
		temp=$(read_one "$z/temp")
		break
	done
	freq=
	for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do
		[ -r "$c" ] || continue
		freq=$(read_one "$c")
		break
	done
	[ -n "$temp" ] && printf 'Temp: %s.%s C\n' "$((temp / 1000))" "$(((temp % 1000) / 100))"
	[ -n "$freq" ] && printf 'CPU: %s MHz\n' "$((freq / 1000))"
	[ -r /proc/loadavg ] && printf 'Load: %s\n' "$(cut -d' ' -f1-3 /proc/loadavg)"
}

show_memory_disk() {
	awk '
		$1 == "MemTotal:" { total = int($2 / 1024) }
		$1 == "MemAvailable:" { avail = int($2 / 1024) }
		END {
			if (total > 0) printf "RAM: %d/%d MB free\n", avail, total
		}
	' /proc/meminfo 2>/dev/null
	df -h / 2>/dev/null | awk 'NR == 2 { printf "Disk /: %s/%s used %s\n", $3, $2, $5 }'
}

draw() {
	clear 2>/dev/null || true
	echo "Pocket Status"
	echo "============="
	show_power
	show_wifi
	show_display
	show_cpu
	show_memory_disk
}

if [ "${1:-}" = once ]; then
	draw
	exit 0
fi

while :; do
	draw
	echo
	printf '[r] refresh  [q] close > '
	read choice || exit 0
	case "$choice" in
		q|Q) exit 0 ;;
	esac
done
EOF

    install_text 0755 "$RFS/usr/local/bin/x-chip-time" <<'EOF'
#!/bin/sh

set -u

SERVERS=${X_CHIP_NTP_SERVERS:-"0.pool.ntp.org 1.pool.ntp.org time.cloudflare.com"}
LOG=${X_CHIP_TIME_LOG:-/var/log/x-chip-time-sync.log}

network_ready() {
	if command -v ip >/dev/null 2>&1; then
		ip route 2>/dev/null | grep -q '^default '
	elif command -v route >/dev/null 2>&1; then
		route -n 2>/dev/null | awk '$1 == "0.0.0.0" { found = 1 } END { exit found ? 0 : 1 }'
	else
		return 0
	fi
}

run_as_root() {
	if [ "$(id -u)" = 0 ]; then
		"$@"
	elif command -v sudo >/dev/null 2>&1; then
		sudo "$@"
	else
		echo "Need root privileges." >&2
		return 1
	fi
}

status() {
	echo "Time"
	echo "===="
	date
	echo "UTC: $(TZ=UTC date)"
	if pgrep -x ntpd >/dev/null 2>&1; then
		echo "NTP: running"
	else
		echo "NTP: stopped"
	fi
	if command -v ip >/dev/null 2>&1; then
		ip route 2>/dev/null | sed -n 's/^default /Default route: /p' | head -n 1
	fi
	[ -r "$LOG" ] && {
		echo
		echo "Last sync log:"
		tail -n 8 "$LOG"
	}
}

sync_now() {
	command -v ntpd >/dev/null 2>&1 || {
		echo "NTP unavailable: ntpd is missing." >&2
		return 1
	}
	args=
	for server in $SERVERS; do
		args="$args -p $server"
	done
	echo "Syncing time..."
	echo "Servers:$SERVERS"
	if command -v timeout >/dev/null 2>&1; then
		# shellcheck disable=SC2086
		run_as_root timeout 60 ntpd -nq $args
	else
		# shellcheck disable=SC2086
		run_as_root ntpd -nq $args
	fi
	rc=$?
	echo
	date
	return "$rc"
}

sync_background() {
	(
		i=0
		while [ "$i" -lt 6 ]; do
			if network_ready; then
				sync_now && exit 0
			else
				echo "Waiting for network..."
			fi
			i=$((i + 1))
			sleep 20
		done
		exit 1
	) >"$LOG" 2>&1 &
}

set_manual() {
	value=${*:-}
	if [ -z "$value" ]; then
		echo "Enter date/time."
		echo "Examples:"
		echo "  2026-06-27 14:30:00"
		echo "  062714302026.00"
		printf '> '
		read value || return 1
	fi
	[ -n "$value" ] || return 1
	run_as_root date -s "$value"
	date
}

case "${1:-status}" in
	status) status ;;
	sync) sync_now ;;
	sync-background) sync_background ;;
	set) shift; set_manual "$@" ;;
	*) echo "Usage: x-chip-time [status|sync|sync-background|set VALUE]" >&2; exit 2 ;;
esac
EOF

    install_text 0755 "$RFS/usr/local/bin/x-chip-brightness" <<'EOF'
#!/bin/sh
set -eu

CONFIG=${X_CHIP_DISPLAY_CONFIG:-/usr/local/etc/x-chip/display.conf}
MIN_BRIGHTNESS=${X_CHIP_MIN_BRIGHTNESS:-1}

find_backlight() {
	for p in /sys/class/backlight/*; do
		[ -d "$p" ] || continue
		[ -r "$p/max_brightness" ] || continue
		printf '%s\n' "$p"
		return 0
	done
	return 1
}

read_num() {
	sed -n '1{s/[^0-9].*$//; /^[0-9][0-9]*$/p;}' "$1" 2>/dev/null
}

write_value() {
	path=$1
	value=$2
	if [ -w "$path" ]; then
		printf '%s\n' "$value" >"$path"
	elif command -v sudo >/dev/null 2>&1; then
		printf '%s\n' "$value" | sudo tee "$path" >/dev/null
	else
		echo "Need root to write $path" >&2
		return 1
	fi
}

load_saved() {
	[ -r "$CONFIG" ] || return 1
	sed -n 's/^LCD_BRIGHTNESS=\([0-9][0-9]*\)$/\1/p' "$CONFIG" | head -n 1
}

clamp() {
	value=$1
	max=$2
	min=$MIN_BRIGHTNESS
	[ "$max" -lt "$min" ] && min="$max"
	[ "$value" -lt "$min" ] && value=$min
	[ "$value" -gt "$max" ] && value=$max
	printf '%s\n' "$value"
}

apply_value() {
	value=$1
	bl=$(find_backlight) || {
		echo "No backlight device found" >&2
		return 1
	}
	max=$(read_num "$bl/max_brightness")
	[ -n "$max" ] || max=8
	value=$(clamp "$value" "$max")
	[ -e "$bl/bl_power" ] && write_value "$bl/bl_power" 0 2>/dev/null || true
	write_value "$bl/brightness" "$value"
	echo "Brightness: $value/$max"
}

status() {
	bl=$(find_backlight) || {
		echo "No backlight device found"
		return 0
	}
	max=$(read_num "$bl/max_brightness")
	current=$(read_num "$bl/brightness")
	saved=$(load_saved 2>/dev/null || true)
	echo "Backlight: ${bl##*/}"
	echo "Brightness: ${current:-?}/${max:-?}"
	[ -n "$saved" ] && echo "Saved: $saved"
}

cmd=${1:-status}
case "$cmd" in
	set)
		value=${2:-}
		case "$value" in
			''|*[!0-9]*) echo "Usage: x-chip-brightness set VALUE" >&2; exit 2 ;;
		esac
		apply_value "$value"
		;;
	apply)
		value=$(load_saved 2>/dev/null || true)
		[ -n "$value" ] || value=${LCD_BRIGHTNESS:-6}
		apply_value "$value"
		;;
	status) status ;;
	*) echo "Usage: x-chip-brightness [status|set VALUE|apply]" >&2; exit 2 ;;
esac
EOF

    install_text 0755 "$RFS/usr/local/bin/x-chip-logs" <<'EOF'
#!/bin/sh
set -eu

show_file() {
	file=$1
	lines=${2:-80}
	echo
	echo "== $file =="
	if [ -r "$file" ]; then
		tail -n "$lines" "$file"
	else
		echo "not available"
	fi
}

case "${1:-all}" in
	boot) show_file /opt/x-chip-boot.log 140 ;;
	wifi)
		show_file /var/log/wpa_supplicant.log 120
		for f in /var/log/dhcpcd-*.log /var/log/udhcpc-*.log; do
			[ -e "$f" ] && show_file "$f" 80
		done
		;;
	system)
		echo "== dmesg =="
		dmesg | tail -n 140
		;;
	all)
		show_file /opt/x-chip-boot.log 120
		show_file /var/log/wpa_supplicant.log 80
		show_file /tmp/x-chip-brightness.log 40
		echo
		echo "== dmesg =="
		dmesg | tail -n 80
		;;
	*) echo "Usage: x-chip-logs [all|boot|wifi|system]" >&2; exit 2 ;;
esac
EOF
}

install_media_tools() {
    need_root install -d "$RFS/usr/local/bin"
    need_root install -d "$RFS/home/$SSH_USER/Pictures" "$RFS/home/$SSH_USER/Videos" \
        "$RFS/home/$SSH_USER/Music" "$RFS/home/$SSH_USER/Downloads"
    need_root chown "$SSH_UID:$SSH_GID" "$RFS/home/$SSH_USER/Pictures" "$RFS/home/$SSH_USER/Videos" \
        "$RFS/home/$SSH_USER/Music" "$RFS/home/$SSH_USER/Downloads"
    install_text 0755 "$RFS/usr/local/bin/x-chip-media-on" <<'EOF'
#!/bin/sh
set -eu

MEDIA_LIST=/tce/media.lst
TC_USER="$(cat /etc/sysconfig/tcuser 2>/dev/null || echo chip)"
LOCK_DIR=/tmp/x-chip-media-on.lock

scrub_kernel_placeholder_deps() {
	for depfile in /tce/optional/*.tcz.dep; do
		[ -f "$depfile" ] || continue
		grep -q KERNEL "$depfile" 2>/dev/null || continue
		tmp="/tmp/${depfile##*/}.clean"
		grep -v KERNEL "$depfile" >"$tmp" || true
		install -m644 "$tmp" "$depfile"
		rm -f "$tmp"
	done
}

extension_ready() {
	ext="$1"
	app="${ext%.tcz}"
	case "$app" in
		ffmpeg)
			command -v ffplay >/dev/null 2>&1
			;;
		mpg123)
			command -v mpg123 >/dev/null 2>&1
			;;
		*)
			[ -e "/usr/local/tce.installed/$app" ]
			;;
	esac
}

load_tcz_one() {
	ext="$1"
	case "$ext" in
		''|\#*) return 0 ;;
	esac
	case "$ext" in
		*.tcz) ;;
		*) ext="$ext.tcz" ;;
	esac
	extension_ready "$ext" && return 0
	scrub_kernel_placeholder_deps
	if [ -f "/tce/optional/$ext" ]; then
		target="/tce/optional/$ext"
	else
		target="$ext"
	fi
	if [ "$(id -u)" = 0 ] && id "$TC_USER" >/dev/null 2>&1; then
		su "$TC_USER" -c "tce-load -il $target"
	else
		tce-load -il "$target"
	fi
}

commands_ready() {
	for cmd in "$@"; do
		command -v "$cmd" >/dev/null 2>&1 || return 1
	done
	return 0
}

require_commands() {
	missing=0
	for cmd in "$@"; do
		if ! command -v "$cmd" >/dev/null 2>&1; then
			echo "$cmd unavailable" >&2
			missing=1
		fi
	done
	[ "$missing" = 0 ] || exit 1
}

load_media_list() {
	[ -f "$MEDIA_LIST" ] || {
		echo "missing $MEDIA_LIST" >&2
		exit 1
	}
	while IFS= read -r ext; do
		ext=${ext%%#*}
		set -- $ext
		ext=${1:-}
		load_tcz_one "$ext"
	done < "$MEDIA_LIST"
}

acquire_lock() {
	waited=0
	while ! mkdir "$LOCK_DIR" 2>/dev/null; do
		waited=$((waited + 1))
		[ "$waited" -lt 90 ] || {
			echo "media loader is busy" >&2
			exit 1
		}
		sleep 1
	done
	trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT INT TERM
}

command -v tce-load >/dev/null 2>&1 || {
	echo "missing tce-load" >&2
	exit 1
}

case "${1:-all}" in
	all|media)
		commands_ready ffplay mpg123 && { echo "media ready"; exit 0; }
		acquire_lock
		commands_ready ffplay mpg123 && { echo "media ready"; exit 0; }
		load_media_list
		require_commands ffplay mpg123
		;;
	ffmpeg|ffplay|video)
		commands_ready ffplay && { echo "media ready"; exit 0; }
		acquire_lock
		commands_ready ffplay && { echo "media ready"; exit 0; }
		load_tcz_one ffmpeg.tcz
		require_commands ffplay
		;;
	mpg123|music|audio)
		commands_ready mpg123 && { echo "media ready"; exit 0; }
		acquire_lock
		commands_ready mpg123 && { echo "media ready"; exit 0; }
		load_tcz_one mpg123.tcz
		require_commands mpg123
		;;
	*)
		echo "Usage: x-chip-media-on [all|ffmpeg|mpg123]" >&2
		exit 2
		;;
esac

echo "media ready"
EOF
}

install_user_command_symlinks() {
    need_root install -d "$RFS/usr/local/bin"
    for tool in iw iwconfig wpa_cli; do
        need_root ln -sfn "../sbin/$tool" "$RFS/usr/local/bin/$tool"
    done

    install_text 0755 "$RFS/usr/local/bin/x-chip-load-rtl8812au" <<'EOF'
#!/bin/sh
set -eu
modprobe 8812au
echo "RTL8812AU module loaded"
echo "No WPA/DHCP started on this adapter; internal RTL8723BS remains primary."
iw dev 2>/dev/null || true
EOF
}

install_rtl8812au_hotplug() {
    need_root install -d "$RFS/etc/udev/rules.d" "$RFS/etc/modprobe.d" "$RFS/usr/local/sbin"

    install_text 0644 "$RFS/etc/modprobe.d/8812au.conf" <<'EOF'
# Keep the external RTL8812AU adapter responsive for scanning.
options 8812au rtw_power_mgnt=0 rtw_ips_mode=0
EOF

    install_text 0755 "$RFS/usr/local/sbin/x-chip-rtl8812au-hotplug" <<'EOF'
#!/bin/sh
HOTPLUG_ENABLED="@RTL8812AU_HOTPLUG@"
LOG=/var/log/rtl8812au-hotplug.log

[ "$HOTPLUG_ENABLED" = 1 ] || exit 0

{
	echo "=== rtl8812au hotplug $(date 2>/dev/null || true) ==="
	echo "ACTION=${ACTION:-}"
	echo "PRODUCT=${PRODUCT:-}"
	echo "DEVPATH=${DEVPATH:-}"

	if lsmod 2>/dev/null | grep -q '^8812au'; then
		echo "8812au already loaded"
	else
		modprobe 8812au && echo "loaded 8812au" || echo "WARN: failed to load 8812au"
	fi

	# Intentionally do not start WPA/DHCP here. The internal r8723bs interface
	# remains the primary SSH/network adapter; this USB adapter is secondary.
	iw dev 2>/dev/null || true
} >>"$LOG" 2>&1

exit 0
EOF
    need_root sed -i "s/@RTL8812AU_HOTPLUG@/${RTL8812AU_HOTPLUG:-1}/g" "$RFS/usr/local/sbin/x-chip-rtl8812au-hotplug"

    install_text 0644 "$RFS/etc/udev/rules.d/90-x-chip-rtl8812au-hotplug.rules" <<'EOF'
# Load the optional RTL8812AU USB WiFi module when a Realtek USB adapter appears.
# Network management is not started here; the adapter remains secondary.
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="0bda", RUN+="/usr/local/sbin/x-chip-rtl8812au-hotplug"
EOF
}

install_extra_firmware() {
    local src base dir file rel
    for src in \
        "$EXTRA_FIRMWARE_SOURCE" \
        "${EXTRA_FIRMWARE_SOURCE%/lib/firmware}/usr/lib/firmware" \
        "../flash/rootfs_trixie/usr/lib/firmware"; do
        case "$src" in
            /*) base=$src ;;
            *)  base="$HERE/$src" ;;
        esac
        [ -d "$base" ] || continue

        for dir in rtlwifi rtl_bt; do
            [ -d "$base/$dir" ] || continue
            while IFS= read -r file; do
                rel=${file#"$base/"}
                need_root install -d "$RFS/lib/firmware/$(dirname "$rel")"
                need_root install -m644 "$file" "$RFS/lib/firmware/$rel"
            done < <(find "$base/$dir" -maxdepth 1 \( -type f -o -type l \) -name 'rtl8723bs*.bin' | sort)
        done
    done
}

install_preseeded_firmware_fallback() {
    [ -s "$RFS/lib/firmware/rtlwifi/rtl8723bs_nic.bin" ] && return 0
    [ -f "$RFS/tce/optional/firmware-rtlwifi.tcz" ] || return 0
    command -v unsquashfs >/dev/null || {
        echo "WARN: unsquashfs missing; cannot extract rtl8723bs firmware from firmware-rtlwifi.tcz" >&2
        return 0
    }

    local tmp file rel
    tmp=$(mktemp -d)
    if ! unsquashfs -quiet -dest "$tmp" "$RFS/tce/optional/firmware-rtlwifi.tcz" >/dev/null; then
        rm -rf "$tmp"
        echo "WARN: could not extract firmware-rtlwifi.tcz" >&2
        return 0
    fi

    while IFS= read -r file; do
        rel=${file#"$tmp/"}
        case "$rel" in
            usr/local/lib/firmware/*) rel=${rel#usr/local/} ;;
            lib/firmware/*) ;;
            *) continue ;;
        esac
        need_root install -d "$RFS/$(dirname "$rel")"
        need_root install -m644 "$file" "$RFS/$rel"
    done < <(find "$tmp" -type f -path '*/firmware/rtlwifi/rtl8723bs*.bin' | sort)

    rm -rf "$tmp"
}

install_extra_modules() {
    local krel module vermagic
    krel="${KERNEL_VERSION}${KERNEL_LOCALVERSION}"
    module="$HERE/build/rtl8812au/8812au.ko"
    [ -f "$module" ] || return 0

    if command -v modinfo >/dev/null; then
        vermagic=$(modinfo -F vermagic "$module" 2>/dev/null || true)
        case "$vermagic" in
            "$krel "*) ;;
            *)
                echo "ERROR: $module vermagic '$vermagic' does not match '$krel'" >&2
                exit 1
                ;;
        esac
    fi

    need_root install -D -m644 "$module" "$RFS/lib/modules/$krel/extra/8812au.ko"
    need_root depmod -b "$RFS" "$krel"
}

preseed_tcz_extensions() {
    [ "${PRESEED_TCZ:-1}" = 1 ] || return 0
    command -v curl >/dev/null || { echo "need curl to preseed TinyCore extensions" >&2; exit 1; }

    local optional="$RFS/tce/optional"
    need_root install -d "$optional"
    declare -A seen=()

    download_optional() {
        local url=$1 dest=$2 tmp
        [ -s "$dest" ] && return 0
        tmp=$(mktemp)
        if curl -fsSL -o "$tmp" "$url"; then
            need_root install -m644 "$tmp" "$dest"
            rm -f "$tmp"
        else
            rm -f "$tmp"
            return 1
        fi
    }

    download_required() {
        local url=$1 dest=$2 tmp
        [ -s "$dest" ] && return 0
        tmp=$(mktemp)
        curl -fSL -o "$tmp" "$url"
        need_root install -m644 "$tmp" "$dest"
        rm -f "$tmp"
    }

    scrub_kernel_placeholder_deps() {
        local depfile=$1 tmp
        [ -s "$depfile" ] || return 0
        if grep -q 'KERNEL' "$depfile"; then
            tmp=$(mktemp)
            grep -v 'KERNEL' "$depfile" >"$tmp" || true
            need_root install -m644 "$tmp" "$depfile"
            rm -f "$tmp"
        fi
    }

    download_tcz() {
        local pkg=$1 dep
        pkg=${pkg%%#*}
        pkg=${pkg//[$'\t\r\n ']/}
        [ -n "$pkg" ] || return 0
        [[ "$pkg" == *.tcz ]] || pkg="$pkg.tcz"
        case "$pkg" in
            *KERNEL*.tcz)
                echo ">> skip TinyCore kernel placeholder $pkg"
                return 0
                ;;
        esac
        [ -n "${seen[$pkg]:-}" ] && return 0
        seen[$pkg]=1

        echo ">> preseed $pkg"
        download_required "$TCZ_REPO/$pkg" "$optional/$pkg"
        download_optional "$TCZ_REPO/$pkg.dep" "$optional/$pkg.dep" || true
        scrub_kernel_placeholder_deps "$optional/$pkg.dep"
        download_optional "$TCZ_REPO/$pkg.md5.txt" "$optional/$pkg.md5.txt" || true
        download_optional "$TCZ_REPO/$pkg.info" "$optional/$pkg.info" || true

        if [ -s "$optional/$pkg.dep" ]; then
            while IFS= read -r dep; do
                download_tcz "$dep"
            done <"$optional/$pkg.dep"
        fi
    }

    while IFS= read -r ext; do
        download_tcz "$ext"
    done < tce/onboot.lst

    if [ -f tce/media.lst ]; then
        while IFS= read -r ext; do
            download_tcz "$ext"
        done < tce/media.lst
    fi

    need_root chown -R 0:0 "$RFS/tce"
}

materialize_tcz_runtime_extensions() {
    [ "${PRESEED_TCZ:-1}" = 1 ] || return 0
    command -v unsquashfs >/dev/null || {
        echo "ERROR: unsquashfs is required to materialize boot-critical TinyCore extensions" >&2
        exit 1
    }

    local optional="$RFS/tce/optional"
    local manifest_dir="$RFS/usr/local/share/x-chip"
    local manifest="$manifest_dir/materialized-tcz.lst"
    local tmp_manifest tmp_extract ext app depfile
    declare -A materialize_seen=()

    need_root install -d "$manifest_dir" "$RFS/usr/local/tce.installed"
    tmp_manifest=$(mktemp)

    normalize_tcz_name() {
        local name=$1
        name=${name%%#*}
        name=${name//[$'\t\r\n ']/}
        [ -n "$name" ] || return 1
        [[ "$name" == *.tcz ]] || name="$name.tcz"
        case "$name" in
            *KERNEL*.tcz) return 1 ;;
        esac
        printf '%s\n' "$name"
    }

    collect_tcz() {
        local name dep
        name=$(normalize_tcz_name "$1") || return 0
        [ -n "${materialize_seen[$name]:-}" ] && return 0
        materialize_seen[$name]=1
        [ -f "$optional/$name" ] || {
            echo "ERROR: cannot materialize missing /tce/optional/$name" >&2
            exit 1
        }
        depfile="$optional/$name.dep"
        if [ -s "$depfile" ]; then
            while IFS= read -r dep; do
                collect_tcz "$dep"
            done <"$depfile"
        fi
        printf '%s\n' "$name" >>"$tmp_manifest"
    }

    for ext in \
        openssh.tcz \
        bash.tcz \
        dhcpcd.tcz \
        wpa_supplicant.tcz \
        iw.tcz \
        wireless_tools.tcz; do
        collect_tcz "$ext"
    done

    sort -u "$tmp_manifest" | while IFS= read -r ext; do
        [ -n "$ext" ] || continue
        echo ">> materialize $ext"
        tmp_extract=$(mktemp -d)
        unsquashfs -quiet -force -dest "$tmp_extract" "$optional/$ext" >/dev/null
        need_root cp -a "$tmp_extract/." "$RFS/"
        rm -rf "$tmp_extract"
        app=${ext%.tcz}
        [ -e "$RFS/usr/local/tce.installed/$app" ] || need_root touch "$RFS/usr/local/tce.installed/$app"
    done

    need_root install -m644 "$tmp_manifest" "$manifest"
    rm -f "$tmp_manifest"
}

install_ca_certificates_bundle() {
    local cert_dir="$RFS/usr/local/share/ca-certificates"
    local conf_src="$cert_dir/files/ca-certificates.conf"
    local conf_dst="$RFS/usr/local/etc/ca-certificates.conf"
    local certs_dir="$RFS/usr/local/etc/ssl/certs"
    local tmp_bundle tmp_list rel cert

    [ -d "$cert_dir" ] || return 0

    need_root install -d \
        "$RFS/usr/local/etc" \
        "$RFS/usr/local/etc/ssl" \
        "$certs_dir" \
        "$RFS/usr/local/etc/pki/certs" \
        "$RFS/etc/ssl"

    if [ ! -s "$conf_dst" ] && [ -s "$conf_src" ]; then
        need_root install -m644 "$conf_src" "$conf_dst"
    fi

    tmp_bundle=$(mktemp)
    tmp_list=$(mktemp)
    if [ -s "$conf_dst" ]; then
        sed -e '/^$/d' -e '/^#/d' -e '/^!/d' "$conf_dst" >"$tmp_list"
    fi
    if [ ! -s "$tmp_list" ]; then
        find "$cert_dir" -type f -name '*.crt' | sed "s#^$cert_dir/##" | sort >"$tmp_list"
    fi

    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        cert="$cert_dir/$rel"
        [ -f "$cert" ] || continue
        sed -e '$a\' "$cert" >>"$tmp_bundle"
    done <"$tmp_list"

    if [ ! -s "$tmp_bundle" ]; then
        rm -f "$tmp_bundle" "$tmp_list"
        echo "ERROR: ca-certificates.tcz was materialized but no CA bundle could be built" >&2
        exit 1
    fi

    need_root install -m644 "$tmp_bundle" "$certs_dir/ca-certificates.crt"
    need_root ln -sfn ca-certificates.crt "$certs_dir/ca-bundle.crt"
    need_root ln -sfn certs/ca-certificates.crt "$RFS/usr/local/etc/ssl/cacert.pem"
    need_root ln -sfn certs/ca-certificates.crt "$RFS/usr/local/etc/ssl/ca-bundle.crt"
    need_root ln -sfn ../../ssl/certs/ca-certificates.crt "$RFS/usr/local/etc/pki/certs/ca-bundle.crt"
    need_root rm -rf "$RFS/etc/ssl/certs"
    need_root ln -sfn /usr/local/etc/ssl/certs "$RFS/etc/ssl/certs"
    rm -f "$tmp_bundle" "$tmp_list"
}

install_boot_runtime_script() {
    local tmp
    tmp=$(mktemp)
    cat >"$tmp" <<'EOF'
#!/bin/sh
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

HOSTNAME_VALUE="@HOSTNAME@"
RTL8812AU_AUTOLOAD_VALUE="@RTL8812AU_AUTOLOAD@"
RTL8812AU_HOTPLUG_VALUE="@RTL8812AU_HOTPLUG@"
LCD_BRIGHTNESS_VALUE="@LCD_BRIGHTNESS@"
LOG=/opt/x-chip-boot.log
exec >>"$LOG" 2>&1
echo "=== x-chip boot runtime $(date 2>/dev/null || true) ==="

boot_seconds() {
	awk '{ printf "%d", $1 }' /proc/uptime 2>/dev/null || echo 0
}

boot_stamp() {
	echo "[$(boot_seconds)s] $*"
}

boot_status() {
	msg="$*"
	boot_stamp "$msg"
	if [ -w /dev/tty1 ]; then
		{
			printf '\033[2J\033[H'
			printf 'X-CHIP TinyCore\n\n'
			printf '%s\n\n' "$msg"
			printf 'Please wait...\n'
		} >/dev/tty1 2>/dev/null || true
	fi
}

if ! grep -q ' /dev/shm ' /proc/mounts 2>/dev/null; then
	mkdir -p /dev/shm 2>/dev/null || true
	mount -t tmpfs tmpfs /dev/shm 2>/dev/null || true
fi
RUN_DIR=/dev/shm/x-chip
RUN_MARKER="$RUN_DIR/boot-ran"
RUN_LOCK="$RUN_DIR/boot.lock"
CONSOLE_READY="$RUN_DIR/console-ready"
TCE_READY="$RUN_DIR/tce-loaded"
mkdir -p "$RUN_DIR" 2>/dev/null || true
rm -rf /tmp/x-chip-firstboot-ran /tmp/x-chip-firstboot.lock 2>/dev/null || true

if [ -e "$RUN_MARKER" ]; then
	echo "x-chip boot runtime already ran this boot"
	exit 0
fi
if ! mkdir "$RUN_LOCK" 2>/dev/null; then
	echo "x-chip boot runtime already running"
	exit 0
fi
trap 'rmdir "$RUN_LOCK" 2>/dev/null || true' EXIT
touch "$RUN_MARKER" 2>/dev/null || true

hostname "$HOSTNAME_VALUE" 2>/dev/null || true
boot_status "Preparing system services"

silence_kernel_console() {
	dmesg -n 1 2>/dev/null || true
	if [ -w /proc/sys/kernel/printk ]; then
		echo '1 4 1 7' > /proc/sys/kernel/printk 2>/dev/null || true
	fi
}

ensure_devpts() {
	mkdir -p /dev/pts 2>/dev/null || true
	if ! grep -q ' /dev/pts ' /proc/mounts 2>/dev/null; then
		mount -t devpts devpts /dev/pts -o mode=620,ptmxmode=666 2>/dev/null || \
			mount -t devpts devpts /dev/pts 2>/dev/null || true
	fi
}

ensure_runtime_dirs() {
	mkdir -p /run /var/run /var/lock /var/run/dbus /var/run/dhcpcd \
		/var/run/tcebootload /var/run/wpa_supplicant 2>/dev/null || true
	chmod 755 /run /var/run /var/run/dbus /var/run/dhcpcd \
		/var/run/tcebootload /var/run/wpa_supplicant 2>/dev/null || true
	chmod 775 /var/lock 2>/dev/null || true
}

reset_tce_installed_markers() {
	[ -d /usr/local/tce.installed ] || return 0
	for marker in /usr/local/tce.installed/*; do
		[ -e "$marker" ] || continue
		ext="${marker##*/}.tcz"
		if [ -r /usr/local/share/x-chip/materialized-tcz.lst ] && grep -qxF "$ext" /usr/local/share/x-chip/materialized-tcz.lst; then
			continue
		fi
		[ -f "/tce/optional/$ext" ] && rm -f "$marker" 2>/dev/null || true
	done
}

prepare_tce_runtime() {
	TC_USER="$(cat /etc/sysconfig/tcuser 2>/dev/null || echo "@SSH_USER@")"
	id "$TC_USER" >/dev/null 2>&1 || TC_USER="@SSH_USER@"

	mkdir -p /usr/local/tce.installed /tmp/tcloop /tmp/tce/optional /tce/optional 2>/dev/null || true
	if [ -d /tce/optional ]; then
		rm -f /etc/sysconfig/tcedir 2>/dev/null || true
		ln -s /tce /etc/sysconfig/tcedir 2>/dev/null || true
	fi
	chgrp staff /usr/local/tce.installed /tmp/tcloop /tmp/tce /tmp/tce/optional /tce /tce/optional 2>/dev/null || true
	chmod g+w /usr/local/tce.installed /tmp/tcloop /tmp/tce /tmp/tce/optional /tce /tce/optional 2>/dev/null || true
	modprobe loop 2>/dev/null || true
	modprobe squashfs 2>/dev/null || true
}

load_tcz_onboot() {
	[ -f /tce/onboot.lst ] || return 0
	command -v tce-load >/dev/null 2>&1 || return 0
	TC_USER="$(cat /etc/sysconfig/tcuser 2>/dev/null || echo "@SSH_USER@")"
	id "$TC_USER" >/dev/null 2>&1 || TC_USER="@SSH_USER@"

	run_tce_load() {
		if [ "$(id -u)" = 0 ] && id "$TC_USER" >/dev/null 2>&1; then
			su "$TC_USER" -c "tce-load -il $1" >/dev/null 2>&1 || true
		else
			tce-load -il "$1" >/dev/null 2>&1 || true
		fi
	}

	load_tcz_one() {
		ext="$1"
		case "$ext" in
			''|\#*) return 0 ;;
		esac
		case "$ext" in
			*.tcz) app="${ext%.tcz}" ;;
			*) app="$ext"; ext="$ext.tcz" ;;
		esac
		[ -e "/usr/local/tce.installed/$app" ] && return 0
		if [ -f "/tce/optional/$ext" ]; then
			run_tce_load "/tce/optional/$ext"
		else
			run_tce_load "$ext"
		fi
	}

	while IFS= read -r ext; do
		load_tcz_one "$ext"
	done < /tce/onboot.lst
}

load_tcz_boot_core() {
	[ -f /tce/onboot.lst ] || return 0
	command -v tce-load >/dev/null 2>&1 || return 0
	for ext in \
		openssh.tcz \
		bash.tcz; do
		app="${ext%.tcz}"
		[ -e "/usr/local/tce.installed/$app" ] && continue
		TC_USER="$(cat /etc/sysconfig/tcuser 2>/dev/null || echo "@SSH_USER@")"
		id "$TC_USER" >/dev/null 2>&1 || TC_USER="@SSH_USER@"
		if [ -f "/tce/optional/$ext" ]; then
			su "$TC_USER" -c "tce-load -il /tce/optional/$ext" >/dev/null 2>&1 || true
		else
			su "$TC_USER" -c "tce-load -il $ext" >/dev/null 2>&1 || true
		fi
	done
}

load_tcz_onboot_background() {
	(
		load_tcz_onboot
		configure_power_management
		load_audio_modules
		start_wifi
		sync_time_background
		load_rtl8812au_if_present
		load_extra_wifi_modules
		start_ssh
		touch "$TCE_READY" 2>/dev/null || true
	) >/var/log/x-chip-tce-background.log 2>&1 &
}

start_usb_debug_gadget() {
	modprobe libcomposite 2>/dev/null || true
	mkdir -p /sys/kernel/config 2>/dev/null || true
	if ! grep -q ' /sys/kernel/config ' /proc/mounts 2>/dev/null; then
		mount -t configfs none /sys/kernel/config 2>/dev/null || true
	fi
	[ -d /sys/kernel/config/usb_gadget ] || {
		echo "WARN: usb gadget configfs not available"
		return 0
	}

	G=/sys/kernel/config/usb_gadget/xchip_tinycore
	mkdir -p "$G" "$G/strings/0x409" "$G/configs/c.1/strings/0x409" 2>/dev/null || return 0
	echo 0x1d6b > "$G/idVendor" 2>/dev/null || true
	echo 0x0104 > "$G/idProduct" 2>/dev/null || true
	echo 0x0100 > "$G/bcdDevice" 2>/dev/null || true
	echo 0x0200 > "$G/bcdUSB" 2>/dev/null || true
	echo xchip-tinycore > "$G/strings/0x409/serialnumber" 2>/dev/null || true
	echo NTC > "$G/strings/0x409/manufacturer" 2>/dev/null || true
	echo "CHIP TinyCore debug" > "$G/strings/0x409/product" 2>/dev/null || true
	echo "USB debug network" > "$G/configs/c.1/strings/0x409/configuration" 2>/dev/null || true
	echo 250 > "$G/configs/c.1/MaxPower" 2>/dev/null || true

	FUNC=
	if mkdir -p "$G/functions/rndis.usb0" 2>/dev/null; then
		FUNC=rndis.usb0
	elif mkdir -p "$G/functions/ecm.usb0" 2>/dev/null; then
		FUNC=ecm.usb0
	else
		echo "WARN: no RNDIS/ECM gadget function available"
		return 0
	fi
	echo de:ad:be:ef:54:01 > "$G/functions/$FUNC/dev_addr" 2>/dev/null || true
	echo de:ad:be:ef:54:02 > "$G/functions/$FUNC/host_addr" 2>/dev/null || true
	[ -e "$G/configs/c.1/$FUNC" ] || ln -s "$G/functions/$FUNC" "$G/configs/c.1/$FUNC" 2>/dev/null || true

	if [ -e "$G/UDC" ]; then
		CURRENT_UDC="$(cat "$G/UDC" 2>/dev/null || true)"
	else
		CURRENT_UDC=
	fi
	if [ -z "$CURRENT_UDC" ]; then
		UDC="$(ls /sys/class/udc 2>/dev/null | head -n 1)"
		[ -n "$UDC" ] && echo "$UDC" > "$G/UDC" 2>/dev/null || true
	fi

	i=0
	while [ "$i" -lt 10 ]; do
		[ -e /sys/class/net/usb0 ] && break
		i=$((i + 1))
		sleep 1
	done
	if [ -e /sys/class/net/usb0 ]; then
		ifconfig usb0 192.168.82.1 netmask 255.255.255.0 up 2>/dev/null || true
		echo "USB debug network ready on 192.168.82.1"
	else
		echo "WARN: usb0 did not appear"
	fi
	}

load_pocketchip_input_modules() {
	modprobe matrix-keymap 2>/dev/null || true
	modprobe tca8418_keypad 2>/dev/null || true
	modprobe sun4i-lradc-keys 2>/dev/null || true
	modprobe sun4i-ts 2>/dev/null || true
}

configure_power_management() {
	modprobe cpufreq-dt 2>/dev/null || true
	modprobe axp20x_battery 2>/dev/null || true
	modprobe axp20x_ac_power 2>/dev/null || true
	modprobe axp20x_usb_power 2>/dev/null || true
	modprobe axp20x_adc 2>/dev/null || true
	modprobe iio-hwmon 2>/dev/null || true
	modprobe sun4i-gpadc-iio 2>/dev/null || true
	modprobe nvmem_sunxi_sid 2>/dev/null || true
	modprobe sunxi_wdt 2>/dev/null || true

	for governor in ondemand conservative powersave; do
		for available in /sys/devices/system/cpu/cpu*/cpufreq/scaling_available_governors; do
			[ -r "$available" ] || continue
			if grep -qw "$governor" "$available" 2>/dev/null; then
				for target in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
					[ -w "$target" ] && echo "$governor" > "$target" 2>/dev/null || true
				done
				echo "CPU governor set to $governor where available"
				return 0
			fi
		done
	done
}

load_audio_modules() {
	modprobe snd-simple-card 2>/dev/null || true
	modprobe snd-soc-simple-card 2>/dev/null || true
	modprobe sun4i-codec 2>/dev/null || true
	modprobe snd-soc-sun4i-codec 2>/dev/null || true
	modprobe sun4i-i2s 2>/dev/null || true
	modprobe snd-soc-sun4i-i2s 2>/dev/null || true
	modprobe sun4i-spdif 2>/dev/null || true
	modprobe snd-soc-sun4i-spdif 2>/dev/null || true
	modprobe snd-usb-audio 2>/dev/null || true
	modprobe snd-seq-midi 2>/dev/null || true
	modprobe snd-virmidi 2>/dev/null || true
	modprobe snd-pcm-oss 2>/dev/null || true
	modprobe snd-mixer-oss 2>/dev/null || true

	i=0
	while [ "$i" -lt 10 ]; do
		[ -r /proc/asound/cards ] && grep -q '^[[:space:]]*[0-9]' /proc/asound/cards 2>/dev/null && break
		i=$((i + 1))
		sleep 1
	done

	if command -v alsactl >/dev/null 2>&1; then
		alsactl init >/var/log/alsactl-init.log 2>&1 || true
	fi
	if command -v amixer >/dev/null 2>&1; then
		amixer set Master unmute >/dev/null 2>&1 || true
		amixer set Master 80% >/dev/null 2>&1 || true
		amixer set Headphone unmute >/dev/null 2>&1 || true
		amixer set Headphone 80% >/dev/null 2>&1 || true
		amixer set Speaker unmute >/dev/null 2>&1 || true
		amixer set Speaker 80% >/dev/null 2>&1 || true
		amixer set PCM 80% >/dev/null 2>&1 || true
		amixer set 'Power Amplifier Mute' on >/dev/null 2>&1 || true
		amixer set 'Power Amplifier Mixer' on >/dev/null 2>&1 || true
		amixer set 'Power Amplifier DAC' on >/dev/null 2>&1 || true
		amixer set 'Power Amplifier' 80% >/dev/null 2>&1 || true
		amixer set 'Left Mixer Left DAC' on >/dev/null 2>&1 || true
		amixer set 'Right Mixer Right DAC' on >/dev/null 2>&1 || true
	fi
}

start_wifi() {
	[ -r /etc/wpa_supplicant.conf ] || return 0
	modprobe r8723bs rtw_power_mgnt=0 rtw_ips_mode=0 2>/dev/null || modprobe r8723bs 2>/dev/null || true
	rfkill unblock wifi 2>/dev/null || true

	i=0
	while [ "$i" -lt 30 ]; do
		WIFI_IFACE="$(find_internal_wifi_iface)"
		[ -n "$WIFI_IFACE" ] && break
		i=$((i + 1))
		sleep 1
	done
	[ -n "$WIFI_IFACE" ] || {
		echo "WARN: internal r8723bs WiFi interface not found"
		return 0
	}

	ip link set "$WIFI_IFACE" up 2>/dev/null || ifconfig "$WIFI_IFACE" up 2>/dev/null || true
	if ! pidof wpa_supplicant >/dev/null 2>&1; then
		wpa_supplicant -B -i "$WIFI_IFACE" -c /etc/wpa_supplicant.conf >/var/log/wpa_supplicant.log 2>&1 || true
	fi

	if command -v dhcpcd >/dev/null 2>&1; then
		dhcpcd -q -t 20 "$WIFI_IFACE" >/var/log/dhcpcd-"$WIFI_IFACE".log 2>&1 || true
	elif command -v udhcpc >/dev/null 2>&1; then
		udhcpc -i "$WIFI_IFACE" -x "hostname:$HOSTNAME_VALUE" -b >/var/log/udhcpc-"$WIFI_IFACE".log 2>&1 || true
	fi
}

sync_time_background() {
	[ -x /usr/local/bin/x-chip-time ] || return 0
	/usr/local/bin/x-chip-time sync-background >/dev/null 2>&1 || true
}

find_internal_wifi_iface() {
	for iface_path in /sys/class/net/wlan* /sys/class/net/wlp*; do
		[ -e "$iface_path" ] || continue
		iface="${iface_path##*/}"
		driver=""
		if [ -r "$iface_path/device/uevent" ]; then
			driver="$(sed -n 's/^DRIVER=//p' "$iface_path/device/uevent" | head -n 1)"
		fi
		if [ -z "$driver" ] && [ -L "$iface_path/device/driver" ]; then
			driver_path="$(readlink "$iface_path/device/driver" 2>/dev/null || true)"
			driver="${driver_path##*/}"
		fi
		case "$driver" in
			r8723bs|rtl8723bs)
				printf '%s\n' "$iface"
				return 0
				;;
		esac
	done
	return 1
}

load_keymap() {
	[ -r /usr/share/kmap/pocketchip.kmap ] || return 0
	if command -v loadkmap >/dev/null 2>&1; then
		loadkmap < /usr/share/kmap/pocketchip.kmap >/var/log/loadkmap.log 2>&1 || true
	fi
}

enable_display_console() {
	for backlight in /sys/class/backlight/*; do
		[ -e "$backlight" ] || continue
		[ -w "$backlight/bl_power" ] && echo 0 > "$backlight/bl_power" 2>/dev/null || true
		if [ -r "$backlight/max_brightness" ] && [ -w "$backlight/brightness" ]; then
			max_brightness="$(cat "$backlight/max_brightness" 2>/dev/null || echo 10)"
			[ -n "$max_brightness" ] || max_brightness=10
			min_brightness=1
			[ "$max_brightness" -lt "$min_brightness" ] && min_brightness=0
			brightness="$LCD_BRIGHTNESS_VALUE"
			case "$brightness" in
				''|*[!0-9]*) brightness="$max_brightness" ;;
			esac
			[ "$brightness" -lt "$min_brightness" ] && brightness="$min_brightness"
			[ "$brightness" -gt "$max_brightness" ] && brightness="$max_brightness"
			echo "$brightness" > "$backlight/brightness" 2>/dev/null || true
			echo "LCD brightness set to $brightness/$max_brightness"
		fi
	done
	for fbblank in /sys/class/graphics/fb*/blank; do
		[ -w "$fbblank" ] && echo 0 > "$fbblank" 2>/dev/null || true
	done
}

load_extra_wifi_modules() {
	[ "$RTL8812AU_AUTOLOAD_VALUE" = 1 ] || {
		echo "RTL8812AU boot autoload disabled; hotplug=$RTL8812AU_HOTPLUG_VALUE"
		return 0
	}
	modprobe 8812au >/var/log/modprobe-8812au.log 2>&1 || true
}

load_rtl8812au_if_present() {
	[ "$RTL8812AU_HOTPLUG_VALUE" = 1 ] || return 0
	for dev in /sys/bus/usb/devices/*; do
		[ -r "$dev/idVendor" ] || continue
		[ "$(cat "$dev/idVendor" 2>/dev/null)" = "0bda" ] || continue
		echo "Realtek USB device present; loading RTL8812AU secondary adapter support"
		/usr/local/sbin/x-chip-rtl8812au-hotplug >/dev/null 2>&1 || modprobe 8812au >/var/log/modprobe-8812au.log 2>&1 || true
		return 0
	done
}

ensure_ssh_host_keys() {
	command -v ssh-keygen >/dev/null 2>&1 || return 0
	mkdir -p /usr/local/etc/ssh
	[ -f /usr/local/etc/ssh/ssh_host_ed25519_key ] || ssh-keygen -q -t ed25519 -N '' -f /usr/local/etc/ssh/ssh_host_ed25519_key
	[ -f /usr/local/etc/ssh/ssh_host_rsa_key ] || ssh-keygen -q -t rsa -b 3072 -N '' -f /usr/local/etc/ssh/ssh_host_rsa_key
}

start_ssh() {
	lock_dir="${RUN_DIR:-/dev/shm/x-chip}/ssh.lock"
	mkdir -p "${lock_dir%/*}" 2>/dev/null || true
	if ! mkdir "$lock_dir" 2>/dev/null; then
		return 0
	fi
	ensure_ssh_host_keys
	if pidof sshd >/dev/null 2>&1; then
		rmdir "$lock_dir" 2>/dev/null || true
		return 0
	fi
	if [ -x /usr/local/etc/init.d/openssh ]; then
		/usr/local/etc/init.d/openssh start >/var/log/openssh.log 2>&1 || true
	elif command -v sshd >/dev/null 2>&1; then
		sshd >/var/log/openssh.log 2>&1 || true
	fi
	rmdir "$lock_dir" 2>/dev/null || true
}

silence_kernel_console
ensure_devpts
ensure_runtime_dirs
prepare_tce_runtime
reset_tce_installed_markers
boot_stamp "Runtime directories and TinyCore state ready"
load_pocketchip_input_modules
load_keymap
enable_display_console
boot_status "Console, keyboard, and display ready"
touch "$CONSOLE_READY" 2>/dev/null || true
start_usb_debug_gadget &
boot_stamp "USB debug network start requested"
boot_status "Loading SSH boot core"
load_tcz_boot_core
boot_stamp "SSH boot core loaded"
start_ssh
boot_stamp "SSH service requested"
load_tcz_onboot_background
boot_stamp "Background extension load requested"
boot_status "Console and SSH recovery ready"
boot_stamp "Boot runtime complete"
EOF
    sed -i "s/@HOSTNAME@/$CHIP_HOSTNAME/g" "$tmp"
    sed -i "s/@SSH_USER@/$SSH_USER/g" "$tmp"
    sed -i "s/@RTL8812AU_AUTOLOAD@/${RTL8812AU_AUTOLOAD:-0}/g" "$tmp"
    sed -i "s/@RTL8812AU_HOTPLUG@/${RTL8812AU_HOTPLUG:-1}/g" "$tmp"
    sed -i "s/@LCD_BRIGHTNESS@/${LCD_BRIGHTNESS:-6}/g" "$tmp"
    need_root rm -f "$RFS/opt/x-chip-firstboot.sh"
    need_root install -m755 "$tmp" "$RFS/opt/x-chip-boot.sh"
    rm -f "$tmp"

    need_root touch "$RFS/opt/bootlocal.sh"
    tmp=$(mktemp)
    awk '
        $0 == "/usr/local/etc/init.d/openssh start" { next }
        $0 == "/opt/x-chip-firstboot.sh" { next }
        $0 == "/opt/x-chip-boot.sh" { next }
        $0 ~ /^# --- x-chip.*(firstboot|boot runtime).*---$/ { next }
        { print }
    ' "$RFS/opt/bootlocal.sh" >"$tmp"
    need_root install -m755 "$tmp" "$RFS/opt/bootlocal.sh"
    rm -f "$tmp"
    need_root chown 0:0 "$RFS/opt/bootlocal.sh" 2>/dev/null || true
    need_root chmod +x "$RFS/opt/bootlocal.sh"
    if ! need_root grep -q '/opt/x-chip-boot.sh' "$RFS/opt/bootlocal.sh"; then
        need_root tee -a "$RFS/opt/bootlocal.sh" >/dev/null <<'EOF'
# --- x-chip boot runtime ---
/opt/x-chip-boot.sh
EOF
    fi

    need_root install -d "$RFS/usr/local/etc/ssh"
    local password_auth
    password_auth=no
    [ "$SSH_PASSWORD_AUTH" = 1 ] && password_auth=yes
    install_text 0644 "$RFS/usr/local/etc/ssh/sshd_config" <<EOF
Port 22
Protocol 2
HostKey /usr/local/etc/ssh/ssh_host_ed25519_key
HostKey /usr/local/etc/ssh/ssh_host_rsa_key
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PasswordAuthentication $password_auth
PermitEmptyPasswords no
PermitRootLogin prohibit-password
UseDNS no
Subsystem sftp internal-sftp
EOF

    need_root touch "$RFS/opt/.filetool.lst"
    tmp=$(mktemp)
    awk '$0 != "opt/x-chip-firstboot.sh" { print }' "$RFS/opt/.filetool.lst" >"$tmp"
    need_root install -m644 "$tmp" "$RFS/opt/.filetool.lst"
    rm -f "$tmp"
    for entry in \
        "etc/hostname" \
        "etc/hosts" \
        "etc/os-release" \
        "etc/issue" \
        "etc/motd" \
        "etc/modprobe.conf" \
        "etc/modprobe.d/8812au.conf" \
        "etc/modprobe.d/r8723bs.conf" \
        "etc/udev/rules.d/90-x-chip-rtl8812au-hotplug.rules" \
        "etc/wpa_supplicant.conf" \
        "home/$SSH_USER/.ssh" \
        "root/.ssh" \
        "usr/local/etc/ssh" \
        "usr/local/etc/x-chip" \
        "usr/share/kmap/pocketchip.kmap" \
        "usr/share/kmap/pocketchip.loadkeys" \
        "usr/local/share/x-chip/materialized-tcz.lst" \
        "usr/local/bin/x-chip-keyboard-status" \
        "usr/local/bin/x-chip-audio-status" \
        "usr/local/bin/x-chip-power-status" \
        "usr/local/bin/x-chip-term-hold" \
        "usr/local/bin/x-chip-status" \
        "usr/local/bin/x-chip-time" \
        "usr/local/bin/x-chip-brightness" \
        "usr/local/bin/x-chip-logs" \
        "usr/local/bin/x-chip-media-on" \
        "usr/local/sbin/x-chip-rtl8812au-hotplug" \
        "opt/x-chip-boot.sh" \
        "opt/x-chip-autologin.sh" \
        "opt/x-chip-tty1-getty.sh" \
        "opt/bootlocal.sh"; do
        need_root grep -qxF "$entry" "$RFS/opt/.filetool.lst" 2>/dev/null || \
            echo "$entry" | need_root tee -a "$RFS/opt/.filetool.lst" >/dev/null
    done
}

# 1. u-boot boot script.
"$MKIMAGE" -A arm -O linux -T script -C none \
    -d boot/boot.cmd "$RFS/boot/boot.scr"

# 2. tce mirror + onboot extension list (pulled on first online boot).
need_root install -d "$RFS/tce/optional"
need_root cp tce/onboot.lst "$RFS/tce/onboot.lst"
[ -f tce/media.lst ] && need_root cp tce/media.lst "$RFS/tce/media.lst"
need_root install -d "$RFS/opt"
echo "$TC_MIRROR" | need_root tee "$RFS/opt/tcemirror" >/dev/null

# 3. Runtime identity, SSH, WiFi and local extensions.
install_runtime_identity
install_os_branding
install_runtime_mounts
install_console_config
patch_tinycore_tce_setup
patch_tinycore_tc_config
write_wifi_config
install_board_runtime_config
install_keymap
install_keyboard_debug_tools
install_hardware_debug_tools
install_media_tools
install_user_command_symlinks
install_rtl8812au_hotplug
install_extra_firmware
install_extra_modules
create_static_dev_nodes
install_early_debug
preseed_tcz_extensions
materialize_tcz_runtime_extensions
install_ca_certificates_bundle
install_preseeded_firmware_fallback
install_boot_runtime_script

# 4. pack (numeric owners; the flasher rebuilds the UBIFS from this tree).
normalize_rootfs_metadata
( cd "$RFS" && tar --numeric-owner -czf "$HERE/$OUT" . )
need_root chown "$(id -u):$(id -g)" "$HERE/$OUT" 2>/dev/null || true
for required in ./bin/busybox ./sbin/init ./init ./etc/inittab ./etc/init.d/tc-config; do
    tar -tzf "$HERE/$OUT" "$required" >/dev/null 2>&1 || {
        echo "ERROR: packed rootfs is missing $required" >&2
        exit 1
    }
done
for required in \
    ./boot/zImage \
    ./boot/boot.scr \
    ./boot/sun5i-r8-chip.dtb \
    ./opt/x-chip-boot.sh \
    ./opt/x-chip-autologin.sh \
    ./opt/x-chip-tty1-getty.sh \
    ./usr/local/bin/x-chip-keyboard-status \
    ./usr/local/bin/x-chip-audio-status \
    ./usr/local/bin/x-chip-power-status \
    ./usr/local/bin/x-chip-term-hold \
    ./usr/local/bin/x-chip-status \
    ./usr/local/bin/x-chip-time \
    ./usr/local/bin/x-chip-brightness \
    ./usr/local/bin/x-chip-logs \
    ./usr/local/bin/x-chip-media-on \
    ./usr/local/sbin/x-chip-rtl8812au-hotplug \
    ./usr/local/etc/x-chip/display.conf \
    ./usr/local/share/x-chip/materialized-tcz.lst \
    ./etc/modprobe.d/8812au.conf \
    ./etc/udev/rules.d/90-x-chip-rtl8812au-hotplug.rules \
    ./usr/local/etc/ssh/sshd_config \
    ./home/$SSH_USER/.ssh/authorized_keys \
    ./home/$SSH_USER/Pictures \
    ./home/$SSH_USER/Videos \
    ./usr/share/kmap/pocketchip.kmap \
    ./lib/firmware/nextthingco/chip/early/x-chip-pocketchip.dtbo \
    ./lib/firmware/rtlwifi/rtl8723bs_nic.bin \
    ./tce/onboot.lst \
    ./tce/media.lst; do
    tar -tzf "$HERE/$OUT" "$required" >/dev/null 2>&1 || {
        echo "ERROR: packed rootfs is missing $required" >&2
        exit 1
    }
done
if [ "${REQUIRE_WIFI_CONFIG:-1}" = 1 ]; then
    tar -tzf "$HERE/$OUT" ./etc/wpa_supplicant.conf >/dev/null 2>&1 || {
        echo "ERROR: packed rootfs is missing WiFi config" >&2
        exit 1
    }
fi
if [ "${RTL8812AU_BUILD:-1}" = 1 ]; then
    tar -tzf "$HERE/$OUT" "./lib/modules/${KERNEL_VERSION}${KERNEL_LOCALVERSION}/extra/8812au.ko" >/dev/null 2>&1 || {
        echo "ERROR: packed rootfs is missing RTL8812AU module" >&2
        exit 1
    }
fi

"$HERE/scripts/07-verify-rootfs.sh" "$HERE/$OUT"

echo ">> wrote $HERE/$OUT"
echo ">> flash: ../x-chip-tools/flash-live.sh $OUT"
