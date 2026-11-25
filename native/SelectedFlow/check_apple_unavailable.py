"""Compile the no-FoundationModels fallback at macOS 13; never invokes a model."""
from pathlib import Path
import subprocess,sys,uuid
ROOT=Path(__file__).resolve().parents[2];sys.path.insert(0,str(ROOT/'native/scripts'))
from build_support import discover_tools,compiler_flags,module_cache
run=ROOT/'.runtime'/('apple-unavailable-'+uuid.uuid4().hex);run.mkdir(parents=True)
source=run/'Unavailable.swift';source.write_text('import Foundation\n@main enum Unavailable {static func main(){precondition(!AppleLocalModel.available());print("PASS unsupported-framework gate: unavailable, no inference")}}\n')
swift,sdk=discover_tools();names=['Classification/FileRegistry.swift','SelectedFlow/PrivateModelHandoff.swift','SelectedFlow/AppleLocalModel.swift']
subprocess.run(compiler_flags(swift,sdk,module_cache(ROOT,'selected-flow'))+['-D','VAPE_NO_FOUNDATION_MODELS']+[str(ROOT/'native'/n) for n in names]+[str(source),'-o',str(run/'Unavailable')],check=True)
subprocess.run([str(run/'Unavailable')],check=True)
