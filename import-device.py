#!/usr/bin/env python3
"""Import only xiaomi.light.bar2 from the authorized local Xiaomi Home database.
Never print credentials or store account credentials. Refuse to replace a config.
"""
from pathlib import Path
import json, os, re, sqlite3, subprocess, sys

root = Path.home() / 'Library/Containers/com.xiaomi.mihome/Data/Documents'
matches = []
for db in root.glob('*_mihome.sqlite'):
    c = sqlite3.connect(db.as_uri()+'?mode=ro', uri=True)
    try:
        matches.extend(c.execute("SELECT ZLOCALIP,ZDID,ZTOKEN,ZMODEL FROM ZDEVICE WHERE ZMODEL='xiaomi.light.bar2'").fetchall())
    finally:
        c.close()
if len(matches) != 1:
    sys.exit('Se necesita exactamente una barra registrada en Xiaomi Home.')
host, did, encrypted, model = matches[0]
if len(encrypted) == 96:
    result = subprocess.run(['/usr/bin/openssl','enc','-d','-aes-128-ecb','-nosalt','-K','0'*32],
                            input=bytes.fromhex(encrypted), capture_output=True, check=True)
    token = result.stdout.decode('ascii')
else:
    token = encrypted
if not re.fullmatch(r'[0-9a-fA-F]{32}',token):
    sys.exit('El formato de la credencial local no es compatible.')
destination = Path.home()/'Library/Application Support/LightBarDirect'
destination.mkdir(mode=0o700,parents=True,exist_ok=True)
destination.chmod(0o700)
path = destination/'device.json'
fd = os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
with os.fdopen(fd,'w') as f:
    json.dump({'host':host,'did':str(did),'token':token,'model':model},f)
print('Credencial de la barra importada localmente. Directorio 700, archivo 600. Sin mostrar secretos.')
