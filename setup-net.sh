#!/usr/bin/env sh
modprobe tun

ip tuntap add dev tap0 mode tap group network
ip addr add 192.168.101.1/24 dev tap0
ip link set tap0 up
iptables -A FORWARD -i $1 -o tap0 -j ACCEPT
iptables -A FORWARD -i tap0 -o $1 -j ACCEPT

ip tuntap add dev tap1 mode tap group network
ip addr add 192.168.102.1/24 dev tap1
ip link set tap1 up
iptables -A FORWARD -i $1 -o tap1 -j ACCEPT
iptables -A FORWARD -i tap1 -o $1 -j ACCEPT

iptables -t nat -A POSTROUTING -o $1 -j MASQUERADE
