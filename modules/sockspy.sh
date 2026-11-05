#!/bin/bash

# Bloque de compatibilidad local completo
print_center() {
    echo -e "$2"
}

msg() {
    echo -e "$2"
}

moportas() {
    echo -e "$1"
}

fun_ip() {
    local MEU_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7}')
    [[ -z "$MEU_IP" ]] && MEU_IP=$(wget -qO- ipv4.icanhazip.com)
    echo "$MEU_IP"
}

stop_all () {
    ck_py=$(lsof -V -i tcp -P -n | grep -i "python")

    if [[ -z $(echo "$ck_py" | awk '{print $1}') ]]; then
        print_center -verm "Puertos PYTHON no activos"
        msg -bar
    else
        ck_port=$(echo "$ck_py" | awk '{print $9}' | awk -F ":" '{print $2}')
        for i in $ck_port; do
            systemctl stop python.${i} &>/dev/null
            systemctl disable python.${i} &>/dev/null
            rm /etc/systemd/system/python.${i}.service &>/dev/null
        done
        print_center -verd "Puertos PYTHON detenidos"
        msg -bar
    fi
}

stop_port () {
    ck_py=$(lsof -V -i tcp -P -n | grep -i "python")

    if [[ -z $(echo "$ck_py" | awk '{print $1}') ]]; then
        print_center -verm "Puertos PYTHON no activos"
        msg -bar
    else
        echo -e " \031\033[1;31mPuertos PYTHON activos:\033[0m"
        echo ""
        echo "$ck_py" | awk '{print $1,$9}' | awk -F ":" '{print $1,$2}' | while read service port; do
            echo -e " \031\033[1;32m$service \033[1;37men el puerto \033[1;33m$port\033[0m"
        done
        echo ""
        msg -bar
        while true; do
            echo -ne " \031\033[1;37mIngrese el puerto a detener\033[1;31m: \033[1;32m" && read portx
            if [[ -z "$portx" ]]; then
                err_fun "Puerto invalido"
            elif [[ -z $(echo "$ck_py" | awk '{print $9}' | awk -F ":" '{print $2}' | grep -w "$portx") ]]; then
                err_fun "Puerto no activo"
            else
                break
            fi
        done
        systemctl stop python.${portx} &>/dev/null
        systemctl disable python.${portx} &>/dev/null
        rm /etc/systemd/system/python.${portx}.service &>/dev/null
        print_center -verd "Puerto PYTHON $portx detenido"
        msg -bar
    fi
}

inicia_py () {
    echo -e " \031\033[1;37mSelecciona Puerto Principal, para Proxy ($pyk)\033[0m"
    echo ""
    moportas
    echo ""
    while true; do
        echo -ne " \031\033[1;37mPuerto python\033[1;31m: \033[1;32m" && read portx
        if [[ -z "$portx" ]]; then
            err_fun "Puerto invalido"
        elif [[ ! -z $(lsof -V -i tcp -P -n | grep -i "listen" | grep -w "$portx") ]]; then
            err_fun "Puerto en uso"
        else
            break
        fi
    done

    echo ""
    msg -bar
    echo -e " \031\033[1;37mSelec Puerto Local SSH/DROPBEAR/OPENVPN\033[0m"
    echo ""
    moportas
    echo ""
    while true; do
        echo -ne " \031\033[1;37mPuerto local\033[1;31m: \033[1;32m" && read port_loc
        if [[ -z "$port_loc" ]]; then
            err_fun "Puerto invalido"
        elif [[ -z $(lsof -V -i tcp -P -n | grep -i "listen" | grep -w "$port_loc") ]]; then
            err_fun "Puerto no activo"
        else
            break
        fi
    done

    echo ""
    msg -bar
    echo -e " \031\033[1;37mIntroduzca su Mini-Banner\033[0m"
    echo ""
    echo -e " \031\033[1;37mIntroduzca un texto [Plano] o en [HTML]\033[0m"
    echo ""
    echo -ne " \031\033[1;32m" && read text_s
    [[ -z "$text_s" ]] && text_s="Nexora"

    cat <<EOF > /etc/systemd/system/python.${portx}.service
[Unit]
Description=Python Proxy Nexora
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/root
ExecStart=/usr/bin/$pyk /etc/nexora/modules/socks.py $portx $port_loc "$text_s"
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload &>/dev/null
    systemctl enable python.${portx} &>/dev/null
    systemctl start python.${portx} &>/dev/null

    if [[ ! -z $(lsof -V -i tcp -P -n | grep -i "python" | grep -w "$portx") ]]; then
        print_center -verd "PYTHON INICIADO CON EXITO EN PUERTO $portx"
        msg -bar
    else
        print_center -verm "PYTHON NO PUDO INICIAR"
        print_center -ama "Revisa con: journalctl -u python.$portx -n 20"
        msg -bar
    fi
}

main_socks () {
    clear
    msg -bar
    print_center -ama "INSTALADOR SOCKS PYTHON (PY2 / PY3)"
    msg -bar
    echo -e " \031\033[1;31m>> \033[1;37mMODOS SIMPLES Y SEGUROS \033[1;31m<<"
    echo -e " \031\033[1;32m[1] > \033[1;37mSocks Python2 SIMPLE"
    echo -e " \031\033[1;32m[2] > \033[1;37mSocks Python3 SIMPLE"
    echo -e " \031\033[1;32m[3] > \033[1;37mSocks Python2 SEGURO"
    echo -e " \031\033[1;32m[4] > \033[1;37mSocks Python3 SEGURO"
    echo -e " \031\033[1;31m>> \033[1;37mMODOS DIRECTOS Y OPEN \033[1;31m<<"
    echo -e " \031\033[1;32m[5] > \033[1;37mSocks Python2 DIRECTO"
    echo -e " \031\033[1;32m[6] > \033[1;37mSocks Python3 DIRECTO"
    echo -e " \031\033[1;32m[7] > \033[1;37mSocks Python2 OPENVPN"
    echo -e " \031\033[1;32m[8] > \033[1;37mSocks Python3 OPENVPN"
    echo -e " \031\033[1;32m[9] > \033[1;37mSocks Python2 GETTUNEL"
    echo ""
    echo -e " \031\033[1;31m[10] > DETENER TODOS    \033[1;31m[11] > DETENER PUERTO"
    echo ""
    echo -e " \031\033[1;31m[0] > \033[1;37mVOLVER"
    msg -bar
    echo -ne " \031\033[1;37mSeleccione una opcion\033[1;31m: \033[1;32m" && read opc

    case $opc in
        1) pyk="python2"; inicia_py;;
        2) pyk="python3"; inicia_py;;
        3) pyk="python2"; inicia_py;;
        4) pyk="python3"; inicia_py;;
        5) pyk="python2"; inicia_py;;
        6) pyk="python3"; inicia_py;;
        7) pyk="python2"; inicia_py;;
        8) pyk="python3"; inicia_py;;
        9) pyk="python2"; inicia_py;;
        10) stop_all;;
        11) stop_port;;
        0) return 0;;
        *) main_socks;;
    esac
}

main_socks
