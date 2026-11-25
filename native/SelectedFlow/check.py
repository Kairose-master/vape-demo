"""Synthetic native registry/shared-UI HTTP bridge integration; picker/scope are doubles."""
import json
from pathlib import Path
import secrets
import subprocess
import sys
import threading
import uuid
ROOT=Path(__file__).resolve().parents[2];sys.path.insert(0,str(ROOT));sys.path.insert(0,str(ROOT/'native/scripts'))
from build_support import discover_tools,compiler_flags,module_cache
from vape.selected_flow.server import make_server
run=ROOT/'.runtime'/('selected-probe-'+uuid.uuid4().hex);run.mkdir(parents=True)
token=secrets.token_hex(32);server=make_server(token);thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
try:
    config=run/'bridge.json';config.write_text(json.dumps({'port':server.server_port,'token':token}));config.chmod(0o600)
    swift,sdk=discover_tools();names=['Classification/FileRegistry.swift','Classification/PrivateRegistryStore.swift','SelectedFlow/MetadataBridge.swift','SelectedFlow/IntegrationProbe.swift']
    subprocess.run(compiler_flags(swift,sdk,module_cache(ROOT,'selected-flow'))+[str(ROOT/'native'/n) for n in names]+['-o',str(run/'Probe')],check=True)
    subprocess.run([str(run/'Probe'),str(run),str(config)],check=True)
finally:server.shutdown();server.server_close();thread.join(timeout=5)
