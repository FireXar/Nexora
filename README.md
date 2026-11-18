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
| Sistema | Info, BBR, swap, update, limpieza automática, actualizar desde GitHub, autoinicio, desinstalar |
| Herramientas extra | Configurar, comprobar y eliminar el dominio del VPS; espacio para futuras herramientas |

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


## Módulos UDP agregados (1.4.1)

Se incorporan UDP-CUSTOM, UDP-HYSTERIA v1 y UDP-ZIVPN como módulos independientes en Servicios. Usan unidades, directorios y copias privadas de authSSH. Las reglas NAT se identifican con comentarios Nexora y se eliminan de forma específica; no se vacían cadenas globales de iptables. UDP-CUSTOM mantiene la configuración remota original; Hysteria mantiene v1.3.5, puerto 36712 y OBFS modv; ZIVPN mantiene puerto 5667, OBFS lacasita y rango 6000:19999. Requieren pruebas en VPS; no se consideran verificados hasta probarlos con el cliente real.


## Dominio del VPS

Durante la instalación Nexora pregunta opcionalmente si deseas configurar un dominio.
También puedes hacerlo luego desde **Herramientas extra → Configurar dominio**.
Nexora verifica que el dominio tenga registros DNS IPv4 (A) y que al menos uno
coincida con la IP pública actual del VPS antes de guardarlo. Si el DNS aún no
está propagado o apunta a otra IP, no lo guarda; puedes volver a intentarlo
cuando corrijas el registro. El dominio se almacena en `db/domain.conf` y se
muestra en el panel principal junto a la IP. No configura automáticamente
DNS, Cloudflare ni certificados SSL.

## Autoinicio del panel

Desde **Sistema → 7) Autoiniciar Nexora** puedes activar o desactivar la apertura
automática del panel al iniciar una sesión SSH interactiva como `root`.
La función queda desactivada por defecto. Al salir del panel, volverás a la
terminal sin cerrar la conexión SSH. No se ejecuta para comandos SSH remotos
no interactivos ni para transferencias SFTP/SCP.
