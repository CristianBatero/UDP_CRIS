# CRISDEV-UDP v2.0 — Instalador Hysteria V1 para VPS

Script de instalación automática del servidor **UDP Hysteria V1** optimizado para
máxima estabilidad con la app **CRISDEV Tunnel** y el motor `libfarikudp.so`.

---

## ¿Qué incluye esta versión v2.0?

- ✅ Config servidor sincronizado con `UDPTunnel.java` (recv_window, idle_timeout, bandwidth)
- ✅ Servicio systemd con `Restart=always` y `LimitNOFILE=1048576`
- ✅ Parámetros del kernel optimizados para QUIC/BBR (sin sobreescribir sysctl.conf)
- ✅ Buffers UDP del kernel de 64 MB para alto rendimiento
- ✅ Firewall limpio — solo abre el puerto necesario, sin DNAT masivo
- ✅ Certificados SSL autofirmados con SAN correcto
- ✅ Resumen de instalación con valores exactos para configurar la app

---

## Instalación rápida en el VPS

```bash
wget https://github.com/CristianBatero/UDP_CRIS/raw/main/install_udp.sh
chmod +x install_udp.sh
./install_udp.sh
```

O en un solo comando:

```bash
bash <(wget -qO- https://github.com/CristianBatero/UDP_CRIS/raw/main/install_udp.sh)
```

---

## Configuración antes de instalar

Edita las variables al inicio del script según tu servidor:

```bash
nano install_udp.sh
```

| Variable | Default | Descripción |
|---|---|---|
| `DOMAIN` | `ip.crispdev.online` | IP o dominio de tu VPS |
| `UDP_PORT` | `:36712` | Puerto de escucha del servidor |
| `OBFS` | `crisdev` | Clave de ofuscación — debe coincidir con la app |
| `PASSWORD` | `crisdev` | Contraseña de autenticación |
| `UP_MBPS` | `100` | Ancho de banda de subida real del VPS |
| `DOWN_MBPS` | `100` | Ancho de banda de bajada real del VPS |

> **⚠️ IMPORTANTE:** `UP_MBPS` y `DOWN_MBPS` deben coincidir con los valores configurados
> en la app. Si el cliente declara más que el servidor → inestabilidad por BBR collapse.

---

## Configuración de la app CRISDEV Tunnel

Tras instalar, configura la app con estos valores:

| Campo | Valor |
|---|---|
| Servidor | IP de tu VPS |
| Puerto | `36712` (o el que configuraste) |
| OBFS | `crisdev` |
| Contraseña | `crisdev` |
| UDP Up Mbps | `100` |
| UDP Down Mbps | `100` |
| UDP Buffer | `8388608` (8 MB) |
| Versión | `v1` |

---

## Comandos de gestión del servidor

```bash
# Ver estado
systemctl status hysteria-server

# Ver logs en tiempo real
journalctl -u hysteria-server -f

# Reiniciar
systemctl restart hysteria-server

# Ver config activa
cat /etc/hysteria/config.json

# Diagnóstico rápido
bash <(wget -qO- https://github.com/CristianBatero/UDP_CRIS/raw/main/check_udp.sh)
```

---

## Port Hopping (puertos múltiples)

Si tu operadora bloquea el puerto fijo, usa un rango en la app (ej. `40000-50000`)
y agrega la regla DNAT en el servidor:

```bash
# En el VPS (reemplaza 36712 con tu puerto real):
iptables -t nat -A PREROUTING -p udp --dport 40000:50000 -j REDIRECT --to-port 36712
iptables-save > /etc/iptables/rules.v4
```

La app con v2.0 usa `hop_interval=30s` (antes 10s) para estabilidad en LTE.

---

## Desinstalar

```bash
./install_udp.sh --remove
```

---

## Soporte

- 📱 App: [CRISDEV Tunnel en Play Store](https://play.google.com/store/apps/details?id=com.cridev.hwt)
- 💬 Telegram: [t.me/crisis1823](https://t.me/crisis1823)
- 🌐 Web: [crispdev.online](https://crispdev.online)
- 🐙 GitHub: [CristianBatero/UDP_CRIS](https://github.com/CristianBatero/UDP_CRIS)
