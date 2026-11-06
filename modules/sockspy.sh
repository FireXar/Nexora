#!/bin/bash
# Nexora - Socks Python (basado en el modulo de ADMRufu, con mejoras)
clear
msg -bar

# Rutas (ajusta si en Nexora se llaman distinto)
PY_DIR="${ADM_inst:-${APP_DIR}/modules}"     # donde estan PDirect.py, PPriv.py, ...
KEY_DIR="${DB_DIR:-/etc/nexora}"             # claves de GetTunnel (modo 600)
UNIT_DIR=/etc/systemd/system
# Igual que el original de ADMRufu: se busca "python" / "python2" directamente.
# "python3" queda como ultimo recurso para sistemas modernos (Ubuntu 22/24) que ya no
# traen python ni python2. Para forzar uno:  SOCKS_PY=/usr/bin/python2  (exportado antes del menu)
PYBIN="${SOCKS_PY:-$(command -v python || command -v python2 || command -v python3)}"

# ---------- utilidades ----------
valid_port(){ [[ $1 =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
port_in_use(){ ss -H -ltn "( sport = :$1 )" 2>/dev/null | grep -q .; }

# Escapa un argumento para ExecStart= de systemd (comillas, \, % y $)
sd_quote(){
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//%/%%}
    s=${s//\$/\$\$}
    printf '"%s"' "$s"
}

# Puertos con servicio python.<puerto>.service
unit_ports(){
    local f p
    for f in "$UNIT_DIR"/python.*.service; do
        [[ -e $f ]] || continue
        p=${f##*/python.}; p=${p%.service}
        [[ $p =~ ^[0-9]+$ ]] && echo "$p"
    done
}

# Modulo (PDirect, PPriv, ...) que usa un puerto
unit_module(){
    grep -o '/P[A-Za-z]*\.py' "$UNIT_DIR/python.$1.service" 2>/dev/null | head -n1 | sed 's#^/##; s#\.py$##'
}

# [ON]/[OFF] de un modulo
mod_status(){
    local f
    for f in "$UNIT_DIR"/python.*.service; do
        [[ -e $f ]] || continue
        if grep -q "/$1\.py" "$f" && systemctl is-active --quiet "${f##*/}"; then
            printf '%s' '\033[1;32m[ON]'; return
        fi
    done
    printf '%s' '\033[1;31m[OFF]'
}

remove_port(){
    local p=$1
    systemctl stop "python.${p}" &>/dev/null
    systemctl disable "python.${p}" &>/dev/null
    rm -f "$UNIT_DIR/python.${p}.service" "$KEY_DIR/pget.${p}.pwd"
    command -v ufw &>/dev/null && ufw delete allow "${p}/tcp" &>/dev/null
}

stop_all () {
    local ports p
    ports=$(unit_ports)
    if [[ -z $ports ]]; then
        print_center -verm "Puertos PYTHON no encontrados"
        msg -bar
    else
        for p in $ports; do remove_port "$p"; done
        systemctl daemon-reload
        print_center -verd "Puertos PYTHON detenidos"
        msg -bar
    fi
    sleep 3
}

stop_port () {
    clear
    local -a pypr=()
    local n=1 p prpy
    msg -bar
    print_center -ama "DETENER UN PUERTO"
    msg -bar
    for p in $(unit_ports); do
        echo -e " \033[1;32m[$n] \033[1;31m> \033[1;37m$p \033[1;33m($(unit_module "$p"))\033[0m"
        pypr[$n]=$p
        ((n++))
    done
    msg -bar
    echo -ne "$(msg -verd "  [0]") $(msg -verm2 ">") " && msg -bra "\033[1;41mVOLVER"
    msg -bar
    echo -ne "\033[1;37m opcion: " && read -r prpy
    tput cuu1 && tput dl1

    [[ $prpy = "0" ]] && return
    if [[ ! $prpy =~ ^[0-9]+$ ]] || [[ -z ${pypr[$prpy]} ]]; then
        print_center -verm2 "Opcion invalida"
        msg -bar; sleep 2
        return
    fi
    remove_port "${pypr[$prpy]}"
    systemctl daemon-reload
    print_center -verd "PUERTO PYTHON ${pypr[$prpy]} detenido"
    msg -bar
    sleep 3
}

# Devuelve, separados por coma, los algoritmos candidatos que este OpenSSH soporta
# (ssh -Q). Si no se puede consultar, devuelve todos. Asi un algoritmo que la version
# instalada ya no trae no invalida el resto de la configuracion.
ssh_supported(){
    local tipo=$1 sup c res=""; shift
    sup=$(ssh -Q "$tipo" 2>/dev/null)
    for c in "$@"; do
        if [[ -z $sup ]] || grep -qx -- "$c" <<< "$sup"; then res+="${res:+,}$c"; fi
    done
    printf '%s' "$res"
}

# FIX-SSH: habilita en OpenSSH los algoritmos viejos que usan muchas apps y dispositivos
# Android antiguos (ssh-rsa, group14/group1/group-exchange-sha1, aes-cbc, 3des-cbc,
# hmac-sha1, hmac-md5). Evita "Cannot negotiate, proposals do not match".
ssh_legacy(){
    [[ ! -d /etc/ssh ]] && return
    local conf=/etc/ssh/sshd_config.d/legacy.conf kw ok=0 kex ciph macs
    kex=$(ssh_supported kex diffie-hellman-group14-sha1 diffie-hellman-group1-sha1 diffie-hellman-group-exchange-sha1)
    ciph=$(ssh_supported cipher aes128-cbc aes256-cbc 3des-cbc)
    macs=$(ssh_supported mac hmac-sha1 hmac-md5)
    mkdir -p /etc/ssh/sshd_config.d
    for kw in PubkeyAcceptedAlgorithms PubkeyAcceptedKeyTypes; do   # el nombre cambia segun version de OpenSSH
        {
            echo "HostKeyAlgorithms +ssh-rsa"
            echo "${kw} +ssh-rsa"
            [[ -n $kex  ]] && echo "KexAlgorithms +${kex}"
            [[ -n $ciph ]] && echo "Ciphers +${ciph}"
            [[ -n $macs ]] && echo "MACs +${macs}"
        } > "$conf"
        grep -q '^Include /etc/ssh/sshd_config.d' /etc/ssh/sshd_config || \
            sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
        if sshd -t &>/dev/null; then ok=1; break; fi
    done
    if (( ok )); then
        systemctl reload ssh &>/dev/null || systemctl reload sshd &>/dev/null \
            || systemctl restart ssh &>/dev/null || systemctl restart sshd &>/dev/null
        echo -e "\033[1;33m SSH legacy:\033[1;32m algoritmos habilitados OK"
    else
        rm -f "$conf"
        echo -e "\033[1;33m SSH legacy:\033[1;31m sshd -t fallo, no se aplico"
    fi
    msg -bar3
}

# FIX-SSH: prueba el proxy como lo haria la app (payload + SSH)
test_pdirect(){
    local r
    r=$(timeout 4 bash -c "exec 3<>/dev/tcp/127.0.0.1/$1; printf 'GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\n\r\nSSH-2.0-test\r\n' >&3; cat <&3" 2>/dev/null | tr -d '\0')
    if echo "$r" | grep -aq "SSH-2.0"; then
        print_center -verd "TEST WEBSOCKET -> SSH OK"
    else
        print_center -ama "TEST: sin banner SSH en el puerto $1 (normal si el destino es OpenVPN)"
    fi
}

colector(){
    local mod=$1 porta_socket="" local_port="" response="" texto="" gpass=""
    local -a args=()

    if [[ -z $PYBIN ]]; then
        print_center -verm2 "No hay python (python3 / python2) instalado"; msg -bar; enter; return
    fi
    if [[ ! -f $PY_DIR/$mod.py ]]; then
        print_center -verm2 "No existe $PY_DIR/$mod.py"; msg -bar; enter; return
    fi

    clear
    msg -bar
    print_center -azu "Selecciona Puerto Principal, para Proxy"
    msg -bar

    while [[ -z $porta_socket ]]; do
        echo -ne "\033[1;37m Digite el Puerto: " && read -r porta_socket
        tput cuu1 && tput dl1
        if valid_port "$porta_socket" && ! port_in_use "$porta_socket"; then
            echo -e "\033[1;33m $(fun_trans  "Puerto python:")\033[1;32m ${porta_socket} OK"
            msg -bar3
        else
            echo -e "\033[1;33m $(fun_trans  "Puerto python:")\033[1;31m ${porta_socket} FAIL" && sleep 2
            tput cuu1 && tput dl1
            porta_socket=""
        fi
    done

    if [[ $mod = "PDirect" ]]; then
        print_center -azu "Selec Puerto Local SSH/DROPBEAR/OPENVPN"
        msg -bar3
        while [[ -z $local_port ]]; do
            echo -ne "\033[1;97m Digite el Puerto: \033[0m" && read -r local_port
            tput cuu1 && tput dl1
            if valid_port "$local_port" && port_in_use "$local_port"; then
                echo -e "\033[1;33m $(fun_trans  "Puerto local:")\033[1;32m ${local_port} OK"
                msg -bar3
            else
                echo -e "\033[1;33m $(fun_trans  "Puerto local:")\033[1;31m ${local_port} FAIL" && sleep 2
                tput cuu1 && tput dl1
                local_port=""
            fi
        done
        print_center -azu "Response personalizado (enter por defecto 200)"
        print_center -ama "NOTA : Para OVER WEBSOCKET escribe (101)"
        msg -bar3
        echo -ne "\033[1;97m Digite un Response: \033[0m" && read -r response
        tput cuu1 && tput dl1
        [[ $response =~ ^[0-9]{3}$ ]] || response="200"
        echo -e "\033[1;33m $(fun_trans  "Response:")\033[1;32m ${response} OK"
        msg -bar3

        ssh_legacy
    fi

    if [[ $mod = "PPub" || $mod = "PPriv" || $mod = "PDirect" ]]; then
        print_center -azu "Introdusca su Mini-Banner"
        msg -bar3
        print_center -azu "Introduzca un texto [Plano] o en [HTML]"
        echo ""
        read -r texto
    fi

    case $mod in
        PDirect) args=(-p "$porta_socket" -l "$local_port" -r "$response")
                 [[ -n $texto ]] && args+=(-t "$texto");;
        PPriv)   args=(-p "$porta_socket" -i "$(fun_ip)")
                 [[ -n $texto ]] && args+=(-t "$texto");;
        PPub)    args=(-p "$porta_socket")
                 [[ -n $texto ]] && args+=(-t "$texto");;
        POpen)   args=(-p "$porta_socket");;
        PGet)
            print_center -azu "Contraseña Gettunel (enter = aleatoria)"
            while :; do
                read -r gpass
                [[ -z $gpass ]] && gpass=$(openssl rand -hex 6)
                [[ $gpass =~ [[:space:]] ]] || break
                print_center -verm2 "La contraseña no puede tener espacios"
            done
            mkdir -p "$KEY_DIR"
            ( umask 077; printf 'master=%s\n' "$gpass" > "$KEY_DIR/pget.${porta_socket}.pwd" )
            args=(-b "0.0.0.0:$porta_socket" -p "$KEY_DIR/pget.${porta_socket}.pwd");;
    esac

    local exec_args="" a
    for a in "${args[@]}"; do exec_args+=" $(sd_quote "$a")"; done

    cat > "$UNIT_DIR/python.${porta_socket}.service" <<UNIT
[Unit]
Description=${mod} Service (Nexora)
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=root
WorkingDirectory=/
ExecStart=${PYBIN} -u ${PY_DIR}/${mod}.py${exec_args}
Restart=always
RestartSec=3s
NoNewPrivileges=yes
ProtectHome=read-only
ProtectSystem=full

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    systemctl enable "python.${porta_socket}" &>/dev/null
    systemctl start "python.${porta_socket}" &>/dev/null
    command -v ufw &>/dev/null && ufw allow "${porta_socket}/tcp" &>/dev/null

    msg -bar
    sleep 2
    if systemctl is-active --quiet "python.${porta_socket}"; then
        print_center -verd "PYTHON INICIADO CON EXITO!!!"
        [[ $mod = "PDirect" ]] && test_pdirect "$porta_socket"
        if [[ $mod = "PGet" ]]; then
            print_center -verd "$(fun_trans  "Gettunel Iniciado com Exito")"
            print_center -azu "$(fun_trans  "Su Contraseña Gettunel es"): $(msg -ama "$gpass")"
        fi
    else
        print_center -verm2 "PYTHON NO PUDO INICIAR"
        print_center -ama "Revisa con: journalctl -u python.${porta_socket} -n 20"
        remove_port "$porta_socket"
        systemctl daemon-reload
        msg -bar
        enter
        return
    fi
    msg -bar
    sleep 3
}

iniciarsocks () {
    local P1 P2 P3 P4 P5 max=6 selection
    P1=$(mod_status PPub)
    P2=$(mod_status PPriv)
    P3=$(mod_status PDirect)
    P4=$(mod_status POpen)
    P5=$(mod_status PGet)
    print_center -ama "$(fun_trans  "INSTALADOR SOCKS PYTHON")"
    msg -bar
    echo -ne "$(msg -verd "  [1]") $(msg -verm2 ">") " && msg -azu "Socks Python SIMPLE      $P1"
    echo -ne "$(msg -verd "  [2]") $(msg -verm2 ">") " && msg -azu "Socks Python SEGURO      $P2"
    echo -ne "$(msg -verd "  [3]") $(msg -verm2 ">") " && msg -azu "Socks Python DIRETO      $P3"
    echo -ne "$(msg -verd "  [4]") $(msg -verm2 ">") " && msg -azu "Socks Python OPENVPN     $P4"
    echo -ne "$(msg -verd "  [5]") $(msg -verm2 ">") " && msg -azu "Socks Python GETTUNEL    $P5"
    msg -bar

    if (( $(unit_ports | wc -l) >= 2 )); then
        echo -e "$(msg -verd "  [6]") $(msg -verm2 ">") $(msg -azu "DETENER TODOS") $(msg -verd "  [7]") $(msg -verm2 ">") $(msg -azu "DETENER UN PUERTO")"
        max=7
    else
        echo -e "$(msg -verd "  [6]") $(msg -verm2 ">") $(msg -azu "DETENER TODOS")"
    fi

    msg -bar
    echo -ne "$(msg -verd "  [0]") $(msg -verm2 ">") " && msg -bra "   \033[1;41m VOLVER \033[0m"
    msg -bar

    selection=$(selection_fun ${max})
    case ${selection} in
        1)colector PPub;;
        2)colector PPriv;;
        3)colector PDirect;;
        4)colector POpen;;
        5)colector PGet;;
        6)stop_all;;
        7)stop_port;;
        0)return 1;;
    esac
    return 1
}
iniciarsocks
