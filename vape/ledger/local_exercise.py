"""Opt-in real, isolated Besu exercise. Never downloads or uses an existing node.

Run: python3 -m vape.ledger.local_exercise
Requires checksum-verified pinned tools in ledger/.local. Always stops its own
child process and leaves only ignored local runtime evidence. No private key output.
"""
import hashlib
import copy
import json
import os
import socket
import shlex
import subprocess
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

from vape.contracts import canonical, digest
from vape.ledger.besu import CHAIN_ID, provision
from vape.ledger.besu_registry import RegistryRPC, RegistryReader, RegistryWriter
from vape.ledger.ethereum_encoding import encode_call, keccak256
from vape.ledger.local_signer import DisposableSigner
from vape.ledger.service import AnchorService, make_record


def besu_jvm_options(runtime):
    # The vetted Besu launcher evaluates BESU_OPTS as shell words. Quote each
    # complete JVM property so isolated paths with spaces/apostrophes stay intact.
    runtime = Path(runtime)
    return ' '.join(shlex.quote(value) for value in [
        '-Xmx512m', '-Djava.io.tmpdir='+str(runtime/'tmp'), '-Duser.home='+str(runtime/'home')])


def _receipt(rpc, tx_hash, timeout=20):
    deadline = time.monotonic()+timeout
    while time.monotonic() < deadline:
        value = rpc.call('eth_getTransactionReceipt', [tx_hash])
        if value is not None:
            return value
        time.sleep(0.2)
    raise TimeoutError('Receipt missing; no automatic resubmission')


def run(tools_dir=None, native_input=None):
    base = Path(__file__).resolve().parent
    # Gate native evidence BEFORE tool execution, node creation or any transaction.
    native_roots = native_input.verify_roots() if native_input is not None else None
    local = Path(tools_dir).resolve() if tools_dir is not None else base/'.local'
    pins = {
        'besu-26.11.1.tar.gz':'28336f46c44d6660e203546b51b8c81eea0cd3499ceff0d3e716f6b029e5e4f7',
        'OpenJDK25U-jdk_aarch64_mac_hotspot_25.0.5.1_2.tar.gz':'248353ea41be39d5d2c1c67c7ce0ae4d1668966aacd0c5308464bc1be42f677b',
        'soljson-0.8.28.js':'72ef580a6ec5943130028e5294313f24e9435520acc89f8c9dbfd0139d9ae146'}
    for name, expected in pins.items():
        if hashlib.sha256((local/name).read_bytes()).hexdigest() != expected:
            raise ValueError('Local tool archive integrity mismatch: '+name)
    jdk = local/'jdk-25.0.5.1+2/Contents/Home'
    besu = local/'besu-26.11.1/bin/besu'
    bc = local/'besu-26.11.1/lib/bcprov-jdk18on-1.86.jar'
    classes = base/'.runtime'/('signer-build-'+uuid.uuid4().hex); classes.mkdir(parents=True)
    subprocess.run([str(jdk/'bin/javac'),'-cp',str(bc),'-d',str(classes),str(base/'DemoSigner.java')], check=True, capture_output=True)
    classpath = str(classes)+os.pathsep+str(bc)
    signer = DisposableSigner(jdk/'bin/java', classpath)
    outsider = DisposableSigner(jdk/'bin/java', classpath)
    source = (base/'RootRegistry.sol').read_text()
    request = {'language':'Solidity','sources':{'RootRegistry.sol':{'content':source}},'settings':{
        'evmVersion':'berlin','optimizer':{'enabled':True,'runs':200},
        'outputSelection':{'*':{'*':['abi','evm.bytecode.object','evm.deployedBytecode.object',
                                     'evm.deployedBytecode.immutableReferences','evm.methodIdentifiers']}}}}
    js = "const fs=require('fs');const c=require(process.argv[1]);process.stdout.write(c.cwrap('solidity_compile','string',['string','number','number'])(fs.readFileSync(0,'utf8'),0,0));"
    compiled = subprocess.run(['node','-e',js,str(local/'soljson-0.8.28.js')],input=json.dumps(request),capture_output=True,text=True,check=True,timeout=60)
    artifact = json.loads(compiled.stdout)
    if any(x['severity']=='error' for x in artifact.get('errors',[])):
        raise ValueError('Solidity compilation failed')
    artifact = artifact['contracts']['RootRegistry.sol']['RootRegistry']
    for signature, selector in artifact['evm']['methodIdentifiers'].items():
        if encode_call(signature,[])[2:10] != selector:
            raise ValueError('Compiler/ABI selector mismatch')
    with socket.socket() as probe:
        probe.bind(('127.0.0.1',0)); port=probe.getsockname()[1]
    parent = base/'.runtime'; parent.mkdir(exist_ok=True)
    runtime = parent/('exercise-'+uuid.uuid4().hex)
    environment=os.environ.copy(); environment['JAVA_HOME']=str(jdk)
    configured = provision(runtime,signer.address,str(besu),port,process_env=environment)
    (runtime/'tmp').mkdir(); (runtime/'home').mkdir()
    environment['BESU_OPTS']=besu_jvm_options(runtime)
    (runtime/'compiler-artifact.json').write_text(json.dumps(artifact))
    result = {'status':'started', 'chainId':CHAIN_ID,'runtime':str(runtime), 'rpcPort':port,
              'sourceSha256':hashlib.sha256(source.encode()).hexdigest(), 'toolSha256':pins,
              'singleValidator':True,'productionNetwork':False,'publicNetworkAccess':False}
    print('New runtime: '+str(runtime),flush=True)
    process=None
    with (runtime/'besu.log').open('w') as log:
        try:
            process=subprocess.Popen(configured['command'],cwd=str(runtime),env=environment,stdout=log,stderr=subprocess.STDOUT)
            rpc=RegistryRPC('http://127.0.0.1:'+str(port))
            deadline=time.monotonic()+45
            while True:
                if process.poll() is not None:
                    raise RuntimeError('New Besu process exited; inspect its own log')
                try:
                    if rpc.call('eth_chainId',[])==hex(CHAIN_ID): break
                except (OSError, ValueError): pass
                if time.monotonic()>deadline: raise TimeoutError('New node did not become ready')
                time.sleep(0.3)
            genesis=rpc.call('eth_getBlockByNumber',['0x0',False])['hash']
            validator=next((runtime/'generated/keys').iterdir()).name
            if not rpc.preflight(genesis,validator,signer.address)['valid']:
                raise ValueError('New private node identity/permission check failed')
            namespace='synthetic-demo'
            scope=bytes.fromhex(digest([str(CHAIN_ID),signer.address,namespace]))
            deployment='0x'+artifact['evm']['bytecode']['object']+signer.address[2:].rjust(64,'0')+scope.hex()
            tx={'from':signer.address,'to':'','chainId':hex(CHAIN_ID),'nonce':'0x0','gasPrice':hex(1000000000),
                'gas':hex(4000000),'value':'0x0','data':deployment}
            raw=signer(tx)
            deploy_hash=rpc.call('eth_sendRawTransaction',[raw])
            result['deploymentTransaction']=deploy_hash
            if deploy_hash!='0x'+keccak256(bytes.fromhex(raw[2:])).hex(): raise ValueError('Deployment hash mismatch')
            receipt=_receipt(rpc,deploy_hash)
            if receipt['status']!='0x1': raise ValueError('Deployment reverted')
            contract=receipt['contractAddress']
            code=bytes.fromhex(rpc.call('eth_getCode',[contract,'latest'])[2:])
            masked=bytearray(code)
            for refs in artifact['evm']['deployedBytecode']['immutableReferences'].values():
                for item in refs:
                    masked[item['start']:item['start']+item['length']]=b'\x00'*item['length']
            if masked.hex()!=artifact['evm']['deployedBytecode']['object']:
                raise ValueError('Deployed bytecode differs from compiler output')
            for method,expected in [('writer()',signer.address[2:].rjust(64,'0')),('scope()',scope.hex()),('chain()',format(CHAIN_ID,'064x'))]:
                if rpc.call('eth_call',[{'to':contract,'data':encode_call(method,[])},'latest'])!='0x'+expected:
                    raise ValueError('Deployed immutable mismatch: '+method)
            code_hash=hashlib.sha256(code).hexdigest()
            def new_reader():
                return RegistryReader(RegistryRPC('http://127.0.0.1:'+str(port)),genesis,validator,
                                      signer.address,namespace,contract,code_hash)
            write_reader,read_reader=new_reader(),new_reader()
            writer=RegistryWriter(write_reader,signer,receipt_timeout=20)
            service=AnchorService(str(CHAIN_ID),signer.address,namespace,writer,read_reader)
            # An explicit native input is revalidated immediately before root submission.
            leaves=[]
            if native_input is not None:
                fresh=native_input.verify_roots()
                if fresh != native_roots: raise ValueError('Native roots changed before submission')
                record=make_record(str(CHAIN_ID),signer.address,namespace,1,fresh['policyVersion'],fresh['policyRoot'],fresh['executionRoot'])
                result['nativeEvidence']=fresh
                result['integrationMode']='explicit-native-cli-anchor; not automatic app recording'
            else:
                leaves=[hashlib.sha256(b'\x00'+canonical({'synthetic':True,'event':i})).digest() for i in (1,2)]
                execution_root=hashlib.sha256(b'\x01'+leaves[0]+leaves[1]).hexdigest()
                record=make_record(str(CHAIN_ID),signer.address,namespace,1,1,digest({'version':1,'synthetic':True}),execution_root)
            anchored=service.anchor(record)
            if not anchored['valid']: raise ValueError('Anchor failed: '+json.dumps(anchored))
            root_receipt=copy.deepcopy(writer.last_receipt)
            independent=service.verify(record)
            if not independent['valid']: raise ValueError('Independent read failed')
            result['independentReadAt']=datetime.now(timezone.utc).isoformat()
            missing=make_record(str(CHAIN_ID),signer.address,namespace,2,record['policyVersion'],record['policyRoot'],record['executionRoot'])
            if service.verify(missing)['valid']: raise ValueError('Missing chain record accepted')
            result['missingRecordRejected']=True
            duplicate=service.anchor(record)
            if duplicate['status']!='indeterminate': raise ValueError('Duplicate accepted')
            gap=make_record(str(CHAIN_ID),signer.address,namespace,3,1,record['policyRoot'],record['executionRoot'])
            if service.anchor(gap)['status']!='indeterminate': raise ValueError('Sequence gap accepted')
            tampered=make_record(str(CHAIN_ID),signer.address,namespace,1,1,'0'*64,record['executionRoot'])
            if service.verify(tampered)['valid']: raise ValueError('Mismatched root accepted')
            # Real denied submission from a new address outside account allowlist.
            denied_tx=dict(tx,**{'from':outsider.address,'to':contract,'data':encode_call('commit(bytes32,uint64,uint64,bytes32,bytes32,bytes32)',
                [scope,(2).to_bytes(32,'big'),(1).to_bytes(32,'big'),bytes.fromhex(record['policyRoot']),
                 bytes.fromhex(record['executionRoot']),bytes.fromhex(record['bindingRoot'])])})
            denied_raw=outsider(denied_tx)
            denied_hash='0x'+keccak256(bytes.fromhex(denied_raw[2:])).hex()
            denied_error=None
            try: rpc.call('eth_sendRawTransaction',[denied_raw])
            except ValueError as error: denied_error=str(error)
            if denied_error is None: raise ValueError('Unauthorized submission was accepted')
            if not any(term in denied_error.lower() for term in ('authoriz', 'permission', 'allowlist')):
                raise ValueError('Denied submission did not prove permission rejection: '+denied_error)
            if rpc.call('eth_getTransactionReceipt',[denied_hash]) is not None:
                raise ValueError('Unauthorized submission has a receipt')
            last=rpc.call('eth_call',[{'to':contract,'data':encode_call('lastSequence()',[])},'latest'])
            if int(last,16)!=1: raise ValueError('Denied operations changed registry sequence')
            result.update(status='passed',genesisHash=genesis,validator=validator,writer=signer.address,
                          contract=contract,codeSha256=code_hash,deploymentTransaction=deploy_hash,
                          deploymentBlock=receipt['blockNumber'],record=record,independentRead=independent,
                          rootTransaction=root_receipt['transactionHash'],rootBlock=root_receipt['blockNumber'],
                          rootBlockHash=root_receipt['blockHash'],executionMerkleLeaves=[leaf.hex() for leaf in leaves],
                          duplicateRejected=True,gapRejected=True,rootMismatchRejected=True,
                          unauthorizedTransaction=denied_hash,unauthorizedRejected=True,
                          unauthorizedError=denied_error,lastSequence=1)
            # Capture only the sockets of this newly created child process.
            sockets=subprocess.run(['/usr/sbin/lsof','-Pan','-p',str(process.pid),'-i'],capture_output=True,text=True)
            addresses=[line.split()[-2] if line.endswith('(LISTEN)') else line.split()[-1]
                       for line in sockets.stdout.splitlines()[1:]]
            if sockets.returncode or not addresses or any(not address.startswith('127.0.0.1:') for address in addresses):
                raise ValueError('Own node socket inventory is not exclusively loopback')
            result['ownProcessSocketAddresses']=addresses
            # Capture an observed block independently of the receipt.
            block=rpc.call('eth_getBlockByNumber',['latest',True])
            result['observedBlockHash']=block['hash']
            result['observedBlockNumber']=block['number']
            result['registryTransactions']=[t['hash'] for t in block.get('transactions',[]) if isinstance(t,dict) and t.get('to')==contract]
            print(json.dumps(result,indent=2),flush=True)
        except Exception as error:
            result.update(status='failed',error=str(error))
            raise
        finally:
            if process is not None and process.poll() is None:
                process.terminate()
                try: process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    process.kill(); process.wait(timeout=5)
            result['nodeStopped']=process is None or process.poll() is not None
            (runtime/'result.json').write_text(json.dumps(result,indent=2))
            print('Evidence saved; own node stopped: '+str(result['nodeStopped']),flush=True)
    return result


if __name__=='__main__':
    run()
