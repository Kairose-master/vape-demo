import AppKit
final class ConsoleBackground:NSView {override func draw(_ dirtyRect:NSRect){NSColor.windowBackgroundColor.setFill();dirtyRect.fill();super.draw(dirtyRect)}}
final class ConsoleSyntheticTransport:CloudSending {
 var calls=0
 func send(key:String,body:Data,completion:@escaping(Int?,Data?,Bool)->Void){calls+=1;completion(nil,nil,true)}
 func cancel(){}
}
final class ConsoleApp:NSObject,NSApplicationDelegate,NSWindowDelegate {
 private var localStatus=NSTextField(wrappingLabelWithString:"아직 확인하지 않았습니다. 모델·체인·Cloud 실행 0회. 준비 상태부터 확인하세요.")
 private var mockStatus=NSTextField(wrappingLabelWithString:"명시적으로 실행하기 전에는 모의 결과도 없습니다.")
 private var localSession:URLSession!;private var endpoint:URL!;private var capability="";private var timer:Timer?
 private let uiTest=CommandLine.arguments.contains("--ui-test");private let synthetic=ConsoleSyntheticTransport()
 private var localButtons:[NSButton]=[];private var pages:NSTabView!;private var navigation:[NSButton]=[]
 private let input=NSSecureTextField(),status=NSTextField(wrappingLabelWithString:"")
 private let sendButton=NSButton();private var window:NSWindow!;private var engine:CloudEngine!;private var key:String?;private var started=false
 func applicationDidFinishLaunching(_ notification:Notification){
  NSApp.mainMenu=SecurePaste.menu()
  do {
   let url=Bundle.main.url(forResource:"local",withExtension:"json")!
   let settings=try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as! [String:String]
   endpoint=URL(string:settings["endpoint"]!)!;capability=settings["capability"]!
   guard endpoint.host=="127.0.0.1",endpoint.scheme=="http",endpoint.port != 8765 else{NSApp.terminate(nil);return}
   let config=URLSessionConfiguration.ephemeral;config.connectionProxyDictionary=[:];config.urlCache=nil;config.httpCookieStorage=nil;config.urlCredentialStorage=nil;config.timeoutIntervalForRequest=5
   localSession=URLSession(configuration:config)
  } catch{NSApp.terminate(nil);return}
  do {let support=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0];try FileManager.default.createDirectory(at:support,withIntermediateDirectories:true);let audit=try CloudAudit(support.appendingPathComponent("CloudAudit-"+UUID().uuidString));engine=CloudEngine(transport:uiTest ? synthetic : HTTPSCloud(),audit:{try audit.append($0)})}
  catch {NSApp.terminate(nil);return}
  window=NSWindow(contentRect:NSRect(x:0,y:0,width:1000,height:880),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false);window.title="VAPE · 통합 보안 실행 콘솔";window.minSize=NSSize(width:900,height:860);window.delegate=self;window.center()
  window.contentView=ConsoleBackground(frame:window.contentView!.bounds)
  var area=window.contentView!.bounds.insetBy(dx:20,dy:20);area.size.height-=44
  let tabs=NSTabView(frame:area);tabs.tabViewType = .noTabsNoBorder;tabs.autoresizingMask=[.width,.height];window.contentView!.addSubview(tabs);pages=tabs
  let nav=NSStackView(frame:NSRect(x:24,y:window.contentView!.bounds.height-54,width:940,height:32));nav.orientation = .horizontal;nav.spacing=16;nav.autoresizingMask=[.width,.minYMargin];window.contentView!.addSubview(nav)
  for (index,title) in ["Apple Local + Besu","OpenAI · 별도 L2","오프라인 모의"].enumerated(){let button=NSButton(title:title,target:self,action:#selector(selectPage(_:)));button.tag=index;button.setButtonType(.pushOnPushOff);button.bezelStyle = .rounded;button.state=index==0 ? .on : .off;navigation.append(button);nav.addArrangedSubview(button)}
  func page(_ title:String)->NSView {let item=NSTabViewItem(identifier:title);item.label=title;let view=NSView();item.view=view;tabs.addTabViewItem(item);return view}
  let localPage=page("Apple Local + Besu"),cloudPage=page("OpenAI · 별도 L2 워크플로"),mockPage=page("오프라인 모의 · 명시 선택")
  let local=makeStack(localPage)
  heading("읽기 허용 ≠ 반출 허용",local)
  label("L1: Cloud 차단 · Apple 기기 내 처리 → 서명/Merkle → 새 사설 Besu 거래 → 별도 RPC 재조회\nL2: 읽기와 외부 송신 분리 · 오른쪽 OpenAI 탭에서 별도 1회 승인\nL3: 쓰기 별도 승인 · 이 콘솔에서는 실행하지 않음",local)
  label("실제 경로 · 고정 합성 TXT만 사용 · 사용자 파일 선택 대역을 사용하는 검증 하네스입니다.\nApple와 Besu가 모두 ready일 때만 통합 실행합니다. 사용 불가 시 자동 대체하지 않습니다.",local)
  addLocal("1. 준비 상태 확인 · 추론/거래 0회",#selector(readiness),local)
  addLocal("2. L1 차단 → 실제 Apple → 실제 Besu (합성 1회)",#selector(apple),local)
  addLocal("Besu만 독립 검증 · Apple 증거 아님 (합성 1회)",#selector(besu),local)
  label("아래 상태와 증거는 이번 콘솔 세션에서 관측한 값입니다. 이전 기록을 성공으로 재사용하지 않습니다.",local)
  evidence(localStatus,local)
  let mock=makeStack(mockPage);heading("오프라인 모의 검증",mock)
  label("실제 Apple·OpenAI·Besu가 아닙니다. 명시 실행 시 정책/감사/새 localhost HTTP 시험을 수행합니다. 모의 성공은 실제 모델·체인 성공을 뜻하지 않습니다.",mock)
  addLocal("모의 자체 검증 실행",#selector(mockRun),mock);evidence(mockStatus,mock)
  let stack=NSStackView();stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=16;stack.translatesAutoresizingMaskIntoConstraints=false;cloudPage.addSubview(stack)
  NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:cloudPage.leadingAnchor,constant:28),stack.trailingAnchor.constraint(equalTo:cloudPage.trailingAnchor,constant:-28),stack.topAnchor.constraint(equalTo:cloudPage.topAnchor,constant:24)])
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
  tabs.selectTabViewItem(at:0)
  if uiTest {
   window.setFrameOrigin(NSPoint(x:-20000,y:-20000));window.orderBack(nil);window.display()
   RunLoop.current.run(until:Date().addingTimeInterval(0.2))
   window.contentView!.layoutSubtreeIfNeeded()
   precondition(tabs.numberOfTabViewItems==3 && tabs.selectedTabViewItem===tabs.tabViewItem(at:0))
   precondition(input.stringValue.isEmpty && !sendButton.isEnabled && !started && key==nil)
   precondition(window.contentView!.frame.width>=900 && localButtons.count==4)
   let semaphore=DispatchSemaphore(value:0);var reachable=false
   var request=URLRequest(url:endpoint.appendingPathComponent("state"));request.setValue("Bearer "+capability,forHTTPHeaderField:"Authorization")
   localSession.dataTask(with:request){data,response,error in reachable=error==nil && (response as? HTTPURLResponse)?.statusCode==200;semaphore.signal()}.resume()
   precondition(semaphore.wait(timeout:.now()+10) == .success && reachable)
   for index in 0..<tabs.numberOfTabViewItems {
    selectPage(navigation[index]);window.contentView!.layoutSubtreeIfNeeded();window.display();RunLoop.current.run(until:Date().addingTimeInterval(0.2))
    let view=window.contentView!;let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds)!;view.cacheDisplay(in:view.bounds,to:bitmap)
    let output=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("VAPE-console-tab-\(index).png")
    try! bitmap.representation(using:.png,properties:[:])!.write(to:output)
    print("OFFSCREEN "+output.path)
   }
   for button in localButtons {precondition(button.frame.width>100 && button.frame.height>10)}
   precondition(sendButton.frame.width>100 && sendButton.frame.height>10)
   window.orderOut(nil)
   tabs.selectTabViewItem(at:0)
   input.stringValue="SYNTHETIC-UI-TEST-NOT-A-REAL-KEY";prepare()
   precondition(synthetic.calls==0 && engine.calls==0 && input.stringValue.isEmpty && sendButton.isEnabled)
   send();send();precondition(synthetic.calls==1 && engine.calls==1 && key==nil && !sendButton.isEnabled)
   cancel();precondition(input.stringValue.isEmpty && !sendButton.isEnabled)
   print("PASS synthetic UI prepare=0, explicit send=1, repeat=0, cancel clears; real calls=0")
   print("PASS console UI: one native window, three tabs, Apple tab selected, blank secure input, send disabled, sandbox loopback reachable, no model calls")
   NSApp.terminate(nil);return
  }
  window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
  timer=Timer.scheduledTimer(withTimeInterval:1,repeats:true){[weak self] _ in self?.refresh()};refresh()
 }
 private func makeStack(_ parent:NSView)->NSStackView {
  let stack=NSStackView();stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=18;stack.translatesAutoresizingMaskIntoConstraints=false;parent.addSubview(stack)
  NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:parent.leadingAnchor,constant:24),stack.trailingAnchor.constraint(equalTo:parent.trailingAnchor,constant:-24),stack.topAnchor.constraint(equalTo:parent.topAnchor,constant:24),stack.bottomAnchor.constraint(lessThanOrEqualTo:parent.bottomAnchor,constant:-16)]);return stack
 }
 private func heading(_ text:String,_ stack:NSStackView){let view=NSTextField(labelWithString:text);view.font = .boldSystemFont(ofSize:27);stack.addArrangedSubview(view)}
 private func label(_ text:String,_ stack:NSStackView){let view=NSTextField(wrappingLabelWithString:text);view.font = .systemFont(ofSize:15);stack.addArrangedSubview(view);view.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive=true}
 private func addLocal(_ title:String,_ action:Selector,_ stack:NSStackView){let button=NSButton(title:title,target:self,action:action);button.bezelStyle = .rounded;stack.addArrangedSubview(button);localButtons.append(button)}
 private func evidence(_ field:NSTextField,_ stack:NSStackView){
  let scroll=NSScrollView();scroll.hasVerticalScroller=true;scroll.borderType = .bezelBorder;stack.addArrangedSubview(scroll);scroll.translatesAutoresizingMaskIntoConstraints=false;scroll.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive=true;scroll.heightAnchor.constraint(equalToConstant:300).isActive=true
  field.font = .monospacedSystemFont(ofSize:13,weight:.regular);field.isSelectable=true;field.frame=NSRect(x:0,y:0,width:850,height:300);scroll.documentView=field
 }
 private func show(_ value:String,_ field:NSTextField){field.stringValue=value;let width=max(700,field.enclosingScrollView?.contentSize.width ?? 850);field.frame.size=NSSize(width:width,height:max(300,field.cell!.cellSize(forBounds:NSRect(x:0,y:0,width:width,height:10000)).height+20))}
 private func action(_ name:String){
  localButtons.forEach{$0.isEnabled=false}
  var request=URLRequest(url:endpoint.appendingPathComponent("action"));request.httpMethod="POST";request.setValue("Bearer "+capability,forHTTPHeaderField:"Authorization");request.setValue("application/json",forHTTPHeaderField:"Content-Type");request.httpBody=try? JSONSerialization.data(withJSONObject:["action":name])
  localSession.dataTask(with:request){[weak self] _,response,error in DispatchQueue.main.async{guard let self=self else{return};if error != nil || (response as? HTTPURLResponse)?.statusCode != 202 {self.show("요청 수락 여부 판정 불가/거부. 자동 재전송하지 않습니다. 상태를 확인하세요.",self.localStatus)};self.refresh()}}.resume()
 }
 private func refresh(){
  var request=URLRequest(url:endpoint.appendingPathComponent("state"));request.setValue("Bearer "+capability,forHTTPHeaderField:"Authorization")
  localSession.dataTask(with:request){[weak self] data,response,error in DispatchQueue.main.async{guard let self=self else{return}
   guard error==nil,(response as? HTTPURLResponse)?.statusCode==200,let data=data,let value=try? JSONSerialization.jsonObject(with:data) as? [String:Any] else {self.localButtons.forEach{$0.isEnabled=false};self.show("로컬 실행 경계에 연결할 수 없습니다. 결과 판정 불가 · 자동 전환 없음.",self.localStatus);return}
   let jobs=value["jobs"] as? [String:Any] ?? [:];let busy=value["phase"] as? String == "running"
   for (index,button) in self.localButtons.enumerated(){let mode=["readiness","apple","besu","mock"][index];button.isEnabled = !busy && (mode=="readiness" || jobs[mode]==nil)}
   var local=value;var localJobs=jobs;localJobs.removeValue(forKey:"mock");local["jobs"]=localJobs
   if let text=try? JSONSerialization.data(withJSONObject:local,options:[.prettyPrinted,.sortedKeys]),let string=String(data:text,encoding:.utf8){let ready=value["readiness"] as? [String:Any];let apple=(ready?["apple"] as? [String:Any])?["status"] as? String ?? "not_checked";let ledger=(ready?["ledger"] as? [String:Any])?["status"] as? String ?? "not_checked"
    let meanings=["disabled":"Apple Intelligence 비활성 · 실제 Apple 실행 차단","not_ready":"Apple 모델 준비 미완료 · 실행 차단","ready":"준비됨","not_checked":"미확인"]
    self.show("Apple: "+(meanings[apple] ?? apple)+"\nBesu 도구: "+ledger+" · 자동 전환 없음\n\n"+string,self.localStatus)}
   if let mock=jobs["mock"],let text=try? JSONSerialization.data(withJSONObject:mock,options:[.prettyPrinted,.sortedKeys]),let string=String(data:text,encoding:.utf8){self.show("모의 전용 — 실제 결과 아님\n"+string,self.mockStatus)}
  }}.resume()
 }
 @objc private func selectPage(_ sender:NSButton){pages.selectTabViewItem(at:sender.tag);for button in navigation{button.state=button===sender ? .on : .off}}
 @objc private func readiness(){action("readiness")}
 @objc private func apple(){action("apple")}
 @objc private func besu(){action("besu")}
 @objc private func mockRun(){action("mock")}
 @objc private func pasteKey(){SecurePaste.userAction(enabled:!started && key==nil && input.isEnabled,focusSecureField:{self.window.makeFirstResponder(self.input)},dispatchStandardPaste:{NSApp.sendAction(Selector(("paste:")),to:nil,from:self.input)})}
 @objc private func prepare(){guard !started,key==nil else{return};let value=input.stringValue;guard CloudDemo.keyFormat(value) else{status.stringValue="키 형식을 확인하세요. 호출 0회.";return};key=value;input.stringValue="";input.isEnabled=false;sendButton.isEnabled=true;status.stringValue="키 준비됨 · 호출 0회. 실제 실행하려면 2번 전송 승인 버튼을 직접 누르세요."}
 @objc private func send(){guard !started,let credential=key else{return};started=true;key=nil;input.stringValue="";sendButton.isEnabled=false;status.stringValue="1등급 차단 및 의도 기록 후 합성 2등급 요청을 1회 실행 중…"
  engine.executeL2(key:credential,approved:true){[weak self] result in DispatchQueue.main.async{guard let self=self else{return};self.status.stringValue="별도 Cloud runID: \(self.engine.runID) · 정책 v1 · 서명 메타데이터 감사 (Besu 아님)\nL1 Cloud 호출 0회 · L2 시도 \(self.engine.calls)회\n결과: \(result.decision) / \(result.delivery) / \(result.reason)\n키 참조 해제 · 자동 재시도 없음\n"+(result.output ?? "응답을 확인하지 못했습니다. 재전송하지 않습니다.")}}
 }
 @objc private func cancel(){key=nil;input.stringValue="";input.isEnabled=false;sendButton.isEnabled=false;started=true;engine.cancel();status.stringValue="취소 · 키 참조 해제. 진행 중이었다면 수신 여부는 판정 불가이며 재시도하지 않습니다."}
 func windowWillClose(_ notification:Notification){timer?.invalidate();localSession.invalidateAndCancel();cancel();NSApp.terminate(nil)}
}
@main enum Main {static func main(){let delegate=ConsoleApp();let app=NSApplication.shared;app.setActivationPolicy(.regular);app.delegate=delegate;app.run()}}
