#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check for root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root${NC}" 
   exit 1
fi

clear
echo -e "${GREEN}====================================================${NC}"
echo -e "${YELLOW}       Auto Tunnel Setup (WireGuard + UDP2Raw)      ${NC}"
echo -e "${GREEN}====================================================${NC}"
echo ""
echo "1) Install EXTERNAL Server (Kharej)"
echo "2) Install IRAN Server (Iran)"
echo "3) Uninstall/Clean"
echo ""
read -p "Select an option [1-3]: " option

# --- Functions ---

install_dependencies() {
    echo -e "${YELLOW}[*] Updating and installing dependencies...${NC}"
    apt update -y
    apt install wireguard iproute2 net-tools nano wget tar -y
    
    # Check if udp2raw exists
    if [ ! -f /root/udp2raw ]; then
        echo -e "${YELLOW}[*] Downloading UDP2Raw...${NC}"
        cd /root
        wget https://github.com/wangyu-/udp2raw-tunnel/releases/download/20200818.0/udp2raw_binaries.tar.gz
        tar xf udp2raw_binaries.tar.gz
        mv udp2raw_amd64 /root/udp2raw
        chmod +x /root/udp2raw
        rm udp2raw_binaries.tar.gz version.txt
    else
        echo -e "${GREEN}[+] UDP2Raw already installed.${NC}"
    fi
}

setup_external() {
    install_dependencies
    
    # Generate Keys
    echo -e "${YELLOW}[*] Generating WireGuard Keys...${NC}"
    mkdir -p /etc/wireguard
    wg genkey | tee /etc/wireguard/privatekey | wg pubkey > /etc/wireguard/publickey
    PRIVATE_KEY=$(cat /etc/wireguard/privatekey)
    PUBLIC_KEY=$(cat /etc/wireguard/publickey)
    
    read -p "Enter Tunnel Password (default: newtunnel): " TUNNEL_PASS
    TUNNEL_PASS=${TUNNEL_PASS:-newtunnel}

    # Config WG0
    cat <<EOF > /etc/wireguard/wg0.conf
[Interface]
Address = 10.0.0.1/24
ListenPort = 1010
PrivateKey = $PRIVATE_KEY
MTU = 1200
PreUp = sysctl -q -w net.ipv4.ip_forward=1
PostUp = iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE; iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -o %i -j TCPMSS --clamp-mss-to-pmtu
PostDown = iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE; iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT

[Peer]
AllowedIPs = 10.0.0.2/32
EOF

    # Config UDP2Raw Service
    cat <<EOF > /etc/systemd/system/udp2raw.service
[Unit]
Description=UDP2RAW Tunnel Server
After=network.target

[Service]
Type=simple
User=root
ExecStart=/root/udp2raw -s -l 0.0.0.0:1376 -r 127.0.0.1:1010 -k "${TUNNEL_PASS}" --raw-mode icmp --seq-mode 1 -a
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    # Enable Services
    systemctl daemon-reload
    systemctl enable wg-quick@wg0
    systemctl start wg-quick@wg0
    systemctl enable udp2raw
    systemctl start udp2raw
    
    # Show Info
    IP=$(curl -s http://checkip.amazonaws.com)
    echo -e "${GREEN}=============================================${NC}"
    echo -e "${GREEN}       EXTERNAL SERVER SETUP COMPLETE        ${NC}"
    echo -e "${GREEN}=============================================${NC}"
    echo -e "Your Server IP: ${YELLOW}$IP${NC}"
    echo -e "Tunnel Password: ${YELLOW}$TUNNEL_PASS${NC}"
    echo -e "Server Public Key (Put this in Iran Panel):"
    echo -e "${YELLOW}$PUBLIC_KEY${NC}"
    echo -e "${GREEN}=============================================${NC}"
}

setup_iran() {
    install_dependencies
    
    read -p "Enter EXTERNAL Server IP: " REMOTE_IP
    read -p "Enter Tunnel Password (same as external): " TUNNEL_PASS
    TUNNEL_PASS=${TUNNEL_PASS:-newtunnel}
    
    # Config UDP2Raw Service (Client Mode)
    cat <<EOF > /etc/systemd/system/udp2raw.service
[Unit]
Description=UDP2RAW Tunnel Client
After=network.target

[Service]
Type=simple
User=root
ExecStart=/root/udp2raw -c -l 0.0.0.0:3333 -r ${REMOTE_IP}:1376 -k "${TUNNEL_PASS}" --raw-mode icmp --seq-mode 1 -a
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    # Enable Services
    systemctl daemon-reload
    systemctl enable udp2raw
    systemctl start udp2raw
    
    echo -e "${GREEN}=============================================${NC}"
    echo -e "${GREEN}         IRAN SERVER SETUP COMPLETE          ${NC}"
    echo -e "${GREEN}=============================================${NC}"
    echo -e "Now go to your X-UI Panel -> Outbounds -> Add WireGuard:"
    echo -e "Address: ${YELLOW}10.0.0.2${NC}"
    echo -e "Private Key: (Generate one in panel)"
    echo -e "Peer Public Key: (The one you got from External Server)"
    echo -e "Endpoint: ${YELLOW}127.0.0.1:3333${NC}"
    echo -e "MTU: ${YELLOW}1200${NC}"
    echo -e "${GREEN}=============================================${NC}"
}

uninstall() {
    systemctl stop wg-quick@wg0 udp2raw
    systemctl disable wg-quick@wg0 udp2raw
    rm /etc/systemd/system/udp2raw.service
    rm -rf /etc/wireguard
    rm /root/udp2raw
    systemctl daemon-reload
    echo -e "${RED}Uninstalled successfully.${NC}"
}

# --- Main Logic ---

case $option in
    1) setup_external ;;
    2) setup_iran ;;
    3) uninstall ;;
    *) echo "Invalid option" ;;
esac
