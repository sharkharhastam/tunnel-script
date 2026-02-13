#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Check Root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Run as root!${NC}" 
   exit 1
fi

# --- Helper Functions ---

install_dependencies() {
    if ! command -v wg &> /dev/null || [ ! -f /root/udp2raw ]; then
        echo -e "${YELLOW}[*] Installing dependencies...${NC}"
        apt update -y
        apt install wireguard iproute2 net-tools nano wget tar -y
        
        if [ ! -f /root/udp2raw ]; then
            cd /root
            wget -q https://github.com/wangyu-/udp2raw-tunnel/releases/download/20200818.0/udp2raw_binaries.tar.gz
            tar xf udp2raw_binaries.tar.gz
            mv udp2raw_amd64 /root/udp2raw
            chmod +x /root/udp2raw
            rm udp2raw_binaries.tar.gz version.txt
        fi
        echo -e "${GREEN}[+] Dependencies ready.${NC}"
    fi
}

get_next_iran_id() {
    # Finds the next available ID for udp2raw service
    # 1 -> udp2raw.service
    # 2 -> udp2raw-2.service
    local i=1
    while true; do
        if [[ $i -eq 1 ]]; then
            SERVICE_NAME="udp2raw"
        else
            SERVICE_NAME="udp2raw-$i"
        fi
        
        if [[ ! -f "/etc/systemd/system/$SERVICE_NAME.service" ]]; then
            echo "$i"
            return
        fi
        ((i++))
    done
}

# --- KHAREJ Functions ---

setup_kharej_initial() {
    install_dependencies
    
    if [[ -f "/etc/wireguard/wg0.conf" ]]; then
        echo -e "${RED}WireGuard is already installed! Use 'Add Peer' option.${NC}"
        return
    fi

    echo -e "${YELLOW}--- Initial Kharej Setup ---${NC}"
    read -p "Enter IRAN Public Key: " PUB_KEY
    read -p "Enter IRAN Internal IP (Default 10.0.0.2): " INT_IP
    INT_IP=${INT_IP:-10.0.0.2}
    read -p "Enter Tunnel Password: " PASS

    # Generate Keys
    mkdir -p /etc/wireguard
    wg genkey | tee /etc/wireguard/privatekey | wg pubkey > /etc/wireguard/publickey
    PRIV=$(cat /etc/wireguard/privatekey)
    MY_PUB=$(cat /etc/wireguard/publickey)

    # WG0 Config
    cat <<EOF > /etc/wireguard/wg0.conf
[Interface]
Address = 10.0.0.1/24
ListenPort = 1010
PrivateKey = $PRIV
MTU = 1200
PreUp = sysctl -q -w net.ipv4.ip_forward=1
PostUp = iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE; iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -o %i -j TCPMSS --clamp-mss-to-pmtu
PostDown = iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE; iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT

[Peer]
# Peer 1
PublicKey = $PUB_KEY
AllowedIPs = $INT_IP/32
EOF

    # UDP2Raw Service (Master)
    cat <<EOF > /etc/systemd/system/udp2raw.service
[Unit]
Description=UDP2RAW Tunnel Server
After=network.target

[Service]
Type=simple
User=root
ExecStart=/root/udp2raw -s -l 0.0.0.0:1376 -r 127.0.0.1:1010 -k "${PASS}" --raw-mode icmp --seq-mode 1 -a
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable wg-quick@wg0 udp2raw
    systemctl start wg-quick@wg0 udp2raw
    
    IP=$(curl -s http://checkip.amazonaws.com)
    echo -e "${GREEN}Kharej Installed.${NC} Public Key: ${YELLOW}$MY_PUB${NC}"
}

add_peer_kharej() {
    if [[ ! -f "/etc/wireguard/wg0.conf" ]]; then
        echo -e "${RED}WireGuard not found. Run Initial Setup first.${NC}"
        return
    fi

    echo -e "${CYAN}--- Add New Peer to wg0 ---${NC}"
    read -p "Enter NEW Iran Public Key: " NEW_PUB
    read -p "Enter NEW Iran Internal IP (e.g., 10.0.0.3): " NEW_IP
    
    if grep -q "$NEW_IP" /etc/wireguard/wg0.conf; then
        echo -e "${RED}This IP is already in use in wg0.conf!${NC}"
        return
    fi

    # Append to wg0.conf
    cat <<EOF >> /etc/wireguard/wg0.conf

[Peer]
# Added via Script
PublicKey = $NEW_PUB
AllowedIPs = $NEW_IP/32
EOF

    # Restart WG to apply
    systemctl restart wg-quick@wg0
    echo -e "${GREEN}Peer Added Successfully!${NC}"
}

# --- IRAN Functions ---

setup_iran() {
    install_dependencies
    
    ID=$(get_next_iran_id)
    
    # Calculate Names and Ports
    # ID 1 -> Service: udp2raw     | Port: 3333
    # ID 2 -> Service: udp2raw-2   | Port: 3334
    
    if [[ $ID -eq 1 ]]; then
        SERVICE_NAME="udp2raw"
        LOCAL_PORT=3333
    else
        SERVICE_NAME="udp2raw-$ID"
        LOCAL_PORT=$((3333 + ID - 1))
    fi

    echo -e "${CYAN}Adding New Connection (ID: $ID)${NC}"
    read -p "Enter Kharej IP: " REM_IP
    read -p "Enter Kharej UDP2Raw Port (Usually 1376): " REM_PORT
    REM_PORT=${REM_PORT:-1376}
    read -p "Enter Tunnel Password: " PASS

    cat <<EOF > /etc/systemd/system/$SERVICE_NAME.service
[Unit]
Description=UDP2RAW Tunnel Client $ID
After=network.target

[Service]
Type=simple
User=root
ExecStart=/root/udp2raw -c -l 0.0.0.0:$LOCAL_PORT -r $REM_IP:$REM_PORT -k "${PASS}" --raw-mode icmp --seq-mode 1 -a
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable $SERVICE_NAME
    systemctl start $SERVICE_NAME
    
    echo -e "${GREEN}Connection Added!${NC}"
    echo -e "Service Name: ${YELLOW}$SERVICE_NAME${NC}"
    echo -e "Local Endpoint: ${YELLOW}127.0.0.1:$LOCAL_PORT${NC}"
}

# --- Delete Functions ---

delete_menu() {
    echo -e "${RED}--- Delete Menu ---${NC}"
    echo "1) Delete an Iran Connection (udp2raw service)"
    echo "2) Uninstall Everything (Full Clean)"
    read -p "Select: " del_opt

    if [[ $del_opt == "1" ]]; then
        # List Active Services
        echo -e "${CYAN}Active Services:${NC}"
        found=0
        for s in /etc/systemd/system/udp2raw*.service; do
            if [[ -f "$s" ]]; then
                name=$(basename "$s")
                echo " - $name"
                found=1
            fi
        done
        
        if [[ $found -eq 0 ]]; then echo "No services found."; return; fi
        
        echo ""
        read -p "Type the FULL service name to delete (e.g. udp2raw-2.service): " S_NAME
        
        if [[ -f "/etc/systemd/system/$S_NAME" ]]; then
            systemctl stop $S_NAME
            systemctl disable $S_NAME
            rm "/etc/systemd/system/$S_NAME"
            systemctl daemon-reload
            echo -e "${GREEN}Deleted $S_NAME${NC}"
        else
            echo -e "${RED}File not found!${NC}"
        fi

    elif [[ $del_opt == "2" ]]; then
        read -p "Are you sure? This deletes ALL configs. (y/n): " confirm
        if [[ $confirm == "y" ]]; then
            systemctl stop wg-quick@wg0 udp2raw*
            rm -f /etc/systemd/system/udp2raw*
            rm -rf /etc/wireguard
            rm -f /root/udp2raw
            apt remove wireguard -y
            systemctl daemon-reload
            echo -e "${GREEN}Fully Uninstalled.${NC}"
        fi
    fi
}

# --- Main ---

clear
echo -e "${GREEN}===========================================${NC}"
echo -e "${YELLOW}   Single-Interface Tunnel Manager v5      ${NC}"
echo -e "${GREEN}===========================================${NC}"
echo "1) KHAREJ: Initial Setup (Fresh Install)"
echo "2) KHAREJ: Add New Peer (For another Iran)"
echo "3) IRAN: Add New Connection (udp2raw client)"
echo "4) Delete / Uninstall"
echo ""
read -p "Select: " opt

case $opt in
    1) setup_kharej_initial ;;
    2) add_peer_kharej ;;
    3) setup_iran ;;
    4) delete_menu ;;
    *) echo "Invalid" ;;
esac
