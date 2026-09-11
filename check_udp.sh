#!/usr/bin/env bash
# check_udp.sh — Diagnóstico rápido CRISDEV-UDP v2.0
# Uso: bash check_udp.sh
# O remotamente: bash <(wget -qO- https://github.com/CristianBatero/UDP_CRIS/raw/main/check_udp.sh)

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'; BOLD='\033[1m'

ok()   { echo -e "   ${GREEN}✅ $1${NC}"; }
warn() { echo -e "   ${YELLOW}⚠️  $1${NC}"; }
fail() { echo -e "   ${RED}❌ $1${NC}"; }

echo -e "${BOLD}${BLUE}═══════════════════════════════════════════${NC}"
echo -e "${BOLD}${BLUE}   CRISDEV-UDP — Diagnóstico Rápido v2.0   ${NC}"
echo -e "${BOLD}${BLUE}═══════════════════════════════════════════${NC}"
echo ""

# 1. Servicio
echo -e "${BOLD}1. Estado del servicio hysteria-server:${NC}"
if systemctl is-active --quiet hysteria-server 2>/dev/null; then
    ok "ACTIVO y corriendo"
else
    fail "INACTIVO — ejecuta: systemctl start hysteria-server"
fi

if systemctl is-enabled --quiet hysteria-server 2>/dev/null; then
    ok "Habilitado para inicio automático"
else
    warn "No habilitado — ejecuta: systemctl enable hysteria-server"
fi

# Verificar Restart=always
if grep -q "Restart=always" /etc/systemd/system/hysteria-server.service 2>/dev/null; then
    ok "Restart=always configurado"
else
    warn "Sin Restart=always — el servicio no se recupera de crashes automáticamente"
fi

echo ""

# 2. Puerto de escucha
echo -e "${BOLD}2. Puerto de escucha:${NC}"
LISTEN_PORT=$(python3 -c "import json; c=json.load(open('/etc/hysteria/config.json')); print(c.get('listen','').lstrip(':'))" 2>/dev/null)
if [[ -n "$LISTEN_PORT" ]]; then
    if ss -tulpn 2>/dev/null | grep -q ":${LISTEN_PORT}"; then
        ok "Hysteria escuchando en UDP :${LISTEN_PORT}"
    else
        fail "Hysteria NO está escuchando en :${LISTEN_PORT} (servicio caído o config inválida)"
    fi
else
    fail "No se pudo leer el puerto del config"
fi

echo ""

# 3. Config crítica
echo -e "${BOLD}3. Parámetros críticos del servidor:${NC}"
if [[ -f /etc/hysteria/config.json ]]; then
    python3 -c "
import json
with open('/etc/hysteria/config.json') as f:
    c = json.load(f)

checks = [
    ('recv_window_conn', c.get('recv_window_conn', 0),  8388608,  '>=8,388,608 (8 MB)'),
    ('recv_window',      c.get('recv_window', 0),       20971520, '>=20,971,520 (20 MB)'),
    ('idle_timeout',     c.get('idle_timeout', 0),      60,       '=60 (sync con cliente)'),
    ('max_conn_client',  c.get('max_conn_client', -1),  0,        '=0 (sin límite)'),
    ('up_mbps',          c.get('up_mbps', 0),           1,        '>0'),
    ('down_mbps',        c.get('down_mbps', 0),         1,        '>0'),
]
for param, val, threshold, note in checks:
    ok = (val >= threshold) if param not in ('idle_timeout','max_conn_client') else (val == threshold)
    icon = '✅' if ok else '⚠️ '
    print(f'   {icon} {param}: {val}  (recomendado: {note})')
obfs = c.get('obfs','')
print(f\"   {'✅' if obfs else '⚠️ '} obfs: '{obfs}'  {'(activo)' if obfs else '(vacío — asegúrate de que la app también tenga OBFS vacío)'}\")
" 2>/dev/null || fail "Error leyendo /etc/hysteria/config.json"
else
    fail "/etc/hysteria/config.json no existe — reinstala con install_udp.sh"
fi

echo ""

# 4. Parámetros del kernel
echo -e "${BOLD}4. Parámetros del kernel:${NC}"
rmem=$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0)
bbr=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
fwd=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)

[[ "$rmem" -ge 67108864 ]] 2>/dev/null && ok "rmem_max=$rmem (≥64 MB)" || warn "rmem_max=$rmem — recomendado 67108864. Ejecuta: sysctl -p /etc/sysctl.d/99-hysteria-udp.conf"
[[ "$bbr" == "bbr" ]] && ok "congestion_control=bbr" || warn "congestion_control=$bbr — recomendado bbr"
[[ "$fwd" == "1" ]] && ok "ip_forward=1" || fail "ip_forward=0 — ejecuta: sysctl -w net.ipv4.ip_forward=1"

echo ""

# 5. Firewall y Port Hopping
echo -e "${BOLD}5. Firewall y Port Hopping:${NC}"
if [[ -n "$LISTEN_PORT" ]]; then
    if iptables -L INPUT -n 2>/dev/null | grep -q "dpt:${LISTEN_PORT}"; then
        ok "Puerto base $LISTEN_PORT abierto en iptables INPUT"
    else
        warn "Puerto base $LISTEN_PORT no encontrado en iptables INPUT"
    fi
    if iptables -t nat -L PREROUTING -n 2>/dev/null | grep -q "dpts:20000:50000"; then
        ok "Port Hopping 20000-50000 activo (DNAT REDIRECT)"
    else
        warn "Port Hopping no activo en iptables nat — agrega: iptables -t nat -A PREROUTING -p udp --dport 20000:50000 -j REDIRECT --to-port $LISTEN_PORT"
    fi
fi

echo ""

# 6. Certificados SSL (crisudp.ca.crt)
echo -e "${BOLD}6. Certificados SSL (crisudp):${NC}"
if [[ -f /etc/hysteria/crisudp.server.crt || -f /etc/hysteria/hysteria.server.crt ]]; then
    CERT_FILE="/etc/hysteria/crisudp.server.crt"
    [[ ! -f "$CERT_FILE" ]] && CERT_FILE="/etc/hysteria/hysteria.server.crt"
    EXPIRY=$(openssl x509 -enddate -noout -in "$CERT_FILE" 2>/dev/null | cut -d= -f2)
    ok "Certificado $CERT_FILE existe — expira: $EXPIRY"
    [[ -f /etc/hysteria/crisudp.ca.crt ]] && ok "Certificado raíz crisudp.ca.crt presente"
else
    fail "Certificados no encontrados en /etc/hysteria/ — ejecuta install_udp.sh"
fi

echo ""

# 7. Últimos logs
echo -e "${BOLD}7. Últimos logs del servicio:${NC}"
journalctl -u hysteria-server -n 8 --no-pager 2>/dev/null || echo "   (no hay logs disponibles)"

echo ""
echo -e "${BOLD}${BLUE}═══════════════════════════════════════════${NC}"
echo -e "${BOLD}  Fin del diagnóstico — CRISDEV by @crisis1823${NC}"
echo -e "${BOLD}${BLUE}═══════════════════════════════════════════${NC}"
