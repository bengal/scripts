#!/bin/sh

modprobe -r mac80211_hwsim
modprobe mac80211_hwsim radios=3

hostapd wlan1.conf &
hostapd wlan2.conf
