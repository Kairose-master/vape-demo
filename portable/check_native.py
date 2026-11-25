"""Offline cross-build checks; never opens an app, reads a key, or invokes a model."""
from pathlib import Path
import json
import platform
import subprocess
import sys
import tempfile

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'native/scripts'))
from build_support import discover_tools, compiler_flags
swift,sdk=discover_tools()
parts=['Classification/FileRegistry.swift','Classification/MacFileSelection.swift','Classification/PrivateRegistryStore.swift',
       'SelectedFlow/AppleLocalModel.swift','UnifiedLedger/Evidence.swift','SelectedFlow/AppleAudit.swift','SelectedFlow/PrivateModelHandoff.swift',
       'SelectedFlow/MetadataBridge.swift','SelectedFlow/Presentation.swift','SelectedFlow/SelectedFlow.swift']
with tempfile.TemporaryDirectory(prefix='vape-cross-build-') as scratch:
    run=Path(scratch);report={}
    for arch in ('arm64','x86_64'):
        flags=compiler_flags(swift,sdk,run/('cache-'+arch),arch)
        binary=run/arch
        subprocess.run(flags+[str(ROOT/'native'/p) for p in parts]+['-o',str(binary)],check=True)
        actual=subprocess.check_output(['xcrun','lipo','-archs',str(binary)],text=True).strip()
        if actual != arch: raise RuntimeError('Wrong architecture')
        loads=subprocess.check_output(['xcrun','otool','-l',str(binary)],text=True)
        if 'minos 13.0' not in loads: raise RuntimeError('Unexpected deployment target')
        report[arch]={'build':'passed','minimumOS':'13.0','physicalExecution':'not tested'}
    universal=run/'universal2'
    subprocess.run(['xcrun','lipo','-create',str(run/'arm64'),str(run/'x86_64'),'-output',str(universal)],check=True)
    arches=set(subprocess.check_output(['xcrun','lipo','-archs',str(universal)],text=True).split())
    if arches != {'arm64','x86_64'}: raise RuntimeError('Universal2 missing architecture')
    gate=run/'Unavailable.swift'
    gate.write_text('import Foundation\n@main enum Gate {static func main(){precondition(!AppleLocalModel.available());print("PASS unsupported FoundationModels: unavailable, no inference")}}\n')
    flags=compiler_flags(swift,sdk,run/('cache-'+platform.machine()))
    subprocess.run(flags+['-D','VAPE_NO_FOUNDATION_MODELS']+[str(ROOT/'native'/p) for p in ['Classification/FileRegistry.swift','SelectedFlow/PrivateModelHandoff.swift','SelectedFlow/AppleLocalModel.swift']]+[str(gate),'-o',str(run/'Gate')],check=True)
    subprocess.run([str(run/'Gate')],check=True)
    print(json.dumps({'architectures':report,'universal2':'passed','modelCalls':0,'appLaunches':0},indent=2))
