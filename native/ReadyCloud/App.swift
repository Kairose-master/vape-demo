import AppKit
final class ReadyCloudApp:NSObject,NSApplicationDelegate,NSWindowDelegate {
 private let input=NSSecureTextField(),status=NSTextField(wrappingLabelWithString:"")
 private let sendButton=NSButton();private var window:NSWindow!;private var engine:CloudEngine!;private var key:String?;private var started=false
 func applicationDidFinishLaunching(_ notification:Notification){
  NSApp.mainMenu=SecurePaste.menu()
  do {let support=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0];try FileManager.default.createDirectory(at:support,withIntermediateDirectories:true);let audit=try CloudAudit(support.appendingPathComponent("CloudAudit-"+UUID().uuidString));engine=CloudEngine(transport:HTTPSCloud(),audit:{try audit.append($0)})}
  catch {NSApp.terminate(nil);return}
  window=NSWindow(contentRect:NSRect(x:0,y:0,width:800,height:650),styleMask:[.titled,.closable],backing:.buffered,defer:false);window.title="VAPE · OpenAI 1회 실검증 — 붙여넣기 수정 v2";window.delegate=self;window.center()
  let stack=NSStackView();stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=16;stack.translatesAutoresizingMaskIntoConstraints=false;window.contentView!.addSubview(stack)
  NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:28),stack.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-28),stack.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:24)])
  let title=NSTextField(labelWithString:"OpenAI · 합성 2등급 자료 1회 실검증");title.font = .boldSystemFont(ofSize:25);stack.addArrangedSubview(title)
  stack.addArrangedSubview(NSTextField(wrappingLabelWithString:"대상: https://api.openai.com/v1/responses\n고정 데모 모델: "+CloudDemo.model+"\n조직 승인 모델을 찾지 못해 문서화된 효율형 모델을 데모 기본값으로 선택했습니다. 아래 전송 버튼은 이 모델의 이번 1회 사용 승인입니다. API 사용료가 발생할 수 있습니다."))
  stack.addArrangedSubview(NSTextField(wrappingLabelWithString:"전송될 정확한 합성 내용:\n"+CloudDemo.text))
  stack.addArrangedSubview(NSTextField(wrappingLabelWithString:"개인 파일 없음 · store:false · 도구 없음 · 리디렉션/재시도/대체 모델 없음\n같은 실행에서 1등급 Cloud 호출 전 차단을 기록한 뒤, 승인된 위 합성 2등급 요청만 보냅니다."))
  input.placeholderString="API 키 직접 입력 · 채팅으로 보내지 마세요";input.stringValue="";input.widthAnchor.constraint(equalToConstant:730).isActive=true;input.setAccessibilityElement(false);stack.addArrangedSubview(input)
  stack.addArrangedSubview(NSButton(title:"키 붙여넣기 · 보안 필드에만",target:self,action:#selector(pasteKey)))
  stack.addArrangedSubview(NSButton(title:"1. 키 준비 — 아직 전송하지 않음",target:self,action:#selector(prepare)))
  sendButton.title="2. 위 모델·합성 내용의 OpenAI 1회 전송 승인";sendButton.target=self;sendButton.action=#selector(send);sendButton.isEnabled=false;stack.addArrangedSubview(sendButton)
  stack.addArrangedSubview(NSButton(title:"취소 · 키 버리기",target:self,action:#selector(cancel)))
  status.stringValue="준비 완료 · 실제 호출 0회. 키 입력 후 1번, 실제 전송하려면 2번을 직접 누르세요.";status.widthAnchor.constraint(equalToConstant:730).isActive=true;stack.addArrangedSubview(status)
  window.makeKeyAndOrderFront(nil);window.makeFirstResponder(input);NSApp.activate(ignoringOtherApps:true)
 }
 @objc private func pasteKey(){SecurePaste.userAction(enabled:!started && key==nil && input.isEnabled,focusSecureField:{self.window.makeFirstResponder(self.input)},dispatchStandardPaste:{NSApp.sendAction(Selector(("paste:")),to:nil,from:self.input)})}
 @objc private func prepare(){guard !started,key==nil else{return};let value=input.stringValue;guard CloudDemo.keyFormat(value) else{status.stringValue="키 형식을 확인하세요. 호출 0회.";return};key=value;input.stringValue="";input.isEnabled=false;sendButton.isEnabled=true;status.stringValue="키 준비됨 · 호출 0회. 실제 실행하려면 2번 전송 승인 버튼을 직접 누르세요."}
 @objc private func send(){guard !started,let credential=key else{return};started=true;key=nil;input.stringValue="";sendButton.isEnabled=false;status.stringValue="1등급 차단 및 의도 기록 후 합성 2등급 요청을 1회 실행 중…"
  engine.executeL2(key:credential,approved:true){[weak self] result in DispatchQueue.main.async{guard let self=self else{return};self.status.stringValue="L1 Cloud 호출 0회 · L2 시도 \(self.engine.calls)회\n결과: \(result.decision) / \(result.delivery) / \(result.reason)\n키 참조 해제 · 자동 재시도 없음\n"+(result.output ?? "응답을 확인하지 못했습니다. 재전송하지 않습니다.")}}
 }
 @objc private func cancel(){key=nil;input.stringValue="";input.isEnabled=false;sendButton.isEnabled=false;started=true;engine.cancel();status.stringValue="취소 · 키 참조 해제. 진행 중이었다면 수신 여부는 판정 불가이며 재시도하지 않습니다."}
 func windowWillClose(_ notification:Notification){cancel();NSApp.terminate(nil)}
}
@main enum Main {static func main(){let delegate=ReadyCloudApp();let app=NSApplication.shared;app.setActivationPolicy(.regular);app.delegate=delegate;app.run()}}
