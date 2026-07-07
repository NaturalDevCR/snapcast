# Plan por etapas — Alternativa a Snapcast en Rust

> Diseñado para validar el riesgo técnico más alto temprano (sync) y producir algo demostrable al final de cada fase. No es un waterfall — cada fase entrega valor independiente.

---

## Fase 0 — Foundation (1 semana)

**Objetivo:** Setup del workspace y validar dependencias clave con spikes pequeños.

### Entregables

- Cargo workspace con crates: `protocol`, `server`, `client`, `common`, `web`
- Spike de CPAL: capturar de mic + reproducir en speaker, medir latencia
- Spike de Tokio: TCP echo server multi-cliente
- Spike de `audiopus`: encode/decode Opus end-to-end
- Decisión documentada de stack

### Stack propuesto

| Necesidad | Crate |
|---|---|
| Async runtime | `tokio` |
| Audio cross-platform | `cpal` |
| Opus | `audiopus` o `opus` |
| FLAC decode | `claxon` (decode) + `flac-bound` (encode) |
| mDNS | `mdns-sd` |
| HTTP/WS server | `axum` + `tokio-tungstenite` |
| JSON-RPC | `jsonrpsee` |
| Serialización binaria | manual (little-endian) — el protocolo lo exige |
| Config | `serde` + `toml` |
| Logging | `tracing` + `tracing-subscriber` |
| Resampling | `rubato` |

### Criterio de éxito

Los 3 spikes funcionan. Si CPAL no sirve para baja latencia (<10ms), cambiar plan en este momento.

---

## Fase 1 — Protocolo y mensajería (2-3 semanas)

**Objetivo:** Implementar el protocolo binario compatible o un protocolo nuevo bien diseñado.

### Decisión clave

¿Compatibilidad con clientes Snapcast existentes, o protocolo limpio nuevo?

- **Compatible:** Permite usar clientes Snapcast existentes mientras construyes los tuyos. Reduce riesgo de adopción.
- **Nuevo:** Más libertad de diseño (timestamps de 64 bits, framing más simple, auth integrado desde el día 1).

**Recomendación:** Empezar **compatible** con el protocolo Snapcast v2 para poder probar tu server con clientes Snapcast reales (validación gratis). Después agregar tu protocolo v3 propio.

### Módulos en `protocol/`

```
protocol/
├── message.rs          — base message header + enum de tipos
├── wire.rs             — serialización little-endian, helpers
└── messages/
    ├── hello.rs
    ├── server_settings.rs
    ├── codec_header.rs
    ├── wire_chunk.rs
    ├── time.rs
    └── client_info.rs
```

### Formato del mensaje base (little-endian)

```
uint16  type
uint16  id
uint16  refers_to
int32   sent_sec
int32   sent_usec
int32   received_sec
int32   received_usec
uint32  size
u8[]    payload[size]
```

### Tipos de mensaje

| ID | Nombre | Descripción |
|---|---|---|
| 1 | `CodecHeader` | Init data del codec (FLAC stream info, Opus config) |
| 2 | `WireChunk` | Frame de audio codificado + timestamp |
| 3 | `ServerSettings` | Volumen, mute, latency (JSON payload) |
| 4 | `Time` | Clock sync request/response |
| 5 | `Hello` | Client intro (versión, hostname, ID único) |
| 7 | `ClientInfo` | Actualizaciones de volumen/mute desde el cliente |
| 8 | `Error` | Auth/error responses |

### Tests

- Round-trip de cada mensaje
- Fuzzing con `arbitrary` + `cargo-fuzz` en el parser
- Parse de un dump de tráfico Snapcast real

### Criterio de éxito

Tu parser puede leer un dump de tráfico de Snapcast real y reconstruirlo idénticamente.

---

## Fase 2 — Sincronización (3-4 semanas) — MÁXIMO RIESGO

**Objetivo:** Implementar y validar el algoritmo de clock sync. Esta es la parte intelectualmente difícil — si no funciona, el proyecto no funciona.

**Por qué ahora:** Validar el riesgo técnico más alto antes de invertir en server/client completos.

### Algoritmo de referencia

Snapcast usa un approach NTP-like:

```
Cliente envía Time { t_client_sent }
                    ↓
Servidor responde { t_server_recv, t_server_sent }
                    ↓
Cliente calcula:
  latency_c2s = t_server_recv - t_client_sent
  latency_s2c = t_client_recv - t_server_sent
  time_diff   = (latency_c2s - latency_s2c) / 2
```

El offset se suaviza con mediana de 200 muestras (resistente a outliers de red).

### Módulos en `crates/sync/`

```
sync/
├── time_provider.rs    — estimación del offset cliente↔servidor
│                         buffer circular de 200 muestras, mediana
│                         clear si >60s sin sync
├── buffer.rs           — queue de PcmChunk con timestamps
│                         latencia adaptativa (mini 20ms, short 100ms, long 500ms)
└── tempo.rs            — frame-level resampling con `rubato`
                          frame duplication/removal para corrección gradual
```

### Plan de validación

1. **Test unitario:** dado stream de timestamps con jitter conocido, el offset converge dentro de N muestras
2. **Test de integración:** dos procesos en la misma máquina, medir desfase con loopback de audio
3. **Test real:** dos Raspberry Pi en LAN, medir desfase con Audacity

### Consideraciones de scheduling

Rust + Tokio puede introducir jitter por el scheduler async. Si el jitter afecta al sync:
- Thread dedicado con `std::thread` para el audio loop (fuera de Tokio)
- Tokio solo para I/O de red, sincronización vía `crossbeam-channel`
- Evaluar `tokio` con thread priority (`thread-priority` crate)

### Criterio de éxito

< 50ms de desfase entre dos clientes en LAN. Snapcast logra ~1ms — apuntar a paridad.

---

## Fase 3 — Servidor MVP (3 semanas)

**Objetivo:** Server que lea de un pipe y transmita a N clientes con un solo codec.

### Módulos en `server/`

```
server/
├── main.rs
├── config.rs               — TOML config, defaults razonables
├── broadcaster.rs          — fan-out de chunks a sesiones activas
├── session.rs              — StreamSession por cliente conectado
├── streamreader/
│   └── pipe.rs             — leer PCM de un FIFO
└── encoder/
    ├── mod.rs              — trait Encoder
    ├── pcm.rs
    └── opus.rs
```

### Scope explícitamente fuera en esta fase

- mDNS (Fase 8)
- Web UI (Fase 7)
- Múltiples streams (Fase 6)
- TLS / Auth (Fase 10)
- FLAC (Fase 5+)

### Criterio de éxito

Tu server transmite a un **cliente Snapcast original sin modificar** y se escucha audio sincronizado.

---

## Fase 4 — Cliente MVP (3 semanas)

**Objetivo:** Cliente que se conecte a tu server (o a Snapcast oficial) y reproduzca audio sincronizado.

### Módulos en `client/`

```
client/
├── main.rs
├── controller.rs       — conexión TCP, handshake, recepción de mensajes
├── player.rs           — wrapper sobre CPAL (abstrae ALSA/CoreAudio/WASAPI)
├── decoder/
│   ├── mod.rs          — trait Decoder
│   ├── pcm.rs
│   └── opus.rs
└── sync/               — importa crate sync de Fase 2
```

### Plataformas objetivo

- Linux (ALSA / PipeWire via CPAL)
- macOS (CoreAudio via CPAL)
- Windows puede esperar hasta Fase 9

### Criterio de éxito

Tu cliente conectado a **Snapcast oficial** reproduce audio sincronizado con otros clientes Snapcast.  
**Este es el milestone más importante del proyecto** — valida server + cliente + sync + protocolo todos juntos.

---

## Fase 5 — Hardening (2 semanas)

**Objetivo:** Resolver los bugs que aparecen al usar el sistema en serio.

### Trabajo esperado

- Reconnection automática del cliente cuando el server se cae
- Recuperación de USB DAC hotplug (Snapcast tiene este bug — arreglarlo es diferenciador)
- Manejo de underruns sin crash ni click
- Cleanup correcto de recursos en shutdown
- Logging estructurado con niveles `tracing` (debug/info/warn/error)
- Primera pasada de configuración por TOML

### Criterio de éxito

El sistema corre 24h sin intervención en una Raspberry Pi.

---

## Fase 6 — Múltiples streams y grupos (3 semanas)

**Objetivo:** Lo que distingue a Snapcast de un simple "audio over TCP".

### Nuevos conceptos

- **Stream:** fuente de audio (pipe, archivo, proceso externo)
- **Group:** colección de clientes que escuchan el mismo stream
- **Client config:** volumen individual, mute, latency offset (para Bluetooth)

### Módulos nuevos

```
server/
├── group.rs
├── stream_manager.rs
└── streamreader/
    ├── file.rs
    └── process.rs      — ejecutar proceso externo y leer su stdout
```

### Criterio de éxito

Dos streams distintos sonando en dos grupos de clientes simultáneamente.

---

## Fase 7 — API de control + Web UI (4 semanas) — DIFERENCIADOR #1

**Objetivo:** Lo que Snapcast no tiene de fábrica. Mayor ventaja competitiva.

### Backend (`server/control/`)

- `axum` HTTP server en puerto separado (ej. 1780)
- WebSocket para notificaciones push en tiempo real
- REST API moderna:

```
GET    /api/server/status
GET    /api/streams
GET    /api/clients
GET    /api/groups
PATCH  /api/clients/{id}/volume    { "volume": 75, "muted": false }
PATCH  /api/clients/{id}/latency   { "latency": 50 }
PATCH  /api/clients/{id}/group     { "group_id": "room-kitchen" }
PATCH  /api/groups/{id}/stream     { "stream_id": "spotify" }
POST   /api/groups
DELETE /api/groups/{id}

WS /api/events   → push de cambios de estado
```

- Compatibilidad JSON-RPC 2.0 opcional (para herramientas existentes de Snapcast)

### Frontend (`web/`)

Stack: **SvelteKit** (ligero, rápido de iterar) + Vite  
La SPA se sirve embebida en el binario del server (`rust-embed` crate).

**Pantallas mínimas:**

| Pantalla | Funcionalidad |
|---|---|
| Dashboard | Lista de clientes con estado (online/offline, volumen, grupo actual) |
| Grupos | Drag-and-drop para asignar clientes a grupos, selector de stream |
| Streams | Lista de fuentes activas, estado |
| Configuración | Hostname, puertos, latencia default |

### Criterio de éxito

Setup de un grupo nuevo desde el browser, sin tocar config files. Un usuario no técnico puede configurar el sistema en < 5 minutos.

---

## Fase 8 — Discovery automático (1 semana)

**Objetivo:** Cero configuración manual de IPs.

### Implementación

- mDNS publish en server con `mdns-sd`:
  ```
  _snapcast._tcp      → puerto stream (1704)
  _snapcast-http._tcp → puerto HTTP/WS (1780)
  ```
- mDNS browse en cliente al arrancar sin `--server` explícito
- Si hay múltiples servers: elegir por hostname o mostrar lista
- Fallback a IP manual si mDNS falla

### Criterio de éxito

Cliente arranca en una LAN nueva y encuentra el server solo, sin configuración.

---

## Fase 9 — Multiplataforma (4-6 semanas)

**Objetivo:** Cobertura de plataformas para adopción.

### Windows

- CPAL ya lo soporta via WASAPI
- Trabajo principal: instalador (`cargo-wix`), Windows Service wrapper
- Testear latencia en WASAPI exclusive mode vs shared mode

### Android

Opciones (evaluar en esta fase):

| Opción | Pros | Contras |
|---|---|---|
| Cliente Rust + app Kotlin thin | Control total del audio | Build cross-compilation complejo |
| App de control puro + cliente Snapcast | Rápido de implementar | Depende de otro proyecto |
| `oboe-rs` crate | API moderna Android Audio | Crate poco maduro |

### Criterio de éxito

Binarios distribuibles para Linux/macOS/Windows. Android evaluado.

---

## Fase 10 — Diferenciadores avanzados (open-ended)

Priorizar según feedback de usuarios reales.

### Candidatos

| Feature | Impacto | Esfuerzo |
|---|---|---|
| Cross-subnet via relay | Alto — Snapcast no lo tiene | Medio |
| TLS + Auth proper | Medio — seguridad | Bajo |
| Plugin system para fuentes | Alto — Spotify, AirPlay, Tidal | Alto |
| Volume normalization entre tracks | Medio | Bajo (con `loudnorm`) |
| Equalización por sala | Medio | Medio (`fundsp` crate) |
| Sleep timers / alarms | Bajo | Bajo |
| App móvil de control (Flutter/RN) | Alto — UX | Alto |

---

## Estructura del workspace

```
snapcast-rs/                    # nombre tentativo
├── Cargo.toml                  # [workspace]
├── crates/
│   ├── protocol/               # Mensajería + serialización binaria
│   ├── sync/                   # Algoritmo de clock sync (testeable aislado)
│   ├── codec/                  # Traits + implementaciones Opus/FLAC/PCM
│   └── common/                 # Tipos compartidos, config, logging
├── server/                     # Binary: snapcast-server
├── client/                     # Binary: snapcast-client
├── web/                        # Frontend SvelteKit
├── docs/
│   ├── protocol.md             # Especificación del protocolo
│   └── architecture.md
└── tests/
    └── integration/            # Tests e2e contra Snapcast oficial
```

---

## Cronograma honesto

| Fase | Hito | Tiempo acumulado |
|---|---|---|
| 0-2 | Sync funcionando aislado | ~8 semanas |
| 3-4 | MVP interop con Snapcast oficial | ~14 semanas |
| 5-6 | Multi-stream estable, 24h sin caídas | ~19 semanas |
| 7 | Web UI — paridad + ventaja sobre Snapcast | ~23 semanas |
| 8-9 | Discovery + Windows | ~28 semanas |
| 10 | Diferenciadores | open-ended |

> Con tiempo parcial (tardes/fines de semana), multiplicar por 2-3x.

---

## Recomendaciones operativas

1. **Empezar privado, abrir cuando funcione el MVP de Fase 4.** Nada peor que un repo público abandonado en Fase 2.

2. **Tests de integración con Snapcast oficial desde Fase 3.** El binario `snapserver`/`snapclient` corriendo en CI valida interoperabilidad continuamente.

3. **No optimizar antes de Fase 5.** Rust de primer intento puede ser subóptimo — correcto primero, rápido después.

4. **Documentar el protocolo desde el día 1.** Si luego quieres atraer contribuidores, esto es lo primero que mirarán.

5. **La propuesta de valor debe ser clara antes de Fase 7.** "Multiroom audio that just works" — setup en < 5 minutos, sin tocar config files, desde cualquier browser.

6. **No intentar soportar 15 plataformas de audio desde el día 1.** CPAL abstrae esto — pero hay bugs específicos por plataforma. Ir de uno en uno.

---

## Señales de alerta (stop/pivot)

| Señal | Acción |
|---|---|
| Jitter de sync > 100ms después de Fase 2 | Investigar scheduling Tokio vs threads dedicados |
| CPAL no soporta latencia < 20ms en plataforma objetivo | Escribir player nativo para esa plataforma |
| Fase 4 MVP no interopera con Snapcast | Revisitar parser de protocolo |
| 6+ meses sin llegar a Fase 4 | Reducir scope — quizás solo server, usar cliente Snapcast existente |
