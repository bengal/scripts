#!/bin/sh

# Set up two virtial Wi-Fi APs, connect to one of them with NM and
# then force a roam.

set -ex

modprobe -r mac80211_hwsim 2>/dev/null || :
ip netns del ns 2>/dev/null || :
killall hostapd 2>/dev/null || :
killall dnsmasq 2>/dev/null || :
nmcli connection delete wifi-roam+ 2>/dev/null || :
rm -f /var/lib/NetworkManager/internal*-wlan0.lease

modprobe mac80211_hwsim radios=3

nmcli device set wlan0 managed yes
nmcli device set wlan1 managed no
nmcli device set wlan2 managed no

ip netns add ns

iw phy phy1 set netns name ns
iw phy phy2 set netns name ns

ip -n ns link add br0 type bridge
ip -n ns link set wlan1 up
ip -n ns link set wlan2 up
ip -n ns link set br0 up
ip -n ns addr add dev br0 172.25.1.1/24

# Delay the 4-way handshake a bit
ip netns exec ns tc qdisc add dev wlan2 root netem delay 20ms

cat <<EOF > /tmp/wlan1.conf
interface=wlan1
driver=nl80211
ctrl_interface=/var/run/hostapd-wlan1
ctrl_interface_group=0
ssid=wifi-roam
country_code=EN
hw_mode=g
channel=7
auth_algs=3
wpa=2
wpa_key_mgmt=WPA-PSK
wpa_passphrase=secret123
bridge=br0
EOF

sed -e 's/wlan1/wlan2/' /tmp/wlan1.conf > /tmp/wlan2.conf

ip netns exec ns hostapd /tmp/wlan1.conf > /tmp/wlan1.log 2>&1 &
ip netns exec ns hostapd /tmp/wlan2.conf > /tmp/wlan2.log 2>&1 &

ip netns exec ns dnsmasq --interface br0 --bind-interfaces --dhcp-range=172.25.1.100,172.25.1.200 --dhcp-sequential-ip --dhcp-leasefile=/dev/null

nmcli connection add \
      type wifi \
      con-name wifi-roam+ \
      ifname wlan0 \
      wifi.ssid wifi-roam \
      wifi-sec.psk secret123 \
      wifi-sec.key-mgmt wpa-psk \
      autoconnect no

nmcli device wifi rescan
sleep 15
nmcli device wifi

nmcli connection up wifi-roam+
ip addr show dev wlan0

path=$(nmcli -g general.dbus-path device show wlan0)
ap=$(busctl -j get-property org.freedesktop.NetworkManager "$path" org.freedesktop.NetworkManager.Device.Wireless ActiveAccessPoint | jq -r .data)
bssid=$(busctl -j get-property org.freedesktop.NetworkManager  "$ap" org.freedesktop.NetworkManager.AccessPoint HwAddress | jq -r .data)

echo $bssid

if [ "$bssid" = 02:00:00:00:01:00 ]; then
    new_bssid=02:00:00:00:02:00
elif [ "$bssid" = 02:00:00:00:02:00 ]; then
    new_bssid=02:00:00:00:01:00
else
    echo " *** Error: unexpected bssid $bssid ***"
    exit 1
fi      

sleep 4

int=$(busctl --list tree fi.w1.wpa_supplicant1  | grep 'Interfaces/[0-9]*$' | tail -n 1)
busctl call fi.w1.wpa_supplicant1 $int fi.w1.wpa_supplicant1.Interface Roam "s" "$new_bssid"

sleep 4

busctl call fi.w1.wpa_supplicant1 $int fi.w1.wpa_supplicant1.Interface Roam "s" "$bssid"
