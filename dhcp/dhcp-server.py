#!/usr/bin/env python3

# Simulate a DHCP server.

from scapy.all import *
from datetime import datetime
import time

IFACE = "veth1"
SERVER_IP = "172.25.1.1"
CLIENT_IP = "172.25.1.200"
SERVER_MAC = "00:01:02:09:04:05"
SUBNET_MASK = "255.255.255.0"
GATEWAY = "172.25.1.254"

DHCP_TYPE_UNKNOWN = 0
DHCP_TYPE_DISCOVER = 1
DHCP_TYPE_OFFER = 2
DHCP_TYPE_REQUEST = 3
DHCP_TYPE_DECLINE = 4
DHCP_TYPE_ACK = 5
DHCP_TYPE_NAK = 6
DHCP_TYPE_RELEASE = 7


def send_offer(pkt):
    sendp(
        Ether(src=SERVER_MAC, dst=pkt[Ether].src)
        / IP(src=SERVER_IP, dst="255.255.255.255")
        / UDP(sport=67, dport=68)
        / BOOTP(
            op=2,
            yiaddr=CLIENT_IP,
            siaddr=SERVER_IP,
            giaddr=GATEWAY,
            chaddr=bytes.fromhex(pkt[Ether].src.replace(":", "")),
            xid=pkt[BOOTP].xid,
        )
        / DHCP(
            options=[
                ("message-type", DHCP_TYPE_OFFER),
                ("server_id", SERVER_IP),
                ("lease_time", 40),
                ("renewal_time", 20),
                ("rebinding_time", 30),
                ("subnet_mask", SUBNET_MASK),
                ("router", GATEWAY),
                ("end"),
            ]
        ),
        iface=IFACE,
        verbose=0,
    )
    log("-> DHCP Offer")


def send_ack(pkt):
    sendp(
        Ether(src=SERVER_MAC, dst=pkt[Ether].src)
        / IP(src=SERVER_IP, dst=CLIENT_IP)
        / UDP(sport=67, dport=68)
        / BOOTP(
            op=2,
            yiaddr=CLIENT_IP,
            siaddr=SERVER_IP,
            giaddr=GATEWAY,
            chaddr=bytes.fromhex(pkt[Ether].src.replace(":", "")),
            xid=pkt[BOOTP].xid,
        )
        / DHCP(
            options=[
                ("message-type", DHCP_TYPE_ACK),
                ("server_id", SERVER_IP),
                ("lease_time", 40),
                ("renewal_time", 20),
                ("rebinding_time", 30),
                ("subnet_mask", SUBNET_MASK),
                ("router", GATEWAY),
                ("end"),
            ]
        ),
        iface=IFACE,
        verbose=0,
    )
    log("-> DHCP Ack")

def on_discover(pkt):
    log("<- DHCP Discover : {}".format(pkt[DHCP].options))
    send_offer(pkt)

def on_request(pkt):
    log("<- DHCP Request : {}".format(pkt[DHCP].options))
    time.sleep(3)
    send_ack(pkt)

def log(msg):
    print("{} | {}".format(datetime.now(), msg))

def handle_dhcp_packet(pkt):
    if not pkt[DHCP]:
        return

    message_type = DHCP_TYPE_UNKNOWN
    for opt in pkt[DHCP].options:
        if opt[0] == "message-type":
            message_type = opt[1]

    if message_type == DHCP_TYPE_DISCOVER:
        on_discover(pkt)

    if message_type == DHCP_TYPE_REQUEST:
        on_request(pkt)

if __name__ == "__main__":
    sniff(iface=IFACE, filter="udp and src port 68 and dst port 67", prn=handle_dhcp_packet)
