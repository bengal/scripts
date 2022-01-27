#!/bin/sh

path=$(nmcli -g general.dbus-path device show wlan0)
ap=$(busctl get-property org.freedesktop.NetworkManager "$path" org.freedesktop.NetworkManager.Device.Wireless ActiveAccessPoint)
state=$(nmcli -g general.state device show wlan0)

echo "DEVICE:     wlan0"
echo "STATE:      $state"
echo "ACTIVE-AP:  $ap"

