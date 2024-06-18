#!/bin/bash

# work in progress

set -x

#  +----------------+     +----------------+     +----------------+                
#  |  (IPv6 SLAAC)  <----->   2002::1/64   |     |                |        
#  |                | n1  |     (radvd)    |     |                |   
#  |                |     |                |     |                | 
#  |     host1      |     |     router     |     |      host2     |
#  |                |     |                | n2  |                |
#  |                |     |   1.0.0.1/24   <----->   1.0.0.2/24   |
#  |                |     |   2001::1/64   |     |   2001::2/64   |         
#  +----------------+     +----------------+     +----------------+

image=fedora-nat64
tmpdir=$(mktemp -d /tmp/nat64-XXXXXX)

trap 'rm -rf "$tmpdir"' EXIT

container_is_running() {
    test "$(podman ps --format "{{.ID}} {{.Names}}" | sed -n "s/ $1\$/\0/p")" != "" || return 1
}

build_base_image()
{
    podman image exists "$image" && return

    mkdir -p $tmpdir/build/
    cp ~/.ssh/authorized_keys $tmpdir/build/
    cat <<EOF > "$tmpdir/build/Containerfile"
FROM fedora:39

ENTRYPOINT ["/sbin/init"]

RUN dnf install -y clang \
    make \
    libmnl-devel \
    bind \
    openssh-server \
    bash-completion \
    less \
    gdb \
    valgrind \
    rsync \
    tcpdump \
    iproute \
    radvd \
    procps-ng \
    iputils \
    tayga
COPY authorized_keys /root/.ssh/authorized_keys
RUN systemctl enable sshd
RUN rm /etc/machine-id
EOF

    podman build \
           --squash-all \
           --tag "$image" \
           "$tmpdir/build"
}

build_base_image

podman network rm -f n1
podman network rm -f n2
podman network rm -f ext

if ! podman network exists n1; then
    podman network create --disable-dns --internal --ipam-driver=none n1
fi

if ! podman network exists n2; then
    podman network create --disable-dns --internal --ipam-driver=none n2
fi

if ! podman network exists ext; then
    podman network create ext
fi


# For now, restart the container every time
podman stop host1 2>/dev/null
podman stop router 2>/dev/null
podman stop host2 2>/dev/null

if ! container_is_running host1; then
    podman run \
           --rm \
           --privileged \
           --detach \
           --tty \
           -v $tmpdir:/tmp/nat64 \
           --network n1 \
           --network ext \
           --name host1 \
           "$image"
fi

if ! container_is_running router; then
    podman run \
           --rm \
           --privileged \
           --detach \
           --tty \
           -v $tmpdir:/tmp/nat64 \
           --network n1 \
           --network n2 \
           --network ext \
           --name router \
           "$image"
fi

if ! container_is_running host2; then
    podman run \
           --rm \
           --privileged \
           --detach \
           --tty \
           -v $tmpdir:/tmp/nat64 \
           --network n2 \
           --name host2 \
           "$image"
fi

sleep 3

### xxx
podman exec router dnf -y install procps-ng radvd

### addresses and routes
podman exec router ip addr add dev eth0 2002::1/64
podman exec router ip addr add dev eth1 1.0.0.1/24
podman exec router ip addr add dev eth1 2001::1/64

podman exec host2  ip addr add dev eth0 1.0.0.2/24
podman exec host2  ip addr add dev eth0 2001::2/64
podman exec host2  ip -6 route add 2002::/64 via 2001::1 dev eth0


podman exec router sysctl -w net.ipv4.ip_forward=1
podman exec router sysctl -w net.ipv6.conf.all.forwarding=1

sleep 3

### radvd
cp radvd.conf $tmpdir/
podman exec router cp /tmp/nat64/radvd.conf /etc/radvd.conf
podman exec router systemctl start radvd

### dns64

cp named.conf $tmpdir/
podman exec router cp /tmp/nat64/named.conf /etc/named.conf
podman exec router systemctl enable --now named
podman exec host1 sh -c "echo 'nameserver 2002::1' > /etc/resolv.conf"

### nat64
cp tayga.conf $tmpdir/
podman exec router dnf -y install tayga
podman exec router cp /tmp/nat64/tayga.conf /etc/tayga/default.conf
podman exec router tayga --config /etc/tayga/default.conf --mktun
podman exec router ip link set nat64 up
podman exec router ip route add 1.0.0.128/25 dev nat64
podman exec router ip route add 64:ff9b::/96 dev nat64
podman exec router systemctl restart tayga@default
podman exec host2  ip route add 1.0.0.128/25 via 1.0.0.1 dev eth0


