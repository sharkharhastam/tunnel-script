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

press_enter() {
    echo ""
    read -p "Press Enter to return to Main Menu..."
    show_menu
}

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
        echo -e "${RED}WireGuard is already installed! Use option 3 (Add Peer).${NC}"
        press_enter
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
    press_enter
}

add_peer_kharej() {
    if [[ ! -f "/etc/wireguard/wg0.conf" ]]; then
        echo -e "${RED}WireGuard not found. Run Initial Setup (Option 1) first.${NC}"
        press_enter
        return
    fi

    echo -e "${CYAN}--- Add New Peer to wg0 ---${NC}"
    read -p "Enter NEW Iran Public Key: " NEW_PUB
    if [ -z "$NEW_PUB" ]; then echo "Cancelled."; press_enter; return; fi
    
    read -p "Enter NEW Iran Internal IP (e.g., 10.0.0.3): " NEW_IP
    
    if grep -w "$NEW_IP" /etc/wireguard/wg0.conf; then
        echo -e "${RED}Error: IP $NEW_IP is already in use in wg0.conf!${NC}"
        press_enter
        return
    fi

    cat <<EOF >> /etc/wireguard/wg0.conf

[Peer]
# Added via Script
PublicKey = $NEW_PUB
AllowedIPs = $NEW_IP/32
EOF

    systemctl restart wg-quick@wg0
    echo -e "${GREEN}Peer Added Successfully!${NC}"
    press_enter
}

# --- IRAN Functions ---

setup_iran() {
    install_dependencies
    
    ID=$(get_next_iran_id)
    
    if [[ $ID -eq 1 ]]; then
        SERVICE_NAME="udp2raw"
        LOCAL_PORT=3333
    else
        SERVICE_NAME="udp2raw-$ID"
        LOCAL_PORT=$((3333 + ID - 1))
    fi

    echo -e "${CYAN}Adding Connection (ID: $ID)${NC}"
    read -p "Enter Kharej IP: " REM_IP
    if [ -z "$REM_IP" ]; then echo "Cancelled."; press_enter; return; fi
    
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
    press_enter
}

# --- Delete Functions ---

delete_menu() {
    echo -e "${RED}--- Delete Menu ---${NC}"
    echo "1) Delete an Iran Connection (Select by Number)"
    echo "2) Uninstall Everything (Full Clean)"
    echo "0) Back to Main Menu"
    read -p "Select: " del_opt

    if [[ $del_opt == "1" ]]; then
        echo -e "${CYAN}Active Services:${NC}"
        
        # Create an array of service files
        files=(/etc/systemd/system/udp2raw*.service)
        
        # Check if no files exist (if pattern matches nothing, it returns the pattern string itself if nullglob is off, 
        # but let's check existence of the first element)
        if [[ ! -e "${files[0]}" ]]; then
            echo -e "${YELLOW}No active udp2raw services found.${NC}"
            press_enter
            return
        fi

        # List files with numbers
        i=1
        for f in "${files[@]}"; do
            filename=$(basename "$f")
            echo "$i) $filename"
            ((i++))
        done
        echo "0) Cancel"
        
        read -p "Select number to delete: " num
        
        # Validation
        if [[ "$num" == "0" || -z "$num" ]]; then
            show_menu
            return
        fi
        
        if ! [[ "$num" =~ ^[0-9]+$ ]] || [[ "$num" -ge "$i" ]] || [[ "$num" -lt 1 ]]; then
            echo -e "${RED}Invalid selection!${NC}"
            press_enter
            return
        fi
        
        # Map number to file
        index=$((num-1))
        TARGET_FILE="${files[$index]}"
        SERVICE_NAME=$(basename "$TARGET_FILE")
        
        # Execute Delete
        systemctl stop $SERVICE_NAME
        systemctl disable $SERVICE_NAME
        rm "$TARGET_FILE"
        systemctl daemon-reload
        echo -e "${GREEN}Deleted: $SERVICE_NAME${NC}"
        press_enter

    elif [[ $del_opt == "2" ]]; then
        echo -e "${RED}WARNING: This will delete WireGuard and ALL udp2raw tunnels!${NC}"
        read -p "Are you sure? (y/N): " confirm
        
        # If not 'y', return to menu
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            echo "Cancelled."
            show_menu
            return
        fi

        systemctl stop wg-quick@wg0 udp2raw*
        rm -f /etc/systemd/system/udp2raw*
        rm -rf /etc/wireguard
        rm -f /root/udp2raw
        apt remove wireguard -y
        systemctl daemon-reload
        echo -e "${GREEN}Fully Uninstalled.${NC}"
        press_enter
    
    elif [[ $del_opt == "0" ]]; then
        show_menu
    else
        echo "Invalid option."
        press_enter
    fi
}

# --- Main Menu Loop ---

show_menu() {
    clear
    echo -e "${GREEN}======================================================${NC}"
    echo -e "${YELLOW} Wireguard Udp2Raw Single-Interface Tunnel Manager v8 ${NC}"
    echo -e "${GREEN}======================================================${NC}"
    echo "1) Kharej"
    echo "2) Iran"
    echo "3) Add Peer (Kharej)"
    echo "4) Add More Kharej To Iran"
    echo "5) Delete / Uninstall"
    echo "0) Exit"
    echo ""
    read -p "Select: " opt

    case $opt in
        1) setup_kharej_initial ;;
        2) setup_iran ;;
        3) add_peer_kharej ;;
        4) setup_iran ;;
        5) delete_menu ;;
        0) exit 0 ;;
        *) echo "Invalid option"; press_enter ;;
    esac
}

# Start the script
show_menu
