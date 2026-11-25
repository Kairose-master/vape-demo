import AppKit
import Foundation
import Darwin

final class Controller: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let output = NSTextView()
    var selectedURL: URL?
    var runFolder: URL?
    var gate: FileGate?
    var audit: NativeSignedAudit?
    var connection: NSXPCConnection?
    var activeAttempt: UUID?
    var runButton: NSButton!
    var selectButton: NSButton!
    var fixture: Fixture!
    var policy: Policy!
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            fixture = try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:Bundle.main.url(forResource:"fixture",withExtension:"json")!))
            policy = try JSONDecoder().decode(Policy.self,from:Data(contentsOf:Bundle.main.url(forResource:"policy",withExtension:"json")!))
            try policy.validate()
        } catch {fatalError("Invalid bundled configuration")}
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:1050,height:740),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title = "VAPE Signed Gateway — 폴더 선택 대기"
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top:22,left:22,bottom:22,right:22)
        root.addArrangedSubview(NSTextField(wrappingLabelWithString:"실제 App Sandbox 파일 집행 → CryptoKit Ed25519 서명 → 로컬 Merkle 포함 증명\n선택한 기존 합성 폴더 안에 새 실행 폴더만 생성합니다. 기존 증거·파일 변경 없음."))
        selectButton = NSButton(title:"1. 승인된 동일 합성 폴더 선택",target:self,action:#selector(selectFolder))
        root.addArrangedSubview(selectButton)
        runButton = NSButton(title:"2. OS 거부 · L2 차단 · L3 1회 쓰기 + 서명 증거 생성",target:self,action:#selector(runChecks))
        runButton.isEnabled = false; root.addArrangedSubview(runButton)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true
        output.isEditable = false; output.font = .monospacedSystemFont(ofSize:12,weight:.regular)
        output.autoresizingMask = [.width]; output.isVerticallyResizable = true; output.textContainer?.widthTracksTextView = true
        scroll.documentView = output; root.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-44).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:490).isActive = true
        window.contentView = root; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
        log("선택 대상: \(fixture.folder)\n새로운 폴더를 대신 승인하지 마세요.")
        log("HMAC 이전 데모와 별도 형식. 키·루트는 로컬 신뢰 기준이며 허가형 체인이나 외부 공증이 아닙니다.")
    }
    func log(_ message: String) {output.string += message+"\n\n"; output.scrollToEndOfDocument(nil)}
    @objc func selectFolder() {
        guard selectedURL == nil else {return}
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath:fixture.folder)
        panel.message = "기존에 승인한 정확한 합성 SelectedTestFolder 하나만 선택하세요."
        guard panel.runModal() == .OK, let url = panel.url else {log("선택 취소"); return}
        let scoped = url.startAccessingSecurityScopedResource()
        do {
            guard url.standardizedFileURL.path == fixture.folder, url.resolvingSymlinksInPath().path == fixture.folder else {throw GateError.wrongFolder}
            let runID = UUID().uuidString
            let folder = url.appendingPathComponent("signed-run-"+runID)
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false)
            var resources = [Resource]()
            for level in ["L1","L2","L3"] {
                let name = level.lowercased()+"-contract.txt"
                let data = Data("[SYNTHETIC SIGNED VAPE TEST] \(level) — no real data\n".utf8)
                try exclusiveDurableWrite(data,to:folder.appendingPathComponent(name))
                resources.append(Resource(id:"contract-"+level,level:level,fileName:name,initialSHA256:sha256(data)))
            }
            let runFixture = Fixture(folder:folder.path,resources:resources)
            try exclusiveDurableWrite(try canonical(runFixture),to:folder.appendingPathComponent("fixture.json"))
            let newGate = try FileGate(folder:folder,fixture:runFixture,policy:policy)
            let newAudit = try NativeSignedAudit(directory:folder.appendingPathComponent("SignedEvidence"),runID:runID)
            gate = newGate; audit = newAudit; selectedURL = url; runFolder = folder
            selectButton.isEnabled = false; runButton.isEnabled = true
            window.title = "VAPE Signed Gateway — 새 합성 실행 준비"
            log("BROKER_FOLDER_SELECTED: scoped=\(scoped), pid=\(getpid()), euid=\(geteuid())")
            log("새 실행: \(folder.path)\nEd25519 public key fingerprint: \(newAudit.keyID)\nprivate key: process memory only; never exported")
        } catch {
            if scoped {url.stopAccessingSecurityScopedResource()}
            log("INDETERMINATE setup: \(error). 기존 파일 변경 없음, 자동 재시도 없음.")
        }
    }
    @objc func runChecks() {
        guard activeAttempt == nil, let folder = runFolder, gate != nil, audit != nil else {return}
        runButton.isEnabled = false
        let attempt = UUID(); activeAttempt = attempt
        let link = NSXPCConnection(serviceName:Bundle.main.bundleIdentifier!+".RestrictedWorker")
        link.remoteObjectInterface = NSXPCInterface(with:RestrictedWorkerProtocol.self)
        link.resume(); connection = link
        let proxy = link.remoteObjectProxyWithErrorHandler { error in
            DispatchQueue.main.async {
                guard self.activeAttempt == attempt else {return}
                self.log("XPC_UNVERIFIED: \(error). OS 차단으로 간주하지 않습니다. 자동 재시도 없음."); self.finish()
            }
        } as! RestrictedWorkerProtocol
        proxy.probe(path:folder.appendingPathComponent("l3-contract.txt").path) {text in
            DispatchQueue.main.async {
                guard self.activeAttempt == attempt else {return}
                do {
                    let facts = try JSONSerialization.jsonObject(with:Data(text.utf8)) as! [String:Any]
                    self.log("WORKER_OS_OBSERVATION: \(text)")
                    guard facts["readDeniedByOS"] as? Bool == true, facts["writeDeniedByOS"] as? Bool == true,
                          let workerPID = facts["workerPID"] as? Int, workerPID != Int(getpid()) else {throw GateError.unsafeFile}
                    try self.recordAndExecute(worker:facts)
                } catch {self.log("INDETERMINATE: \(error). OS/집행/증거를 확인할 수 없음. 자동 재시도하지 않습니다.")}
                self.finish()
            }
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+8) {
            if self.activeAttempt == attempt {self.log("XPC_TIMEOUT: 판정 불가, 브로커 쓰기 진행 없음"); self.finish()}
        }
    }
    func recordAndExecute(worker: [String:Any]) throws {
        guard let gate = gate, let audit = audit else {return}
        let l2 = BrokerContext(role:"operator",workflow:"approved-cloud-read")
        let l3 = BrokerContext(role:"operator",workflow:"approved-workflow")
        var observed = nativeFacts(resource:try gate.resource("contract-L3"),context:l3,requestID:UUID().uuidString,
                                   before:try gate.read(id:"contract-L3",context:l3))
        observed.merge(["phase":"result","decision":"deny","policyDecision":"allow","enforcement":"worker-os-observation",
                        "observationScope":"this-instrumented-worker-only","workerPID":String(worker["workerPID"] as! Int),
                        "workerEUID":String(worker["workerEUID"] as! Int),"readErrno":String(worker["readErrno"] as! Int),
                        "writeErrno":String(worker["writeErrno"] as! Int),"readOpened":"false","writeOpened":"false"]) {_,new in new}
        try audit.append(policy:policy,facts:observed)
        log("SIGNED_OS_DENIAL: this instrumented worker only; not other apps or global OS control")
        let denied = executeSignedWrite(gate:gate,audit:audit,resourceID:"contract-L2",context:l2)
        log("L2: \(denied.decision), effect=\(denied.effectStatus), \(denied.reason)")
        guard denied.decision == "deny" else {throw GateError.unsafeFile}
        let written = executeSignedWrite(gate:gate,audit:audit,resourceID:"contract-L3",context:l3)
        log("L3: \(written.decision), effect=\(written.effectStatus), \(written.reason)")
        guard written.decision == "allow" else {throw GateError.unsafeFile}
        let package = try audit.exportRun()
        log("EXECUTION_COMPLETE — 독립 verifier 실행은 별도 단계입니다.\nPackage: \(package.path)\nPublic key: \(audit.directory.path)/TrustExport/public-key.raw\nCheckpoints: \(audit.directory.path)/TrustExport/trust-set.json")
        log("원문 없음. Ed25519는 이 브로커 기록의 서명이며 OS 사실을 독립 공증하지 않습니다. 로컬 Merkle 루트이며 허가형 원장 연결은 아직 없습니다.")
        window.title = "VAPE Signed Gateway — 집행·서명 완료 / 독립 검증 대기"
    }
    func finish() {activeAttempt = nil; connection?.invalidate(); connection = nil}
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool {true}
}
@main enum BrokerMain {
    static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let controller = Controller(); app.delegate = controller; app.run()
    }
}
