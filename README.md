# LightBar Direct

Controla una barra de luz Xiaomi (`xiaomi.light.bar2`) desde la barra de menús de macOS,
por Wi-Fi local, sin pasar por la app Xiaomi Home ni por internet.

Encendido, brillo (1 a 100 %) y temperatura de color (2700 a 6500 K). La app habla el
protocolo local miIO/MIoT de Xiaomi directamente con la barra, cifrado con la llave
propia del dispositivo.

## Requisitos

- macOS 13 o posterior, con Xcode Command Line Tools (`xcode-select --install`).
- La barra vinculada una vez en **Xiaomi Home para Mac**. De su base de datos local sale la
  llave del dispositivo; después puedes cerrar Xiaomi Home.
- La Mac y la barra en la misma red Wi-Fi.

## Instalación

```bash
./build.sh                      # compila ~/Applications/LightBar Direct.app
python3 import-device.py        # copia la llave de la barra a ~/Library/Application Support/LightBarDirect/device.json
open "$HOME/Applications/LightBar Direct.app"
```

La primera vez macOS pide permiso de **red local**; acéptalo. Para que arranque sola,
agrégala en Ajustes del Sistema > General > Ítems de inicio.

`import-device.py` solo lee la base de Xiaomi Home, nunca muestra la llave y se niega a
sobrescribir un `device.json` existente. Si la barra se restablece o se vuelve a vincular, borra
ese archivo y vuelve a importar.

## Uso

En el menú: botón de encendido, deslizadores de brillo y temperatura, y el interruptor
**Seguir la pantalla de la Mac**: con monitores externos conectados, apaga la barra al
bloquear o dormir la pantalla y la vuelve a encender al regresar. Sin monitores no hace nada,
pensado para escritorios donde los monitores se comparten con otra computadora.

También por línea de comandos:

```bash
APP="$HOME/Applications/LightBar Direct.app/Contents/MacOS/LightBarDirect"
"$APP" --status
"$APP" --power on
"$APP" --brightness 60
"$APP" --temperature 4000
"$APP" --get 2 4          # lee cualquier propiedad MIoT (siid, piid)
"$APP" --self-test        # cambia y restaura brillo, temperatura y encendido
```

## Cómo funciona

1. Saludo UDP (puerto 54321) a la barra; responde con su identificador y su reloj.
2. La orden va en JSON (`set_properties` / `get_properties`), cifrada con AES-128-CBC usando
   una llave derivada del token del dispositivo, firmada con MD5.
3. La app vuelve a leer el estado y solo muestra lo que la barra confirma.

Propiedades usadas (servicio 2): `1` encendido, `2` brillo, `3` temperatura. La especificación
completa del modelo está en [miot-spec.org](https://miot-spec.org/miot-spec-v2/instance?type=urn:miot-spec-v2:device:light:0000A001:xiaomi-bar2:1:0000C802)
e incluye modos, apagado con retardo, modo enfoque y la configuración del doble clic de la perilla.

## Límites

- Solo `xiaomi.light.bar2`. Otro modelo necesita sus propios `siid`/`piid` (ver su spec).
- Solo macOS. El protocolo (`LightBar.swift`) es portable; en Windows o Linux el camino corto es
  [python-miio](https://github.com/rytilahti/python-miio) con el mismo token, por ejemplo
  `miiocli device --ip IP --token TOKEN raw_command set_properties '[{"did":"ID","siid":2,"piid":2,"value":60}]'`.
  En Windows el token se obtiene de un respaldo de Xiaomi Home o con un extractor de tokens de la nube de Xiaomi.
- UDP sin garantía: la app reintenta el saludo, no cada orden.

## Archivos

| Archivo | Qué es |
|---|---|
| `LightBar.swift` | Cliente del protocolo local: cifrado, saludo, lectura y escritura de propiedades |
| `main.swift` | Línea de comandos y app de barra de menús |
| `build.sh` | Compila, genera `Info.plist` y firma la app |
| `import-device.py` | Importa la llave de la barra desde Xiaomi Home para Mac |

Licencia MIT.
