import AppKit
import Foundation
import Darwin


private enum ConsoleStyle {
    static let ink = NSColor(srgbRed:0.10,green:0.15,blue:0.23,alpha:1)
    static let muted = NSColor(srgbRed:0.39,green:0.44,blue:0.51,alpha:1)
    static let teal = NSColor(srgbRed:0.00,green:0.43,blue:0.38,alpha:1)
    static let amber = NSColor(srgbRed:0.62,green:0.35,blue:0.04,alpha:1)
    static let purple = NSColor(srgbRed:0.34,green:0.27,blue:0.67,alpha:1)
    static let red = NSColor(srgbRed:0.70,green:0.19,blue:0.18,alpha:1)
    static func label(_ text:String,size:CGFloat,weight:NSFont.Weight = .regular,color:NSColor = ink) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString:text)
        field.font = .systemFont(ofSize:size,weight:weight); field.textColor = color
        field.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        return field
    }
}
private final class StepCard: NSView {
    let value = ConsoleStyle.label("확인 전",size:32,weight:.semibold,color:ConsoleStyle.muted)
    let detail = ConsoleStyle.label("실행 결과를 기다립니다",size:13,color:ConsoleStyle.muted)
    init(number:String,title:String,subtitle:String) {
        super.init(frame:.zero); wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor; layer?.cornerRadius = 14
        layer?.borderWidth = 1; layer?.borderColor = NSColor(srgbRed:0.86,green:0.89,blue:0.92,alpha:1).cgColor
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 9
        stack.addArrangedSubview(ConsoleStyle.label(number+"  /  "+subtitle,size:11,weight:.semibold,color:ConsoleStyle.muted))
        stack.addArrangedSubview(ConsoleStyle.label(title,size:18,weight:.semibold))
        stack.addArrangedSubview(value); stack.addArrangedSubview(detail)
        addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:leadingAnchor,constant:20),stack.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-20),stack.topAnchor.constraint(equalTo:topAnchor,constant:20),stack.bottomAnchor.constraint(lessThanOrEqualTo:bottomAnchor,constant:-18),heightAnchor.constraint(equalToConstant:194)])
    }
    required init?(coder:NSCoder) {fatalError("not used")}
    func show(_ text:String,_ description:String,color:NSColor) {value.stringValue=text;value.textColor=color;detail.stringValue=description}
}

final class NetworkController: NSObject, NSApplicationDelegate {
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
    var config: NetworkConfig!
    private var cards = [StepCard]()
    private let headlineStatus = ConsoleStyle.label("01  승인된 합성 폴더를 선택하세요",size:15,weight:.medium)
    private let workerStatus = ConsoleStyle.label("OS 작업자 검증 · 확인 전",size:13,color:ConsoleStyle.muted)
    private let receiverStatus = ConsoleStyle.label("수신기 · 확인 전",size:13,color:ConsoleStyle.muted)
    private var observer: Timer?
    private var observationDeadline = Date.distantFuture
    private var outcomeShown = false
    private var stoppedShown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            fixture = try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:Bundle.main.url(forResource:"fixture",withExtension:"json")!))
            policy = try JSONDecoder().decode(Policy.self,from:Data(contentsOf:Bundle.main.url(forResource:"policy",withExtension:"json")!))
            config = try JSONDecoder().decode(NetworkConfig.self,from:Data(contentsOf:Bundle.main.url(forResource:"network",withExtension:"json")!))
            try policy.validate()
        } catch {fatalError("Invalid bundled configuration")}
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:1220,height:840),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.minSize = NSSize(width:1100,height:790)
        window.title = "VAPE · 로컬 집행 검증"
        window.appearance = NSAppearance(named:.aqua)
        window.backgroundColor = NSColor(srgbRed:0.96,green:0.97,blue:0.98,alpha:1)
        let canvas = NSView(); window.contentView = canvas
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 20
        canvas.addSubview(root); root.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:canvas.leadingAnchor,constant:32),root.trailingAnchor.constraint(equalTo:canvas.trailingAnchor,constant:-32),root.topAnchor.constraint(equalTo:canvas.topAnchor,constant:24),root.bottomAnchor.constraint(equalTo:canvas.bottomAnchor,constant:-24)])
        let bar = NSStackView(); bar.orientation = .horizontal; bar.spacing = 12
        bar.addArrangedSubview(ConsoleStyle.label("VAPE",size:24,weight:.bold))
        bar.addArrangedSubview(ConsoleStyle.label("/  EXECUTION CONSOLE",size:11,weight:.semibold,color:ConsoleStyle.muted))
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow,for:.horizontal);bar.addArrangedSubview(spacer)
        bar.addArrangedSubview(ConsoleStyle.label("●  LOCAL VERIFICATION",size:11,weight:.semibold,color:ConsoleStyle.teal))
        root.addArrangedSubview(bar);bar.widthAnchor.constraint(equalTo:root.widthAnchor).isActive=true
        let intro = NSStackView(); intro.orientation = .vertical; intro.alignment = .leading; intro.spacing = 7
        intro.addArrangedSubview(ConsoleStyle.label("자료 접근과 반출, 각각의 권한으로.",size:32,weight:.bold))
        intro.addArrangedSubview(ConsoleStyle.label("2등급 읽기 → 미등록 반출 차단 → 3등급 승인 전송 → 독립 감사 검증",size:15,color:ConsoleStyle.muted))
        root.addArrangedSubview(intro)
        let controls = NSStackView();controls.orientation = .horizontal;controls.spacing = 12
        selectButton = NSButton(title:"1  합성 폴더 선택",target:self,action:#selector(selectFolder))
        runButton = NSButton(title:"2  검증 실행",target:self,action:#selector(runChecks));runButton.isEnabled=false
        for button in [selectButton!,runButton!] {button.bezelStyle = .rounded;button.controlSize = .large;button.font = .systemFont(ofSize:14,weight:.semibold);button.heightAnchor.constraint(equalToConstant:38).isActive=true;controls.addArrangedSubview(button)}
        runButton.contentTintColor = ConsoleStyle.teal
        controls.addArrangedSubview(headlineStatus);root.addArrangedSubview(controls)
        let row = NSStackView();row.orientation = .horizontal;row.spacing = 14;row.distribution = .fillEqually
        cards = [StepCard(number:"01",title:"2등급 읽기",subtitle:"FILE ACCESS"),StepCard(number:"02",title:"미등록 반출",subtitle:"POLICY DENY"),StepCard(number:"03",title:"승인된 전송",subtitle:"LOOPBACK HTTP"),StepCard(number:"04",title:"감사 증명",subtitle:"INDEPENDENT VERIFY")]
        for card in cards {row.addArrangedSubview(card)}
        root.addArrangedSubview(row);row.widthAnchor.constraint(equalTo:root.widthAnchor).isActive=true
        let statuses = NSStackView();statuses.orientation = .horizontal;statuses.spacing = 26
        statuses.addArrangedSubview(workerStatus);statuses.addArrangedSubview(receiverStatus);root.addArrangedSubview(statuses)
        let bottom = NSStackView();bottom.orientation = .horizontal;bottom.alignment = .top;bottom.spacing = 24
        let trace = NSStackView();trace.orientation = .vertical;trace.alignment = .leading;trace.spacing = 8
        trace.addArrangedSubview(ConsoleStyle.label("실행 기록",size:14,weight:.semibold))
        let scroll = NSScrollView();scroll.hasVerticalScroller=true;scroll.borderType = .noBorder
        output.isEditable=false;output.font = .monospacedSystemFont(ofSize:11,weight:.regular);output.textColor=ConsoleStyle.muted
        output.backgroundColor = NSColor.white;output.textContainerInset=NSSize(width:12,height:12)
        output.autoresizingMask = [.width];output.isVerticallyResizable=true;output.textContainer?.widthTracksTextView=true
        scroll.documentView=output;scroll.wantsLayer=true;scroll.layer?.cornerRadius=10
        trace.addArrangedSubview(scroll);scroll.widthAnchor.constraint(equalTo:trace.widthAnchor).isActive=true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:180).isActive=true
        bottom.addArrangedSubview(trace)
        let scope = NSStackView();scope.orientation = .vertical;scope.alignment = .leading;scope.spacing=10
        scope.addArrangedSubview(ConsoleStyle.label("이 시연이 확인하는 것",size:14,weight:.semibold))
        scope.addArrangedSubview(ConsoleStyle.label("합성 자료 · 이 Mac의 loopback 수신기\n별도 App Sandbox 작업자\nEd25519 서명 · 로컬 Merkle 체크포인트",size:13,color:ConsoleStyle.muted))
        scope.addArrangedSubview(ConsoleStyle.label("실제 클라우드나 허가형 원장 연결이 아닙니다. OS 거부 관측은 이 작업자에만 해당합니다.",size:13,color:ConsoleStyle.muted))
        scope.addArrangedSubview(ConsoleStyle.label("수신 건수는 실행기의 실측 후 표시합니다. 증거가 없거나 무효면 판정 불가이며 자동 재전송하지 않습니다.",size:13,color:ConsoleStyle.muted))
        scope.widthAnchor.constraint(equalToConstant:285).isActive=true;bottom.addArrangedSubview(scope)
        root.addArrangedSubview(bottom);bottom.widthAnchor.constraint(equalTo:root.widthAnchor).isActive=true
        scroll.heightAnchor.constraint(equalTo:bottom.heightAnchor,constant:-26).isActive=true
        window.center();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        log("선택 대상: \(fixture.folder)\n새로운 폴더를 대신 승인하지 마세요.")
        log("HMAC 이전 데모와 별도 형식. 키·루트는 로컬 신뢰 기준이며 허가형 체인이나 외부 공증이 아닙니다.")
    }
    func log(_ message: String) {
        if message.contains("INDETERMINATE") || message.contains("XPC_UNVERIFIED") || message.contains("XPC_TIMEOUT") || message.contains("시간 초과") || message.contains("사후 증거 실패") { showUncertain() }
        output.string += message+"\n\n"; output.scrollToEndOfDocument(nil)}
    @objc func selectFolder() {
        guard selectedURL == nil else {return}
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath:fixture.folder)
        panel.message = "기존에 승인한 정확한 합성 SelectedTestFolder 하나만 선택하세요."
        guard panel.runModal() == .OK, let url = panel.url else {log("선택 취소"); return}
        let scoped = url.startAccessingSecurityScopedResource()
        do {
            guard url.standardizedFileURL.path == fixture.folder, url.resolvingSymlinksInPath().path == fixture.folder else {throw GateError.wrongFolder}
            let runID = config.runID
            let folder = url.appendingPathComponent("network-run-"+runID)
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false)
            var resources = [Resource]()
            for level in ["L1","L2","L3"] {
                let name = level.lowercased()+"-contract.txt"
                let data = Data("[SYNTHETIC NETWORK VAPE TEST] \(level) — no real data\n".utf8)
                try exclusiveDurableWrite(data,to:folder.appendingPathComponent(name))
                resources.append(Resource(id:"contract-"+level,level:level,fileName:name,initialSHA256:sha256(data)))
            }
            let runFixture = Fixture(folder:folder.path,resources:resources)
            try exclusiveDurableWrite(try canonical(runFixture),to:folder.appendingPathComponent("fixture.json"))
            let newGate = try FileGate(folder:folder,fixture:runFixture,policy:policy)
            let newAudit = try NativeSignedAudit(directory:folder.appendingPathComponent("SignedEvidence"),runID:runID)
            gate = newGate; audit = newAudit; selectedURL = url; runFolder = folder
            beginObservation()
            headlineStatus.stringValue = "공개키 사전 확보 중 · 실행 대기"
            selectButton.isEnabled = false
            waitForFile("key-pinned.json") { self.runButton.isEnabled = true; self.headlineStatus.stringValue = "02  준비 완료 · 검증을 실행하세요"; self.log("독립 공개키 사전 확보 완료. 실행 버튼을 누르세요.") }
            window.title = "VAPE Network Gateway — 새 합성 실행 준비"
            log("BROKER_FOLDER_SELECTED: scoped=\(scoped), pid=\(getpid()), euid=\(geteuid())")
            log("새 실행: \(folder.path)\nEd25519 public key fingerprint: \(newAudit.keyID)\nprivate key: process memory only; never exported")
        } catch {
            if scoped {url.stopAccessingSecurityScopedResource()}
            log("INDETERMINATE setup: \(error). 기존 파일 변경 없음, 자동 재시도 없음.")
        }
    }
    @objc func runChecks() {
        guard activeAttempt == nil, runFolder != nil, gate != nil, audit != nil else {return}
        runButton.isEnabled = false
        headlineStatus.stringValue = "집행 중 · 수신 건수와 증거를 확인합니다"
        receiverStatus.stringValue = "수신기 · 관측 대기"
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
        proxy.probeNetwork(port:config.port) {text in
            DispatchQueue.main.async {
                guard self.activeAttempt == attempt else {return}
                do {
                    let facts = try JSONSerialization.jsonObject(with:Data(text.utf8)) as! [String:Any]
                    self.log("WORKER_NETWORK_OBSERVATION: \(text)")
                    try self.recordAndExecute(worker:facts)
                } catch {self.log("INDETERMINATE: \(error). 자동 재전송 없음."); self.finish()}
            }
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+8) {
            if self.activeAttempt == attempt && self.audit?.bundles.isEmpty == true {self.log("XPC_TIMEOUT: 판정 불가"); self.finish()}
        }
    }
    func waitForFile(_ name:String, action:@escaping()->Void, remaining:Int = 1200) {
        guard let folder = runFolder else {return}
        if FileManager.default.fileExists(atPath:folder.appendingPathComponent(name).path) {action(); return}
        guard remaining > 0 else {log("준비 시간 초과 — 판정 불가, 재전송 없음"); finish(); return}
        DispatchQueue.main.asyncAfter(deadline:.now()+0.1) {self.waitForFile(name,action:action,remaining:remaining-1)}
    }
    func recordAndExecute(worker:[String:Any]) throws {
        guard let gate = gate, let audit = audit, let folder = runFolder else {return}
        let l2 = BrokerContext(role:"operator",workflow:"approved-cloud-read")
        let l3 = BrokerContext(role:"operator",workflow:"approved-workflow")
        var facts = nativeFacts(resource:try gate.resource("contract-L3"),context:l3,requestID:UUID().uuidString,before:try gate.read(id:"contract-L3",context:l3))
        let osDenied = worker["deniedByOS"] as? Bool == true
        facts.merge(["operation":"tool_send","destination":"approved-loopback","phase":"result","policyDecision":"allow",
            "decision":osDenied ? "deny":"indeterminate","enforcement":"worker-network-observation",
            "workerPID":String(worker["workerPID"] as! Int),"connectErrno":String(worker["connectErrno"] as! Int),
            "connected":String(worker["connected"] as! Bool),"observationScope":"this-instrumented-worker-only",
            "endpoint":"http://127.0.0.1:\(config.port)/ingest"]) {_,new in new}
        // An unsuccessful connection alone is never labeled OS denial.
        if osDenied {try audit.append(policy:policy,facts:facts)}
        workerStatus.stringValue = osDenied ? "OS 작업자 · 접속 거부 확인 (EPERM/EACCES)" : "OS 작업자 · 차단 미입증"
        workerStatus.textColor = osDenied ? ConsoleStyle.teal : ConsoleStyle.amber
        log(osDenied ? "작업자 connect OS 거부 확인 (이 프로세스만)" : "작업자 OS 차단 미입증")
        let network = NetworkGate(files:gate,audit:audit,port:config.port)
        let denied = network.send(resourceID:"contract-L2",context:l2,destination:"unregistered-external")
        guard denied.decision == "deny", network.attempts == 0 else {throw GateError.unsafeFile}
        cards[0].show("성공", "2등급 · 승인된 파일 읽기", color:ConsoleStyle.teal)
        cards[1].show("차단", "정책 거부 · 실제 수신 건수 확인 중", color:ConsoleStyle.amber)
        log("L2 승인 읽기 성공 / 미등록 반출 정책 거부 / 소켓 시도 0")
        try exclusiveDurableWrite(try canonical(["decision":denied.decision,"networkAttempts":"0","workerOSDenied":String(osDenied)]),to:folder.appendingPathComponent("denied.json"))
        waitForFile("receiver-zero.json") {
            do {
                if let data = try? Data(contentsOf:folder.appendingPathComponent("receiver-zero.json")),
                   let value = try? JSONSerialization.jsonObject(with:data) as? [String:Any], value["count"] as? Int == 0 {
                    self.cards[1].show("0건", "반출 차단 · 실제 수신 0건 확인", color:ConsoleStyle.amber)
                }
                let sent = network.send(resourceID:"contract-L3",context:l3,destination:"approved-loopback")
                self.cards[2].show(sent.decision == "allow" ? "수신 확인 중" : "판정 불가", sent.decision == "allow" ? "HTTP 응답 완료 · 실측 대조 중" : "전송/증거 실패 · 자동 재전송 없음", color:ConsoleStyle.muted)
                self.log("L3 승인 전송: \(sent.decision), effect=\(sent.effectStatus). \(sent.reason)")
                let package = try audit.exportRun()
                try exclusiveDurableWrite(try canonical(["decision":sent.decision,"effectStatus":sent.effectStatus,"networkAttempts":String(network.attempts),"package":package.path,"workerOSDenied":String(osDenied)]),to:folder.appendingPathComponent("completed.json"))
                self.log("서명 패키지 생성 완료. 별도 실행기가 실제 수신 횟수와 독립 검증 결과를 출력합니다.\n\(package.path)")
                self.log("실제 loopback 격리 전송만 검증. 실제 클라우드/외부 목적지/허가형 체인 미검증.")
                self.headlineStatus.stringValue = "03  별도 검증기가 수신 기록과 서명을 대조합니다"
                self.cards[3].show("검증 중", "별도 프로세스의 결과 대기", color:ConsoleStyle.purple)
                self.window.title = "VAPE · 독립 검증 대기"
            } catch {self.log("사후 증거 실패: 판정 불가, 자동 재전송 없음")}
            self.finish()
        }
    }
    private func showUncertain() {
        headlineStatus.stringValue = "확인 실패 · 결과를 단정하지 않습니다";headlineStatus.textColor=ConsoleStyle.red
        for card in cards where ["확인 전","수신 확인 중","검증 중"].contains(card.value.stringValue) {card.show("판정 불가","확인 실패 · 자동 재전송 없음",color:ConsoleStyle.red)}
    }
    private func beginObservation() {
        observationDeadline=Date().addingTimeInterval(330)
        observer=Timer.scheduledTimer(withTimeInterval:0.25,repeats:true) {[weak self] _ in self?.observePresentationResult()}
    }
    private func observePresentationResult() {
        guard let folder=runFolder else {return}
        if !outcomeShown, let data=try? Data(contentsOf:folder.appendingPathComponent("ui-outcome.json")),
           let result=try? JSONSerialization.jsonObject(with:data) as? [String:Any], result["session"] as? String == config.runID {
            outcomeShown=true
            if result["status"] as? String == "PASS", result["receiverBefore"] as? Int == 0, result["receiverAfter"] as? Int == 1,
               result["signatureVerified"] as? Bool == true {
                cards[1].show("0건","미등록 반출 차단 · 수신기 실측",color:ConsoleStyle.amber)
                cards[2].show("1건","승인된 요청 1회 · 수신기 실측",color:ConsoleStyle.teal)
                cards[3].show("검증 완료","Ed25519 + Merkle · 별도 검증기",color:ConsoleStyle.purple)
                headlineStatus.stringValue="검증 완료 · 읽기 허용 / 반출 분리 / 증거 확인";headlineStatus.textColor=ConsoleStyle.teal
                window.title="VAPE · 로컬 집행 검증 완료"
            } else {showUncertain();cards[3].show("판정 불가","실행기 검증 실패 · 기록 확인 필요",color:ConsoleStyle.red)}
        }
        if !stoppedShown, let data=try? Data(contentsOf:folder.appendingPathComponent("ui-receiver-stopped.json")),
           let result=try? JSONSerialization.jsonObject(with:data) as? [String:Any], result["session"] as? String == config.runID {
            stoppedShown=true;receiverStatus.stringValue="수신기 · 종료됨 (이번 실행의 관측값 표시)"
            if !outcomeShown {showUncertain()}
        }
        if Date()>observationDeadline && !outcomeShown {showUncertain();receiverStatus.stringValue="수신기 · 상태 확인 실패";observer?.invalidate()}
        if outcomeShown && stoppedShown {observer?.invalidate()}
    }
    func finish() {activeAttempt = nil; connection?.invalidate(); connection = nil}
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool {true}
}
@main enum NetworkBrokerMain {
    static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let controller = NetworkController(); app.delegate = controller; app.run()
    }
}
