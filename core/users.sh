# ==========================================================
#  USUARIOS: modos SSH · HWID · TOKEN  (adaptado de ADMRufu)
# ==========================================================
#  users.db:  usuario|expira|limite|creado|tipo|cliente
#    tipo = ssh | hwid | token   (vacío = ssh → compatible con bases viejas)
#
#  ssh   → cuenta normal: usuario + contraseña.
#  hwid  → la cuenta del sistema ES el HWID del dispositivo
#          (usuario = contraseña = HWID). "cliente" es solo un nombre visible.
#  token → la cuenta del sistema ES el token; la contraseña es una sola,
#          compartida por todos los clientes TOKEN (token.pass).
# ==========================================================

MODE_FILE="${DB_DIR}/user_mode"          # ssh | hwid | token
TOKEN_PASS_FILE="${DB_DIR}/token.pass"   # clave compartida del modo TOKEN
TMP_DB="${DB_DIR}/tmp.db"                # usuario|fin_epoch   (cuentas temporales)
LIM_CONF="${DB_DIR}/limiter.conf"        # LIM_ON / LIM_EVERY / LIM_UNLOCK
LIM_LOCKS="${DB_DIR}/limiter.lock"       # usuario|desbloqueo_epoch (0 = manual)
LIM_LOG="${DB_DIR}/limiter.log"
CRON_FILE="/etc/cron.d/${APP_ID}"
LIMITS_CONF="/etc/security/limits.conf"

# ---------------------------------------------------------- helpers generales
trim() { local s="$*"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

user_mode() {
    local m; m=$(cat "$MODE_FILE" 2>/dev/null)
    case "$m" in ssh|hwid|token) echo "$m";; *) echo ssh;; esac
}

valid_user() { [[ "$1" =~ ^[a-z_][a-z0-9_-]{2,15}$ ]]; }
valid_client() { local re='^[A-Za-z0-9_.-][A-Za-z0-9 _.-]{2,19}$'; [[ "$1" =~ $re ]]; }
valid_id() {   # valid_id <texto> <mínimo>   (HWID / TOKEN: máx. 32, límite de Linux)
    local re="^[A-Za-z0-9_][A-Za-z0-9._-]{$(( $2 - 1 )),31}\$"
    [[ "$1" =~ $re ]]
}

# ¿useradd acepta nombres "raros" (mayúsculas, empiezan con número)?
badname_flag() {
    local h; h=$(useradd --help 2>&1)
    if   grep -q -- '--badnames' <<< "$h"; then echo --badnames
    elif grep -q -- '--badname'  <<< "$h"; then echo --badname
    fi
}

# ---------------------------------------------------------- base de datos
db_remove() { awk -F'|' -v u="$1" '$1 != u' "$USERS_DB" > "$USERS_DB.tmp"; mv "$USERS_DB.tmp" "$USERS_DB"; }
db_has()    { awk -F'|' -v u="$1" '$1 == u {f=1} END {exit !f}' "$USERS_DB"; }
db_get()    { awk -F'|' -v u="$1" -v c="$2" '$1 == u {print $c; exit}' "$USERS_DB"; }
db_set_field() {   # db_set_field usuario columna valor
    awk -F'|' -v OFS='|' -v u="$1" -v c="$2" -v v="$3" '$1==u{$c=v}1' "$USERS_DB" > "$USERS_DB.tmp"
    mv "$USERS_DB.tmp" "$USERS_DB"
}
db_users_of() {    # cuentas de un modo, en orden de creación
    awk -F'|' -v t="$1" 'NF && (($5 == "" ? "ssh" : $5) == t) {print $1}' "$USERS_DB"
}
db_client_taken() { # ¿ya existe ese nombre de cliente en el modo?
    awk -F'|' -v t="$1" -v c="$2" '$5 == t && tolower($6) == tolower(c) {f=1} END {exit !f}' "$USERS_DB"
}
kv_remove() {      # quita la línea "usuario|..." de un archivo auxiliar
    [[ -f "$1" ]] || return 0
    awk -F'|' -v u="$2" '$1 != u' "$1" > "$1.tmp"; mv "$1.tmp" "$1"
}
disp_name() {      # nombre para mostrar: cliente (HWID/TOKEN) o usuario (SSH)
    local c; c=$(db_get "$1" 6); echo "${c:-$1}"
}

# ---------------------------------------------------------- límites y cuentas
unset_limit() {
    [[ -f "$LIMITS_CONF" ]] || return 0
    awk -v u="$1" '!($1 == u && $2 == "hard" && $3 == "maxlogins")' "$LIMITS_CONF" > "$LIMITS_CONF.tmp" \
        && cat "$LIMITS_CONF.tmp" > "$LIMITS_CONF"
    rm -f "$LIMITS_CONF.tmp"
}
set_limit() { unset_limit "$1"; echo "$1 hard maxlogins $2" >> "$LIMITS_CONF"; }

is_locked() { [[ "$(passwd -S "$1" 2>/dev/null | awk '{print $2}')" == "L" ]]; }

conn_count() { local n; n=$(pgrep -u "$1" -fc 'sshd|dropbear' 2>/dev/null); echo "${n:-0}"; }

# Conexiones de todos los usuarios con un solo "ps"  →  ON[usuario]=n
load_online() {
    declare -gA ON=()
    local n u
    while read -r n u; do [[ -n "$u" ]] && ON[$u]=$n; done < <(
        ps -eo user:32=,args= 2>/dev/null \
            | awk '$1 != "root" && /sshd|dropbear/ {c[$1]++} END {for (u in c) print c[u], u}')
}
# Estado de /etc/shadow con una sola lectura  →  SH_EXP[usuario]=días  SH_LOCK[usuario]=1
load_shadow() {
    declare -gA SH_EXP=() SH_LOCK=()
    local n p e
    while IFS=: read -r n p _ _ _ _ _ e _; do
        SH_EXP[$n]=$e
        [[ "$p" == '!'* ]] && SH_LOCK[$n]=1
    done < /etc/shadow
}
load_tmp() {
    declare -gA TMPEND=()
    local u e
    [[ -s "$TMP_DB" ]] || return 0
    while IFS='|' read -r u e; do [[ -n "$u" ]] && TMPEND[$u]=$e; done < "$TMP_DB"
}

# mk_account usuario clave expira límite tipo cliente
mk_account() {
    local flag; flag=$(badname_flag)
    # shellcheck disable=SC2086
    useradd -M -s /bin/false -e "$3" -c "$5,$6" $flag "$1" &>/dev/null || return 1
    if ! echo "$1:$2" | chpasswd 2>/dev/null; then userdel -f "$1" &>/dev/null; return 1; fi
    set_limit "$1" "$4"
    echo "$1|$3|$4|$(date +%F)|$5|$6" >> "$USERS_DB"
}

rm_account() {
    pkill -KILL -u "$1" 2>/dev/null
    userdel -f "$1" &>/dev/null
    unset_limit "$1"
    db_remove "$1"
    kv_remove "$TMP_DB" "$1"
    kv_remove "$LIM_LOCKS" "$1"
}

# ---------------------------------------------------------- tabla y selección
# list_table <modo>  →  tabla numerada (sirve en celular, ~44 columnas)
list_table() {
    local m=$1 i=0 u e l t c n exp_d days col st name now_d now title=CLIENTE
    load_online; load_shadow; load_tmp
    now=$(date +%s); now_d=$(( now / 86400 ))
    [[ "$m" == "ssh" ]] && title=USUARIO
    printf " ${Y}%-4s%-14s %-8s %5s %5s %s${W}\n" "#" "$title" VENCE DIAS CON EST
    while IFS='|' read -r u e l _ t c; do
        [[ -z "$u" ]] && continue
        [[ "${t:-ssh}" == "$m" ]] || continue
        i=$(( i + 1 ))
        n=${ON[$u]:-0}
        name=${c:-$u}; name=${name:0:14}
        col=$G
        if [[ -n "${TMPEND[$u]}" ]]; then
            days="$(( (TMPEND[$u] - now + 59) / 60 ))m"
            (( TMPEND[$u] <= now )) && { days="fin"; col=$R; }
        else
            exp_d=${SH_EXP[$u]}
            if [[ -z "$exp_d" ]]; then days="-"
            elif (( exp_d <= now_d )); then days="venc"; col=$R
            else days=$(( exp_d - now_d )); (( days <= 3 )) && col=$Y
            fi
        fi
        if [[ -n "${SH_LOCK[$u]}" ]]; then st="${R}LOK${W}"; else st="${G}ULK${W}"; fi
        printf " ${G}%-4s${W}%-14s %-8s ${col}%5s${W} %5s %b\n" "$i)" "$name" \
            "${e:8:2}/${e:5:2}/${e:2:2}" "$days" "$n/$l" "$st"
        [[ "$m" != "ssh" ]] && printf "     ${DIM}↳ %s${W}\n" "$u"
    done < "$USERS_DB"
    (( i == 0 )) && warn "No hay cuentas ${m^^}"
    return 0
}

# pick_user <modo>  →  muestra la tabla y deja la cuenta elegida en PICK
pick_user() {
    local m=$1 o c; local -a L=()
    PICK=""
    mapfile -t L < <(db_users_of "$m")
    if (( ${#L[@]} == 0 )); then warn "No hay cuentas ${m^^}"; pause; return 1; fi
    list_table "$m"; thin
    read -rp " Número o nombre (0 = volver): " o
    o=$(trim "$o")
    [[ -z "$o" || "$o" == "0" ]] && return 1
    if is_num "$o" && (( o >= 1 && o <= ${#L[@]} )); then
        PICK=${L[$((o - 1))]}
    else
        for c in "${L[@]}"; do
            if [[ "$c" == "$o" ]] || [[ "$(db_get "$c" 6 | tr '[:upper:]' '[:lower:]')" == "${o,,}" ]]; then
                PICK=$c; break
            fi
        done
    fi
    [[ -n "$PICK" ]] || { err "No encontrado: $o"; pause; return 1; }
}

# ---------------------------------------------------------- crear
user_create() {   # user_create [tmp]
    local m lbl tmp=$1 u p c="" d l min exp end
    m=$(user_mode); lbl=${m^^}

    if [[ "$m" == "token" && ! -s "$TOKEN_PASS_FILE" ]]; then
        header "CREAR · TOKEN"
        warn "Todavía no hay contraseña TOKEN configurada."
        pause; token_pass_menu
        [[ -s "$TOKEN_PASS_FILE" ]] || return
    fi

    if [[ -n "$tmp" ]]; then header "CREAR TEMPORAL · $lbl"; else header "CREAR · $lbl"; fi
    echo -e " ${DIM}Deja vacío o escribe 0 para cancelar${W}"

    case "$m" in
        ssh)
            read -rp " Usuario         : " u; u=$(trim "$u")
            [[ -z "$u" || "$u" == "0" ]] && return
            valid_user "$u" || { err "Inválido (3-16: a-z 0-9 _ -)"; pause; return; }
            id "$u" &>/dev/null && { err "Ese usuario ya existe"; pause; return; }
            read -rp " Contraseña      : " p
            (( ${#p} >= 4 && ${#p} <= 32 )) || { err "La clave debe tener entre 4 y 32 caracteres"; pause; return; }
            ;;
        hwid|token)
            read -rp " Nombre cliente  : " c; c=$(trim "$c")
            [[ -z "$c" || "$c" == "0" ]] && return
            valid_client "$c" || { err "Nombre inválido (3-20: letras, números, espacio . _ -)"; pause; return; }
            db_client_taken "$m" "$c" && { err "Ya hay un cliente $lbl con ese nombre"; pause; return; }
            if [[ "$m" == "hwid" ]]; then
                read -rp " HWID            : " u; u=$(trim "$u")
                valid_id "$u" 8 || { err "HWID inválido (8-32: letras, números . _ -)"; pause; return; }
                p=$u
            else
                read -rp " TOKEN           : " u; u=$(trim "$u")
                valid_id "$u" 6 || { err "Token inválido (6-32: letras, números . _ -)"; pause; return; }
                p=$(cat "$TOKEN_PASS_FILE")
            fi
            id "$u" &>/dev/null && { err "Ese $lbl ya está registrado en el servidor"; pause; return; }
            ;;
    esac

    if [[ -n "$tmp" ]]; then
        read -rp " Duración (min)  : " min
        is_num "$min" && (( min > 0 && min <= 1440 )) || { err "Minutos inválidos (1-1440)"; pause; return; }
        end=$(( $(date +%s) + min * 60 ))
        exp=$(date -d "@$(( end + 86400 ))" +%F)   # el cron la borra al cumplir los minutos
    else
        read -rp " Días            : " d
        is_num "$d" && (( d > 0 && d <= 3650 )) || { err "Días inválidos"; pause; return; }
        exp=$(date -d "+$d days" +%F)
    fi

    if [[ "$m" == "ssh" ]]; then
        read -rp " Límite de conex.: " l
    else
        read -rp " Límite de conex. [1]: " l; l=${l:-1}
    fi
    is_num "$l" && (( l > 0 && l <= 999 )) || { err "Límite inválido (1-999)"; pause; return; }

    mk_account "$u" "$p" "$exp" "$l" "$m" "$c" || {
        err "No se pudo crear la cuenta (useradd rechazó el nombre)"; pause; return; }
    [[ -n "$tmp" ]] && echo "$u|$end" >> "$TMP_DB"

    header "CUENTA CREADA · $lbl"
    echo -e " Host     : ${G}$(get_ip)${W}"
    case "$m" in
        ssh)   echo -e " Usuario  : ${G}$u${W}"
               echo -e " Clave    : ${G}$p${W}";;
        hwid)  echo -e " Cliente  : ${G}$c${W}"
               echo -e " HWID     : ${G}$u${W}";;
        token) echo -e " Cliente  : ${G}$c${W}"
               echo -e " Token    : ${G}$u${W}";;
    esac
    if [[ -n "$tmp" ]]; then
        echo -e " Duración : ${G}$min min${W} ${DIM}(hasta $(date -d "@$end" +%H:%M))${W}"
    else
        echo -e " Expira   : ${G}$exp${W} ${DIM}($d días)${W}"
    fi
    echo -e " Límite   : ${G}$l${W}"
    pause
}

# ---------------------------------------------------------- eliminar / renovar / editar
user_delete() {
    local m name; m=$(user_mode)
    header "ELIMINAR · ${m^^}"
    pick_user "$m" || return
    name=$(disp_name "$PICK")
    rm_account "$PICK"; ok "Eliminado: $name"
    pause
}

user_renew() {
    local m d exp x name; m=$(user_mode)
    header "RENOVAR · ${m^^}"
    pick_user "$m" || return
    name=$(disp_name "$PICK")
    read -rp " Días desde hoy para $name: " d
    is_num "$d" && (( d > 0 && d <= 3650 )) || { err "Días inválidos"; pause; return; }
    exp=$(date -d "+$d days" +%F)
    chage -E "$exp" "$PICK" || { err "No se pudo renovar"; pause; return; }
    db_set_field "$PICK" 2 "$exp"
    kv_remove "$TMP_DB" "$PICK"          # si era temporal, pasa a ser normal
    if is_locked "$PICK"; then
        read -rp " Está bloqueada. ¿Desbloquear? [S/n]: " x
        [[ "$x" != [nN] ]] && { usermod -U "$PICK"; kv_remove "$LIM_LOCKS" "$PICK"; }
    fi
    ok "$name renovado hasta $exp"; pause
}

user_edit() {
    local m p l c; m=$(user_mode)
    header "EDITAR · ${m^^}"
    pick_user "$m" || return
    echo -e " ${DIM}Deja vacío para no cambiar${W}"
    if [[ "$m" == "ssh" ]]; then
        read -rp " Nueva clave     : " p
        if [[ -n "$p" ]]; then
            (( ${#p} >= 4 && ${#p} <= 32 )) || { err "La clave debe tener entre 4 y 32 caracteres"; pause; return; }
            echo "$PICK:$p" | chpasswd && ok "Clave cambiada"
        fi
    else
        read -rp " Nuevo nombre    : " c; c=$(trim "$c")
        if [[ -n "$c" ]]; then
            valid_client "$c" || { err "Nombre inválido"; pause; return; }
            db_client_taken "$m" "$c" && { err "Ya hay un cliente con ese nombre"; pause; return; }
            db_set_field "$PICK" 6 "$c"; usermod -c "$m,$c" "$PICK" 2>/dev/null
            ok "Nombre cambiado"
        fi
    fi
    read -rp " Nuevo límite    : " l
    if [[ -n "$l" ]]; then
        is_num "$l" && (( l > 0 && l <= 999 )) || { err "Límite inválido"; pause; return; }
        set_limit "$PICK" "$l"; db_set_field "$PICK" 3 "$l"; ok "Límite: $l"
    fi
    pause
}

user_block() {
    local m name; m=$(user_mode)
    header "BLOQUEAR / DESBLOQUEAR · ${m^^}"
    pick_user "$m" || return
    name=$(disp_name "$PICK")
    if is_locked "$PICK"; then
        usermod -U "$PICK"; kv_remove "$LIM_LOCKS" "$PICK"; ok "$name desbloqueado"
    else
        usermod -L "$PICK"; pkill -KILL -u "$PICK" 2>/dev/null; ok "$name bloqueado y desconectado"
    fi
    pause
}

# ---------------------------------------------------------- listar / conectados
user_list() {
    local m; m=$(user_mode)
    header "CUENTAS · ${m^^}"
    list_table "$m"; thin
    echo -e " Total: ${G}$(db_users_of "$m" | grep -c .)${W}  ${DIM}· LOK = bloqueada · Nm = temporal${W}"
    pause
}

user_online() {
    local u l t c any=0
    header "CONECTADOS"
    load_online
    printf " ${Y}%-6s %-20s %s${W}\n" MODO CUENTA CONEX
    while IFS='|' read -r u _ l _ t c; do
        [[ -z "$u" ]] && continue
        (( ${ON[$u]:-0} > 0 )) || continue
        any=1
        printf " %-6s %-20s ${G}%s${W}\n" "${t:-ssh}" "${c:-$u}" "${ON[$u]}/$l"
    done < "$USERS_DB"
    (( any )) || warn "Nadie conectado"
    pause
}

# ---------------------------------------------------------- borrar vencidos / todos
user_cleanup() {   # user_cleanup [modo]  ·  sin modo = todos (lo usa el cron diario)
    local hoy u e t; hoy=$(date +%F)
    while IFS='|' read -r u e _ _ t _; do
        [[ -z "$u" ]] && continue
        [[ -n "$1" && "${t:-ssh}" != "$1" ]] && continue
        if [[ "$e" < "$hoy" ]]; then rm_account "$u"; echo "expirado eliminado: $u"; fi
    done < <(cat "$USERS_DB")
}
user_cleanup_menu() {
    local m out; m=$(user_mode)
    header "BORRAR VENCIDOS · ${m^^}"
    out=$(user_cleanup "$m")
    if [[ -n "$out" ]]; then echo "$out" | sed 's/^/ /'; ok "Listo"; else ok "No había cuentas vencidas"; fi
    pause
}

user_delete_all() {
    local m n u; m=$(user_mode)
    header "BORRAR TODAS · ${m^^}"
    n=$(db_users_of "$m" | grep -c .)
    (( n > 0 )) || { warn "No hay cuentas ${m^^}"; pause; return; }
    warn "Se eliminarán las ${n} cuentas ${m^^}. Los otros modos no se tocan."
    confirm_si || return
    while read -r u; do rm_account "$u"; done < <(db_users_of "$m")
    ok "$n cuentas eliminadas"; pause
}

# ---------------------------------------------------------- temporales y limitador (cron)
lim_load() {
    LIM_ON=0; LIM_EVERY=3; LIM_UNLOCK=0
    # shellcheck source=/dev/null
    [[ -f "$LIM_CONF" ]] && . "$LIM_CONF"
    is_num "$LIM_EVERY" && (( LIM_EVERY > 0 )) || LIM_EVERY=3
    is_num "$LIM_UNLOCK" || LIM_UNLOCK=0
}
lim_save() { printf 'LIM_ON=%s\nLIM_EVERY=%s\nLIM_UNLOCK=%s\n' "$LIM_ON" "$LIM_EVERY" "$LIM_UNLOCK" > "$LIM_CONF"; }
lim_log() {
    echo "$(date '+%d/%m %H:%M') $*" >> "$LIM_LOG"
    if (( $(wc -l < "$LIM_LOG") > 300 )); then tail -n 200 "$LIM_LOG" > "$LIM_LOG.tmp"; mv "$LIM_LOG.tmp" "$LIM_LOG"; fi
}

# Bloquea a quien supera su límite de conexiones (todos los modos)
lim_run() {
    local u l n now; now=$(date +%s)
    load_online
    while IFS='|' read -r u _ l _; do
        [[ -z "$u" ]] && continue
        is_num "$l" || continue
        n=${ON[$u]:-0}
        (( n > l )) || continue
        pkill -KILL -u "$u" 2>/dev/null
        usermod -L "$u" &>/dev/null
        kv_remove "$LIM_LOCKS" "$u"
        if (( LIM_UNLOCK > 0 )); then echo "$u|$(( now + LIM_UNLOCK * 60 ))" >> "$LIM_LOCKS"
        else echo "$u|0" >> "$LIM_LOCKS"; fi
        lim_log "$(disp_name "$u") bloqueado ($n/$l conexiones)"
    done < <(cat "$USERS_DB")
}

# Lo ejecuta el cron cada minuto:  nexora --tick
user_tick() {
    local now u v; now=$(date +%s)
    touch "$TMP_DB" "$LIM_LOCKS"
    # 1) cuentas temporales cumplidas
    while IFS='|' read -r u v; do
        [[ -n "$u" ]] && is_num "$v" && (( now >= v )) && rm_account "$u"
    done < <(cat "$TMP_DB")
    # 2) desbloqueos automáticos del limitador
    while IFS='|' read -r u v; do
        [[ -n "$u" ]] && is_num "$v" && (( v > 0 && now >= v )) || continue
        usermod -U "$u" &>/dev/null; kv_remove "$LIM_LOCKS" "$u"
        lim_log "$(disp_name "$u") desbloqueado (auto)"
    done < <(cat "$LIM_LOCKS")
    # 3) limitador de conexiones, cada LIM_EVERY minutos
    lim_load
    [[ "$LIM_ON" == "1" ]] && (( (now / 60) % LIM_EVERY == 0 )) && lim_run
    return 0
}

# Agrega la tarea por minuto si falta (instalaciones viejas)
ensure_cron() {
    grep -qF -- '--tick' "$CRON_FILE" 2>/dev/null && return 0
    echo "* * * * * root $BIN_LINK --tick >/dev/null 2>&1" >> "$CRON_FILE"
}

limiter_menu() {
    local o e un
    while true; do
        lim_load
        header "LIMITADOR DE CONEXIONES"
        if [[ "$LIM_ON" == "1" ]]; then
            if (( LIM_UNLOCK > 0 )); then un="a los ${LIM_UNLOCK} min"; else un="manual"; fi
            echo -e " Estado: ${G}ON${W} · revisa cada ${LIM_EVERY} min · desbloqueo ${un}"
        else
            echo -e " Estado: ${R}OFF${W}"
        fi
        echo -e " ${DIM}Bloquea (todos los modos) a quien supere su límite.${W}"
        thin
        item 1 "Activar / configurar"
        item 2 "Desactivar"
        item 3 "Ver registro"
        item 4 "Limpiar registro"
        item 0 "Volver"; line
        read -rp " Opción: " o
        case $o in
            1) read -rp " Revisar cada (minutos) [3]: " e; e=${e:-3}
               is_num "$e" && (( e > 0 && e <= 60 )) || { err "Valor inválido (1-60)"; pause; continue; }
               read -rp " Desbloquear tras (min, 0 = manual) [15]: " un; un=${un:-15}
               is_num "$un" || { err "Valor inválido"; pause; continue; }
               LIM_ON=1; LIM_EVERY=$e; LIM_UNLOCK=$un; lim_save; ensure_cron
               ok "Limitador activo"; pause;;
            2) LIM_ON=0; lim_save; ok "Limitador detenido"
               warn "Las cuentas que ya bloqueó siguen así hasta su desbloqueo."; pause;;
            3) header "REGISTRO DEL LIMITADOR"
               if [[ -s "$LIM_LOG" ]]; then tail -n 40 "$LIM_LOG" | sed 's/^/ /'; else warn "Sin registros"; fi
               pause;;
            4) : > "$LIM_LOG"; ok "Registro limpio"; pause;;
            0) return;;
        esac
    done
}

# ---------------------------------------------------------- contraseña TOKEN
token_pass_menu() {
    local np x n u
    header "CONTRASEÑA TOKEN"
    if [[ -s "$TOKEN_PASS_FILE" ]]; then
        echo -e " Actual: ${G}$(cat "$TOKEN_PASS_FILE")${W}"
    else
        warn "No hay contraseña configurada"
    fi
    echo -e " ${DIM}Es la misma clave para todos los clientes TOKEN.${W}"; thin
    read -rp " Nueva clave (vacío = cancelar): " np
    [[ -z "$np" ]] && return 1
    (( ${#np} >= 6 && ${#np} <= 32 )) || { err "Debe tener entre 6 y 32 caracteres"; pause; return 1; }
    printf '%s' "$np" > "$TOKEN_PASS_FILE"; chmod 600 "$TOKEN_PASS_FILE"
    ok "Clave guardada"
    n=$(db_users_of token | grep -c .)
    if (( n > 0 )); then
        read -rp " ¿Aplicarla a los ${n} clientes TOKEN existentes? [S/n]: " x
        if [[ "$x" != [nN] ]]; then
            while read -r u; do echo "$u:$np" | chpasswd; done < <(db_users_of token)
            ok "Aplicada a $n clientes"
        fi
    fi
    pause
}

# ---------------------------------------------------------- backup / restaurar
user_backup() {
    local f u e l cr t c h n
    f="/root/${APP_ID}-usuarios-$(date +%Y%m%d-%H%M).bak"
    : > "$f"; chmod 600 "$f"
    {
        echo "#${APP_ID}-backup v1"
        [[ -s "$TOKEN_PASS_FILE" ]] && echo "#tokenpass|$(cat "$TOKEN_PASS_FILE")"
        while IFS='|' read -r u e l cr t c; do
            [[ -z "$u" ]] && continue
            h=$(getent shadow "$u" | cut -d: -f2)
            [[ -z "$h" ]] && continue
            echo "$u|$e|$l|$cr|${t:-ssh}|$c|$h"
        done < "$USERS_DB"
    } >> "$f"
    n=$(grep -vc '^#' "$f")
    ok "Backup de $n cuentas (todos los modos)"
    echo -e " Archivo: ${G}$f${W}"
    warn "Contiene las claves cifradas: guárdalo en un lugar seguro."
}

user_restore() {
    local -a F=(); local o f u e l cr t c h x flag n=0 s=0
    mapfile -t F < <(ls -1t /root/"${APP_ID}"-usuarios-*.bak 2>/dev/null)
    (( ${#F[@]} )) || { warn "No hay backups en /root"; return; }
    for x in "${!F[@]}"; do item "$(( x + 1 ))" "$(basename "${F[$x]}")"; done
    read -rp " Elige un backup (0 = volver): " o
    is_num "$o" && (( o >= 1 && o <= ${#F[@]} )) || return
    f=${F[$((o - 1))]}
    flag=$(badname_flag)
    x=$(grep '^#tokenpass|' "$f" | head -1 | cut -d'|' -f2-)
    if [[ -n "$x" && ! -s "$TOKEN_PASS_FILE" ]]; then
        printf '%s' "$x" > "$TOKEN_PASS_FILE"; chmod 600 "$TOKEN_PASS_FILE"
    fi
    while IFS='|' read -r u e l cr t c h; do
        [[ -z "$u" || "$u" == '#'* || -z "$h" ]] && continue
        if id "$u" &>/dev/null || db_has "$u"; then s=$(( s + 1 )); continue; fi
        # shellcheck disable=SC2086
        useradd -M -s /bin/false -e "$e" -c "$t,$c" $flag "$u" &>/dev/null || { s=$(( s + 1 )); continue; }
        usermod -p "$h" "$u"
        set_limit "$u" "$l"
        echo "$u|$e|$l|$cr|$t|$c" >> "$USERS_DB"
        n=$(( n + 1 ))
    done < "$f"
    ok "Restauradas: $n"
    (( s > 0 )) && warn "Omitidas (ya existían o inválidas): $s"
    return 0
}

backup_menu() {
    local o
    header "BACKUP DE CUENTAS"
    item 1 "Crear backup"
    item 2 "Restaurar backup"
    item 0 "Volver"; line
    read -rp " Opción: " o
    case $o in
        1) header "CREAR BACKUP"; user_backup; pause;;
        2) header "RESTAURAR BACKUP"; user_restore; pause;;
    esac
}

# ---------------------------------------------------------- cambiar modo
user_mode_menu() {
    local o cur; cur=$(user_mode)
    header "CAMBIAR MODO"
    echo -e " Modo actual: ${G}${cur^^}${W}"; thin
    item 1 "SSH"   "usuario + contraseña"
    item 2 "HWID"  "ID del dispositivo"
    item 3 "TOKEN" "token + clave compartida"
    item 0 "Volver"; line
    read -rp " Opción: " o
    case $o in
        1) echo ssh   > "$MODE_FILE";;
        2) echo hwid  > "$MODE_FILE";;
        3) echo token > "$MODE_FILE";;
        *) return;;
    esac
    cur=$(user_mode); ok "Modo ${cur^^} activo"; sleep 1
}

# ---------------------------------------------------------- menú
menu_users() {
    local o m lbl n lim
    ensure_cron
    while true; do
        m=$(user_mode); lbl=${m^^}; lim_load
        n=$(db_users_of "$m" | grep -c .)
        if [[ "$LIM_ON" == "1" ]]; then lim="ON"; else lim="OFF"; fi

        header "USUARIOS · $lbl"
        echo -e " ${DIM}Modo activo:${W} ${G}${lbl}${W} ${DIM}·${W} ${n} cuenta(s)"
        thin
        item 1  "Crear"             "nueva cuenta $lbl"
        item 2  "Crear temporal"    "dura N minutos"
        item 3  "Eliminar"
        item 4  "Renovar"           "días desde hoy"
        if [[ "$m" == "ssh" ]]; then item 5 "Editar" "clave · límite"
        else                         item 5 "Editar" "nombre · límite"; fi
        item 6  "Bloquear/Desbloq."
        item 7  "Listar"
        item 8  "Conectados"        "todos los modos"
        item 9  "Limitador [$lim]"  "bloqueo por exceso"
        item 10 "Borrar vencidos"   "solo $lbl"
        item 11 "Borrar todos"      "solo $lbl"
        item 12 "Backup/Restaurar"  "todos los modos"
        item 13 "Cambiar modo"      "SSH · HWID · TOKEN"
        [[ "$m" == "token" ]] && item 14 "Clave TOKEN" "clave compartida"
        item 0  "Volver"
        line
        echo -ne " ${Y}❯${W} Opción: "
        read -r o
        case $o in
            1)  user_create;;
            2)  user_create tmp;;
            3)  user_delete;;
            4)  user_renew;;
            5)  user_edit;;
            6)  user_block;;
            7)  user_list;;
            8)  user_online;;
            9)  limiter_menu;;
            10) user_cleanup_menu;;
            11) user_delete_all;;
            12) backup_menu;;
            13) user_mode_menu;;
            14) [[ "$m" == "token" ]] && token_pass_menu;;
            0)  return;;
        esac
    done
}
