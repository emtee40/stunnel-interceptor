#!/bin/bash

# File stdin format:
#
# baseIP	basePort	netmask	baseDevice
# interceptedIP	interceptedPort
# interceptedIP	interceptedPort
# interceptedIP	interceptedPort
# interceptedIP	interceptedPort
# interceptedIP	interceptedPort
# ...
#
# Sample:
# 192.168.0.200	9000	255.255.255.0	wlan0
# 123.48.12.122	443
# 123.48.12.128	143
# 123.43.12.112	587

set -e

read localBase
localBaseIP="$(cut -f 1 <<< "$localBase")"
localBasePort="$(cut -f 2 <<< "$localBase")"
localBaseNetmask="$(cut -f 3 <<< "$localBase")"
localBaseDevice="$(cut -f 4 <<< "$localBase")"
stunnelConfigDir="$(mktemp -d)"
cd $stunnelConfigDir

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
openssl x509 -noout -fingerprint -text < host.cert > host.info
cat host.cert host.key > host.pem


counter=0
while read line; do
	remoteIP="$(cut -f 1 <<< "$line")"
	remotePort="$(cut -f 2 <<< "$line")"
	localIP="$(cut -f 1,2,3 -d . <<< "$localBaseIP").$(($(cut -f 4 -d . <<< "$localBaseIP") + $counter))"
	localPort="$(($localBasePort + $counter))"
	device="$localBaseDevice:$counter"
	serverConfig="server-$counter.conf"
	clientConfig="client-$counter.conf"
	
	echo "[+] Configuring $device to $localIP"
	ifconfig "$device" "$localIP" netmask "$localBaseNetmask"
	echo "[+] Writing stunnel config for $remoteIP:$remotePort <--> $localIP:$localPort"
	echo "	foreground=no
		service=stunnel
		cert=host.pem
		[server]
		accept=$localIP:$remotePort
		connect=127.0.0.1:$localPort" > "$serverConfig"
	echo "	foreground=no
		client=yes
		[client]
		accept=127.0.0.1:$localPort
		connect=$remoteIP:$remotePort" > "$clientConfig"
	
	echo "[+] Starting server-$counter"
	stunnel "$serverConfig"
	echo "[+] Starting client-$counter"
	stunnel "$clientConfig"
	
	counter="$(($counter + 1))"
done

cd - > /dev/null
rm -rf "$stunnelConfigDir"
