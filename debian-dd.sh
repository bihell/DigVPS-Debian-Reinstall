#!/bin/bash

# color
underLine='\033[4m'
aoiBlue='\033[36m'
blue='\033[34m'
yellow='\033[33m'
green='\033[32m'
red='\033[31m'
plain='\033[0m'

clear
# 检查是否是 root 用户
if [ "$EUID" -ne 0 ]; then
    echo "Error: Please use the root user to execute this script."
    exit
fi

echo "-----------------------------------------------------------------"
echo -e "This script was written by ${aoiBlue}DigVPS.COM${plain}"
echo -e "${aoiBlue}VPS Review Site${plain}: https://digvps.com/"
echo "-----------------------------------------------------------------"

debian_version="trixie"

echo -en "\n${aoiBlue}Start installing Debian $debian_version...${plain}\n"

echo -en "\n${aoiBlue}Set hostname:${plain}\n"
read -p "Please input [Default digvps]:" HostName
if [ -z "$HostName" ]; then
    HostName="digvps"
fi

echo -ne "\n${aoiBlue}Set root password${plain}\n"
read -p "Please input [Enter directly to generate a random password]: " passwd
if [ -z "$passwd" ]; then
# Length of the password
    PASSWORD_LENGTH=16

    # Generate the password
    passwd=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c $PASSWORD_LENGTH)

    echo -e "Generated password: ${red}$passwd${plain}"
fi

echo -ne "\n${aoiBlue}Set ssh port${plain}\n"
read -p "Please input [Default 22]: " sshPORT
if [ -z "$sshPORT" ]; then
    sshPORT=22
fi

echo -ne "\n${aoiBlue}Whether to enable BBR${plain}\n"
read -p "Please input y/n [Default y]: " enableBBR
if [[ -z "$enableBBR" || "$enableBBR" =~ ^[Yy]$ ]]; then
    echo -ne "${aoiBlue}Use advanced (aggressive) TCP tuning?${plain}\n"
    read -p "y/n [Default n]: " enableBBRAdv

    # Target file inside the installed system
    bbr_path="/etc/sysctl.d/99-sysctl.conf"

    # Minimal safe set (always enabled when BBR is chosen)
    BBR_MIN_CONTENT="'net.core.default_qdisc = fq' 'net.ipv4.tcp_congestion_control = bbr'"

    # Advanced optional set (toggleable)
    BBR_ADV_CONTENT="'net.ipv4.tcp_rmem = 8192 262144 536870912' \
                     'net.ipv4.tcp_wmem = 4096 16384 536870912' \
                     'net.ipv4.tcp_adv_win_scale = -2' \
                     'net.ipv4.tcp_collapse_max_bytes = 6291456' \
                     'net.ipv4.tcp_notsent_lowat = 131072' \
                     'net.ipv4.ip_local_port_range = 1024 65535' \
                     'net.core.rmem_max = 536870912' \
                     'net.core.wmem_max = 536870912' \
                     'net.core.somaxconn = 32768' \
                     'net.core.netdev_max_backlog = 32768' \
                     'net.ipv4.tcp_max_tw_buckets = 65536' \
                     'net.ipv4.tcp_abort_on_overflow = 1' \
                     'net.ipv4.tcp_slow_start_after_idle = 0' \
                     'net.ipv4.tcp_timestamps = 1' \
                     'net.ipv4.tcp_syncookies = 0' \
                     'net.ipv4.tcp_syn_retries = 3' \
                     'net.ipv4.tcp_synack_retries = 3' \
                     'net.ipv4.tcp_max_syn_backlog = 32768' \
                     'net.ipv4.tcp_fin_timeout = 15' \
                     'net.ipv4.tcp_keepalive_intvl = 3' \
                     'net.ipv4.tcp_keepalive_probes = 5' \
                     'net.ipv4.tcp_keepalive_time = 600' \
                     'net.ipv4.tcp_retries1 = 3' \
                     'net.ipv4.tcp_retries2 = 5' \
                     'net.ipv4.tcp_no_metrics_save = 1' \
                     'net.ipv4.ip_forward = 1' \
                     'fs.file-max = 104857600' \
                     'fs.inotify.max_user_instances = 8192' \
                     'fs.nr_open = 1048576'"

    # Build printf args: minimal always, plus advanced if selected
    if [[ "$enableBBRAdv" =~ ^[Yy]$ ]]; then
        BBR_CONTENT="$BBR_MIN_CONTENT $BBR_ADV_CONTENT"
    else
        BBR_CONTENT="$BBR_MIN_CONTENT"
    fi

    # Write the content atomically inside target, ensuring directory exists
    target="in-target"
    BBR="$target /bin/sh -c \"mkdir -p /etc/sysctl.d; \\
        printf '%s\\n' $BBR_CONTENT > $bbr_path; \\
        sysctl --system >/dev/null 2>&1 || true\";"
else
    BBR=""
fi

# Get the device number of the root directory
root_device=$(df / | awk 'NR==2 {print $1}')

# Extract the partition number from the device number
partitionr_root_number=$(echo "$root_device" | grep -oE '[0-9]+$')

# Resolve root block device and its parent (handles NVMe, SCSI, virtio, etc.)
ROOT_SOURCE=$(findmnt -no SOURCE /)
ROOT_BLK=$(readlink -f "$ROOT_SOURCE")
# If this is a mapper device, find its underlying block device
PARENT_DISK=$(lsblk -no pkname "$ROOT_BLK" 2>/dev/null | head -n1)
if [ -z "$PARENT_DISK" ]; then
    # If pkname is empty (e.g., for partitions), strip partition suffix to get disk
    PARENT_DISK=$(lsblk -no name "$ROOT_BLK" | head -n1)
fi
# If still empty, fallback to parsing df output
if [ -z "$PARENT_DISK" ]; then
    PARENT_DISK=$(lsblk -no pkname "$(df / | awk 'NR==2 {print $1}')" 2>/dev/null | head -n1)
fi
if [ -z "$PARENT_DISK" ]; then
    echo "Could not determine the parent disk of /. Exiting to avoid data loss." && exit 1
fi
DEVICE_PREFIX="$PARENT_DISK"

# Check if any disk is mounted
if [ -z "$(df -h)" ]; then
    echo "No disks are currently mounted."
    exit 1
fi

rm -rf /netboot
mkdir /netboot && cd /netboot

# Select primary physical network interface (ignore virtual: veth, docker*, br-*, lo, tun*, tap*, wg*, tailscale*, virbr*, vnet*, vmnet*)
get_physical_ifaces() {
    for i in $(ls -1 /sys/class/net); do
        [ "$i" = "lo" ] && continue
        case "$i" in veth*|docker*|br-*|tun*|tap*|wg*|tailscale*|virbr*|vnet*|vmnet*) continue;; esac
        # Only keep if it has a backing device (physical)
        if [ -e "/sys/class/net/$i/device" ]; then
            echo "$i"
        fi
    done
}

# Pick interface that carries the default route (prefer IPv4, then IPv6)
PRIMARY_IFACE=""
for cand in $(get_physical_ifaces); do
    if ip -4 route show default 2>/dev/null | grep -q " dev $cand "; then PRIMARY_IFACE="$cand"; break; fi
done
if [ -z "$PRIMARY_IFACE" ]; then
    for cand in $(get_physical_ifaces); do
        if ip -6 route show default 2>/dev/null | grep -q " dev $cand "; then PRIMARY_IFACE="$cand"; break; fi
    done
fi
# Fallback to first physical iface
if [ -z "$PRIMARY_IFACE" ]; then
    PRIMARY_IFACE=$(get_physical_ifaces | head -n1)
fi

if [ -z "$PRIMARY_IFACE" ]; then
    echo "No physical network interface detected." && exit 1
fi
PRIMARY_MAC=$(cat "/sys/class/net/$PRIMARY_IFACE/address" 2>/dev/null || true)

# IPv4 details
IPV4_CIDR=$(ip -4 -o addr show dev "$PRIMARY_IFACE" scope global | awk '{print $4}' | head -n1)
IPV4_ADDR=${IPV4_CIDR%%/*}
IPV4_PREFIX=${IPV4_CIDR##*/}
IPV4_DEFAULT_ROUTE=$(ip -4 route show default dev "$PRIMARY_IFACE" 2>/dev/null | head -n1)
IPV4_GATEWAY=$(echo "$IPV4_DEFAULT_ROUTE" | awk '/default/ {print $3; exit}')
IPV4_ONLINK=""
echo "$IPV4_DEFAULT_ROUTE" | grep -qw onlink && IPV4_ONLINK="yes"

# Convert prefix to netmask (e.g., 24 -> 255.255.255.0)
to_netmask() {
    local p=$1; local mask=""; local i
    for i in 1 2 3 4; do
        if [ $p -ge 8 ]; then mask+="255"; p=$((p-8))
        else mask+=$((256 - 2**(8-p))) ; p=0; fi
        [ $i -lt 4 ] && mask+="."
    done
    echo "$mask"
}
IPV4_NETMASK=""
if [ -n "$IPV4_PREFIX" ]; then IPV4_NETMASK=$(to_netmask "$IPV4_PREFIX"); fi

# IPv6 details (global address only)
# Detect IPv6 default gateway by explicitly extracting the token after 'via' and strip zone id (e.g., %eth0)
IPV6_DEFAULT_ROUTE=$(ip -6 route show default dev "$PRIMARY_IFACE" 2>/dev/null | head -n1)
IPV6_ONLINK=""
echo "$IPV6_DEFAULT_ROUTE" | grep -qw onlink && IPV6_ONLINK="yes"
IPV6_GATEWAY=$(echo "$IPV6_DEFAULT_ROUTE" \
    | awk '($1=="default"){for(i=1;i<=NF;i++){if($i=="via"){print $(i+1); exit}}}' \
    | sed 's/%.*//')
# Sanity: if awk somehow yielded a bare integer (e.g., mis-parse), drop it
if echo "$IPV6_GATEWAY" | grep -qE '^[0-9]+$'; then IPV6_GATEWAY=""; fi

IPV6_CIDR=$(ip -6 -o addr show dev "$PRIMARY_IFACE" scope global | awk '{print $4}' | head -n1)
IPV6_ADDR=${IPV6_CIDR%%/*}
IPV6_PREFIX=${IPV6_CIDR##*/}

# ifupdown target methods. Keep DHCP/RA fallback when no static value is detected.
IFUPDOWN_IPV4_METHOD="dhcp"
[ -n "$IPV4_ADDR" ] && IFUPDOWN_IPV4_METHOD="static"

IFUPDOWN_IPV6_METHOD="auto"
[ -n "$IPV6_ADDR" ] && IFUPDOWN_IPV6_METHOD="static"

IFUPDOWN_IPV4_GATEWAY_LINE=""
IFUPDOWN_IPV4_ROUTE_LINES=""
if [ -n "$IPV4_GATEWAY" ]; then
    if [ "$IPV4_PREFIX" = "32" ] || [ "$IPV4_ONLINK" = "yes" ]; then
        IFUPDOWN_IPV4_ROUTE_LINES="'    post-up ip route replace default via ${IPV4_GATEWAY} dev \\\$IFACE onlink' '    pre-down ip route del default via ${IPV4_GATEWAY} dev \\\$IFACE || true'"
    else
        IFUPDOWN_IPV4_GATEWAY_LINE="'    gateway ${IPV4_GATEWAY}'"
    fi
fi

IFUPDOWN_IPV6_GATEWAY_LINE=""
IFUPDOWN_IPV6_LINKLOCAL_ROUTE_LINES=""
if [ -n "$IPV6_GATEWAY" ]; then
    if echo "$IPV6_GATEWAY" | grep -qi '^fe80:'; then
        IFUPDOWN_IPV6_LINKLOCAL_ROUTE_LINES="'    post-up ip -6 route replace default via ${IPV6_GATEWAY} dev \\\$IFACE' '    pre-down ip -6 route del default via ${IPV6_GATEWAY} dev \\\$IFACE || true'"
    elif [ "$IPV6_PREFIX" = "128" ] || [ "$IPV6_ONLINK" = "yes" ]; then
        IFUPDOWN_IPV6_LINKLOCAL_ROUTE_LINES="'    post-up ip -6 route replace default via ${IPV6_GATEWAY} dev \\\$IFACE onlink' '    pre-down ip -6 route del default via ${IPV6_GATEWAY} dev \\\$IFACE || true'"
    else
        IFUPDOWN_IPV6_GATEWAY_LINE="'    gateway ${IPV6_GATEWAY}'"
    fi
fi

# DNS selection (user choice: default to Google IPv4/IPv6)
GOOGLE_NS_V4="8.8.8.8 1.1.1.1"
GOOGLE_NS_V6="2001:4860:4860::8888 2606:4700:4700::1111"

echo -ne "\n${aoiBlue}DNS configuration${plain}\n"
read -p "Use current system DNS? y/n [Default n -> Google]: " useDefaultDNS

# Helper to collect current resolv.conf nameservers and filter out link-local IPv6
collect_dns() {
    awk '/^nameserver/ {print $2}' /etc/resolv.conf 2>/dev/null | awk 'NF {print $1}'
}

if [[ "$useDefaultDNS" =~ ^[Yy]$ ]]; then
    DNS_ALL=$(collect_dns)
    # Filter out link-local IPv6 (fe80::/10) and empty lines
    DNS_ALL=$(echo "$DNS_ALL" | awk 'NF && $1 !~ /^fe8[0-9a-f]:/ && $1 !~ /^fe9[0-9a-f]:/ && $1 !~ /^fea[0-9a-f]:/ && $1 !~ /^feb[0-9a-f]:/')
    # Split into families
    NS_V4=$(echo "$DNS_ALL" | awk 'index($1, ":")==0' | xargs)
    NS_V6=$(echo "$DNS_ALL" | awk 'index($1, ":")>0' | xargs)
    # If either family missing, supplement with Google defaults
    [ -z "$NS_V4" ] && NS_V4="$GOOGLE_NS_V4"
    [ -z "$NS_V6" ] && NS_V6="$GOOGLE_NS_V6"
else
    NS_V4="$GOOGLE_NS_V4"
    NS_V6="$GOOGLE_NS_V6"
fi

# Combine back; keep order v4 first then v6
NAMESERVERS="$(echo $NS_V4 $NS_V6 | xargs)"
# Safety: always have a fallback so resolv.conf is not left empty
if [ -z "$NAMESERVERS" ]; then
    NAMESERVERS="$GOOGLE_NS_V4 $GOOGLE_NS_V6"
fi

echo -en "\n${aoiBlue}Download boot file...${plain}\n"
wget -q -O linux "https://ftp.debian.org/debian/dists/$debian_version/main/installer-amd64/current/images/netboot/debian-installer/amd64/linux" || { echo "Error: failed to download netboot kernel (linux)." >&2; exit 1; }
wget -q -O initrd.gz "https://ftp.debian.org/debian/dists/$debian_version/main/installer-amd64/current/images/netboot/debian-installer/amd64/initrd.gz" || { echo "Error: failed to download netboot initrd (initrd.gz)." >&2; exit 1; }


echo -e "${aoiBlue}Start configuring pre-installed file...${plain}"
mkdir temp_initrd
cd temp_initrd
gunzip -c ../initrd.gz | cpio -i

cat << EOF > preseed.cfg

d-i debian-installer/locale string en_US.UTF-8
d-i debian-installer/language string en
d-i debian-installer/country string CN
d-i keyboard-configuration/xkb-keymap select us
d-i passwd/make-user boolean false
d-i passwd/root-password password $passwd
d-i passwd/root-password-again password $passwd
d-i user-setup/allow-password-weak boolean true

### Network configuration
# Configure networking during install based on the current system values.
d-i netcfg/choose_interface select auto
# IPv4 static when detected; otherwise allow autoconfig
${IPV4_ADDR:+d-i netcfg/disable_autoconfig boolean true}
${IPV4_ADDR:+d-i netcfg/dhcp_failed note}
${IPV4_ADDR:+d-i netcfg/dhcp_options select Configure network manually}
${IPV4_ADDR:+d-i netcfg/get_ipaddress string $IPV4_ADDR}
${IPV4_NETMASK:+d-i netcfg/get_netmask string $IPV4_NETMASK}
${IPV4_GATEWAY:+d-i netcfg/get_gateway string $IPV4_GATEWAY}
d-i netcfg/get_nameservers string $NAMESERVERS
${IPV4_ADDR:+d-i netcfg/confirm_static boolean true}
# IPv6: enable and seed static values if detected; otherwise allow RA/DHCPv6
d-i netcfg/enable_ipv6 boolean true

### Low memory mode
d-i lowmem/low note

### hostname
d-i netcfg/hostname string $HostName

### Mirror settings
d-i mirror/country string manual
d-i mirror/http/hostname string deb.debian.org
d-i mirror/http/directory string /debian
d-i mirror/http/proxy string

d-i clock-setup/utc boolean true
d-i clock-setup/ntp boolean true
d-i time/zone string Asia/Shanghai
d-i partman-auto/disk string /dev/$DEVICE_PREFIX
# (installer echo) using detected root disk /dev/$DEVICE_PREFIX
d-i partman-auto/method string regular
d-i partman-lvm/device_remove_lvm boolean true
d-i partman-md/device_remove_md boolean true
d-i partman-basicfilesystems/no_swap boolean false
d-i partman-auto/expert_recipe string                       \
200 1 200 ext4 \
        \$primary{ } \$bootable{ } \
        method{ format } format{ } \
        use_filesystem{ } filesystem{ ext4 } \
        mountpoint{ /boot } \
    . \
201 2 -1 ext4 \
        \$primary{ } \
        method{ format } format{ } \
        use_filesystem{ } filesystem{ ext4 } \
        mountpoint{ / } \
    .
d-i partman-md/confirm_nooverwrite boolean true
d-i partman-lvm/confirm_nooverwrite boolean true
d-i partman/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true

### Package selection
tasksel tasksel/first multiselect standard, ssh-server
d-i pkgsel/include string ifupdown lrzsz net-tools vim rsync socat curl sudo wget telnet iptables gpg zsh python3 python3-pip nmap tree iperf3 vnstat ufw unzip

d-i pkgsel/update-policy select none
d-i pkgsel/upgrade select none

d-i grub-installer/grub2_instead_of_grub_legacy boolean true
d-i grub-installer/only_debian boolean true
d-i grub-installer/bootdev string /dev/$DEVICE_PREFIX

### Write preseed
d-i preseed/late_command string \
sed -ri 's/^#?PermitRootLogin.*/PermitRootLogin yes/g' /target/etc/ssh/sshd_config; \
sed -ri 's/^#?Port.*/Port ${sshPORT}/g' /target/etc/ssh/sshd_config; \
${BBR} \
 TARGET_IFACE=\$(awk '\$1=="iface" && \$2!="lo" && \$3=="inet" {print \$2; exit}' /target/etc/network/interfaces 2>/dev/null); \
 [ -n "\$TARGET_IFACE" ] || TARGET_IFACE=\$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++){if(\$i=="dev"){print \$(i+1); exit}}}'); \
 [ -n "\$TARGET_IFACE" ] || TARGET_IFACE=\$(ip -6 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++){if(\$i=="dev"){print \$(i+1); exit}}}'); \
 [ -n "\$TARGET_IFACE" ] || TARGET_IFACE="${PRIMARY_IFACE}"; \
 echo "debian-dd.sh final network interface: \$TARGET_IFACE (source ${PRIMARY_IFACE}, mac ${PRIMARY_MAC})" > /target/root/debian-dd-network.log; \
 in-target mkdir -p /etc/network/interfaces.d; \
 in-target /bin/sh -c "printf '%s\n' \
 '# This file is managed by debian-dd.sh.' \
 'source /etc/network/interfaces.d/*' \
 '' \
 'auto lo' \
 'iface lo inet loopback' \
 '' \
 'auto '\${TARGET_IFACE} \
 'allow-hotplug '\${TARGET_IFACE} \
 'iface '\${TARGET_IFACE}' inet ${IFUPDOWN_IPV4_METHOD}' \
 ${IPV4_ADDR:+"'    address ${IPV4_ADDR}'"} \
 ${IPV4_NETMASK:+"'    netmask ${IPV4_NETMASK}'"} \
 ${IFUPDOWN_IPV4_GATEWAY_LINE} \
 ${IFUPDOWN_IPV4_ROUTE_LINES} \
 ${NAMESERVERS:+"'    dns-nameservers ${NAMESERVERS}'"} \
 '' \
 'iface '\${TARGET_IFACE}' inet6 ${IFUPDOWN_IPV6_METHOD}' \
 ${IPV6_ADDR:+"'    address ${IPV6_ADDR}'"} \
 ${IPV6_PREFIX:+"'    netmask ${IPV6_PREFIX}'"} \
 ${IFUPDOWN_IPV6_GATEWAY_LINE} \
 ${IFUPDOWN_IPV6_LINKLOCAL_ROUTE_LINES} \
 > /etc/network/interfaces"; \
 in-target /bin/sh -c "rm -f /etc/resolv.conf; : > /etc/resolv.conf; for ns in ${NAMESERVERS}; do printf 'nameserver %s\n' \"\$ns\" >> /etc/resolv.conf; done"; \
 in-target systemctl disable systemd-networkd.service systemd-resolved.service 2>/dev/null || true;
### Shutdown machine
d-i finish-install/reboot_in_progress note
EOF
find . | cpio -H newc -o | gzip -6 > ../initrd.gz && cd ..
rm -rf temp_initrd 
cat << EOF >> /etc/grub.d/40_custom
menuentry "DigVPS.COM Debian Installer AMD64" {
    set root="(hd0,$partitionr_root_number)"
    linux /netboot/linux auto=true priority=critical lowmem/low=true preseed/file=/preseed.cfg
    initrd /netboot/initrd.gz
}
EOF

# Modifying the GRUB DEFAULT option
sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=2/' /etc/default/grub
# Modify the GRUB TIMEOUT option
sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=2/' /etc/default/grub

update-grub 

echo "-----------------------------------------------------------------"
echo "Reinstall summary (what the installer will use):"
echo "  Root disk      : /dev/${DEVICE_PREFIX} (GRUB target)"
echo "  Boot partition : (hd0,${partitionr_root_number}) in GRUB entry"
echo "  Interface      : ${PRIMARY_IFACE}"
if [ -n "${PRIMARY_MAC}" ]; then echo "  MAC            : ${PRIMARY_MAC}"; fi
if [ -n "${IPV4_ADDR}" ]; then echo "  IPv4           : ${IPV4_ADDR}/${IPV4_PREFIX}  gw ${IPV4_GATEWAY}"; else echo "  IPv4           : (none)"; fi
if [ -n "${IPV6_ADDR}" ]; then echo "  IPv6           : ${IPV6_ADDR}/${IPV6_PREFIX}  gw ${IPV6_GATEWAY}"; else echo "  IPv6           : (none)"; fi
echo "  DNS            : ${NAMESERVERS}"
echo "-----------------------------------------------------------------"

echo -ne "\n[${aoiBlue}Finish${plain}] Input '${red}reboot${plain}' to continue the subsequential installation.\n"
exit 1
