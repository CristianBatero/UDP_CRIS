# CRISDEV-UDP v2.0 — Servidor y Motor Propietario para VPS

Script de instalación y optimización automática del servidor **CRIS UDP (QUIC)** diseñado para máxima velocidad, bypass de limitaciones de operadoras móviles (LTE/4G/5G) y estabilidad absoluta con la app **CRISDEV Tunnel** y los motores `UDPCris.java` / `libudpcris.so`.

---

## 🚀 Novedades y Mejoras de la Versión v2.0

- ✅ **Certificados Unificados:** Generación nativa de `crisudp.ca.crt` (10 años de validez) sin errores de cadena TLS.
- ✅ **Bypass de Throttling por Operadora:** Redirección automática de rango Multi-Puerto (`20000-50000`) para Port Hopping cada 30 segundos.
- ✅ **Puertos Prioritarios QoS:** Puertos `443` (HTTPS/QUIC), `53` (DNS), `123` (NTP) y `4500` (VoLTE) abiertos y redirigidos para máxima prioridad en torres celulares.
- ✅ **Autenticación Dual Sincronizada:** Soporte para contraseñas maestras y credenciales en formato `usuario:contraseña`.
- ✅ **Optimización de Kernel:** 64 MB de buffers UDP (`rmem_max`/`wmem_max`), disciplina de colas `fq` + `bbr` y conntrack UDP extendido.
- ✅ **Servicio de Alta Resiliencia:** `Restart=always`, `RestartSec=5s`, `LimitNOFILE=1048576` y `OOMScoreAdjust=-100`.

---

## ⚡ Instalación Rápida en el VPS

En un solo comando:

```bash
bash <(wget -qO- https://github.com/CristianBatero/UDP_CRIS/raw/main/install_udp.sh)
```

O paso a paso:

```bash
wget https://github.com/CristianBatero/UDP_CRIS/raw/main/install_udp.sh
chmod +x install_udp.sh
./install_udp.sh
```

---

## ⚙️ Parámetros de Configuración del Servidor

Variables principales en `install_udp.sh`:

| Variable | Valor por Defecto | Descripción |
|---|---|---|
| `DOMAIN` | `ip.crispdev.online` | IP o dominio de tu servidor VPS |
| `UDP_PORT` | `:36712` | Puerto base de escucha del daemon |
| `OBFS` | `crisdev` | Clave de ofuscación XOR anti-DPI |
| `PASSWORD` | `crisdev` | Contraseña predeterminada |
| `UP_MBPS` | `100` | Ancho de banda de subida declarado |
| `DOWN_MBPS` | `100` | Ancho de banda de bajada declarado |

---

## 📱 Configuración en la App Android (CRISDEV Tunnel)

Para conectar con el nuevo motor **CRIS UDP (`UDPCris.java`)**:

| Parámetro | Valor Recomendado |
|---|---|
| **Servidor** | IP de tu VPS |
| **Puerto o Rango** | `20000-50000` (o directo `36712`, `443`, `53`) |
| **Protocolo** | `CRIS UDP` (`libudpcris.so` / `libfarikudp.so`) |
| **OBFS** | `crisdev` |
| **Usuario / Pass** | Tu usuario y contraseña (o solo contraseña) |
| **UDP Up Mbps** | `100` |
| **UDP Down Mbps** | `100` |
| **UDP Buffer** | `8388608` (8 MB) |

---

## 🛠️ Comandos de Gestión y Diagnóstico

```bash
# Ver estado del servicio
systemctl status hysteria-server

# Ver logs en tiempo real
journalctl -u hysteria-server -f

# Reiniciar el servicio
systemctl restart hysteria-server

# Ejecutar diagnóstico completo
bash <(wget -qO- https://github.com/CristianBatero/UDP_CRIS/raw/main/check_udp.sh)
```

---

## 🗑️ Desinstalación

```bash
./install_udp.sh --remove
```

---

## 👥 Soporte y Comunidad

- 📱 **App Oficial:** [CRISDEV Tunnel en Play Store](https://play.google.com/store/apps/details?id=com.doriaxvpn.unlimited)
- 💬 **Telegram:** [t.me/crisis1823](https://t.me/crisis1823)
- 🐙 **Repositorio Oficial:** [CristianBatero/UDP_CRIS](https://github.com/CristianBatero/UDP_CRIS)
