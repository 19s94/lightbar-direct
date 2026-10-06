#!/bin/zsh
set -eu
PROJECT_DIR="${0:A:h}"
APP_DIR="$HOME/Applications/LightBar Direct.app"
mkdir -p "$APP_DIR/Contents/MacOS"
/usr/bin/swiftc -swift-version 5 -O "$PROJECT_DIR/LightBar.swift" "$PROJECT_DIR/main.swift" -o "$APP_DIR/Contents/MacOS/LightBarDirect" -framework AppKit
/usr/bin/python3 - "$APP_DIR" <<'PY'
import plistlib,sys
from pathlib import Path
p=Path(sys.argv[1])/'Contents/Info.plist'
metadata={'CFBundleIdentifier':'local.lightbar-direct','CFBundleName':'LightBar Direct',
 'CFBundleDisplayName':'LightBar Direct','CFBundleExecutable':'LightBarDirect','CFBundlePackageType':'APPL',
 'CFBundleShortVersionString':'1.0','CFBundleVersion':'1','LSUIElement':True,'LSMinimumSystemVersion':'13.0',
 'NSLocalNetworkUsageDescription':'Controlar tu lámpara Xiaomi directamente por Wi-Fi local, sin enviar órdenes a Internet.'}
with p.open('wb') as f: plistlib.dump(metadata,f)
PY
/usr/bin/codesign --force --sign - "$APP_DIR"
echo "Compilada: $APP_DIR"
