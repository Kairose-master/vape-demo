import AppKit
import Foundation
import Darwin

// Registry and UI run in the read-only user-selected App Sandbox broker.
// The optional HTTP coordinator receives metadata only. Apple mode has no network entitlement.
final class FlowController: NSObject, NSApplicationDelegate {
 var unified:UnifiedEvidence?; var ledgerTimer:Timer?; var demoAttempted=false
 var presentation:PresentationView!; var localOutcome:PrivateModelResult?; var cloudOutcome:PrivateModelResult?
 var window:NSWindow!;var registry:FileClassificationRegistry!;var current:RegisteredFile?;var handoff:PrivateModelHandoff!
 let principal=RegistryPrincipal(id:"native-selected-user")
 let grade=NSPopUpButton();let status=NSTextField(wrappingLabelWithString:"")
 var config:[String:Any]=[:];var appleMode=false;var busy=false;var appleAudit:AppleAudit?;var modelCalls=0;var cloudResult="미실행";var networkDenied=false
 func applicationDidFinishLaunching(_ notification:Notification) {
  do {
   config=try JSONSerialization.jsonObject(with:Data(contentsOf:Bundle.main.url(forResource:"bridge",withExtension:"json")!)) as! [String:Any]
   let home=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
   try FileManager.default.createDirectory(at:home,withIntermediateDirectories:true)
   let storage=try PrivateRegistryStore(directory:home.appendingPathComponent("SelectedRegistry"))
   registry=try FileClassificationRegistry(storage:storage,access:MacSelectedFileAccess(),policy:{UnifiedPolicy.snapshot})
   appleMode=config["appleLocal"] as? Bool == true
   if appleMode {
    let audit=try AppleAudit(home.appendingPathComponent("AppleAudit-"+UUID().uuidString));appleAudit=audit
    if config["unifiedLedger"] as? Bool == true {unified=try UnifiedEvidence(home.appendingPathComponent("UnifiedLedger"))}
    networkDenied=try audit.networkProbe(port:config["port"] as! Int)
    handoff=PrivateModelHandoff(registry:registry,principal:principal,configuration:{[unowned self] in
     guard let selected=self.current,let expected=self.config["syntheticSHA256"] as? String else{return nil}
     return PrivateModelConfiguration(enabled:self.appleMode,route:.local,model:"apple-system-default",destinationID:"apple-system-on-device",
       runtimeReady:{AppleLocalModel.available()},approval:{binding in
        binding.resourceID == selected.resource_id && binding.revision == selected.classification_revision && binding.policyVersion == selected.policy_version && binding.route == .local && (binding.contentDigest == nil || binding.contentDigest == expected)
       },dispatch:{[unowned self] input in self.modelCalls+=1;return try AppleLocalModel.respond(input,expectedDigest:expected)},syntheticLoopbackOnly:false)
    },audit:{[unowned self] in try audit.append($0);try self.unified?.append($0)})
   } else {handoff=PrivateModelHandoff(registry:registry,principal:principal,audit:{_ in throw HandoffError.intentFailed})}
  } catch {fatalError("Private registry unavailable; no reset attempted")}
  window=NSWindow(contentRect:NSRect(x:0,y:0,width:1180,height:1000),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
  window.title=unified != nil ? "VAPE · Apple + Besu 통합 합성 검증" : "VAPE · Policy & Evidence";window.minSize=NSSize(width:1120,height:700);window.center()
  grade.addItems(withTitles:["L1 · 로컬 전용","L2 · 읽기/반출 분리","L3 · 쓰기 별도 승인"])
  var buttons=[NSButton(title:"파일 등록",target:self,action:#selector(pick)),NSButton(title:"등급 변경",target:self,action:#selector(change)),NSButton(title:appleMode ? "로컬 실제 추론":"로컬 경로 확인",target:self,action:#selector(local)),NSButton(title:"Cloud 차단 확인",target:self,action:#selector(cloud))]
  if unified != nil {buttons.append(NSButton(title:"L1 검증 → Besu 기록 (1회)",target:self,action:#selector(unifiedDemo)))}
  status.stringValue="등록 전 · macOS 선택 창에서 이번 실행의 새 합성 파일을 선택하세요.\n등록은 모델 전송 승인이 아닙니다."
  presentation=PresentationView(grade:grade,detail:status,actions:buttons)
  let scroll=NSScrollView(frame:window.contentView!.bounds);scroll.autoresizingMask=[.width,.height];scroll.hasVerticalScroller=true;scroll.documentView=presentation;presentation.autoresizingMask=[.width];presentation.setFrameSize(NSSize(width:scroll.contentSize.width,height:presentation.frame.height))
  window.contentView!.addSubview(scroll)
  if appleMode {status.stringValue += "\nApple 모델 준비: \(AppleLocalModel.available() ? "사용 가능":"사용 불가 / 지원 OS·모델 확인 필요") · 앱 직접 TCP: \(networkDenied ? "OS 거부 관측":"격리 미검증")"}
  if unified != nil {presentation.ledgerValue.stringValue="Besu · 미실행 / 명시적 버튼 승인 필요"}
  refreshPresentation()
  window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
 }
 func refreshPresentation() {
  guard presentation != nil else{return}
  presentation.update(PresentationObservation(appleMode:appleMode,registered:current != nil,busy:busy,policyVersion:current?.policy_version,localDecision:localOutcome?.decision,localDelivery:localOutcome?.delivery,cloudDecision:cloudOutcome?.decision,calls:modelCalls,auditRecords:appleAudit?.records ?? 0,isolationObserved:networkDenied))
  if demoAttempted {presentation.actions.last?.isEnabled=false}
 }
 func post(_ path:String,_ value:[String:Any]) throws -> [String:Any] {try MetadataBridge.post(config,path,value)}
 func sync(_ file:RegisteredFile,active:Bool=true) throws {
  if appleMode{return} // Native registry is authoritative in the network-denied Apple mode.
  _ = try post("/native/register",["resource_id":file.resource_id.uuidString,"level":file.level.rawValue,"classification_revision":file.classification_revision,"policy_version":file.policy_version,"active":active])
 }
 func describe(_ file:RegisteredFile)->String {"ID \(file.resource_id.uuidString)\n등급 \(file.level.rawValue) · 분류 revision \(file.classification_revision) · 정책 v\(file.policy_version)"}
 @objc func pick(){defer{refreshPresentation()};guard !busy else{return};do {let picker:UserFileSelection = appleMode ? PinnedSyntheticPicker(expected:URL(fileURLWithPath:config["syntheticFile"] as! String)):MacUserFileSelection();if let file=try registry.register(using:picker,level:RegisteredLevel(rawValue:grade.indexOfSelectedItem+1)!,principal:principal){current=file;localOutcome=nil;cloudOutcome=nil;try sync(file);status.stringValue=describe(file)+"\n등록 완료 · 모델 본문 읽기/전송 없음"}}catch{status.stringValue="등록/연결 실패 · 권한 우회나 자동 재시도 없음"}}
 @objc func change(){defer{refreshPresentation()};guard !busy,let file=current else{return};do{let updated=try registry.changeLevel(resourceID:file.resource_id,to:RegisteredLevel(rawValue:grade.indexOfSelectedItem+1)!,expectedRevision:file.classification_revision,principal:principal);current=updated;localOutcome=nil;cloudOutcome=nil;try sync(updated);status.stringValue=describe(updated)+"\n등급 변경 완료 · 이전 revision 요청은 무효"}catch{try? sync(file,active:false);status.stringValue="등급 변경 불가 · 새 파일 선택 등록 필요"}}
 func route(_ name:String){defer{refreshPresentation()};guard !busy,let file=current else{return}
  if name == "local" {localOutcome=nil} else {cloudOutcome=nil}
  if appleMode {
   busy=true;grade.isEnabled=false;status.stringValue=describe(file)+"\n정책·파일·승인 재확인 및 로컬 실행 중…"
   DispatchQueue.global(qos:.userInitiated).async {[self] in
    let result=handoff.execute(resource:file,route:name == "local" ? .local:.cloud)
    DispatchQueue.main.async {[self] in
     busy=false;grade.isEnabled=true
     if name == "local" {localOutcome=result} else {cloudOutcome=result}
     defer{refreshPresentation()}
     if name == "cloud" {cloudResult=result.decision+" / 호출 전 중단"}
     status.stringValue=describe(file)+"\n결과: \(result.decision) · 수신: \(result.delivery) · \(result.reason)\nApple 호출 \(modelCalls)회 · Cloud 전송 비활성 · Cloud 경로: \(cloudResult)\n서명 감사 \(appleAudit?.records ?? 0)건 · 앱 직접 TCP: \(networkDenied ? "OS 거부 관측":"미검증")\n"+(result.output.map{"실제 Apple 로컬 응답:\n"+$0} ?? "모델 응답 없음 · 자동 재시도/Cloud 전환 없음")
    }
   };return
  }
  do{let value=try post("/native/preflight",["resource_id":file.resource_id.uuidString,"classification_revision":file.classification_revision,"policy_version":file.policy_version,"route":name,"action":"model_send"])
  let allowed=value["policyDecision"] as? String == "allow"
  if name == "cloud" && !allowed {cloudOutcome=PrivateModelResult(decision:"deny",reason:"metadata_preflight_denied",delivery:"not-started",output:nil)}
  if allowed {
   let result=handoff.execute(resource:file,route:name == "local" ? .local:.cloud)
   guard result.reason == "disabled" else {status.stringValue="네이티브 결과: \(result.decision) · 수신 상태: \(result.delivery) · 자동 재시도 없음";return}
  }
  status.stringValue=describe(file)+"\n\(name == "local" ? "로컬" : "Cloud") 정책: \(allowed ? "허용 조건 일치" : "거부")\n"+(allowed ? "모델 미연결 · 본문 읽기/전송 없음 · 추론 아님" : "1등급 Cloud 또는 등록/버전 조건 거부 · 본문 접근 없음")
 }catch{status.stringValue="서버 확인 불가 · 본문 접근·전송·자동 재시도 없음"}}
 @objc func unifiedDemo(){
  guard !busy,!demoAttempted,let f=current,let e=unified else{return}
  guard e.ready,f.level == .one else{status.stringValue="도우미 준비와 L1 등록 필요 · 실행 없음";return}
  demoAttempted=true;busy=true;grade.isEnabled=false;refreshPresentation()
  status.stringValue=describe(f)+"\n같은 등록 파일의 L1 Cloud 차단 → Apple 실제 응답 → 서명 검증 후 Besu 기록 중…"
  DispatchQueue.global(qos:.userInitiated).async {[self] in
   do {let (c,l)=try executeUnifiedDemo(f,e,handoff)
    DispatchQueue.main.async {[self] in cloudOutcome=c;localOutcome=l;status.stringValue=describe(f)+"\nCloud 호출 전 차단 · Apple 실제 응답:\n"+(l.output ?? "")+"\n서명 검증 및 체인 결과 대기 중 · 자동 재실행 없음";refreshPresentation()
     ledgerTimer=Timer.scheduledTimer(withTimeInterval:1,repeats:true){[weak self] timer in
      guard let self=self else{timer.invalidate();return}
      guard let data=try? Data(contentsOf:e.directory.appendingPathComponent("result.json")),let obj=try? JSONSerialization.jsonObject(with:data) as? [String:Any] else{return}
      timer.invalidate();self.busy=false;self.grade.isEnabled=true
      let ok=obj["status"] as? String == "verified"
      self.presentation.ledgerValue.stringValue=ok ? "Besu · 채굴·독립 재조회 확인 / 현재 노드 종료" : "Besu · 판정 불가 / 자동 재전송 없음"
      if ok {for field in ["verifiedAt","policyRoot","executionRoot","block","transaction","tamperedCopy"] {self.status.stringValue += "\n"+field+": "+(obj[field] as? String ?? "미검증")}}
      self.refreshPresentation()
     }
     DispatchQueue.main.asyncAfter(deadline:.now()+240){[weak self] in guard let self=self,self.busy else{return};self.ledgerTimer?.invalidate();self.busy=false;self.grade.isEnabled=true;self.presentation.ledgerValue.stringValue="Besu · 시간 초과 / 판정 불가 · 자동 재전송 없음";self.refreshPresentation()}
    }
   }catch {DispatchQueue.main.async {[self] in busy=false;grade.isEnabled=true;status.stringValue="실행 또는 증거 실패 · 체인 기록 확인 불가 · 자동 재시도 없음";refreshPresentation()}}
  }
 }
 @objc func local(){route("local")}
 @objc func cloud(){route("cloud")}

}
@main enum SelectedFlowApp {static func main(){let delegate=FlowController();let app=NSApplication.shared;app.setActivationPolicy(.regular);app.delegate=delegate;app.run()}}
