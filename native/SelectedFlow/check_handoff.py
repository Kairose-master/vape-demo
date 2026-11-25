"""Native private handoff tests; no HTTP plaintext endpoint or external connection."""
from pathlib import Path
import subprocess
import sys
import uuid
ROOT=Path(__file__).resolve().parents[2];sys.path.insert(0,str(ROOT/'native/scripts'))
from build_support import discover_tools,compiler_flags,module_cache
run=ROOT/'.runtime'/('handoff-'+uuid.uuid4().hex);run.mkdir(parents=True)
swift,sdk=discover_tools()
names=['Classification/FileRegistry.swift','SelectedFlow/PrivateModelHandoff.swift','SelectedFlow/HandoffTests.swift']
subprocess.run(compiler_flags(swift,sdk,module_cache(ROOT,'handoff'))+[str(ROOT/'native'/n) for n in names]+['-o',str(run/'Tests')],check=True)
subprocess.run([str(run/'Tests'),str(run)],check=True,timeout=30)
