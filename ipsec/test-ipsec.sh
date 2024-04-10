#!/bin/bash

# work in progress

#set -x

distro=fedora:39
image=fedora-ipsec
cont1=libreswan1
cont2=libreswan2
scriptdir="$(dirname "$(readlink -f "$0")")"
conf=host-to-host
tmpdir=$(mktemp -d /tmp/libreswan-XXXXXX)

trap 'rm -rf "$tmpdir"' EXIT

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

# FIXME: the tmp dir changes every time, need to restart container
podman stop "$cont1"
podman stop "$cont2"

if ! container_is_running "$cont1"; then
    podman run \
           --rm \
           --privileged \
           --detach \
           -v $tmpdir:/tmp/ipsec \
           -v $XAUTHORITY:$XAUTHORITY:ro -v /tmp/.X11-unix:/tmp/.X11-unix:ro \
           --security-opt label=type:container_runtime_t \
           --name "$cont1" \
           "$image"
fi

if ! container_is_running "$cont2"; then
    podman run \
           --rm \
           --privileged \
           --detach \
           -v $tmpdir:/tmp/ipsec \
           -v $XAUTHORITY:$XAUTHORITY:ro -v /tmp/.X11-unix:/tmp/.X11-unix:ro \
           --security-opt label=type:container_runtime_t \
           --name "$cont2" \
           "$image"
fi

ip1=$(podman inspect "$cont1" -f '{{ .NetworkSettings.IPAddress }}')
ip2=$(podman inspect "$cont2" -f '{{ .NetworkSettings.IPAddress }}')

echo " * Container 1 is running with address $ip1"
echo " * Container 2 is running with address $ip2"

echo " * Setting hostnames ..."
podman exec "$cont1" hostname hosta.example.org
podman exec "$cont2" hostname hostb.example.org

echo " * Generating keys ..."
key1=$(generate_host_key "$cont1")
key2=$(generate_host_key "$cont2")

echo "   - key1: $key1"
echo "   - key2: $key2"

cp "$conf_dir/1.conf" "$tmpdir/ipsec1.conf"
cp "$conf_dir/2.conf" "$tmpdir/ipsec2.conf"

for f in "$tmpdir/ipsec1.conf" "$tmpdir/ipsec2.conf"; do
    replace_string "@@IP1@@"  "$ip1"  "$f"
    replace_string "@@IP2@@"  "$ip2"  "$f"
    replace_string "@@KEY1@@" "$key1" "$f"
    replace_string "@@KEY2@@" "$key2" "$f"
done

printf "$ip1 $ip2 : PSK \"a64-charslongrandomstringgeneratedwithpwgenoropensslorothertool\"" > "$tmpdir/ipsec.secrets"

podman exec "$cont1" cp /tmp/ipsec/ipsec.secrets /etc/
podman exec "$cont2" cp /tmp/ipsec/ipsec.secrets /etc/

echo " * Setting up certificates..."

set -x

for h in hosta.example.org hostb.example.org; do
    openssl pkcs12 -export -in "$scriptdir/certs/$h.crt" \
            -inkey "$scriptdir/certs/$h.key" \
            -certfile "$scriptdir/certs/ca.crt" \
            -passout pass:password \
            -out "$tmpdir/$h.p12"
done

podman exec "$cont1" pk12util -i /tmp/ipsec/hosta.example.org.p12 \
       -d sql:/var/lib/ipsec/nss \
       -W password
podman exec "$cont1" certutil -M \
       -n "nmstate-test-ca.example.org" -t CT,, -d sql:/var/lib/ipsec/nss

podman exec "$cont2" pk12util -i /tmp/ipsec/hostb.example.org.p12 \
       -d sql:/var/lib/ipsec/nss \
       -W password
podman exec "$cont2" certutil -M \
       -n "nmstate-test-ca.example.org" -t CT,, -d sql:/var/lib/ipsec/nss

echo " * Setting up IPv6..."

podman exec "$cont1" nmcli connection modify eth0 \
       ipv6.method manual ipv6.addresses fd01::2/64 ipv6.gateway fd01::1
podman exec "$cont1" nmcli connection up eth0

podman exec "$cont2" nmcli connection modify eth0 \
       ipv6.method manual ipv6.addresses fd01::3/64 ipv6.gateway fd01::1
podman exec "$cont2" nmcli connection up eth0


echo " * Starting IPsec..."

cat "$tmpdir/ipsec1.conf" | podman exec -i "$cont1" /bin/bash -c "cat > /etc/ipsec.conf"
podman exec "$cont1" ipsec setup stop
podman exec "$cont1" ipsec setup start

cat "$tmpdir/ipsec2.conf" | podman exec -i "$cont2" /bin/bash -c "cat > /etc/ipsec.conf"
podman exec "$cont2" ipsec setup stop
podman exec "$cont2" ipsec setup start

sleep 2

podman exec "$cont1" ipsec auto --status
podman exec "$cont2" ipsec auto --status
