"""Explicit native CLI -> independent verifier -> local Besu roots. No downloads; no existing node.

python3 -m vape.ledger.native_exercise --tools-dir <verified project-local .local>
"""
import argparse
from dataclasses import replace
import hashlib
import json
import os
from pathlib import Path
import selectors
import subprocess
import sys
import uuid
from vape.contracts import canonical
from vape.ledger.native_evidence import NativeEvidenceInput, sha
from vape.ledger.local_exercise import run as run_chain


def put(path,value):
    with path.open('x') as stream:json.dump(value,stream,indent=2)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tools-dir',required=True,type=Path)
    args=parser.parse_args()
    root=Path(__file__).resolve().parents[2]
    tools_dir=args.tools_dir.resolve()
    # Only already-provisioned tooling inside the same VAPE workspace is accepted.
    if root.parent not in tools_dir.parents or tools_dir.name!='.local':
        parser.error('Use existing project-local verified .local tools in this workspace')
    runtime=root/'.runtime'/('native-anchor-'+uuid.uuid4().hex);runtime.mkdir(parents=True)
    sys.path.insert(0,str(root/'native/scripts'))
    from build_support import compiler_flags,discover_tools,module_cache
    swift,sdk=discover_tools(); flags=compiler_flags(swift,sdk,module_cache(root,'native-anchor'))
    producer=runtime/'NativeExecutionCLI';verifier=runtime/'NativeVerifier'
    common=['Core.swift','SignedAudit.swift']
    source_names=common+['SignedWorkflow.swift','ExecutionCLI.swift','Verifier.swift']
    source_hash=sha(canonical({name:sha((root/'native/Sources'/name).read_bytes()) for name in source_names}))
    subprocess.run(flags+[str(root/'native/Sources'/name) for name in common+['SignedWorkflow.swift','ExecutionCLI.swift']]+['-o',str(producer)],check=True,capture_output=True)
    subprocess.run(flags+[str(root/'native/Sources'/name) for name in common+['Verifier.swift']]+['-o',str(verifier)],check=True,capture_output=True)
    for binary in [producer,verifier]:
        subprocess.run(['codesign','--force','--sign','-','--timestamp=none',str(binary)],check=True,capture_output=True)
        subprocess.run(['codesign','--verify','--strict',str(binary)],check=True,capture_output=True)
    producer_hash=sha(producer.read_bytes()); verifier_hash=sha(verifier.read_bytes())
    run_id=str(uuid.uuid4()).upper();folder=runtime/'execution';pins=runtime/'separate-pins';pins.mkdir()
    policy_path=root/'native/Resources/policy.json';policy_hash=sha(canonical(json.loads(policy_path.read_text())))
    process=subprocess.Popen([str(producer),str(folder),run_id,str(policy_path)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    try:
        with selectors.DefaultSelector() as selection:
            selection.register(process.stdout,selectors.EVENT_READ)
            if not selection.select(timeout=15):raise TimeoutError('Native key announcement missing; no execution authorized')
            ready=json.loads(process.stdout.readline())
        evidence=folder/'SignedEvidence'
        key=(evidence/'TrustExport/public-key.raw').read_bytes()
        if (ready['status']!='KEY_READY' or ready['keyID']!=sha(key) or ready['runID']!=run_id
                or ready['producerPID']!=str(process.pid) or ready['policyHash']!=policy_hash
                or sha(producer.read_bytes())!=producer_hash):
            raise ValueError('Native producer origin mismatch')
        (pins/'public-key.raw').write_bytes(key)
        put(pins/'origin.json',{'runID':run_id,'producerPID':process.pid,'producerBinarySHA256':producer_hash,
            'verifierBinarySHA256':verifier_hash,'sourceSHA256':source_hash,'keyID':sha(key),'policyHash':policy_hash,
            'acquiredBeforeExecution':True,'trust':'local operator/build provenance; not external attestation'})
        stdout,stderr=process.communicate('PINNED\n',timeout=20)
        if process.returncode or json.loads(stdout)['status']!='EXECUTED':raise ValueError('Native CLI execution failed; no anchor')
    finally:
        if process.poll() is None:process.terminate();process.wait(timeout=5)
    package=evidence/'run-package.json'
    (pins/'trust-set.json').write_bytes((evidence/'TrustExport/trust-set.json').read_bytes())
    for p in pins.iterdir():p.chmod(0o444)
    inputs=NativeEvidenceInput(package,pins/'public-key.raw',pins/'trust-set.json',verifier,verifier_hash,sha(key),run_id,
                              process.pid,policy_hash,sha(package.read_bytes()),sha((pins/'trust-set.json').read_bytes()))
    roots=inputs.verify_roots()
    fixture=json.loads((folder/'fixture.json').read_text())
    for resource in fixture['resources']:
        data=(folder/resource['fileName']).read_bytes()
        if resource['level']=='L2':assert sha(data)==resource['initialSHA256']
        else:assert data.count(b'[SYNTHETIC VAPE L3 WRITE')==1
    print('Native actual L2 unchanged / L3 one append; independent verifier passed. '+str(runtime),flush=True)
    # Real verifier/provenance failures must stop before any chain/tool setup.
    original=json.loads(package.read_text()); failures=[]
    for name in ['missing-event','signature','policy','missing-file','wrong-producer','wrong-key-pin']:
        variant=inputs
        if name in ('missing-event','signature','policy'):
            obj=json.loads(json.dumps(original))
            if name=='missing-event':obj['bundles'].pop()
            elif name=='signature':obj['bundles'][-1]['leaf']['signature']='AA=='
            else:obj['bundles'][0]['policy']['version']=999
            path=runtime/(name+'.json');put(path,obj)
            variant=replace(inputs,package=path,expected_package_hash=sha(path.read_bytes()))
        elif name=='missing-file':variant=replace(inputs,package=runtime/'absent.json')
        elif name=='wrong-producer':variant=replace(inputs,expected_producer_pid=process.pid+1)
        else:variant=replace(inputs,expected_key_id='0'*64)
        try:run_chain(tools_dir=tools_dir,native_input=variant)
        except (ValueError,FileNotFoundError):failures.append(name)
        else:raise AssertionError('Invalid native evidence reached chain: '+name)
    assert inputs.verify_roots()==roots
    chain=run_chain(tools_dir=tools_dir,native_input=inputs)
    assert chain['status']=='passed' and chain['nodeStopped'] and chain['record']['policyRoot']==roots['policyRoot'] and chain['record']['executionRoot']==roots['executionRoot']
    report={'status':'PASS','mode':'explicit CLI anchoring, not automatic app recording','nativeScope':'unsandboxed native CLI actual file operations; no new OS sandbox claim',
            'nativeRoots':roots,'nativePreAnchorRejections':failures,'L2Unchanged':True,'L3Appends':1,
            'chainRuntime':chain['runtime'],'chainId':chain['chainId'],'rootTransaction':chain['rootTransaction'],
            'independentRead':chain['independentRead'],'nodeStopped':chain['nodeStopped'],
            'missingRecordRejected':chain['missingRecordRejected'],'rootMismatchRejected':chain['rootMismatchRejected'],
            'unauthorizedRejected':chain['unauthorizedRejected'],'singleValidator':True,'externalConnections':False}
    put(runtime/'integration-result.json',report)
    print(json.dumps(report,indent=2),flush=True)


if __name__=='__main__':main()
