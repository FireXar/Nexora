# Nexora

Panel en Bash para administrar usuarios SSH (vencimiento y límite de
conexiones), túneles y Xray en un VPS Debian/Ubuntu.

## Instalar

```bash
git clone https://github.com/FireXar/Nexora.git
cd Nexora
bash install.sh
nexora
```

## Qué incluye

| Menú | Función |
|---|---|
| Usuarios | Tres modos (SSH, HWID y TOKEN): crear, crear temporal (minutos), eliminar, renovar, editar, bloquear, listar, conectados, limitador de conexiones, borrar vencidos/todos, backup y restauración |
| Servicios | Lista con estado [ON]/[OFF]: Ajustes SSH, Dropbear, Socks Python (Directo, Seguro, OpenVPN, GetTunnel y Simple; varios puertos por modo), Stunnel SSL, Xray, BadVPN-UDPGW y Squid restringido. Cada uno con instalar, iniciar/detener, reiniciar y desinstalar |
| Xray (VLESS) | Instala Xray con checksum verificado, clientes con vencimiento, enlaces `vless://` |
| Panel | Cabecera con IP, RAM, disco, CPU, usuarios online, alertas de vencimiento y estado de servicios |
| Sistema | Info, BBR, swap, update, limpieza automática, actualizar desde GitHub, desinstalar |

## Estructura

```
install.sh          instalador
core/               config, interfaz y menús (usuarios, servicios, sistema)
modules/            módulos que se cargan solos (xray.sh, sockspy.sh, slowdns.sh, xray-cfg.py...)
                    y los proxies Python de SOCKS PYTHON (PDirect, PPriv, POpen, PGet)
NOTICE.md           software de terceros que se instala (no se redistribuye)
```

## Modos de usuarios

Se cambia desde **Usuarios → 13) Cambiar modo**. Los tres modos conviven: cada uno
lista y gestiona solo sus cuentas.

| Modo | Cuenta en el servidor | Contraseña |
|---|---|---|
| SSH | usuario elegido | la que pongas |
| HWID | el HWID del dispositivo | el mismo HWID |
| TOKEN | el token | una clave única para todos (opción 14) |

En HWID y TOKEN el "nombre de cliente" es solo para identificarlo en el panel.
El cron `nexora --tick` corre cada minuto: borra las cuentas temporales y
aplica el limitador de conexiones si está activo.

## Configuración de marca

Todo en `core/config.sh`: `APP_NAME`, `APP_ID`, `APP_AUTHOR` y `APP_REPO`.

## Agregar un servicio al menú

1. Crea `modules/miservicio.sh` con `miservicio_install`, `miservicio_remove` y
   `miservicio_menu() { svc_generic_menu "ETIQUETA" "unidad-systemd" miservicio_install miservicio_remove; }`.
2. Agrega una línea en `svc_registry` de `core/services.sh`:
   `id|ETIQUETA|unidad-systemd|miservicio_menu`
3. Aparece solo en la lista con su estado [ON]/[OFF].

## Agregar un módulo

1. Crea `modules/mimodulo.sh` con tus funciones y un `menu_mimodulo`.
2. Agrega una línea en `core/menu.sh` para abrirlo.
3. Si necesita limpieza diaria, define `mimodulo_cleanup` y llámala en `--clean`.

## Flujo de trabajo con Git

```bash
# en tu PC
git add . && git commit -m "Describe el cambio" && git push

# en el VPS (o desde el menú: Sistema → Actualizar)
nexora      # Sistema → 6) Actualizar
```

## Seguridad

- Xray corre como usuario `nobody`, no como root.
- Las descargas se verifican con SHA-256 cuando el proyecto publica checksum.
- Nexora no desactiva el firewall ni borra logs del sistema.
- Nunca subas claves, tokens ni certificados al repositorio (`.gitignore` ya los excluye).
