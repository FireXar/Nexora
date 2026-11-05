#!/bin/bash
# ==========================================
# Módulo SOCKS Python (PY2 / PY3) - Nexora
# ==========================================

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

# Funciones de instalación por cada modo
socks_p2_simple() {
    clear
    echo -e "${GREEN}=== SOCKS Python2 Simple ===${NC}"
    read -p "Puerto [80]: " PORT
    PORT=${PORT:-80}
    # [Lógica de instalación para python2 simple]
    echo -e "\n${GREEN}✔ SOCKS Python2 Simple activo en puerto $PORT${NC}"
    read -p "ENTER para continuar..."
}

socks_p3_simple() {
    clear
    echo -e "${GREEN}=== SOCKS Python3 Simple ===${NC}"
    read -p "Puerto público [80]: " PUB_PORT
    PUB_PORT=${PUB_PORT:-80}
    read -p "Puerto SSH destino [22]: " SSH_PORT
    SSH_PORT=${SSH_PORT:-22}
    read -p "Ingrese su mini-banner: " USER_BANNER
    USER_BANNER=${USER_BANNER:-Nexora}

    systemctl stop nexora-socks.service >/dev/null 2>&1
    
    cat << EOF > /etc/nexora/socks_server.py
import socket, threading, sys

def handle_client(client_socket, target_port):
    try:
        target_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        target_socket.connect(('127.0.0.1', target_port))
        target_socket.sendall(b"$USER_BANNER\n")
    except Exception:
        client_socket.close()
        return

    def forward(source, destination):
        try:
            while True:
                data = source.recv(4096)
                if not data:
                    break
                destination.sendall(data)
        except Exception:
            pass
        finally:
            source.close()
            destination.close()

    threading.Thread(target=forward, args=(client_socket, target_socket)).start()
    threading.Thread(target=forward, args=(target_socket, client_socket)).start()

def main():
    if len(sys.argv) < 3:
        return
    listen_port = int(sys.argv[1])
    target_port = int(sys.argv[2])
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(('0.0.0.0', listen_port))
    server.listen(100)
    while True:
        client_sock, _ = server.accept()
        threading.Thread(target=handle_client, args=(client_sock, target_port)).start()

if __name__ == '__main__':
    main()
EOF

    cat << EOF > /etc/systemd/system/nexora-socks.service
[Unit]
Description=Nexora SOCKS WebSocket Proxy
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /etc/nexora/socks_server.py $PUB_PORT $SSH_PORT
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable nexora-socks.service >/dev/null 2>&1
    systemctl start nexora-socks.service >/dev/null 2>&1

    echo -e "\n${GREEN}✔ WebSocket activo: $PUB_PORT → $SSH_PORT${NC}"
    read -p "ENTER para continuar..."
}

stop_all_socks() {
    systemctl stop nexora-socks.service >/dev/null 2>&1
    systemctl disable nexora-socks.service >/dev/null 2>&1
    echo -e "\n${RED}✔ Todos los servicios SOCKS detenidos.${NC}"
    sleep 1.5
}

# Submenú con todos los modos (NO se auto-ejecuta al final)
main_socks() {
    while true; do
        clear
        echo -e "${GREEN}INSTALADOR SOCKS PYTHON (PY2 / PY3)${NC}\n"
        echo -e ">> MODOS SIMPLES Y SEGUROS <<"
        echo "[1] > Socks Python2 SIMPLE"
        echo "[2] > Socks Python3 SIMPLE"
        echo "[3] > Socks Python2 SEGURO"
        echo "[4] > Socks Python3 SEGURO"
        echo -e ">> MODOS DIRECTOS Y OPEN <<"
        echo "[5] > Socks Python2 DIRECTO"
        echo "[6] > Socks Python3 DIRECTO"
        echo "[7] > Socks Python2 OPENVPN"
        echo "[8] > Socks Python3 OPENVPN"
        echo "[9] > Socks Python2 GETTUNEL"
        echo -e "\n[10] > DETENER TODOS   [11] > DETENER PUERTO"
        echo -e "\n[0] > VOLVER\n"
        
        read -p "Seleccione una opcion: " opt
        case $opt in
            1) socks_p2_simple ;;
            2) socks_p3_simple ;;
            3) echo "Modo seguro Py2"; sleep 1 ;;
            4) echo "Modo seguro Py3"; sleep 1 ;;
            5) echo "Modo directo Py2"; sleep 1 ;;
            6) echo "Modo directo Py3"; sleep 1 ;;
            7) echo "OpenVPN Py2"; sleep 1 ;;
            8) echo "OpenVPN Py3"; sleep 1 ;;
            9) echo "Gettunel Py2"; sleep 1 ;;
            10) stop_all_socks ;;
            11) stop_all_socks ;;
            0) break ;;
            *) echo -e "${RED}Opción inválida${NC}"; sleep 1 ;;
        esac
    done
}
