#!/bin/bash

# File stdin format:
#
# basePort
# interceptedIP	interceptedPort
# interceptedIP	interceptedPort
# interceptedIP	interceptedPort
# interceptedIP	interceptedPort
# interceptedIP	interceptedPort
# ...
#
# Sample:
# 9000	10000
# 123.48.12.122	443
# 123.48.12.128	143
# 123.43.12.112	587

set -e

read localBase
localBasePort1="$(cut -f 1 <<< "$localBase")"
localBasePort2="$(cut -f 2 <<< "$localBase")"
stunnelConfigDir="$(mktemp -d)"
cd $stunnelConfigDir

echo "[+] Killing previous stunnels."
killall -9 stunnel

echo "[+] Configuring iptables and forwarding."
echo 1 > /proc/sys/net/ipv4/ip_forward
iptables -t nat -F

echo "[+] Generating wildcard certificate."
openssl genrsa 2048 > host.key
subj="
C=CR
ST=ST
O=ACME
localityName=TOWN
commonName=*
organizationalUnitName=INTERCEPT
emailAddress=$(whoami)@$(uname -n)"
openssl req -new -x509 -nodes -sha1 -days 3650 -key host.key -subj "$(tr "\n" "/" <<< "$subj")" > host.cert
cat host.cert host.key > host.pem


counter=0
while read line; do
	remoteIP="$(cut -f 1 <<< "$line")"
	remotePort="$(cut -f 2 <<< "$line")"
	localPort1="$(($localBasePort1 + $counter))"
	localPort2="$(($localBasePort2 + $counter))"
	serverConfig="server-$counter.conf"
	clientConfig="client-$counter.conf"
	
	echo "[+] Configuring iptables to redirect $remoteIP:$remotePort <--> incoming:$localPort1"
	iptables -t nat -A PREROUTING -p TCP --destination $remoteIP --dport $remotePort -j REDIRECT --to-port $localPort1
	
	echo "[+] Writing stunnel config for incoming:$localPort1 <--> localhost:$localPort2"
	echo "	foreground=no
		service=stunnel
		cert=host.pem
		[server]
		accept=0.0.0.0:$localPort1
		connect=127.0.0.1:$localPort2" > "$serverConfig"
	echo "	foreground=no
		client=yes
		[client]
		accept=127.0.0.1:$localPort2
		connect=$remoteIP:$remotePort" > "$clientConfig"
	
	echo "[+] Starting server-$counter"
	stunnel "$serverConfig"
	echo "[+] Starting client-$counter"
	stunnel "$clientConfig"
	
	counter="$(($counter + 1))"
done

cd - > /dev/null
rm -rf "$stunnelConfigDir"
