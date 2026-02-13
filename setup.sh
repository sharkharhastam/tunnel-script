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
    echo -e "${CYAN}---------------------------------${NC}"
    read -p "Press Enter to return to menu..."
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

# --- STATUS & RESTART ---

show_status() {
    clear
    echo -e "${CYAN}--- System Status ---${NC}"
    
    if [[ -f "/etc/wireguard/wg0.conf" ]]; then
        echo -e "${YELLOW}>> WireGuard (wg0):${NC}"
        systemctl status wg-quick@wg0 --no-pager | grep "Active:"
    else
        echo -e "${YELLOW}>> WireGuard:${NC} Not Installed"
    fi
    
    echo ""
    echo -e "${YELLOW}>> UDP2Raw Tunnels:${NC}"
    found=0
    for s in /etc/systemd/system/udp2raw*.service; do
        if [[ -f "$s" ]]; then
            s_name=$(basename "$s")
            echo -n "   - $s_name: "
            systemctl is-active "$s_name"
            found=1
        fi
    done
    
    if [[ $found -eq 0 ]]; then echo "   No UDP2Raw services found."; fi
    press_enter
}

restart_wg() {
    echo -e "${YELLOW}[*] Restarting WireGuard (wg0)...${NC}"
    if [[ -f "/etc/wireguard/wg0.conf" ]]; then
        systemctl restart wg-quick@wg0
        if [[ $? -eq 0 ]]; then
            echo -e "${GREEN}WireGuard restarted successfully!${NC}"
        else
            echo -e "${RED}Failed to restart WireGuard! Check logs.${NC}"
        fi
    else
        echo -e "${RED}WireGuard is not installed.${NC}"
    fi
    press_enter
}

# --- KHAREJ Functions ---

setup_kharej_initial() {
    install_dependencies
    
    if [[ -f "/etc/wireguard/wg0.conf" ]]; then
        echo -e "${RED}WireGuard is already installed! Use option 3 (Add Peer).${NC}"
        return
    fi

    echo -e "${YELLOW}--- Initial Kharej Setup ---${NC}"
    echo "0) Back to Menu"
    read -p "Enter IRAN Public Key: " PUB_KEY
    if [[ "$PUB_KEY" == "0" || -z "$PUB_KEY" ]]; then return; fi

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
    
    echo -e "${GREEN}=============================================${NC}"
    echo -e "${GREEN}          KHAREJ SETUP COMPLETE              ${NC}"
    echo -e "${GREEN}=============================================${NC}"
    echo -e "Server Public Key (SAVE THIS): ${YELLOW}$MY_PUB${NC}"
    echo -e "Assigned Internal IP:          ${YELLOW}$INT_IP${NC}"
    echo -e "Tunnel Password:               ${YELLOW}$PASS${NC}"
    echo -e "---------------------------------------------"
    echo -e "${CYAN}Checking Status...${NC}"
    systemctl status udp2raw --no-pager | grep "Active:"
    press_enter
}

add_peer_kharej() {
    if [[ ! -f "/etc/wireguard/wg0.conf" ]]; then
        echo -e "${RED}WireGuard not found. Run Initial Setup (Option 1) first.${NC}"
        return
    fi

    echo -e "${CYAN}--- Add New Peer to wg0 ---${NC}"
    echo "0) Back to Menu"
    read -p "Enter NEW Iran Public Key: " NEW_PUB
    if [[ "$NEW_PUB" == "0" || -z "$NEW_PUB" ]]; then return; fi
    
    read -p "Enter NEW Iran Internal IP (e.g., 10.0.0.3): " NEW_IP
    
    if grep -w "$NEW_IP" /etc/wireguard/wg0.conf; then
        echo -e "${RED}Error: IP $NEW_IP is already in use in wg0.conf!${NC}"
        return
    fi

    cat <<EOF >> /etc/wireguard/wg0.conf

[Peer]
# Added via Script
PublicKey = $NEW_PUB
AllowedIPs = $NEW_IP/32
EOF

    systemctl restart wg-quick@wg0
    
    # Retrieve Kharej Public Key
    MY_PUB=$(cat /etc/wireguard/publickey)
    
    echo -e "${GREEN}=============================================${NC}"
    echo -e "${GREEN}       PEER ADDED SUCCESSFULLY!              ${NC}"
    echo -e "${GREEN}=============================================${NC}"
    echo -e "Peer Internal IP:              ${YELLOW}$NEW_IP${NC}"
    echo -e "Kharej Server Public Key:      ${YELLOW}$MY_PUB${NC}"
    echo -e "---------------------------------------------"
    echo -e "${CYAN}Status (wg0):${NC}"
    systemctl status wg-quick@wg0 --no-pager | grep "Active:"
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
    echo "0) Back to Menu"
    read -p "Enter Kharej IP: " REM_IP
    if [[ "$REM_IP" == "0" || -z "$REM_IP" ]]; then return; fi
    
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
    
    echo -e "${GREEN}=============================================${NC}"
    echo -e "${GREEN}          IRAN SETUP COMPLETE                ${NC}"
    echo -e "${GREEN}=============================================${NC}"
    echo -e "${CYAN}Status ($SERVICE_NAME):${NC}"
    systemctl status $SERVICE_NAME --no-pager | grep "Active:"
    echo -e "---------------------------------------------"
    echo -e "${YELLOW}COPY THIS INTO YOUR X-UI OUTBOUND CONFIG:${NC}"
    echo ""
    echo -e "Protocol:       ${GREEN}WireGuard${NC}"
    echo -e "Address:        ${GREEN}10.0.0.2${NC} (Or the IP you set in Kharej)"
    echo -e "Private Key:    ${GREEN}<Generate in Panel>${NC}"
    echo -e "MTU:            ${GREEN}1200${NC}"
    echo -e "Peer PublicKey: ${GREEN}<PUT KHAREJ PUBLIC KEY HERE>${NC}"
    echo -e "Peer Endpoint:  ${GREEN}127.0.0.1:$LOCAL_PORT${NC}"
    echo -e "Allowed IPs:    ${GREEN}0.0.0.0/0${NC}"
    echo -e "KeepAlive:      ${GREEN}25${NC}"
    echo ""
    echo -e "${GREEN}=============================================${NC}"
    press_enter
}

# --- Delete Functions ---

delete_menu() {
    echo -e "${RED}--- Delete Menu ---${NC}"
    echo "1) Delete an Iran Connection (udp2raw)"
    echo "2) Delete a Kharej Peer (WireGuard Client)"
    echo "3) Uninstall Everything (Full Clean)"
    echo "0) Back to Main Menu"
    read -p "Select: " del_opt

    # --- DELETE IRAN UDP2RAW ---
    if [[ $del_opt == "1" ]]; then
        echo -e "${CYAN}Active Iran Connections:${NC}"
        files=(/etc/systemd/system/udp2raw*.service)
        if [[ ! -e "${files[0]}" ]]; then
            echo -e "${YELLOW}No active udp2raw services found.${NC}"; return
        fi
        
        i=1
        for f in "${files[@]}"; do
            echo "$i) $(basename "$f")"
            ((i++))
        done
        echo "0) Cancel"
        read -p "Select number: " num
        if [[ "$num" == "0" || -z "$num" ]]; then return; fi
        
        index=$((num-1))
        TARGET="${files[$index]}"
        
        if [[ -f "$TARGET" ]]; then
            S_NAME=$(basename "$TARGET")
            systemctl stop $S_NAME
            systemctl disable $S_NAME
            rm "$TARGET"
            systemctl daemon-reload
            echo -e "${GREEN}Deleted: $S_NAME${NC}"
        else
            echo "Invalid selection."
        fi

    # --- DELETE KHAREJ PEER ---
    elif [[ $del_opt == "2" ]]; then
        if [[ ! -f "/etc/wireguard/wg0.conf" ]]; then
            echo -e "${RED}WireGuard config not found.${NC}"; return
        fi
        
        echo -e "${CYAN}Active Peers (Kharej Clients):${NC}"
        # Extract IPs from config
        mapfile -t peers < <(grep "AllowedIPs" /etc/wireguard/wg0.conf | cut -d'=' -f2 | tr -d ' ')
        
        if [[ ${#peers[@]} -eq 0 ]]; then
            echo -e "${YELLOW}No peers found in config.${NC}"; return
        fi
        
        i=1
        for ip in "${peers[@]}"; do
            echo "$i) $ip"
            ((i++))
        done
        echo "0) Cancel"
        
        read -p "Select peer to DELETE: " num
        if [[ "$num" == "0" || -z "$num" ]]; then return; fi
        
        index=$((num-1))
        TARGET_IP="${peers[$index]}"
        
        if [[ -z "$TARGET_IP" ]]; then echo "Invalid selection."; return; fi
        
        echo -e "${YELLOW}Deleting Peer with IP: $TARGET_IP...${NC}"
        
        # Use sed to delete the Peer block (From [Peer] down to the line containing the IP)
        # Note: This relies on standard script structure where AllowedIPs is last line of block
        ESCAPED_IP=$(echo $TARGET_IP | sed 's/\//\\\//g')
        sed -i "/\[Peer\]/,/AllowedIPs = $ESCAPED_IP/d" /etc/wireguard/wg0.conf
        
        systemctl restart wg-quick@wg0
        echo -e "${GREEN}Peer deleted and WireGuard restarted.${NC}"

    # --- UNINSTALL ALL ---
    elif [[ $del_opt == "3" ]]; then
        echo -e "${RED}WARNING: This will delete WireGuard and ALL udp2raw tunnels!${NC}"
        read -p "Are you sure? (y/N): " confirm
        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
            systemctl stop wg-quick@wg0 udp2raw*
            rm -f /etc/systemd/system/udp2raw*
            rm -rf /etc/wireguard
            rm -f /root/udp2raw
            apt remove wireguard -y
            systemctl daemon-reload
            echo -e "${GREEN}Fully Uninstalled.${NC}"
        else
            echo "Cancelled."
        fi
    
    elif [[ $del_opt == "0" ]]; then
        return
    else
        echo "Invalid option."
    fi
}

# --- Main Loop ---

while true; do
    clear
    echo -e "${GREEN}======================================================${NC}"
    echo -e "${YELLOW}       Wireguard Udp2Raw Tunnel By SharKhar           ${NC}"
    echo -e "${GREEN}======================================================${NC}"
    echo "1) Kharej"
    echo "2) Iran"
    echo "3) Add Peer (Kharej)"
    echo "4) Add More Kharej To Iran"
    echo "5) System Status"
    echo "6) Restart WireGuard"
    echo "7) Delete / Uninstall"
    echo "0) Exit"
    echo ""
    read -p "Select: " opt

    case $opt in
        1) setup_kharej_initial; press_enter ;;
        2) setup_iran; press_enter ;;
        3) add_peer_kharej; press_enter ;;
        4) setup_iran; press_enter ;;
        5) show_status ;;
        6) restart_wg ;;
        7) delete_menu; press_enter ;;
        0) echo "Bye!"; exit 0 ;;
        *) echo "Invalid option"; press_enter ;;
    esac
done
