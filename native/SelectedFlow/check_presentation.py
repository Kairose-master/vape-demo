"""Compile app without launch/server; test UI states; optional isolated offscreen PNG."""
import argparse
from pathlib import Path
import subprocess
import sys
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--render', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(root / 'native/scripts'))
from build_support import discover_tools, compiler_flags
swift, sdk = discover_tools()
with tempfile.TemporaryDirectory(prefix='vape-presentation-') as scratch:
    temp = Path(scratch)
    flags = compiler_flags(swift, sdk, temp / 'cache')
    parts = ['Classification/FileRegistry.swift', 'Classification/MacFileSelection.swift',
             'Classification/PrivateRegistryStore.swift', 'SelectedFlow/AppleLocalModel.swift',
             'UnifiedLedger/Evidence.swift','SelectedFlow/AppleAudit.swift', 'SelectedFlow/PrivateModelHandoff.swift',
             'SelectedFlow/MetadataBridge.swift', 'SelectedFlow/Presentation.swift', 'SelectedFlow/SelectedFlow.swift']
    subprocess.run(flags + [str(root / 'native' / p) for p in parts] + ['-o', str(temp / 'AppBuildOnly')], check=True)
    print('PASS: full app built only; application not launched', flush=True)
    subprocess.run(flags + [str(root / 'native/SelectedFlow' / p) for p in ['Presentation.swift', 'PresentationCheck.swift']] + ['-o', str(temp / 'PresentationCheck')], check=True)
    command = [str(temp / 'PresentationCheck')]
    if args.render:
        args.render.parent.mkdir(parents=True, exist_ok=True)
        command.append(str(args.render.resolve()))
    subprocess.run(command, check=True)
