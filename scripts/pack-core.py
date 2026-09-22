#!/usr/bin/env python3
"""Package committed core sources with the release's Google Desktop OAuth client."""
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile

root = Path(__file__).resolve().parent.parent
if len(sys.argv) != 2:
    sys.exit('Usage: scripts/pack-core.py OUTPUT.tar.gz')
client_file = os.environ.get('ROUTI_GOOGLE_CLIENT_FILE')
if client_file:
    client = json.loads(Path(client_file).read_text()).get('installed', {})
else:
    client = {'client_id': os.environ.get('ROUTI_GOOGLE_CLIENT_ID'),
              'client_secret': os.environ.get('ROUTI_GOOGLE_CLIENT_SECRET')}
if not all(isinstance(client.get(k), str) and client[k].strip() for k in ('client_id', 'client_secret')):
    sys.exit('Release requires a Google Desktop OAuth client: set ROUTI_GOOGLE_CLIENT_FILE or ROUTI_GOOGLE_CLIENT_ID and ROUTI_GOOGLE_CLIENT_SECRET.')
# Desktop clients are public clients. These values ship in the downloadable core;
# they are not user credentials. Never package the rest of the downloaded JSON.
client = {key: client[key] for key in ('client_id', 'client_secret')}
module = ('// Google Desktop OAuth client supplied by release packaging.\n'
          'export const bundledGoogleClient = ' + json.dumps(client) + '\n').encode()
archive = subprocess.check_output(['git', '-C', str(root), 'archive', '--format=tar',
    '--prefix=routi-core/', 'HEAD', 'daemon', 'protocol', 'containers', 'scripts',
    'package.json', 'pnpm-lock.yaml', 'pnpm-workspace.yaml', 'tsconfig.base.json', 'README.md'])
target = 'routi-core/daemon/src/plugins/google-oauth-client.ts'
output = Path(sys.argv[1])
output.parent.mkdir(parents=True, exist_ok=True)
with tarfile.open(fileobj=io.BytesIO(archive)) as source:
    if target not in source.getnames():
        sys.exit('Commit the OAuth client module before packaging a release.')
    with tarfile.open(output, 'w:gz') as destination:
        for entry in source:
            data = source.extractfile(entry) if entry.isfile() else None
            if entry.name == target:
                entry.size = len(module)
                data = io.BytesIO(module)
            destination.addfile(entry, data)
print('Packaged core with Google Desktop OAuth configuration.')
