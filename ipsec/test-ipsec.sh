#!/bin/bash

# work in progress

set -x

#  +----------------+      +----------------+      +----------------+
#  | 172.16.1.10/24 <------> 172.16.1.15/24 |      |                |
#  |  fd01::10/64   |  n1  |  fd01::15/64   |      |                |
#  |                |      |                |      |                |
#  |  ipsec-host1   |      |  ipsec-router  |      |  ipsec-host2   |
#  |                |      |                |      |                |
#  |                |      | 172.16.2.15/24 <------> 172.16.2.20/24 |
#  |                |      |  fd02::15/64   |  n2  |  fd02::20/64   |
#  +----------------+      +----------------+      +----------------+
#  
distro=fedora:39
image=fedora-ipsec
c1=ipsec-host1
c2=ipsec-host2
cr=ipsec-router
scriptdir="$(dirname "$(readlink -f "$0")")"
tmpdir=$(mktemp -d /tmp/libreswan-XXXXXX)

# trap 'rm -rf "$tmpdir"' EXIT

while [[ $# -gt 0 ]]; do
    case "$1" in
        --conf|-c)
            if [[ $# -lt 1 ]]; then
                echo "Missing argument to '$1'"
                exit 1
            fi

            conf=$2

            shift
            shift
            ;;
        *)
            echo "Invalid option '$1'"
            exit 1
            ;;
    esac
done

conf=${conf:-host-to-host}
conf_dir="$scriptdir/confs/$conf"
if [[ ! -d "$conf_dir" ]]; then
    echo "Directory '$conf_dir' does not exist"
    exit 1
fi

container_is_running() {
    test "$(podman ps --format "{{.ID}} {{.Names}}" | sed -n "s/ $1\$/\0/p")" != "" || return 1
}

generate_host_key()
{
    local container="$1"

    podman exec "$container" rm -f /var/lib/ipsec/nss/*.db /var/lib/ipsec/nss/pkcs11.txt
    podman exec "$container" ipsec initnss --nssdir /var/lib/ipsec/nss > /dev/null
    podman exec "$container" ipsec newhostkey /dev/null
    ckaid=$(podman exec "$container" ipsec showhostkey --list | tail -n 1 | grep -o "[0-9a-f]*$")
    key=$(podman exec "$container" ipsec showhostkey --left --ckaid $ckaid)
    echo "$key" | sed -e '/^\t#/d' -e 's/^\tleftrsasigkey=//'
}

replace_string()
{
    local from="$1"
    local to="$2"
    local file="$3"

    to_escaped=$(sed 's/[&/\]/\\&/g' <<< "$to")
    sed -i -e "s/$from/$to_escaped/g" "$file"
}

build_base_image()
{
    podman image exists "$image" && return

    mkdir -p $tmpdir/build/
    cp ~/.ssh/authorized_keys $tmpdir/build/
    cat <<EOF > "$tmpdir/build/Containerfile"
FROM $distro

ENTRYPOINT ["/sbin/init"]

RUN dnf install -y libreswan \
    NetworkManager-libreswan \
    NetworkManager-libreswan-gnome \
    nm-connection-editor \
    iputils \
    hostname \
    openssh-server \
    bash-completion \
    less \
    policycoreutils \
    tcpdump
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

if ! podman network exists n1; then
    podman network create --internal --subnet 172.16.1.0/24 --ipv6 --subnet fd01::/64 n1
fi

if ! podman network exists n2; then
    podman network create --internal --subnet 172.16.2.0/24 --ipv6 --subnet fd02::/64 n2
fi


# FIXME: the tmp dir changes every time, need to restart container
podman stop "$c1"
podman stop "$c2"
podman stop "$cr"

if ! container_is_running "$c1"; then
    podman run \
           --rm \
           --privileged \
           --detach \
           --tty \
           -v $tmpdir:/tmp/ipsec \
           -v $XAUTHORITY:$XAUTHORITY:ro -v /tmp/.X11-unix:/tmp/.X11-unix:ro \
           --security-opt label=type:container_runtime_t \
           --network n1:ip=172.16.1.10,ip=fd01::10 \
           --name "$c1" \
           "$image"
fi

if ! container_is_running "$c2"; then
    podman run \
           --rm \
           --privileged \
           --detach \
           --tty \
           -v $tmpdir:/tmp/ipsec \
           -v $XAUTHORITY:$XAUTHORITY:ro -v /tmp/.X11-unix:/tmp/.X11-unix:ro \
           --security-opt label=type:container_runtime_t \
           --network n2:ip=172.16.2.20,ip=fd02::20 \
           --name "$c2" \
           "$image"
fi

if ! container_is_running "$cr"; then
    podman run \
           --rm \
           --privileged \
           --detach \
           --tty \
           -v $tmpdir:/tmp/ipsec \
           -v $XAUTHORITY:$XAUTHORITY:ro -v /tmp/.X11-unix:/tmp/.X11-unix:ro \
           --security-opt label=type:container_runtime_t \
           --network n1:ip=172.16.1.15,ip=fd01::15 \
           --network n2:ip=172.16.2.15,ip=fd02::15 \
           --name "$cr" \
           "$image"
fi

echo " * Setting up IPv6..."

sleep 3 # XXX

podman exec "$c1" nmcli connection modify eth0 \
       ipv4.gateway 172.16.1.15 ipv6.gateway fd01::15
podman exec "$c1" nmcli device reapply eth0

podman exec "$c2" nmcli connection modify eth0 \
       ipv4.gateway 172.16.2.15 ipv6.gateway fd02::15
podman exec "$c2" nmcli device reapply eth0

podman exec "$cr" sh -c "echo 1 > /proc/sys/net/ipv4/conf/all/forwarding"
podman exec "$cr" sh -c "echo 1 > /proc/sys/net/ipv6/conf/all/forwarding"

ip1=$(podman inspect "$c1" -f '{{ .NetworkSettings.IPAddress }}')
ip2=$(podman inspect "$c2" -f '{{ .NetworkSettings.IPAddress }}')

echo " * Setting hostnames ..."
podman exec "$c1" hostname hosta.example.org
podman exec "$c2" hostname hostb.example.org

echo " * Generating keys ..."
key1=$(generate_host_key "$c1")
key2=$(generate_host_key "$c2")

echo "   - key1: $key1"
echo "   - key2: $key2"

cp "$conf_dir/1.conf" "$tmpdir/ipsec1.conf"
cp "$conf_dir/2.conf" "$tmpdir/ipsec2.conf"
if [ -e "$conf_dir/post.sh" ]; then
    cp "$conf_dir/post.sh" "$tmpdir"
    podman exec "$c1" sh /tmp/ipsec/post.sh
    podman exec "$c2" sh /tmp/ipsec/post.sh
fi

for f in "$tmpdir/ipsec1.conf" "$tmpdir/ipsec2.conf"; do
    replace_string "@@IP1@@"  "$ip1"  "$f"
    replace_string "@@IP2@@"  "$ip2"  "$f"
    replace_string "@@KEY1@@" "$key1" "$f"
    replace_string "@@KEY2@@" "$key2" "$f"
done

printf "$ip1 $ip2 : PSK \"a64-charslongrandomstringgeneratedwithpwgenoropensslorothertool\"" > "$tmpdir/ipsec.secrets"

podman exec "$c1" cp /tmp/ipsec/ipsec.secrets /etc/
podman exec "$c2" cp /tmp/ipsec/ipsec.secrets /etc/

echo " * Setting up certificates..."

for h in hosta.example.org hostb.example.org; do
    openssl pkcs12 -export -in "$scriptdir/certs/$h.crt" \
            -inkey "$scriptdir/certs/$h.key" \
            -certfile "$scriptdir/certs/ca.crt" \
            -passout pass:password \
            -out "$tmpdir/$h.p12"
done

podman exec "$c1" pk12util -i /tmp/ipsec/hosta.example.org.p12 \
       -d sql:/var/lib/ipsec/nss \
       -W password
podman exec "$c1" certutil -M \
       -n "nmstate-test-ca.example.org" -t CT,, -d sql:/var/lib/ipsec/nss

podman exec "$c2" pk12util -i /tmp/ipsec/hostb.example.org.p12 \
       -d sql:/var/lib/ipsec/nss \
       -W password
podman exec "$c2" certutil -M \
       -n "nmstate-test-ca.example.org" -t CT,, -d sql:/var/lib/ipsec/nss



echo " * Starting IPsec..."

cat "$tmpdir/ipsec1.conf" | podman exec -i "$c1" /bin/bash -c "cat > /etc/ipsec.conf"
podman exec "$c1" ipsec setup stop
podman exec "$c1" ipsec setup start

cat "$tmpdir/ipsec2.conf" | podman exec -i "$c2" /bin/bash -c "cat > /etc/ipsec.conf"
podman exec "$c2" ipsec setup stop
podman exec "$c2" ipsec setup start

sleep 2

podman exec "$c1" ipsec auto --status
podman exec "$c2" ipsec auto --status
