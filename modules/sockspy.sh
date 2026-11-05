#!/bin/bash
# Funciones de compatibilidad local
print_center() {
    echo -e "$2"
}

msg() {
    echo -e "$2"
}

stop_all () {
    ck_py=$(lsof -V -i tcp -P -n | grep -v "ESTABLISHED" |grep -v "COMMAND"|grep "python")

    if [[ -z $(echo "$ck_py" | awk '{print $1}' | head -n 1) ]]; then
        print_center -verm "Puertos PYTHON no encontrados"
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
    sleep 3
}

stop_port () {
    clear
    STPY=$(lsof -V -i tcp -P -n | grep -v "ESTABLISHED" |grep -v "COMMAND"|grep "python" | awk '{print $9}' | awk -F ":" '{print $2}')

    msg -bar
    print_center -ama "DETENER UN PUERTO"
    msg -bar

    n=1
    for i in $STPY; do
        echo -e " \033[1;32m[$n] \033[1;31m> \033[1;37m$i\033[0m"
        pypr[$n]=$i
        let n++ 
    done

    msg -bar
    echo -ne "$(msg -verd "  [0]") $(msg -verm2 ">") " && msg -bra "\033[1;41mVOLVER"
    msg -bar
    echo -ne "\033[1;37m opcion: " && read prpy
    tput cuu1 && tput dl1

    [[ $prpy = "0" ]] && return

    systemctl stop python.${pypr[$prpy]} &>/dev/null
    systemctl disable python.${pypr[$prpy]} &>/dev/null
    rm /etc/systemd/system/python.${pypr[$prpy]}.service &>/dev/null

    print_center -verd "PUERTO PYTHON ${pypr[$prpy]} detenido"
    msg -bar
    sleep 3
}

colector(){
    clear
    msg -bar
    print_center -azu "Selecciona Puerto Principal, para Proxy ($2)"
    msg -bar

    while [[ -z $porta_socket ]]; do
        echo -ne "\033[1;37m Digite el Puerto: " && read porta_socket
        tput cuu1 && tput dl1

        [[ $(mportas|grep -w "${porta_socket}") = "" ]] && {
            echo -e "\033[1;33m Puerto python:\033[1;32m ${porta_socket} OK"
            msg -bar3
        } || {
            echo -e "\033[1;33m Puerto python:\033[1;31m ${porta_socket} FAIL" && sleep 2
            tput cuu1 && tput dl1
            unset porta_socket
        }
    done

    py="$2"

    if [[ $1 = "PDirect" ]]; then
        print_center -azu "Selec Puerto Local SSH/DROPBEAR/OPENVPN"
        msg -bar3

        while [[ -z $local ]]; do
            echo -ne "\033[1;97m Digite el Puerto: \033[0m" && read local
            tput cuu1 && tput dl1

            [[ $(mportas|grep -w "${local}") = "" ]] && {
                echo -e "\033[1;33m Puerto local:\033[1;31m ${local} FAIL" && sleep 2
                tput cuu1 && tput dl1
                unset local
            } || {
                echo -e "\033[1;33m Puerto local:\033[1;32m ${local} OK"
                msg -bar3
            }
        done
        print_center -azu "Response personalizado (enter por defecto 200)"
        print_center -ama "NOTA : Para OVER WEBSOCKET escribe (101)"
        msg -bar3
        echo -ne "\033[1;97m Digite un Response: \033[0m" && read response
        tput cuu1 && tput dl1
        [[ -z $response ]] && response="200"
        msg -bar3
    fi

    if [[ ! $1 = "PGet" ]] && [[ ! $1 = "POpen" ]]; then
        print_center -azu "Introduzca su Mini-Banner"
        msg -bar3
        print_center -azu "Introduzca un texto [Plano] o en [HTML]"
        echo ""
        read texto_soket
    fi

    if [[ $1 = "PPriv" ]]; then
        IP=$(fun_ip)
    elif [[ $1 = "PGet" ]]; then
        echo "master=NetVPS" > ${ADM_tmp}/pwd.pwd
        while read service; do
            [[ -z $service ]] && break
            echo "127.0.0.1:$(echo $service|cut -d' ' -f2)=$(echo $service|cut -d' ' -f1)" >> ${ADM_tmp}/pwd.pwd
        done <<< "$(mportas)"
        porta_bind="0.0.0.0:$porta_socket"
        pass_file="${ADM_tmp}/pwd.pwd"
        py="python"
    fi

    [[ ! -z $porta_bind ]] && conf="-b $porta_bind " || conf="-p $porta_socket "
    [[ ! -z $pass_file ]] && conf+="-p $pass_file"
    [[ ! -z $local ]] && conf+="-l $local "
    [[ ! -z $response ]] && conf+="-r $response "
    [[ ! -z $IP ]] && conf+="-i $IP "
    [[ ! -z $texto_soket ]] && conf+="-t '$texto_soket'"

    echo -e "[Unit]
Description=$1 ($py) Service by Nexora
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=root
WorkingDirectory=/root
ExecStart=/usr/bin/$py ${ADM_inst}/$1.py $conf
Restart=always
RestartSec=3s

[Install]
WantedBy=multi-user.target" > /etc/systemd/system/python.$porta_socket.service

    systemctl enable python.$porta_socket &>/dev/null
    systemctl start python.$porta_socket &>/dev/null

    msg -bar
    sleep 2
    if [[ $(systemctl is-active python.$porta_socket) = "active" ]]; then
        print_center -verd "PYTHON ($py) INICIADO CON EXITO!!!"
    else
        print_center -verm2 "PYTHON NO PUDO INICIAR"
        print_center -ama "Revisa con: journalctl -u python.$porta_socket -n 20"
        systemctl disable python.$porta_socket &>/dev/null
        systemctl stop python.$porta_socket &>/dev/null
        rm -f /etc/systemd/system/python.$porta_socket.service
    fi
    msg -bar
    sleep 3
}

iniciarsocks () {
    pidproxy=$(pgrep -f "PPub.py") && [[ ! -z $pidproxy ]] && P1="\033[1;32m[ON]" || P1="\033[1;31m[OFF]"
    pidproxy2=$(pgrep -f "PPriv.py") && [[ ! -z $pidproxy2 ]] && P2="\033[1;32m[ON]" || P2="\033[1;31m[OFF]"
    pidproxy3=$(pgrep -f "PDirect.py") && [[ ! -z $pidproxy3 ]] && P3="\033[1;32m[ON]" || P3="\033[1;31m[OFF]"
    pidproxy4=$(pgrep -f "POpen.py") && [[ ! -z $pidproxy4 ]] && P4="\033[1;32m[ON]" || P4="\033[1;31m[OFF]"
    pidproxy5=$(pgrep -f "PGet.py") && [[ ! -z $pidproxy5 ]] && P5="\033[1;32m[ON]" || P5="\033[1;31m[OFF]"

    print_center -ama "INSTALADOR SOCKS PYTHON (PY2 / PY3)"
    msg -bar
    echo -e " \033[1;33m>> MODOS SIMPLES Y SEGUROS <<\033[0m"
    echo -ne "$(msg -verd "  [1]") $(msg -verm2 ">") " && msg -azu "Socks Python2 SIMPLE     $P1"
    echo -ne "$(msg -verd "  [2]") $(msg -verm2 ">") " && msg -azu "Socks Python3 SIMPLE     $P1"
    echo -ne "$(msg -verd "  [3]") $(msg -verm2 ">") " && msg -azu "Socks Python2 SEGURO     $P2"
    echo -ne "$(msg -verd "  [4]") $(msg -verm2 ">") " && msg -azu "Socks Python3 SEGURO     $P2"
    echo -e " \033[1;33m>> MODOS DIRECTOS Y OPEN <<\033[0m"
    echo -ne "$(msg -verd "  [5]") $(msg -verm2 ">") " && msg -azu "Socks Python2 DIRECTO    $P3"
    echo -ne "$(msg -verd "  [6]") $(msg -verm2 ">") " && msg -azu "Socks Python3 DIRECTO    $P3"
    echo -ne "$(msg -verd "  [7]") $(msg -verm2 ">") " && msg -azu "Socks Python2 OPENVPN    $P4"
    echo -ne "$(msg -verd "  [8]") $(msg -verm2 ">") " && msg -azu "Socks Python3 OPENVPN    $P4"
    echo -ne "$(msg -verd "  [9]") $(msg -verm2 ">") " && msg -azu "Socks Python2 GETTUNEL   $P5"
    msg -bar

    py=10
    if [[ $(lsof -V -i tcp -P -n|grep -v "ESTABLISHED"|grep -v "COMMAND"|grep "python"|wc -l) -ge "1" ]]; then
        echo -e "$(msg -verd " [10]") $(msg -verm2 ">") $(msg -azu "DETENER TODOS")   $(msg -verd " [11]") $(msg -verm2 ">") $(msg -azu "DETENER PUERTO")"
        py=11
    else
        echo -e "$(msg -verd " [10]") $(msg -verm2 ">") $(msg -azu "DETENER TODOS")"
    fi

    msg -bar
    echo -ne "$(msg -verd "  [0]") $(msg -verm2 ">") " && msg -bra "   \033[1;41m VOLVER \033[0m"
    msg -bar

    read -r selection
    case ${selection} in
        1) colector PPub python2;;
        2) colector PPub python3;;
        3) colector PPriv python2;;
        4) colector PPriv python3;;
        5) colector PDirect python2;;
        6) colector PDirect python3;;
        7) colector POpen python2;;
        8) colector POpen python3;;
        9) colector PGet python2;;
        10) stop_all;;
        11) stop_port;;
        0) return 1;;
    esac
    return 1
}
iniciarsocks
