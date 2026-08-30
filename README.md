# wireplumber-macos-policy

[![CI](https://github.com/gach87/wireplumber-macos-policy/actions/workflows/ci.yml/badge.svg)](https://github.com/gach87/wireplumber-macos-policy/actions/workflows/ci.yml)

Política de selección de dispositivos de audio al estilo de macOS, como
componente nativo de WirePlumber 0.5+.

Conectas unos auriculares y el audio se va a ellos. Eliges otra salida a mano y
se respeta. Los desconectas y vuelve a lo que estabas usando. Las tres cosas a
la vez.

## El problema

WirePlumber decide la salida por defecto puntuando cada nodo con tres hooks. El
mayor bono, **+30000**, va al último dispositivo que elegiste a mano. Eso hace
que estas dos cosas sean **mutuamente excluyentes**:

- Que el Bluetooth gane al conectarse → necesita prioridad > 30000
- Que puedas elegir otra salida a mano estando el BT conectado → necesita < 30000

No es un ajuste que falte: las dos situaciones —"elegí las cornetas antes de
conectar" y "las elegí después"— producen **exactamente el mismo estado**, y
WirePlumber no tiene el concepto de "recién llegado" para distinguirlas.

## El modelo de macOS

macOS sí lo resuelve, y no con prioridades. Leyendo
`/Library/Preferences/Audio/com.apple.audio.SystemSettings.plist` en un Mac
mini aparece una clave `preferred devices` con una lista **ordenada** por
dirección, más un `global.arrival` `{seed,time}` por dispositivo y un contador
global de llegadas:

```
preferred devices / output          global.arrival por dispositivo
  0. BEHRINGER UMC204HD               seed=39
  1. BEHRINGER UMC204HD (variante)    seed global = 74
  2. BuiltInSpeakerDevice
```

La regla que reproduce su comportamiento:

> **Al llegar, un dispositivo pasa al frente de la lista.
> Gana siempre el primero de la lista que esté presente.**

Una lista ordenada expresa las tres cosas sin contradicción, porque tanto una
llegada como una elección manual son "mover al frente", y la vuelta tras una
desconexión es simplemente el siguiente presente.

## Qué hace

- **Llegada → al frente.** Conectas algo y gana, sin configurar nada. Funciona
  con dispositivos que nunca ha visto.
- **Elección manual → al frente.** Se respeta y se recuerda.
- **Al desconectar, cae al siguiente presente**, en orden y predecible — no a
  lo que dicte el puntaje del historial.
- **Prefiere el mejor perfil Bluetooth** disponible (p. ej. SBC-XQ sobre SBC),
  incluso cuando WirePlumber ya guardó uno degradado.
- **Deshace el muteo protector cuando el Bluetooth vuelve.** El ajuste
  `mute-on-bluetooth-playback-removed` mutea todo al irse el BT y no desmutea
  nunca; si el BT está de vuelta, esa condición terminó.

Corre **dentro del proceso de WirePlumber**: cero procesos extra, cero polling.

## Instalación

Descarga el `.zip` o `.tar.gz` de la
[última release](https://github.com/gach87/wireplumber-macos-policy/releases),
descomprime y:

```sh
./install.sh
```

O desde el código:

```sh
git clone https://github.com/gach87/wireplumber-macos-policy
cd wireplumber-macos-policy
./install.sh
```

Y `./uninstall.sh` para revertir. El instalador comprueba que WirePlumber
arranque y se deshace solo si no.

Requiere WirePlumber 0.5+.

## Configuración

La lista de preferidos **se construye sola** con el uso. Vive en
`~/.local/state/wireplumber/audio-preferred-devices`:

```
sink.0=bluez_output.XX_XX_XX_XX_XX_XX.1
sink.1=alsa_output.usb-...
sink.2=alsa_output.pci-...
```

Se puede editar a mano para fijar un orden inicial. Los nombres son `node.name`
(`wpctl inspect <id>`).

### Dispositivos que no deben robar el foco

Algunos nodos aparecen y desaparecen solos —sinks de red, monitores virtuales—
y eso no es una acción del usuario. En `scripts/preferred-devices.lua`:

```lua
NO_ARRIVAL = { "to%-desktop%-" }   -- patrones Lua contra node.name
```

Siguen siendo elegibles a mano y sirven de respaldo; sólo pierden el
"gana el que llega".

### Perfil Bluetooth preferido

En `config/91-bt-profile.conf`, usando la sección declarativa nativa
`device.profile.priority.rules`:

```
device.profile.priority.rules = [
  {
    matches = [ { device.name = "~bluez_card.*" } ]
    actions = { update-props = { priorities = [ "a2dp-sink-sbc_xq", "a2dp-sink" ] } }
  }
]
```

Para ver qué ofrece tu dispositivo: `pw-cli enum-params <device-id> EnumProfile`.

## Limitación conocida

**Reiniciar WirePlumber con auriculares Bluetooth conectados pierde el registro
del endpoint A2DP**, y el dispositivo se queda ofreciendo sólo HFP (mono, 8 kHz).
Se arregla reconectando el dispositivo.

Esto **no lo puede curar el componente**: requiere hablar con BlueZ por D-Bus y
el sandbox Lua de WirePlumber no lo expone (la librería no exporta ningún
símbolo `wp_dbus`). Afecta sobre todo a reinicios manuales, no al arranque
normal, donde el BT se conecta después de que WirePlumber ya está en pie.

## Notas de implementación

Cosas que costaron un fallo real y que no están documentadas en ningún sitio
obvio:

- **Un `requires` con un nombre de feature inexistente no se ignora: impide que
  WirePlumber arranque**, y te quedas sin audio. Verifica contra
  `grep "provides =" /usr/share/wireplumber/wireplumber.conf`.
- **`available-nodes` trae todos los nodos**, no sólo los de la dirección del
  evento. Hay que filtrar por `media.class` a mano.
- **Hace falta `before = { "default-nodes/apply-default-node" }`.** Ese hook
  declara el mismo `after` que el tuyo, así que el orden queda indefinido y tu
  decisión puede llegar cuando ya se aplicó la suya. El síntoma engaña: el log
  dice que elegiste bien y `wpctl` muestra otra cosa.
- **La elección manual sólo cuenta cuando cambia.** El hook nativo la
  re-propone con 30000 en cada evento; sin recordar la última vista, se
  re-promueve al frente y pisa la llegada de un dispositivo nuevo.
- **Hay que escribir `default.configured` con el ganador.** Si no, elegir a mano
  el dispositivo que ya figuraba configurado no cambia el metadata, no emite
  evento, y el clic del usuario no hace nada.
- El sandbox Lua **no expone `io` ni `os`**; para persistir se usa `State`.
- Los `log:info` no se ven al nivel por defecto. Para depurar, `log:warning`.

## Desarrollo

```
src/                       el componente y su configuración
  preferred-devices.lua
  config/*.conf
test/
  fake-wireplumber.lua     doble configurable de la API de WirePlumber
  test-preferred-devices.lua
  check-configs.sh
```

Las pruebas ejecutan la **lógica real del componente sin WirePlumber
corriendo**. `fake-wireplumber.lua` implementa los globales que WirePlumber
inyecta en el sandbox Lua (`Log`, `State`, `Json`, `SimpleEventHook`...) con
valores que cada prueba configura, captura los hooks al registrarse y los
invoca con eventos falsos:

```lua
local wp = Fake.new { state = { ["sink.0"] = "bocinas" } }
local c  = wp:load ("src/preferred-devices.lua")
local ev = wp:select_event { kind = "audio.sink", nodes = {...} }
c:run ("preferred-devices/select", ev)
assert (ev:selected () == "bt")
```

```sh
lua5.3 test/test-preferred-devices.lua   # o lua5.4
./test/check-configs.sh
```

Cada prueba se verifica rompiendo el arreglo que debería proteger. Las cinco
mutaciones probadas —quitar el filtro por `media.class`, la guarda de llegada
masiva, la exclusión `NO_ARRIVAL`, la guarda de llamada en curso y el filtro de
dirección de ruta— son detectadas.

## Licencia

MIT, igual que WirePlumber.
