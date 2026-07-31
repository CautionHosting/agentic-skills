#!/bin/busybox sh
set -eu

echo "Configuring QEMU virtio networking..."
while IFS= read -r module; do
    [ -n "$module" ] || continue
    /bin/busybox insmod "$module"
done < /qemu-network/modules.list

/bin/busybox ip link set eth0 up
/bin/busybox ip addr add 10.0.2.15/24 dev eth0
/bin/busybox ip route add default via 10.0.2.2 dev eth0
echo "nameserver 10.0.2.3" > /etc/resolv.conf
/bin/busybox ip addr show eth0

exec /run.sh
