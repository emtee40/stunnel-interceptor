#!/bin/bash

# File stdin format:
#
# sourceIP	basePort1	basePort2
# interceptedIP	interceptedPort	interceptedDomain
# interceptedIP	interceptedPort	interceptedDomain
# interceptedIP	interceptedPort	interceptedDomain
# interceptedIP	interceptedPort	interceptedDomain
# interceptedIP	interceptedPort	interceptedDomain
# ...
#
# Sample:
# 192.168.0.4	9000	10000
# 123.48.12.122	443	googblie.com
# 123.48.12.128	143	schmooblie.com
# 123.43.12.112	587	lars.mooblie.com

set -e

read localBase
sourceIP="$(cut -f 1 <<< "$localBase")"
localBasePort1="$(cut -f 2 <<< "$localBase")"
localBasePort2="$(cut -f 3 <<< "$localBase")"
if [ "$1" != "" ]; then
	stunnelConfigDir="$1"
else
	stunnelConfigDir="$(mktemp -d)"
fi
cd $stunnelConfigDir

echo "[+] Killing previous stunnels."
killall -9 stunnel || true

echo "[+] Configuring iptables and forwarding."
echo 1 > /proc/sys/net/ipv4/ip_forward
iptables -t nat -F

if [ ! -f ./demoCA/private/cakey.pem ]; then
	echo "[+] Generating ca certificate."
	subj="
	C=CR
	ST=ST
	O=ACME
	localityName=TOWN
	commonName=THECN
	organizationalUnitName=INTERCEPT
	emailAddress=$(whoami)@$(uname -n)"
	mkdir -p demoCA/{certs,crl,newcerts,private}
	echo 01 > demoCA/serial
	touch demoCA/index.txt
	openssl req -new -x509 -keyout demoCA/private/cakey.pem -out demoCA/cacert.pem -days 3652 -passout pass:1234 -subj "$(tr -d '\t' <<< "$subj" | tr "\n" "/")"
	openssl pkcs12 -passin pass:1234 -passout pass:1234 -export -in demoCA/cacert.pem -inkey demoCA/private/cakey.pem -out cacert.p12
fi

counter=0
while read line; do
	remoteIP="$(cut -f 1 <<< "$line")"
	remotePort="$(cut -f 2 <<< "$line")"
	remoteDomain="$(cut -f 3 <<< "$line")"
	localPort1="$(($localBasePort1 + $counter))"
	localPort2="$(($localBasePort2 + $counter))"
	serverConfig="server-$counter.conf"
	clientConfig="client-$counter.conf"
	
	echo "[+] Configuring iptables to redirect $remoteIP:$remotePort <--> incoming:$localPort1"
	iptables -t nat -A PREROUTING -p TCP --source "$sourceIP" --destination "$remoteIP" --dport "$remotePort" -j REDIRECT --to-port "$localPort1"

	if [ ! -f "$remoteDomain.pem" ]; then
		echo "[+] Generating host certificate."
		subj="
			C=CR
			ST=ST
			O=ACME
			localityName=TOWN
			commonName=$remoteDomain
			organizationalUnitName=INTERCEPT
			emailAddress=$(whoami)@$(uname -n)"
		openssl req -new -keyout ./$remoteDomain.req -out ./$remoteDomain.req -days 3652 -passout pass:1234 -passin pass:1234 -subj "$(tr -d '\t' <<< "$subj" | tr "\n" "/")"
		echo -e "y\ny"|openssl ca  -passin pass:1234 -policy policy_anything -out $remoteDomain.crt -infiles $remoteDomain.req
		openssl rsa -passin pass:1234 < $remoteDomain.req > $remoteDomain.key
		cat $remoteDomain.crt $remoteDomain.key > $remoteDomain.pem
	fi
	
	echo "[+] Writing stunnel config for incoming:$localPort1 <--> localhost:$localPort2"
	echo "	foreground=no
		debug=7
		socket=l:TCP_NODELAY=1
		socket=r:TCP_NODELAY=1
		cert=$remoteDomain.pem
		output="$serverConfig.log"
		pid="$(pwd)/$serverConfig.pid"
		[server]
		accept=0.0.0.0:$localPort1
		connect=127.0.0.1:$localPort2" > "$serverConfig"
	echo "	foreground=no
		debug=7
		socket=l:TCP_NODELAY=1
		socket=r:TCP_NODELAY=1
		client=yes
		output="$clientConfig.log"
		pid="$(pwd)/$clientConfig.pid"
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
#rm -rf "$stunnelConfigDir"
echo $stunnelConfigDir
