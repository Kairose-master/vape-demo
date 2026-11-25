"""Synthetic framework errors only: no model session or external request."""
from pathlib import Path
import subprocess,sys,uuid
ROOT=Path(__file__).resolve().parents[2];sys.path.insert(0,str(ROOT/'native/scripts'))
from build_support import discover_tools,compiler_flags,module_cache
run=ROOT/'.runtime'/('apple-diagnostics-'+uuid.uuid4().hex);run.mkdir(parents=True)
source=run/'Tests.swift'
source.write_text('''import Foundation
import FoundationModels
@main enum Tests {static func main(){if #available(macOS 26.0,*) {
 let c=LanguageModelSession.GenerationError.Context(debugDescription:"SYNTHETIC PRIVATE TEXT MUST NOT ESCAPE")
 let cases:[(LanguageModelSession.GenerationError,HandoffError)]=[(.guardrailViolation(c),.appleGuardrail),(.unsupportedLanguageOrLocale(c),.appleUnsupportedLanguage),(.assetsUnavailable(c),.appleAssetsUnavailable),(.exceededContextWindowSize(c),.appleContextLimit),(.unsupportedGuide(c),.appleUnsupportedGuide),(.decodingFailure(c),.appleDecoding),(.rateLimited(c),.appleRateLimited),(.concurrentRequests(c),.appleConcurrentRequest)]
 for (error,expected) in cases {precondition(AppleLocalModel.classify(error)==expected)}
 precondition(AppleLocalModel.classify(NSError(domain:"SYNTHETIC PRIVATE",code:1)) == .appleFrameworkError)
 let box=AppleResponseBox();box.fail(.appleGuardrail);precondition(box.read()==nil && box.failure()==.appleGuardrail)
 print("PASS 10 redacted Apple diagnostic checks; model calls=0")
}}}
'''.replace('()==.appleGuardrail','() == .appleGuardrail'))
swift,sdk=discover_tools();names=['Classification/FileRegistry.swift','SelectedFlow/PrivateModelHandoff.swift','SelectedFlow/AppleLocalModel.swift']
subprocess.run(compiler_flags(swift,sdk,module_cache(ROOT,'selected-flow'))+[str(ROOT/'native'/n) for n in names]+[str(source),'-o',str(run/'Tests')],check=True)
subprocess.run([str(run/'Tests')],check=True)
