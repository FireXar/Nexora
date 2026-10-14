valid_user() { [[ "$1" =~ ^[a-z_][a-z0-9_-]{2,15}$ ]]; }

set_limit() {
    sed -i "/^$1 hard maxlogins/d" /etc/security/limits.conf
    echo "$1 hard maxlogins $2" >> /etc/security/limits.conf
}
db_remove() { grep -v "^$1|" "$USERS_DB" > "$USERS_DB.tmp"; mv "$USERS_DB.tmp" "$USERS_DB"; }
db_set_field() {   # db_set_field usuario columna valor
    awk -F'|' -v OFS='|' -v u="$1" -v c="$2" -v v="$3" '$1==u{$c=v}1' "$USERS_DB" > "$USERS_DB.tmp"
    mv "$USERS_DB.tmp" "$USERS_DB"
}
conn_count() { pgrep -u "$1" -fc 'sshd|dropbear' 2>/dev/null || true; }

user_create() {
    header "CREAR USUARIO"
    read -rp " Usuario         : " u
    valid_user "$u" || { err "Inválido (3-16 chars: a-z 0-9 _ -)"; pause; return; }
    id "$u" &>/dev/null && { err "Ese usuario ya existe"; pause; return; }
    read -rsp " Contraseña      : " p; echo
    [[ ${#p} -lt 4 ]] && { err "Mínimo 4 caracteres"; pause; return; }
    read -rp " Días            : " d
    read -rp " Límite de conex.: " l
    is_num "$d" && is_num "$l" || { err "Días y límite deben ser números"; pause; return; }

    exp=$(date -d "+$d days" +%F)
    useradd -M -s /bin/false -e "$exp" "$u" || { err "No se pudo crear"; pause; return; }
    echo "$u:$p" | chpasswd
    set_limit "$u" "$l"
    echo "$u|$exp|$l|$(date +%F)" >> "$USERS_DB"

    header "CUENTA CREADA"
    echo -e " Host    : ${G}$(get_ip)${W}"
    echo -e " Usuario : ${G}$u${W}"
    echo -e " Clave   : ${G}$p${W}"
    echo -e " Expira  : ${G}$exp${W}"
    echo -e " Límite  : ${G}$l${W}"
    pause
}

user_delete() {
    header "ELIMINAR USUARIO"
    read -rp " Usuario: " u
    grep -q "^$u|" "$USERS_DB" || { err "No está en la base de $APP_NAME"; pause; return; }
    pkill -u "$u" 2>/dev/null; userdel -f "$u" 2>/dev/null
    sed -i "/^$u hard maxlogins/d" /etc/security/limits.conf
    db_remove "$u"; ok "Eliminado: $u"; pause
}

user_renew() {
    header "RENOVAR USUARIO"
    read -rp " Usuario: " u
    grep -q "^$u|" "$USERS_DB" || { err "No existe"; pause; return; }
    read -rp " Días desde hoy: " d
    is_num "$d" || { err "Número inválido"; pause; return; }
    exp=$(date -d "+$d days" +%F)
    chage -E "$exp" "$u"; usermod -U "$u" 2>/dev/null
    db_set_field "$u" 2 "$exp"; ok "Nueva expiración: $exp"; pause
}

user_limit() {
    header "CAMBIAR LÍMITE"
    read -rp " Usuario: " u
    grep -q "^$u|" "$USERS_DB" || { err "No existe"; pause; return; }
    read -rp " Nuevo límite: " l
    is_num "$l" || { err "Número inválido"; pause; return; }
    set_limit "$u" "$l"; db_set_field "$u" 3 "$l"
    ok "Límite actualizado"; pause
}

user_lock()   { header "BLOQUEAR";    read -rp " Usuario: " u; usermod -L "$u" && pkill -u "$u"; ok "Bloqueado"; pause; }
user_unlock() { header "DESBLOQUEAR"; read -rp " Usuario: " u; usermod -U "$u" && ok "Desbloqueado"; pause; }

user_list() {
    header "USUARIOS"
    printf " ${Y}%-16s %-12s %-7s %-7s${W}\n" USUARIO EXPIRA LÍMITE ONLINE
    local total=0 hoy col; hoy=$(date +%F)
    while IFS='|' read -r u e l c; do
        [[ -z "$u" ]] && continue
        col=$G; [[ "$e" < "$hoy" ]] && col=$R
        printf " ${col}%-16s %-12s %-7s %-7s${W}\n" "$u" "$e" "$l" "$(conn_count "$u")"
        total=$((total+1))
    done < "$USERS_DB"
    echo; echo -e " Total: ${G}$total${W}"; pause
}

user_online() {
    header "CONECTADOS"
    local any=0 n
    while IFS='|' read -r u _; do
        [[ -z "$u" ]] && continue
        n=$(conn_count "$u")
        if [[ "${n:-0}" -gt 0 ]]; then echo -e " ${G}$u${W} → $n conexión(es)"; any=1; fi
    done < "$USERS_DB"
    [[ $any -eq 0 ]] && warn "Nadie conectado"
    pause
}

user_cleanup() {   # silencioso: lo usa el cron
    local hoy; hoy=$(date +%F)
    while IFS='|' read -r u e _; do
        [[ -z "$u" ]] && continue
        if [[ "$e" < "$hoy" ]]; then
            pkill -u "$u" 2>/dev/null; userdel -f "$u" 2>/dev/null
            sed -i "/^$u hard maxlogins/d" /etc/security/limits.conf
            db_remove "$u"; echo "expirado eliminado: $u"
        fi
    done < <(cat "$USERS_DB")
}
user_cleanup_menu() { header "LIMPIAR EXPIRADOS"; user_cleanup; ok "Listo"; pause; }

menu_users() {
    local o x
    while true; do
        header "USUARIOS"
        echo -e " ${G}1)${W} Crear           ${G}5)${W} Listar"
        echo -e " ${G}2)${W} Eliminar        ${G}6)${W} Conectados"
        echo -e " ${G}3)${W} Renovar         ${G}7)${W} Bloquear / Desbloquear"
        echo -e " ${G}4)${W} Cambiar límite  ${G}8)${W} Borrar expirados"
        echo -e " ${G}0)${W} Volver"; line
        read -rp " Opción: " o
        case $o in
            1) user_create;; 2) user_delete;; 3) user_renew;; 4) user_limit;;
            5) user_list;;   6) user_online;; 8) user_cleanup_menu;;
            7) read -rp " [b]loquear o [d]esbloquear: " x
               if [[ $x == b ]]; then user_lock; else user_unlock; fi;;
            0) return;;
        esac
    done
}
