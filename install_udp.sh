#!/usr/bin/env bash
#
# Try `install_udp.sh --help` for usage.
#
# (c) 2023-2026 CRISDEV
# Versión mejorada v2.0 — Optimizada para máxima estabilidad con libfarikudp.so
#

set -e


###
# SCRIPT CONFIGURATION
###

# Domain o IP del VPS
DOMAIN="ip.crispdev.online"

# PROTOCOL — udp | wechat-video | faketcp
# En redes donde UDP está bloqueado, usar faketcp mejora la estabilidad
PROTOCOL="udp"

# Puerto UDP principal de escucha del servidor
UDP_PORT=":36712"

# OBFS — debe coincidir EXACTAMENTE con lo configurado en la app
# Settings.UDP_OBFS → udp_obfs en UDPTunnel.java → "obfs" en config.json cliente
OBFS="crisdev"

# PASSWORD — el cliente envía auth_str = contraseña (o usuario:contraseña)
# Si el usuario configura solo contraseña en la app: auth_str = "crisdev"
# Si configura usuario Y contraseña distintos: auth_str = "usuario:contraseña"
# El servidor lista ambas variantes para tolerancia
PASSWORD="crisdev"

# ─── PARÁMETROS DE RENDIMIENTO ────────────────────────────────────────────────
#
# Estos valores deben estar SINCRONIZADOS con los defaults de UDPTunnel.java:
#   UDP_BUFFER (app default) = 8,388,608  → recv_window_conn del servidor debe ser ≥ este valor
#   UDP_BUFFER * 2.5 (app)  = 20,971,520  → recv_window del servidor debe ser ≥ este valor
#
# Regla: el servidor declara ventanas MAYORES que el cliente para nunca ser el cuello de botella.

# Ventana de recepción por conexión QUIC (bytes) — debe ser >= UDP_BUFFER de la app (8 MB)
# 15 MB es el valor óptimo probado para LTE con buffer de app en 8 MB
RECV_WINDOW_CONN=15728640

# Ventana de recepción total de sesión QUIC (bytes) — debe ser >= recv_window del cliente (20 MB)
# 64 MB da espacio amplio para múltiples conexiones concurrentes sin bloquear el flujo
RECV_WINDOW=67108864

# Ancho de banda declarado — CRÍTICO: debe coincidir con la realidad del VPS
# Si el cliente declara más que el servidor, BBR entra en colapso
# Ajusta estos valores al ancho de banda real de tu VPS
UP_MBPS=100
DOWN_MBPS=100

# Clientes máximos simultáneos (0 = sin límite)
MAX_CONN_CLIENT=0

# Timeout de idle sincronizado con el cliente (UDPTunnel hardcodea 60s)
# Si el servidor cierra antes (default Hysteria: 30s) → conexión fantasma de 30s
IDLE_TIMEOUT=60

# ──────────────────────────────────────────────────────────────────────────────

# Basename de este script
SCRIPT_NAME="$(basename "$0")"

# Argumentos del script
SCRIPT_ARGS=("$@")

# Ruta de instalación del ejecutable
EXECUTABLE_INSTALL_PATH="/usr/local/bin/hysteria"

# Directorio de servicios systemd
SYSTEMD_SERVICES_DIR="/etc/systemd/system"

# Directorio de configuración de hysteria
CONFIG_DIR="/etc/hysteria"

# URLs de GitHub (Hysteria V1 — fork apernet)
REPO_URL="https://github.com/apernet/hysteria"
API_BASE_URL="https://api.github.com/repos/apernet/hysteria"

# Flags de curl con reintentos
CURL_FLAGS=(-L -f -q --retry 5 --retry-delay 10 --retry-max-time 60)


###
# AUTO DETECTED GLOBAL VARIABLE
###

PACKAGE_MANAGEMENT_INSTALL="${PACKAGE_MANAGEMENT_INSTALL:-}"
OPERATING_SYSTEM="${OPERATING_SYSTEM:-}"
ARCHITECTURE="${ARCHITECTURE:-}"
HYSTERIA_USER="${HYSTERIA_USER:-}"
HYSTERIA_HOME_DIR="${HYSTERIA_HOME_DIR:-}"


###
# ARGUMENTS
###

OPERATION=
VERSION=
FORCE=
LOCAL_FILE=


###
# COMMAND REPLACEMENT & UTILITIES
###

has_command() {
    local _command=$1
    type -P "$_command" > /dev/null 2>&1
}

curl() {
    command curl "${CURL_FLAGS[@]}" "$@"
}

mktemp() {
    command mktemp "$@" "hyservinst.XXXXXXXXXX"
}

tput() {
    if has_command tput; then
        command tput "$@"
    fi
}

tred()    { tput setaf 1; }
tgreen()  { tput setaf 2; }
tyellow() { tput setaf 3; }
tblue()   { tput setaf 4; }
taoi()    { tput setaf 6; }
tbold()   { tput bold; }
treset()  { tput sgr0; }

note() {
    local _msg="$1"
    echo -e "$SCRIPT_NAME: $(tbold)note: $_msg$(treset)"
}

warning() {
    local _msg="$1"
    echo -e "$SCRIPT_NAME: $(tyellow)warning: $_msg$(treset)"
}

error() {
    local _msg="$1"
    echo -e "$SCRIPT_NAME: $(tred)error: $_msg$(treset)"
}

has_prefix() {
    local _s="$1"
    local _prefix="$2"
    if [[ -z "$_prefix" ]]; then return 0; fi
    if [[ -z "$_s" ]]; then return 1; fi
    [[ "x$_s" != "x${_s#"$_prefix"}" ]]
}

systemctl() {
    if [[ "x$FORCE_NO_SYSTEMD" == "x2" ]] || ! has_command systemctl; then
        return
    fi
    command systemctl "$@"
}

show_argument_error_and_exit() {
    local _error_msg="$1"
    error "$_error_msg"
    echo "Try \"$0 --help\" for the usage." >&2
    exit 22
}

install_content() {
    local _install_flags="$1"
    local _content="$2"
    local _destination="$3"
    local _tmpfile="$(mktemp)"
    echo -ne "Install $_destination ... "
    echo "$_content" > "$_tmpfile"
    if install "$_install_flags" "$_tmpfile" "$_destination"; then
        echo -e "ok"
    fi
    rm -f "$_tmpfile"
}

remove_file() {
    local _target="$1"
    echo -ne "Remove $_target ... "
    if rm "$_target"; then
        echo -e "ok"
    fi
}

exec_sudo() {
    local _saved_ifs="$IFS"
    IFS=$'\n'
    local _preserved_env=(
        $(env | grep "^PACKAGE_MANAGEMENT_INSTALL=" || true)
        $(env | grep "^OPERATING_SYSTEM=" || true)
        $(env | grep "^ARCHITECTURE=" || true)
        $(env | grep "^HYSTERIA_\w*=" || true)
        $(env | grep "^FORCE_\w*=" || true)
    )
    IFS="$_saved_ifs"
    exec sudo env \
        "${_preserved_env[@]}" \
        "$@"
}

detect_package_manager() {
    if [[ -n "$PACKAGE_MANAGEMENT_INSTALL" ]]; then return 0; fi

    if has_command apt; then
        PACKAGE_MANAGEMENT_INSTALL='apt update; apt -y install'
        return 0
    fi
    if has_command dnf; then
        PACKAGE_MANAGEMENT_INSTALL='dnf check-update; dnf -y install'
        return 0
    fi
    if has_command yum; then
        PACKAGE_MANAGEMENT_INSTALL='yum update; yum -y install'
        return 0
    fi
    if has_command zypper; then
        PACKAGE_MANAGEMENT_INSTALL='zypper update; zypper install -y --no-recommends'
        return 0
    fi
    if has_command pacman; then
        PACKAGE_MANAGEMENT_INSTALL='pacman -Syu; pacman -Syu --noconfirm'
        return 0
    fi
    return 1
}

install_software() {
    local _package_name="$1"
    if ! detect_package_manager; then
        error "Supported package manager is not detected, please install the following package manually:"
        echo
        echo -e "\t* $_package_name"
        echo
        exit 65
    fi
    echo "Installing missing dependence '$_package_name' with '$PACKAGE_MANAGEMENT_INSTALL' ... "
    if $PACKAGE_MANAGEMENT_INSTALL "$_package_name"; then
        echo "ok"
    else
        error "Cannot install '$_package_name' with detected package manager, please install it manually."
        exit 65
    fi
}

is_user_exists() {
    local _user="$1"
    id "$_user" > /dev/null 2>&1
}

check_permission() {
    if [[ "$UID" -eq '0' ]]; then return; fi
    note "The user currently executing this script is not root."
    case "$FORCE_NO_ROOT" in
        '1')
            warning "FORCE_NO_ROOT=1 is specified, we will process without root and you may encounter the insufficient privilege error."
            ;;
        *)
            if has_command sudo; then
                note "Re-running this script with sudo, you can also specify FORCE_NO_ROOT=1 to force this script running with current user."
                exec_sudo "$0" "${SCRIPT_ARGS[@]}"
            else
                error "Please run this script with root or specify FORCE_NO_ROOT=1 to force this script running with current user."
                exit 13
            fi
            ;;
    esac
}

check_environment_operating_system() {
    if [[ -n "$OPERATING_SYSTEM" ]]; then
        warning "OPERATING_SYSTEM=$OPERATING_SYSTEM is specified, operating system detection will not be performed."
        return
    fi
    if [[ "x$(uname)" == "xLinux" ]]; then
        OPERATING_SYSTEM=linux
        return
    fi
    error "This script only supports Linux."
    note "Specify OPERATING_SYSTEM=[linux|darwin|freebsd|windows] to bypass this check."
    exit 95
}

check_environment_architecture() {
    if [[ -n "$ARCHITECTURE" ]]; then
        warning "ARCHITECTURE=$ARCHITECTURE is specified, architecture detection will not be performed."
        return
    fi
    case "$(uname -m)" in
        'i386' | 'i686')        ARCHITECTURE='386' ;;
        'amd64' | 'x86_64')     ARCHITECTURE='amd64' ;;
        'armv5tel' | 'armv6l' | 'armv7' | 'armv7l') ARCHITECTURE='arm' ;;
        'armv8' | 'aarch64')    ARCHITECTURE='arm64' ;;
        'mips' | 'mipsle' | 'mips64' | 'mips64le') ARCHITECTURE='mipsle' ;;
        's390x')                ARCHITECTURE='s390x' ;;
        *)
            error "The architecture '$(uname -a)' is not supported."
            note "Specify ARCHITECTURE=<architecture> to bypass this check."
            exit 8
            ;;
    esac
}

check_environment_systemd() {
    if [[ -d "/run/systemd/system" ]] || grep -q systemd <(ls -l /sbin/init); then
        return
    fi
    case "$FORCE_NO_SYSTEMD" in
        '1')
            warning "FORCE_NO_SYSTEMD=1 is specified, we will process as normal even if systemd is not detected."
            ;;
        '2')
            warning "FORCE_NO_SYSTEMD=2 is specified, all systemd commands will be skipped."
            ;;
        *)
            error "This script only supports Linux distributions with systemd."
            note "Specify FORCE_NO_SYSTEMD=1 to disable this check."
            note "Specify FORCE_NO_SYSTEMD=2 to disable this check along with all systemd commands."
            ;;
    esac
}

check_environment_curl() {
    if has_command curl; then return; fi
    apt update; apt -y install curl
}

check_environment_grep() {
    if has_command grep; then return; fi
    apt update; apt -y install grep
}

check_environment() {
    check_environment_operating_system
    check_environment_architecture
    check_environment_systemd
    check_environment_curl
    check_environment_grep
}

vercmp_segment() {
    local _lhs="$1"
    local _rhs="$2"
    if [[ "x$_lhs" == "x$_rhs" ]]; then echo 0; return; fi
    if [[ -z "$_lhs" ]]; then echo -1; return; fi
    if [[ -z "$_rhs" ]]; then echo 1; return; fi

    local _lhs_num="${_lhs//[A-Za-z]*/}"
    local _rhs_num="${_rhs//[A-Za-z]*/}"

    if [[ "x$_lhs_num" == "x$_rhs_num" ]]; then echo 0; return; fi
    if [[ -z "$_lhs_num" ]]; then echo -1; return; fi
    if [[ -z "$_rhs_num" ]]; then echo 1; return; fi

    local _numcmp=$(($_lhs_num - $_rhs_num))
    if [[ "$_numcmp" -ne 0 ]]; then echo "$_numcmp"; return; fi

    local _lhs_suffix="${_lhs#"$_lhs_num"}"
    local _rhs_suffix="${_rhs#"$_rhs_num"}"

    if [[ "x$_lhs_suffix" == "x$_rhs_suffix" ]]; then echo 0; return; fi
    if [[ -z "$_lhs_suffix" ]]; then echo 1; return; fi
    if [[ -z "$_rhs_suffix" ]]; then echo -1; return; fi
    if [[ "$_lhs_suffix" < "$_rhs_suffix" ]]; then echo -1; return; fi
    echo 1
}

vercmp() {
    local _lhs=${1#v}
    local _rhs=${2#v}

    while [[ -n "$_lhs" && -n "$_rhs" ]]; do
        local _clhs="${_lhs/.*/}"
        local _crhs="${_rhs/.*/}"
        local _segcmp="$(vercmp_segment "$_clhs" "$_crhs")"
        if [[ "$_segcmp" -ne 0 ]]; then echo "$_segcmp"; return; fi
        _lhs="${_lhs#"$_clhs"}"; _lhs="${_lhs#.}"
        _rhs="${_rhs#"$_crhs"}"; _rhs="${_rhs#.}"
    done

    if [[ "x$_lhs" == "x$_rhs" ]]; then echo 0; return; fi
    if [[ -z "$_lhs" ]]; then echo -1; return; fi
    if [[ -z "$_rhs" ]]; then echo 1; return; fi
}

check_hysteria_user() {
    local _default_hysteria_user="$1"
    if [[ -n "$HYSTERIA_USER" ]]; then return; fi
    if [[ ! -e "$SYSTEMD_SERVICES_DIR/hysteria-server.service" ]]; then
        HYSTERIA_USER="$_default_hysteria_user"
        return
    fi
    HYSTERIA_USER="$(grep -o '^User=\w*' "$SYSTEMD_SERVICES_DIR/hysteria-server.service" | tail -1 | cut -d '=' -f 2 || true)"
    if [[ -z "$HYSTERIA_USER" ]]; then
        HYSTERIA_USER="$_default_hysteria_user"
    fi
}

check_hysteria_homedir() {
    local _default_hysteria_homedir="$1"
    if [[ -n "$HYSTERIA_HOME_DIR" ]]; then return; fi
    if ! is_user_exists "$HYSTERIA_USER"; then
        HYSTERIA_HOME_DIR="$_default_hysteria_homedir"
        return
    fi
    HYSTERIA_HOME_DIR="$(eval echo ~"$HYSTERIA_USER")"
}


###
# ARGUMENTS PARSER
###

show_usage_and_exit() {
    echo
    echo -e "\t$(tbold)$SCRIPT_NAME$(treset) - CRISDEV-UDP server install script v2.0"
    echo
    echo -e "Usage:"
    echo
    echo -e "$(tbold)Install CRISDEV-UDP$(treset)"
    echo -e "\t$0 [ -f | -l <file> | --version <version> ]"
    echo -e "Flags:"
    echo -e "\t-f, --force\tForce re-install latest or specified version even if it has been installed."
    echo -e "\t-l, --local <file>\tInstall specified CRISDEV-UDP binary instead of downloading it."
    echo -e "\t--version <version>\tInstall specified version instead of the latest."
    echo
    echo -e "$(tbold)Remove CRISDEV-UDP$(treset)"
    echo -e "\t$0 --remove"
    echo
    echo -e "$(tbold)Check for the update$(treset)"
    echo -e "\t$0 -c"
    echo -e "\t$0 --check"
    echo
    echo -e "$(tbold)Show this help$(treset)"
    echo -e "\t$0 -h"
    echo -e "\t$0 --help"
    exit 0
}

parse_arguments() {
    while [[ "$#" -gt '0' ]]; do
        case "$1" in
            '--remove')
                if [[ -n "$OPERATION" && "$OPERATION" != 'remove' ]]; then
                    show_argument_error_and_exit "Option '--remove' is conflicted with other options."
                fi
                OPERATION='remove'
                ;;
            '--version')
                VERSION="$2"
                if [[ -z "$VERSION" ]]; then
                    show_argument_error_and_exit "Please specify the version for option '--version'."
                fi
                shift
                if ! has_prefix "$VERSION" 'v'; then
                    show_argument_error_and_exit "Version numbers should begin with 'v' (such like 'v1.3.1'), got '$VERSION'"
                fi
                ;;
            '-c' | '--check')
                if [[ -n "$OPERATION" && "$OPERATION" != 'check' ]]; then
                    show_argument_error_and_exit "Option '-c' or '--check' is conflicted with other option."
                fi
                OPERATION='check_update'
                ;;
            '-f' | '--force')
                FORCE='1'
                ;;
            '-h' | '--help')
                show_usage_and_exit
                ;;
            '-l' | '--local')
                LOCAL_FILE="$2"
                if [[ -z "$LOCAL_FILE" ]]; then
                    show_argument_error_and_exit "Please specify the local binary to install for option '-l' or '--local'."
                fi
                break
                ;;
            *)
                show_argument_error_and_exit "Unknown option '$1'"
                ;;
        esac
        shift
    done

    if [[ -z "$OPERATION" ]]; then
        OPERATION='install'
    fi

    case "$OPERATION" in
        'install')
            if [[ -n "$VERSION" && -n "$LOCAL_FILE" ]]; then
                show_argument_error_and_exit '--version and --local cannot be specified together.'
            fi
            ;;
        *)
            if [[ -n "$VERSION" ]]; then
                show_argument_error_and_exit "--version is only available when install."
            fi
            if [[ -n "$LOCAL_FILE" ]]; then
                show_argument_error_and_exit "--local is only available when install."
            fi
            ;;
    esac
}


###
# FILE TEMPLATES
###

# /etc/systemd/system/hysteria-server.service
#
# CAMBIOS v2.0:
#   + Restart=always       — se reinicia automáticamente si el proceso muere
#   + RestartSec=5         — espera 5s antes de reintentar (evita loops rápidos)
#   + LimitNOFILE=1048576  — 1M file descriptors: Hysteria abre 1 fd por conn UDP activa
#   + LimitNPROC=512       — evitar fork bombs en caso de bug
#   + OOMScoreAdjust=-100  — el OOM killer lo elige último (alta prioridad)
tpl_hysteria_server_service_base() {
    local _config_name="$1"
    cat << EOF
[Unit]
Description=CRISDEV-UDP Service (Hysteria V1)
After=network.target
Wants=network-online.target
After=network-online.target

[Service]
User=root
Group=root
WorkingDirectory=/etc/hysteria
Environment="PATH=/usr/local/bin/hysteria"
ExecStart=/usr/local/bin/hysteria -config /etc/hysteria/config.json server
Restart=always
RestartSec=5
LimitNOFILE=1048576
LimitNPROC=512
OOMScoreAdjust=-100

[Install]
WantedBy=multi-user.target
EOF
}

tpl_hysteria_server_service() {
    tpl_hysteria_server_service_base 'config'
}

tpl_hysteria_server_x_service() {
    tpl_hysteria_server_service_base '%i'
}

# /etc/hysteria/config.json — Servidor Hysteria V1 optimizado
#
# Campos CRÍTICOS sincronizados con UDPTunnel.java / buildConfigV1():
#
#   recv_window_conn  = 15,728,640  (≥ UDP_BUFFER cliente default 8,388,608)
#   recv_window       = 67,108,864  (≥ recv_window cliente = buffer * 2.5 = 20,971,520)
#   idle_timeout      = 60          (= idle_timeout hardcodeado en buildConfigV1())
#   max_conn_client   = 0           (sin límite — el retry=3 de la app lo necesita)
#
# alpn NO se declara en el servidor para tolerancia: si el cliente negocia h3,
# Hysteria V1 lo acepta por defecto en el TLS QUIC subyacente.
#
# up_mbps/down_mbps DEBEN coincidir con la realidad del VPS.
# Si el cliente declara más que el servidor (app default 1000 Mbps),
# BBR entra en colapso de congestión. El servidor es la autoridad.
tpl_etc_hysteria_config_json() {
    cat << EOF
{
  "listen": "$UDP_PORT",
  "protocol": "$PROTOCOL",
  "cert": "/etc/hysteria/hysteria.server.crt",
  "key": "/etc/hysteria/hysteria.server.key",
  "up": "$UP_MBPS Mbps",
  "up_mbps": $UP_MBPS,
  "down": "$DOWN_MBPS Mbps",
  "down_mbps": $DOWN_MBPS,
  "disable_udp": false,
  "obfs": "$OBFS",
  "recv_window_conn": $RECV_WINDOW_CONN,
  "recv_window": $RECV_WINDOW,
  "max_conn_client": $MAX_CONN_CLIENT,
  "idle_timeout": $IDLE_TIMEOUT,
  "auth": {
    "mode": "passwords",
    "config": ["$PASSWORD"]
  }
}
EOF
}


###
# SYSTEMD
###

get_running_services() {
    if [[ "x$FORCE_NO_SYSTEMD" == "x2" ]]; then return; fi
    systemctl list-units --state=active --plain --no-legend \
        | grep -o "hysteria-server@*[^\s]*.service" || true
}

restart_running_services() {
    if [[ "x$FORCE_NO_SYSTEMD" == "x2" ]]; then return; fi
    echo "Restarting running service ... "
    for service in $(get_running_services); do
        echo -ne "Restarting $service ... "
        systemctl restart "$service"
        echo "done"
    done
}

stop_running_services() {
    if [[ "x$FORCE_NO_SYSTEMD" == "x2" ]]; then return; fi
    echo "Stopping running service ... "
    for service in $(get_running_services); do
        echo -ne "Stopping $service ... "
        systemctl stop "$service"
        echo "done"
    done
}


###
# HYSTERIA & GITHUB API
###

is_hysteria_installed() {
    if [[ -f "$EXECUTABLE_INSTALL_PATH" || -h "$EXECUTABLE_INSTALL_PATH" ]]; then
        return 0
    fi
    return 1
}

get_installed_version() {
    if is_hysteria_installed; then
        "$EXECUTABLE_INSTALL_PATH" -v | cut -d ' ' -f 3
    fi
}

get_latest_version() {
    if [[ -n "$VERSION" ]]; then
        echo "$VERSION"
        return
    fi

    # Versión de Hysteria V1 conocida compatible con libfarikudp.so (CRISDEV-UDP)
    # Se usa como fallback si la API de GitHub no responde (firewall, rate-limit, DNS).
    local FALLBACK_VERSION="v1.3.5"

    local _tmpfile=$(mktemp)
    if ! curl -sS --connect-timeout 8 --max-time 15 \
         -H 'Accept: application/vnd.github.v3+json' \
         "$API_BASE_URL/releases/latest" -o "$_tmpfile" 2>/dev/null; then
        warning "No se pudo contactar GitHub API. Usando versión estable conocida: $FALLBACK_VERSION"
        rm -f "$_tmpfile"
        echo "$FALLBACK_VERSION"
        return
    fi

    local _latest_version=$(grep 'tag_name' "$_tmpfile" | head -1 | grep -o '"v[^"]*"')
    _latest_version=${_latest_version#'"'}
    _latest_version=${_latest_version%'"'}

    rm -f "$_tmpfile"

    if [[ -n "$_latest_version" ]]; then
        echo "$_latest_version"
    else
        warning "Respuesta de GitHub API inválida. Usando versión estable conocida: $FALLBACK_VERSION"
        echo "$FALLBACK_VERSION"
    fi
}

download_hysteria() {
    local _version="$1"
    local _destination="$2"

    # URLs de descarga del binario Hysteria V1 (en orden de preferencia)
    # Si github.com no es accesible desde el VPS, se prueban mirrors alternativos.
    local _filename="hysteria-$OPERATING_SYSTEM-$ARCHITECTURE"
    local _urls=(
        "$REPO_URL/releases/download/$_version/$_filename"
        "https://objects.githubusercontent.com/github-production-release-asset-2e65be/apernet/hysteria/${_version}/${_filename}"
        "https://ghproxy.com/$REPO_URL/releases/download/$_version/$_filename"
        "https://mirror.ghproxy.com/$REPO_URL/releases/download/$_version/$_filename"
    )

    for _url in "${_urls[@]}"; do
        echo "Downloading hysteria binary: $_url ..."
        if curl -R --connect-timeout 15 --max-time 120 \
                -H 'Cache-Control: no-cache' "$_url" -o "$_destination" 2>/dev/null; then
            # Verificar que el archivo descargado es un ejecutable ELF (no una página HTML de error)
            if file "$_destination" 2>/dev/null | grep -q "ELF"; then
                echo "Binario descargado correctamente desde: $_url"
                return 0
            else
                warning "El archivo descargado no es un binario válido (posiblemente error HTTP). Probando siguiente URL..."
                rm -f "$_destination"
            fi
        else
            warning "Falló la descarga desde: $_url"
        fi
    done

    error "No se pudo descargar el binario hysteria desde ninguna URL."
    error "Opciones manuales:"
    error "  1. Descarga el binario manualmente y usa: ./install_udp.sh -l /ruta/al/binario"
    error "  2. URL directa: $REPO_URL/releases/download/$_version/$_filename"
    return 11
}

check_update() {
    # RETURN VALUE
    # 0: update available (o instalación necesaria)
    # 1: installed version is latest

    echo -ne "Checking for installed version ... "
    local _installed_version="$(get_installed_version)"
    if [[ -n "$_installed_version" ]]; then
        echo "$_installed_version"
    else
        echo "not installed"
    fi

    echo -ne "Checking for latest version ... "
    local _latest_version="$(get_latest_version)"
    if [[ -n "$_latest_version" ]]; then
        echo "$_latest_version"
        VERSION="$_latest_version"
    else
        # Nunca debería llegar aquí (get_latest_version siempre retorna algo),
        # pero por seguridad forzamos instalación.
        echo "unknown — forcing install"
        VERSION="v1.3.5"
        return 0
    fi

    # Si no está instalado, siempre necesita instalación
    if [[ -z "$_installed_version" ]]; then
        return 0
    fi

    local _vercmp="$(vercmp "$_installed_version" "$_latest_version")"
    if [[ "$_vercmp" -lt 0 ]]; then
        return 0
    fi
    return 1
}


###
# ENTRY
###

perform_install_hysteria_binary() {
    if [[ -n "$LOCAL_FILE" ]]; then
        note "Performing local install: $LOCAL_FILE"
        echo -ne "Installing hysteria executable ... "
        if install -Dm755 "$LOCAL_FILE" "$EXECUTABLE_INSTALL_PATH"; then
            echo "ok"
        else
            exit 2
        fi
        return
    fi

    local _tmpfile=$(mktemp)
    if ! download_hysteria "$VERSION" "$_tmpfile"; then
        rm -f "$_tmpfile"
        exit 11
    fi

    echo -ne "Installing hysteria executable ... "
    if install -Dm755 "$_tmpfile" "$EXECUTABLE_INSTALL_PATH"; then
        echo "ok"
    else
        exit 13
    fi
    rm -f "$_tmpfile"
}

perform_remove_hysteria_binary() {
    remove_file "$EXECUTABLE_INSTALL_PATH"
}

perform_install_hysteria_example_config() {
    if [[ ! -d "$CONFIG_DIR" ]]; then
        install -d "$CONFIG_DIR"
    fi
    if [[ ! -f "$CONFIG_DIR/config.json" ]]; then
        install_content -Dm644 "$(tpl_etc_hysteria_config_json)" "$CONFIG_DIR/config.json"
    else
        note "Config ya existe en $CONFIG_DIR/config.json, no se sobreescribe."
        note "Para regenerar elimínalo primero: rm $CONFIG_DIR/config.json"
    fi
}

perform_install_hysteria_systemd() {
    if [[ "x$FORCE_NO_SYSTEMD" == "x2" ]]; then return; fi

    install_content -Dm644 "$(tpl_hysteria_server_service)" "$SYSTEMD_SERVICES_DIR/hysteria-server.service"
    install_content -Dm644 "$(tpl_hysteria_server_x_service)" "$SYSTEMD_SERVICES_DIR/hysteria-server@.service"

    systemctl daemon-reload
}

perform_remove_hysteria_systemd() {
    remove_file "$SYSTEMD_SERVICES_DIR/hysteria-server.service"
    remove_file "$SYSTEMD_SERVICES_DIR/hysteria-server@.service"
    systemctl daemon-reload
}

perform_install_hysteria_home_legacy() {
    if ! is_user_exists "$HYSTERIA_USER"; then
        echo -ne "Creating user $HYSTERIA_USER ... "
        useradd -r -d "$HYSTERIA_HOME_DIR" -m "$HYSTERIA_USER"
        echo "ok"
    fi
}

perform_install() {
    local _is_fresh_install
    if ! is_hysteria_installed; then
        _is_fresh_install=1
    fi

    local _is_update_required

    if [[ -n "$LOCAL_FILE" ]] || [[ -n "$VERSION" ]] || check_update; then
        _is_update_required=1
    fi

    if [[ "x$FORCE" == "x1" ]]; then
        if [[ -z "$_is_update_required" ]]; then
            note "Option '--force' is specified, re-install even if installed version is the latest."
        fi
        _is_update_required=1
    fi

    if [[ -z "$_is_update_required" ]]; then
        echo "$(tgreen)Installed version is up-to-date, nothing to do.$(treset)"
        return
    fi

    perform_install_hysteria_binary
    perform_install_hysteria_example_config
    perform_install_hysteria_home_legacy
    perform_install_hysteria_systemd
    setup_ssl
    setup_kernel_params
    setup_firewall
    start_services

    if [[ -n "$_is_fresh_install" ]]; then
        print_install_summary
    else
        restart_running_services
        echo
        echo -e "$(tbold)CRISDEV-UDP se ha actualizado con éxito a $VERSION.$(treset)"
        echo
    fi
}

perform_remove() {
    perform_remove_hysteria_binary
    stop_running_services
    perform_remove_hysteria_systemd

    echo
    echo -e "$(tbold)CRISDEV-UDP ha sido eliminado con éxito de su servidor.$(treset)"
    echo
    echo -e "Aún debe eliminar los archivos de configuración manualmente:"
    echo
    echo -e "\t$(tred)rm -rf $CONFIG_DIR$(treset)"
    if [[ "x$HYSTERIA_USER" != "xroot" ]]; then
        echo -e "\t$(tred)userdel -r $HYSTERIA_USER$(treset)"
    fi
    if [[ "x$FORCE_NO_SYSTEMD" != "x2" ]]; then
        echo
        echo -e "También deshabilita los servicios systemd:"
        echo
        echo -e "\t$(tred)rm -f /etc/systemd/system/multi-user.target.wants/hysteria-server.service$(treset)"
        echo -e "\t$(tred)rm -f /etc/systemd/system/multi-user.target.wants/hysteria-server@*.service$(treset)"
        echo -e "\t$(tred)systemctl daemon-reload$(treset)"
    fi
    echo
}

perform_check_update() {
    if check_update; then
        echo
        echo -e "$(tbold)Actualización disponible: $VERSION$(treset)"
        echo
        echo -e "$(tgreen)Ejecuta este script sin argumentos para instalar la última versión.$(treset)"
        echo
    else
        echo
        echo "$(tgreen)La versión instalada está actualizada.$(treset)"
        echo
    fi
}


###
# SSL SETUP
###

setup_ssl() {
    echo "Generando certificados SSL para Hysteria V1 ..."

    mkdir -p "$CONFIG_DIR"

    openssl genrsa -out "$CONFIG_DIR/hysteria.ca.key" 2048

    openssl req -new -x509 -days 3650 \
        -key "$CONFIG_DIR/hysteria.ca.key" \
        -subj "/C=CN/ST=GD/L=SZ/O=Hysteria, Inc./CN=Hysteria Root CA" \
        -out "$CONFIG_DIR/hysteria.ca.crt"

    openssl req -newkey rsa:2048 -nodes \
        -keyout "$CONFIG_DIR/hysteria.server.key" \
        -subj "/C=CN/ST=GD/L=SZ/O=Hysteria, Inc./CN=$DOMAIN" \
        -out "$CONFIG_DIR/hysteria.server.csr"

    openssl x509 -req \
        -extfile <(printf "subjectAltName=DNS:%s,IP:%s" "$DOMAIN" "$(hostname -I | awk '{print $1}')") \
        -days 3650 \
        -in "$CONFIG_DIR/hysteria.server.csr" \
        -CA "$CONFIG_DIR/hysteria.ca.crt" \
        -CAkey "$CONFIG_DIR/hysteria.ca.key" \
        -CAcreateserial \
        -out "$CONFIG_DIR/hysteria.server.crt"

    echo "Certificados SSL generados correctamente."
}


###
# KERNEL PARAMS — optimización para QUIC/UDP de alta velocidad
#
# CAMBIOS v2.0:
#   - Usa sysctl.d para NO sobreescribir /etc/sysctl.conf completo
#   - rp_filter=0 solo en la interfaz de salida, no en "all" globalmente
#   - Agrega buffers UDP del kernel ampliados para QUIC (rmem/wmem)
#   - Habilita ECN para mejor control de congestión BBR
###

setup_kernel_params() {
    echo "Configurando parámetros del kernel para QUIC/UDP optimizado ..."

    # Detectar interfaz de red principal
    local NET_IF
    NET_IF=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)

    if [[ -z "$NET_IF" ]]; then
        warning "No se pudo detectar la interfaz de red principal. Usando eth0 como fallback."
        NET_IF="eth0"
    fi

    echo "Interfaz de red detectada: $NET_IF"

    # Escribir en /etc/sysctl.d/ para no sobreescribir /etc/sysctl.conf
    cat > /etc/sysctl.d/99-hysteria-udp.conf << EOF
# ═══════════════════════════════════════════════════════════════════
# CRISDEV-UDP — Parámetros de kernel optimizados para Hysteria V1
# Generado por install_udp.sh v2.0
# ═══════════════════════════════════════════════════════════════════

# Reenvío de paquetes IPv4
net.ipv4.ip_forward = 1

# rp_filter SOLO en la interfaz de salida (no en all globalmente)
# Necesario para que QUIC funcione con DNAT y múltiples paths
net.ipv4.conf.${NET_IF}.rp_filter = 0
net.ipv4.conf.lo.rp_filter = 0

# ── Buffers UDP del kernel — crítico para QUIC/BBR ──────────────────
# rmem_max/wmem_max: tamaño máximo del socket buffer (64 MB)
# Hysteria V1 con recv_window de 64 MB necesita al menos este espacio
# en el kernel para no dropar paquetes antes de que lleguen al proceso
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 16777216
net.core.wmem_default = 16777216

# Backlog de conexiones para el socket de escucha UDP
net.core.netdev_max_backlog = 65536

# ── Control de congestión BBR ────────────────────────────────────────
# BBR mejora drásticamente el throughput en conexiones con pérdida de paquetes
# (LTE / redes móviles con congestion occasional)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# ── ECN (Explicit Congestion Notification) ───────────────────────────
# ECN permite que routers intermedios señalen congestión sin dropear paquetes
net.ipv4.tcp_ecn = 1

# ── Timeouts y keepalive ─────────────────────────────────────────────
# Evitar que conexiones UDP inactivas ocupen tablas conntrack
net.netfilter.nf_conntrack_udp_timeout = 60
net.netfilter.nf_conntrack_udp_timeout_stream = 120
EOF

    # Aplicar inmediatamente
    sysctl -p /etc/sysctl.d/99-hysteria-udp.conf

    echo "Parámetros del kernel aplicados."
}


###
# FIREWALL — solo abre el puerto necesario, sin DNAT masivo
#
# CAMBIOS v2.0:
#   - Elimina el DNAT masivo (10000-65000) que causaba captura de tráfico ajeno
#   - Solo abre el puerto $UDP_PORT directamente
#   - Soporte IPv6 separado y correcto
#   - Persiste reglas de forma limpia
###

setup_firewall() {
    echo "Configurando firewall para CRISDEV-UDP ..."

    # Instalar iptables-persistent de forma desatendida
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables-persistent

    # Extraer número de puerto desde UDP_PORT (formato ":36712" → "36712")
    local PORT_NUM
    PORT_NUM="${UDP_PORT#:}"

    # ── Reglas IPv4 ─────────────────────────────────────────────────────
    # Aceptar tráfico UDP en el puerto de Hysteria directamente
    # NO se usa DNAT masivo — Hysteria escucha directo en $UDP_PORT
    iptables -A INPUT -p udp --dport "$PORT_NUM" -j ACCEPT
    iptables -A INPUT -p tcp --dport "$PORT_NUM" -j ACCEPT   # por si PROTOCOL=faketcp

    # Permitir tráfico de retorno (conexiones establecidas)
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

    # ── Reglas IPv6 (solo el puerto específico) ──────────────────────────
    ip6tables -A INPUT -p udp --dport "$PORT_NUM" -j ACCEPT
    ip6tables -A INPUT -p tcp --dport "$PORT_NUM" -j ACCEPT
    ip6tables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

    # Persistir
    iptables-save > /etc/iptables/rules.v4
    ip6tables-save > /etc/iptables/rules.v6

    echo "Firewall configurado: puerto UDP/TCP $PORT_NUM abierto."

    # ── Nota sobre port hopping ──────────────────────────────────────────
    note "Si la app usa port hopping (rango de puertos), agrega las reglas DNAT necesarias:"
    echo ""
    echo -e "\t$(tblue)# Ejemplo: rango 40000-50000 → $PORT_NUM$(treset)"
    echo -e "\t$(tblue)RANGE_START=40000$(treset)"
    echo -e "\t$(tblue)RANGE_END=50000$(treset)"
    echo -e "\t$(tblue)iptables -t nat -A PREROUTING -p udp --dport \${RANGE_START}:\${RANGE_END} -j REDIRECT --to-port $PORT_NUM$(treset)"
    echo ""
    note "Con port hopping RECOMENDAMOS hop_interval >= 30s en la app para evitar pérdida por cambio de puerto durante RTT alto."
}


###
# START SERVICES
###

start_services() {
    echo "Iniciando CRISDEV-UDP ..."

    systemctl daemon-reload
    systemctl enable hysteria-server.service
    systemctl start hysteria-server.service

    # Verificar que el servicio levantó correctamente
    sleep 2
    if systemctl is-active --quiet hysteria-server.service; then
        echo "$(tgreen)Servicio hysteria-server iniciado correctamente.$(treset)"
    else
        warning "El servicio no está activo. Revisando logs:"
        systemctl status hysteria-server.service --no-pager -l || true
        echo ""
        note "Verifica que el puerto $UDP_PORT no esté en uso: ss -tulpn | grep ${UDP_PORT#:}"
    fi
}


###
# RESUMEN DE INSTALACIÓN
###

print_install_summary() {
    local PORT_NUM="${UDP_PORT#:}"

    echo
    echo -e "$(tbold)════════════════════════════════════════════════════════$(treset)"
    echo -e "$(tbold)  CRISDEV-UDP instalado correctamente en su servidor   $(treset)"
    echo -e "$(tbold)════════════════════════════════════════════════════════$(treset)"
    echo
    echo -e "$(tbold)Configuración del servidor:$(treset)"
    echo -e "  Protocolo: $(tgreen)$PROTOCOL$(treset)"
    echo -e "  Puerto:    $(tgreen)$PORT_NUM$(treset)"
    echo -e "  OBFS:      $(tgreen)$OBFS$(treset)"
    echo -e "  Contraseña:$(tgreen)$PASSWORD$(treset)"
    echo -e "  Up/Down:   $(tgreen)${UP_MBPS}/${DOWN_MBPS} Mbps$(treset)"
    echo
    echo -e "$(tbold)Configuración de la App (CRISDEV Tunnel):$(treset)"
    echo -e "  Servidor:     $(tblue)IP_DEL_VPS$(treset)"
    echo -e "  Puerto/Rango: $(tblue)$PORT_NUM$(treset)  (o rango ej. 40000-50000 para port hopping)"
    echo -e "  OBFS:         $(tblue)$OBFS$(treset)"
    echo -e "  Contraseña:   $(tblue)$PASSWORD$(treset)"
    echo -e "  UDP Up Mbps:  $(tblue)$UP_MBPS$(treset)  ← IMPORTANTE: mismo valor que el servidor"
    echo -e "  UDP Down Mbps:$(tblue)$DOWN_MBPS$(treset)  ← IMPORTANTE: mismo valor que el servidor"
    echo -e "  UDP Buffer:   $(tblue)8388608$(treset)  (8 MB — valor por defecto óptimo)"
    echo -e "  Versión:      $(tblue)v1$(treset)  (libfarikudp.so)"
    echo
    echo -e "$(tbold)Cliente app:$(treset)"
    echo -e "$(tblue)https://play.google.com/store/apps/details?id=com.cridev.hwt$(treset)"
    echo
    echo -e "Sígueme:"
    echo -e "\t+ Sitio Web $(tblue)https://cripdev.ml$(treset)"
    echo -e "\t+ Telegram: $(tblue)https://t.me/crisis1823$(treset)"
    echo
}


###
# MAIN
###

main() {
    parse_arguments "$@"
    check_permission
    check_environment
    check_hysteria_user "hysteria"
    check_hysteria_homedir "/var/lib/$HYSTERIA_USER"
    case "$OPERATION" in
        "install")
            perform_install
            ;;
        "remove")
            perform_remove
            ;;
        "check_update")
            perform_check_update
            ;;
        *)
            error "Unknown operation '$OPERATION'."
            ;;
    esac
}

main "$@"

# vim:set ft=bash ts=4 sw=4 sts=4 et:
