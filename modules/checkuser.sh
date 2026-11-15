# ==========================================================
#  CheckUser — API HTTP para apps de verificación
#  · POST {"user":"nombre"}  → fecha de vencimiento
#  · GET  (sin body)         → usuarios online (número o JSON)
# ==========================================================
CHECKUSER_SVC="${APP_ID}-checkuser"
CHECKUSER_DIR="${APP_DIR}/checkuser"
CHECKUSER_PHP="${CHECKUSER_DIR}/index.php"
CHECKUSER_CONF="${CHECKUSER_DIR}/config"

# ---------- helpers ----------
checkuser_port() {
    [[ -f "$CHECKUSER_CONF" ]] && awk -F= '/^PORT=/{print $2; exit}' "$CHECKUSER_CONF"
}

checkuser_datefmt() {
    [[ -f "$CHECKUSER_CONF" ]] && awk -F= '/^DATEFMT=/{print $2; exit}' "$CHECKUSER_CONF"
    echo "dmY"
}

checkuser_onlinefmt() {
    [[ -f "$CHECKUSER_CONF" ]] && awk -F= '/^ONLINE=/{print $2; exit}' "$CHECKUSER_CONF"
    echo "DIRECTO"
}

checkuser_write_conf() {
    local port="$1" datefmt="$2" online="$3"
    mkdir -p "$CHECKUSER_DIR"
    cat > "$CHECKUSER_CONF" <<EOF
PORT=$port
DATEFMT=$datefmt
ONLINE=$online
EOF
    chmod 640 "$CHECKUSER_CONF"
}

checkuser_write_php() {
    local datefmt online
    datefmt=$(checkuser_datefmt)
    online=$(checkuser_onlinefmt)
    mkdir -p "$CHECKUSER_DIR"
    cat > "$CHECKUSER_PHP" <<'PHPEOF'
<?php
// Nexora CheckUser API — entrada sanitizada
$raw = file_get_contents("php://input");
$update = json_decode($raw, true);
$FORMATO = "DATEFMT_PLACEHOLDER";
$ONLINE  = "ONLINE_PLACEHOLDER";

if (is_array($update) && isset($update["user"])) {
    $usuario = preg_replace("/[^a-zA-Z0-9._-]/", "", (string)$update["user"]);
    if ($usuario === "" || strlen($usuario) > 32) {
        http_response_code(400);
        echo "invalid";
        exit;
    }
    // Solo cuentas del sistema (no root)
    if ($usuario === "root" || !posix_getpwnam($usuario)) {
        echo "never";
        exit;
    }
    $cmd = "chage -l " . escapeshellarg($usuario) . " 2>/dev/null | grep 'Account expires'";
    $datos = shell_exec($cmd);
    if ($datos === null || $datos === "") {
        echo "never";
        exit;
    }
    $parts = explode(": ", $datos, 2);
    $exp = isset($parts[1]) ? trim($parts[1]) : "";
    if ($exp === "" || stripos($exp, "never") !== false) {
        echo "never";
        exit;
    }
    $ts = strtotime($exp);
    if ($ts === false) {
        echo "never";
        exit;
    }
    echo date($FORMATO, $ts);
    exit;
}

// Contador de usuarios online (sshd + dropbear + openvpn si existe)
$ssh = (int)trim((string)shell_exec("ps -eo user:32=,args= 2>/dev/null | awk '/sshd:|dropbear/ && \$1 != \"root\" {print \$1}' | sort -u | wc -l"));
$openvpn = 0;
if (is_file("/etc/openvpn/openvpn-status.log")) {
    $openvpn = (int)trim((string)shell_exec("grep -c '10.8.0' /etc/openvpn/openvpn-status.log 2>/dev/null"));
}
$total = $ssh + $openvpn;

switch ($ONLINE) {
    case "JSON":
        header("Content-Type: application/json");
        echo json_encode(["onlines" => $total, "limite" => "2500"]);
        break;
    default:
        echo (string)$total;
        break;
}
exit;
PHPEOF
    # Sustituir placeholders de forma segura
    sed -i "s/DATEFMT_PLACEHOLDER/${datefmt}/g; s/ONLINE_PLACEHOLDER/${online}/g" "$CHECKUSER_PHP"
    chmod 644 "$CHECKUSER_PHP"
}

checkuser_write_unit() {
    local port="$1"
    local phpbin
    phpbin=$(command -v php) || return 1
    cat > "/etc/systemd/system/${CHECKUSER_SVC}.service" <<EOF
[Unit]
Description=${APP_NAME} CheckUser API
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${CHECKUSER_DIR}
ExecStart=${phpbin} -S 0.0.0.0:${port} -t ${CHECKUSER_DIR}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

# ---------- acciones ----------
checkuser_install() {
    header "CHECKUSER · INSTALAR"
    warn "API HTTP para apps de verificación de usuarios/online."
    warn "Puede consumir un poco de CPU/RAM en conexiones inestables."
    thin

    local port datefmt online o
    read -rp " Puerto [8888]: " port; port=${port:-8888}
    if ! { is_num "$port" && (( port >= 10 && port <= 65535 )); }; then
        err "Puerto inválido (10-65535)"; pause; return
    fi
    if port_busy "$port" php; then
        err "El puerto $port ya está en uso"; pause; return
    fi

    echo
    echo " Formato de fecha de vencimiento:"
    item 1 "DD/MM/YYYY" "más usado en LATAM"
    item 2 "YYYY/MM/DD"
    echo -ne " ${Y}❯${W} Opción [1]: "; read -r o; o=${o:-1}
    case $o in
        2) datefmt="Ymd";;
        *) datefmt="dmY";;
    esac

    echo
    echo " Formato de usuarios online:"
    item 1 "DIRECTO" "solo el número"
    item 2 "JSON"    '{"onlines":N,"limite":"2500"}'
    echo -ne " ${Y}❯${W} Opción [1]: "; read -r o; o=${o:-1}
    case $o in
        2) online="JSON";;
        *) online="DIRECTO";;
    esac

    echo
    echo " Instalando PHP..."
    if ! command -v php >/dev/null 2>&1; then
        apt-get install -y php-cli >/dev/null 2>&1 || apt-get install -y php >/dev/null 2>&1 || {
            err "No se pudo instalar PHP"
            pause; return
        }
    fi
    command -v php >/dev/null 2>&1 || { err "PHP no disponible"; pause; return; }
    ok "PHP listo"

    # Quitar apache si quedó de instalaciones previas (opcional, no obligatorio)
    if systemctl is-active --quiet apache2 2>/dev/null; then
        systemctl stop apache2 2>/dev/null
        systemctl disable apache2 2>/dev/null
    fi

    checkuser_write_conf "$port" "$datefmt" "$online"
    checkuser_write_php
    checkuser_write_unit "$port" || { err "No se pudo crear el servicio"; pause; return; }

    open_port "$port"
    systemctl enable --now "$CHECKUSER_SVC" >/dev/null 2>&1
    systemctl restart "$CHECKUSER_SVC"

    if svc_on "$CHECKUSER_SVC"; then
        local ip
        ip=$(get_ip)
        ok "CheckUser activo"
        echo
        echo -e " URL:  ${C}http://${ip}:${port}${W}"
        echo -e " Alt:  ${C}http://${ip}:${port}/checkUser${W}"
        echo -e " Fecha: ${Y}$( [[ $datefmt == Ymd ]] && echo YYYY/MM/DD || echo DD/MM/YYYY )${W}  ·  Online: ${Y}${online}${W}"
    else
        err "No pudo iniciar — journalctl -u $CHECKUSER_SVC -n 20"
    fi
    pause
}

checkuser_change_port() {
    header "CHECKUSER · CAMBIAR PUERTO"
    unit_exists "$CHECKUSER_SVC" || { err "Instala CheckUser primero"; pause; return; }
    local port
    read -rp " Nuevo puerto: " port
    if ! { is_num "$port" && (( port >= 10 && port <= 65535 )); }; then
        err "Puerto inválido"; pause; return
    fi
    if port_busy "$port" php; then
        err "El puerto $port ya está en uso"; pause; return
    fi
    local old datefmt online
    old=$(checkuser_port)
    datefmt=$(checkuser_datefmt)
    online=$(checkuser_onlinefmt)
    systemctl stop "$CHECKUSER_SVC" 2>/dev/null
    checkuser_write_conf "$port" "$datefmt" "$online"
    checkuser_write_unit "$port"
    open_port "$port"
    systemctl enable --now "$CHECKUSER_SVC" >/dev/null 2>&1
    if svc_on "$CHECKUSER_SVC"; then
        ok "Puerto actualizado: $old → $port"
        echo -e " URL: ${C}http://$(get_ip):${port}${W}"
    else
        err "Falló al reiniciar el servicio"
    fi
    pause
}

checkuser_change_date() {
    header "CHECKUSER · FORMATO DE FECHA"
    unit_exists "$CHECKUSER_SVC" || { err "Instala CheckUser primero"; pause; return; }
    local o datefmt online port
    item 1 "DD/MM/YYYY"
    item 2 "YYYY/MM/DD"
    item 0 "Volver"; line
    echo -ne " ${Y}❯${W} Opción: "; read -r o
    case $o in
        1) datefmt="dmY";;
        2) datefmt="Ymd";;
        *) return;;
    esac
    port=$(checkuser_port)
    online=$(checkuser_onlinefmt)
    checkuser_write_conf "$port" "$datefmt" "$online"
    checkuser_write_php
    ok "Formato de fecha actualizado"
    pause
}

checkuser_change_online() {
    header "CHECKUSER · FORMATO ONLINE"
    unit_exists "$CHECKUSER_SVC" || { err "Instala CheckUser primero"; pause; return; }
    local o datefmt online port
    item 1 "DIRECTO" "solo el número"
    item 2 "JSON"
    item 0 "Volver"; line
    echo -ne " ${Y}❯${W} Opción: "; read -r o
    case $o in
        1) online="DIRECTO";;
        2) online="JSON";;
        *) return;;
    esac
    port=$(checkuser_port)
    datefmt=$(checkuser_datefmt)
    checkuser_write_conf "$port" "$datefmt" "$online"
    checkuser_write_php
    ok "Formato online actualizado ($online)"
    pause
}

checkuser_remove() {
    header "CHECKUSER · DESINSTALAR"
    confirm_si || return
    systemctl disable --now "$CHECKUSER_SVC" 2>/dev/null
    rm -f "/etc/systemd/system/${CHECKUSER_SVC}.service"
    rm -rf "$CHECKUSER_DIR"
    systemctl daemon-reload
    ok "CheckUser eliminado"
    pause
}

# ---------- menú ----------
checkuser_menu() {
    local o port ip datefmt online
    while true; do
        header "CHECKUSER"
        if unit_exists "$CHECKUSER_SVC"; then
            port=$(checkuser_port)
            datefmt=$(checkuser_datefmt)
            online=$(checkuser_onlinefmt)
            ip=$(get_ip)
            if svc_on "$CHECKUSER_SVC"; then
                ok "Estado: ACTIVO"
            else
                warn "Estado: DETENIDO"
            fi
            echo -e " URL:    ${C}http://${ip}:${port}${W}"
            echo -e " Fecha:  ${Y}$( [[ $datefmt == Ymd ]] && echo YYYY/MM/DD || echo DD/MM/YYYY )${W}"
            echo -e " Online: ${Y}${online}${W}"
            thin
            item 1 "Reiniciar / Iniciar-Detener"
            item 2 "Cambiar puerto"
            item 3 "Cambiar formato de fecha"
            item 4 "Cambiar formato online"
            item 5 "Reinstalar"
            item 6 "Desinstalar"
            item 0 "Volver"; line
            echo -ne " ${Y}❯${W} Opción: "; read -r o
            case $o in
                1) svc_toggle "$CHECKUSER_SVC" 2>/dev/null || {
                       if svc_on "$CHECKUSER_SVC"; then
                           systemctl stop "$CHECKUSER_SVC" && ok "Detenido"
                       else
                           systemctl start "$CHECKUSER_SVC" && ok "Iniciado"
                       fi
                       sleep 1
                   };;
                2) checkuser_change_port;;
                3) checkuser_change_date;;
                4) checkuser_change_online;;
                5) checkuser_install;;
                6) checkuser_remove; return;;
                0) return;;
            esac
        else
            warn "No instalado"
            thin
            item 1 "Instalar"
            item 0 "Volver"; line
            echo -ne " ${Y}❯${W} Opción: "; read -r o
            case $o in
                1) checkuser_install;;
                0) return;;
            esac
        fi
    done
}
