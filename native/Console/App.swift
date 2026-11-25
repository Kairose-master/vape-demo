import AppKit
import CryptoKit
final class PromptEditor:NSTextView {override func draggingEntered(_ sender:NSDraggingInfo)->NSDragOperation{[]};override func performDragOperation(_ sender:NSDraggingInfo)->Bool{false}}
final class ConsoleBackground:NSView {override func draw(_ dirtyRect:NSRect){NSColor.windowBackgroundColor.setFill();dirtyRect.fill();super.draw(dirtyRect)}}
final class ConsoleSyntheticTransport:CloudSending {
 var calls=0
 func send(key:String,body:Data,completion:@escaping(Int?,Data?,Bool)->Void){calls+=1;completion(nil,nil,true)}
 func cancel(){}
}
final class ConsoleApp:NSObject,NSApplicationDelegate,NSWindowDelegate {
 private var fileBridge:FileBridge!;private let attachments=NSPopUpButton();private var attachedFiles=[[String:Any]]()
 private let prompt=PromptEditor(),reply=NSTextField(wrappingLabelWithString:"메시지를 입력하세요. 아직 모델을 호출하지 않았습니다."),route=NSPopUpButton()
 private let fileStatus=NSTextField(wrappingLabelWithString:"로컬 TXT를 가져온 뒤 등급을 저장하고 다시 조회하세요. 등록은 전송 승인이 아닙니다."),grade=NSPopUpButton()
 private var chatBusy=false
 private var localStatus=NSTextField(wrappingLabelWithString:"아직 확인하지 않았습니다. 모델·체인·Cloud 실행 0회. 준비 상태부터 확인하세요.")
 private var mockStatus=NSTextField(wrappingLabelWithString:"명시적으로 실행하기 전에는 모의 결과도 없습니다.")
 private var localSession:URLSession!;private var endpoint:URL!;private var capability="";private var timer:Timer?
 private let uiTest=CommandLine.arguments.contains("--ui-test");private let synthetic=ConsoleSyntheticTransport()
 private var localButtons:[NSButton]=[];private var pages:NSTabView!;private var navigation:[NSButton]=[]
 private let input=NSSecureTextField(),status=NSTextField(wrappingLabelWithString:"")
 private let sendButton=NSButton();private var window:NSWindow!;private var engine:CloudEngine!;private var key:String?;private var started=false
 func applicationDidFinishLaunching(_ notification:Notification){
  NSApp.mainMenu=SecurePaste.menu()
  do{fileBridge=try FileBridge()}catch{NSApp.terminate(nil);return}
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
  window=NSWindow(contentRect:NSRect(x:0,y:0,width:1000,height:960),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false);window.title=CommandLine.arguments.contains("--gui-qa") ? "VAPE · 합성 GUI 검증":"VAPE · 통합 보안 실행 콘솔";window.minSize=NSSize(width:900,height:920);window.delegate=self;window.center()
  window.contentView=ConsoleBackground(frame:window.contentView!.bounds)
  var area=window.contentView!.bounds.insetBy(dx:20,dy:20);area.size.height-=44
  let tabs=NSTabView(frame:area);tabs.tabViewType = .noTabsNoBorder;tabs.autoresizingMask=[.width,.height];window.contentView!.addSubview(tabs);pages=tabs
  let nav=NSStackView(frame:NSRect(x:24,y:window.contentView!.bounds.height-54,width:940,height:32));nav.orientation = .horizontal;nav.spacing=16;nav.autoresizingMask=[.width,.minYMargin];window.contentView!.addSubview(nav)
  for (index,title) in ["감사·체인 상세","모델 설정","모의 진단","감사자","사용자"].enumerated(){let button=NSButton(title:title,target:self,action:#selector(selectPage(_:)));button.tag=index;button.setButtonType(.pushOnPushOff);button.bezelStyle = .rounded;button.state=index==4 ? .on : .off;navigation.append(button)}
  for index in [4,1,3]{nav.addArrangedSubview(navigation[index])}
  func page(_ title:String)->NSView {let item=NSTabViewItem(identifier:title);item.label=title;let view=NSView();item.view=view;tabs.addTabViewItem(item);return view}
  let localPage=page("Apple Local + Besu"),cloudPage=page("OpenAI · 별도 L2 워크플로"),mockPage=page("오프라인 모의 · 명시 선택")
  let filePage=page("감사자"),userPage=page("사용자")
  let user=makeStack(userPage);heading("VAPE",user)
  label("무엇을 도와드릴까요? 모델은 ‘모델 설정’에서 선택합니다. 각 메시지는 별도 실행입니다. 감사자가 미리 등록·등급 저장한 파일만 아래 목록에서 첨부할 수 있습니다.",user)
  let editor=NSScrollView();editor.hasVerticalScroller=true;editor.borderType = .bezelBorder;editor.documentView=prompt;prompt.font = .systemFont(ofSize:17);prompt.isRichText=false;prompt.isVerticallyResizable=true;prompt.autoresizingMask = .width;prompt.textContainer?.widthTracksTextView=true
  user.addArrangedSubview(editor);editor.widthAnchor.constraint(equalTo:user.widthAnchor).isActive=true;editor.heightAnchor.constraint(equalToConstant:130).isActive=true
  attachments.addItem(withTitle:"첨부 없음");user.addArrangedSubview(attachments)
  user.addArrangedSubview(NSButton(title:"등록 파일 목록 새로고침",target:self,action:#selector(loadAttachments)))
  user.addArrangedSubview(NSButton(title:"메시지 보내기",target:self,action:#selector(sendPrompt)))
  evidence(reply,user)
  let file=makeStack(filePage);heading("감사자 · 같은 파일의 보안 확인",file)
  label("① 로컬 TXT 가져오기 → ② 등급 저장 → ③ 저장된 등급 재조회 → ④ 정책·서명 감사 검증\n외부 업로드/모델 전송 없음. 파일이나 등급이 바뀌면 이전 검증은 현재 상태에 적용하지 않습니다.",file)
  file.addArrangedSubview(NSButton(title:"1. 로컬 TXT 가져오기",target:self,action:#selector(selectFile)))
  grade.addItems(withTitles:["L1 · 로컬 전용","L2 · 외부 송신 별도 승인","L3 · 쓰기 별도 승인"]);file.addArrangedSubview(grade)
  file.addArrangedSubview(NSButton(title:"2. 등급 저장 · 사용자 B에게 읽기 허용",target:self,action:#selector(saveGrade)))
  file.addArrangedSubview(NSButton(title:"3. 실제 저장된 등급 조회",target:self,action:#selector(lookupGrade)))
  file.addArrangedSubview(NSButton(title:"4. 같은 파일 정책·서명 감사 검증",target:self,action:#selector(verifyFile)))
  file.addArrangedSubview(NSButton(title:"사용자 B 읽기 권한 철회",target:self,action:#selector(revokeFile)))
  file.addArrangedSubview(NSButton(title:"저장된 감사 이력 재검증",target:self,action:#selector(fileAudit)))
  label("선택 파일의 체인: 미기록 · 현재 이 파일을 위한 앵커 기능은 제공하지 않습니다. ‘감사·체인 상세’의 Besu 검증은 별도 합성 실행이며 이 파일의 체인 증거가 아닙니다.",file)
  let auditTools=NSStackView();auditTools.orientation = .horizontal;auditTools.spacing=12
  auditTools.addArrangedSubview(NSButton(title:"감사·체인 상세",target:self,action:#selector(auditDetails)))
  auditTools.addArrangedSubview(NSButton(title:"명시적 모의 진단",target:self,action:#selector(mockDetails)));file.addArrangedSubview(auditTools)
  evidence(fileStatus,file)
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
  heading("모델 설정",stack)
  route.addItems(withTitles:["Apple · 기기 내 로컬","OpenAI · 외부 클라우드"]);stack.addArrangedSubview(route)
  label("Apple 준비 상태: "+(AppleLocalModel.available() ? "ready":"사용 불가")+"\nOpenAI 모델: "+CloudDemo.model+" · 별도 API 키 필요\n외부 송신은 메시지마다 정확한 내용을 표시하는 확인창에서 직접 승인해야 합니다. 자동 전환·재시도 없음.",stack)
  input.placeholderString="API 키 직접 입력 · 채팅으로 보내지 마세요";input.stringValue="";input.widthAnchor.constraint(equalToConstant:730).isActive=true;input.setAccessibilityElement(false);stack.addArrangedSubview(input)
  stack.addArrangedSubview(NSButton(title:"키 붙여넣기 · 보안 필드에만",target:self,action:#selector(pasteKey)))
  stack.addArrangedSubview(NSButton(title:"1. 키 준비 — 아직 전송하지 않음",target:self,action:#selector(prepare)))
  sendButton.title="2. 위 모델·합성 내용의 OpenAI 1회 전송 승인";sendButton.target=self;sendButton.action=#selector(send);sendButton.isEnabled=false;// Sending happens only from the user screen after exact-content confirmation.
  stack.addArrangedSubview(NSButton(title:"취소 · 키 버리기",target:self,action:#selector(cancel)))
  status.stringValue="키 준비 전 · 실제 호출 0회. 사용자 화면의 전송 버튼에서 내용을 확인한 뒤 승인하세요.";status.widthAnchor.constraint(equalToConstant:730).isActive=true;stack.addArrangedSubview(status)
  tabs.selectTabViewItem(at:4)
  if uiTest {
   window.setFrameOrigin(NSPoint(x:-20000,y:-20000));window.orderBack(nil);window.display()
   RunLoop.current.run(until:Date().addingTimeInterval(0.2))
   window.contentView!.layoutSubtreeIfNeeded()
   precondition(tabs.numberOfTabViewItems==5 && tabs.selectedTabViewItem===tabs.tabViewItem(at:4))
   precondition(input.stringValue.isEmpty && !sendButton.isEnabled && !started && key==nil)
   precondition(window.contentView!.frame.width>=900 && localButtons.count==4)
   var bridgeChecked=false
   fileBridge.call(["action":"list"]){result in precondition(result["status"] as? String=="loaded" && (result["files"] as? [[String:Any]])?.isEmpty==true);bridgeChecked=true}
   let bridgeDeadline=Date().addingTimeInterval(10)
   while !bridgeChecked && Date()<bridgeDeadline {RunLoop.current.run(until:Date().addingTimeInterval(0.05))}
   precondition(bridgeChecked)
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
   precondition(prompt.string.isEmpty && route.indexOfSelectedItem==0)
   window.orderOut(nil)
   tabs.selectTabViewItem(at:0)
   input.stringValue="SYNTHETIC-UI-TEST-NOT-A-REAL-KEY";prepare()
   precondition(synthetic.calls==0 && engine.calls==0 && input.stringValue.isEmpty && sendButton.isEnabled)
   send();send();precondition(synthetic.calls==1 && engine.calls==1 && key==nil && !sendButton.isEnabled)
   cancel();precondition(input.stringValue.isEmpty && !sendButton.isEnabled)
   print("PASS synthetic UI prepare=0, explicit send=1, repeat=0, cancel clears; real calls=0")
   print("PASS console UI: one native window, five screens, user screen selected, blank secure input, send disabled, sandbox loopback reachable, no model calls")
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
   if let file=value["file"],let data=try? JSONSerialization.data(withJSONObject:file,options:[.prettyPrinted,.sortedKeys]),let text=String(data:data,encoding:.utf8){self.show(text,self.fileStatus)}
   let jobs=value["jobs"] as? [String:Any] ?? [:];let busy=value["phase"] as? String == "running"
   for (index,button) in self.localButtons.enumerated(){let mode=["readiness","apple","besu","mock"][index];button.isEnabled = !busy && (mode=="readiness" || jobs[mode]==nil)}
   var local=value;var localJobs=jobs;localJobs.removeValue(forKey:"mock");local["jobs"]=localJobs
   if let text=try? JSONSerialization.data(withJSONObject:local,options:[.prettyPrinted,.sortedKeys]),let string=String(data:text,encoding:.utf8){let ready=value["readiness"] as? [String:Any];let apple=(ready?["apple"] as? [String:Any])?["status"] as? String ?? "not_checked";let ledger=(ready?["ledger"] as? [String:Any])?["status"] as? String ?? "not_checked"
    let meanings=["disabled":"Apple Intelligence 비활성 · 실제 Apple 실행 차단","not_ready":"Apple 모델 준비 미완료 · 실행 차단","ready":"준비됨","not_checked":"미확인"]
    self.show("Apple: "+(meanings[apple] ?? apple)+"\nBesu 도구: "+ledger+" · 자동 전환 없음\n\n"+string,self.localStatus)}
   if let mock=jobs["mock"],let text=try? JSONSerialization.data(withJSONObject:mock,options:[.prettyPrinted,.sortedKeys]),let string=String(data:text,encoding:.utf8){self.show("모의 전용 — 실제 결과 아님\n"+string,self.mockStatus)}
  }}.resume()
 }
 private func fileAction(_ action:String,level:Int?=nil){
  var body:[String:Any]=["action":action];if let level=level{body["level"]=level}
  show("처리 중 · 이전 검증은 현재 상태에 적용하지 않습니다.",fileStatus)
  fileBridge.call(body){[weak self] result in guard let self=self else{return};if let data=try? JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]),let text=String(data:data,encoding:.utf8){self.show(text,self.fileStatus)};self.loadAttachments()}
 }
 @objc private func loadAttachments(){
  fileBridge.call(["action":"list"]){[weak self] result in guard let self=self else{return};self.attachedFiles=result["files"] as? [[String:Any]] ?? [];self.attachments.removeAllItems();self.attachments.addItem(withTitle:"첨부 없음")
   for file in self.attachedFiles {let id=file["resourceID"] as? String ?? "unknown";self.attachments.addItem(withTitle:"L\(file["level"] ?? "?") · "+id+" · r\(file["revision"] ?? "?")")}
  }
 }
 @objc private func auditDetails(){selectPage(navigation[0])}
 @objc private func mockDetails(){selectPage(navigation[2])}
 @objc private func revokeFile(){fileAction("revoke")}
 @objc private func selectFile(){fileAction("select")}
 @objc private func saveGrade(){fileAction("save",level:grade.indexOfSelectedItem+1)}
 @objc private func lookupGrade(){fileAction("lookup")}
 @objc private func verifyFile(){fileAction("verify")}
 @objc private func fileAudit(){fileAction("audit")}
 @objc private func sendPrompt(){
  guard !chatBusy else{return};let text=prompt.string
  guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,text.utf8.count<=65536 else{show("메시지는 1~65536 UTF-8 바이트여야 합니다.",reply);return}
  if attachments.indexOfSelectedItem>0 {
   let file=attachedFiles[attachments.indexOfSelectedItem-1]
   var request:[String:Any]=["action":route.indexOfSelectedItem==0 ? "local":"preview","resourceID":file["resourceID"]!,"revision":file["revision"]!,"prompt":text]
   chatBusy=true;show("첨부 등록 ID와 현재 등급·파일 상태를 검사하고 있습니다…",reply)
   fileBridge.call(request){[weak self] result in guard let self=self else{return}
    if request["action"] as? String=="local" {self.chatBusy=false;let text=result["output"] as? String ?? "";self.show(text.isEmpty ? "처리 거부/판정 불가: "+(result["reason"] as? String ?? "unknown") : text,self.reply);return}
    guard result["status"] as? String=="approval-required",let body=result["body"] as? String,let token=result["token"] as? String else{self.chatBusy=false;self.show("클라우드 전송 차단: "+(result["reason"] as? String ?? "unverified"),self.reply);return}
    guard self.confirmCloud(body),!self.started,let credential=self.key else{self.chatBusy=false;self.show("승인 취소 또는 키 준비 필요 · 전송 0회",self.reply);return}
    request["action"]="commit";request["token"]=token
    self.fileBridge.call(request){[weak self] grant in guard let self=self else{return};guard grant["status"] as? String=="approved-once",let current=grant["body"] as? String,current==body else{self.chatBusy=false;self.show("파일·등급·정책 변경 또는 승인 무효 · 전송 0회",self.reply);return};self.sendCloud(body,key:credential)}
   }
   return
  }
  if route.indexOfSelectedItem==0 {
   guard AppleLocalModel.available() else{show("Apple 시스템 모델 사용 불가 · 설정/자산 준비 상태를 확인하세요. 다른 모델로 전환하지 않았습니다.",reply);return}
   chatBusy=true;show("Apple 기기 내 모델이 응답 중입니다…",reply)
   DispatchQueue.global().async{[weak self] in
    let digest=SHA256.hash(data:Data(text.utf8)).map{String(format:"%02x",$0)}.joined()
    let binding=HandoffBinding(resourceID:UUID(),revision:1,policyVersion:1,level:.one,route:.local,model:"apple-system-default",destinationID:"apple-system-on-device",contentDigest:digest)
    let answer:String
    do{answer=try AppleLocalModel.respond(PrivateModelInput(text:text,binding:binding),expectedDigest:digest,chat:true)}catch{answer="응답 판정 불가: "+((error as? HandoffError)?.rawValue ?? "appleFrameworkError")+" · 자동 재시도 없음"}
    DispatchQueue.main.async{self?.chatBusy=false;if let self=self{self.show(answer,self.reply)}}
   }
  } else {
   guard !started,let credential=key else{show("모델 설정에서 키를 직접 준비하세요. 이 세션에서 이미 1회 전송했다면 자동 재송신하지 않습니다.",reply);return}
   guard confirmCloud(text) else{return}
   sendCloud(text,key:credential)
  }
 }
 private func confirmCloud(_ text:String)->Bool {
   let alert=NSAlert();alert.messageText="OpenAI 외부 전송 1회 승인";alert.informativeText="대상: "+CloudDemo.endpoint.absoluteString+"\n모델: "+CloudDemo.model+"\n아래 메시지와 첨부가 표시된 경우 그 본문 전체를 1회 전송합니다. 등록 파일은 현재 L2일 때만 허용됩니다.";let review=NSScrollView(frame:NSRect(x:0,y:0,width:560,height:260));let body=NSTextView(frame:review.bounds);body.string=text;body.isEditable=false;body.isSelectable=true;body.font = .systemFont(ofSize:15);body.isVerticallyResizable=true;body.autoresizingMask = .width;body.textContainer?.widthTracksTextView=true;review.hasVerticalScroller=true;review.documentView=body;alert.accessoryView=review;alert.addButton(withTitle:"이 내용 1회 전송 승인");alert.addButton(withTitle:"취소")
   return alert.runModal() == .alertFirstButtonReturn

 }
 private func sendCloud(_ text:String,key credential:String){
   started=true;key=nil;input.stringValue="";sendButton.isEnabled=false;chatBusy=true
   do{let support=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0];let audit=try CloudAudit(support.appendingPathComponent("PromptAudit-"+UUID().uuidString));let request=CloudEngine(transport:HTTPSCloud(),audit:{try audit.append($0)},text:text);self.engine=request
    show("승인된 메시지 1회 전송 중…",reply)
    request.executeL2(key:credential,approved:true){[weak self] result in DispatchQueue.main.async{guard let self=self else{return};self.chatBusy=false;self.show(result.output ?? ("판정: "+result.decision+" · "+result.reason+" · 자동 재시도 없음"),self.reply)}}
   }catch{chatBusy=false;show("감사 기록 준비 실패 · 전송하지 않았습니다.",reply)}
 }
 @objc private func selectPage(_ sender:NSButton){pages.selectTabViewItem(at:sender.tag);for button in navigation{button.state=button===sender ? .on : .off}
  fileBridge.call(["action":"role","role":[0,2,3].contains(sender.tag) ? "auditor-a":"user-b"]){[weak self] _ in if sender.tag==4{self?.loadAttachments()}}
 }
 @objc private func readiness(){action("readiness")}
 @objc private func apple(){action("apple")}
 @objc private func besu(){action("besu")}
 @objc private func mockRun(){action("mock")}
 @objc private func pasteKey(){SecurePaste.userAction(enabled:!started && key==nil && input.isEnabled,focusSecureField:{self.window.makeFirstResponder(self.input)},dispatchStandardPaste:{NSApp.sendAction(Selector(("paste:")),to:nil,from:self.input)})}
 @objc private func prepare(){guard !started,key==nil else{return};let value=input.stringValue;guard CloudDemo.keyFormat(value) else{status.stringValue="키 형식을 확인하세요. 호출 0회.";return};key=value;input.stringValue="";input.isEnabled=false;sendButton.isEnabled=true;status.stringValue="키 준비됨 · 호출 0회. 사용자 화면에서 전송 내용을 확인해 승인하세요."}
 @objc private func send(){guard !started,let credential=key else{return};started=true;key=nil;input.stringValue="";sendButton.isEnabled=false;status.stringValue="1등급 차단 및 의도 기록 후 합성 2등급 요청을 1회 실행 중…"
  engine.executeL2(key:credential,approved:true){[weak self] result in DispatchQueue.main.async{guard let self=self else{return};self.status.stringValue="별도 Cloud runID: \(self.engine.runID) · 정책 v1 · 서명 메타데이터 감사 (Besu 아님)\nL1 Cloud 호출 0회 · L2 시도 \(self.engine.calls)회\n결과: \(result.decision) / \(result.delivery) / \(result.reason)\n키 참조 해제 · 자동 재시도 없음\n"+(result.output ?? "응답을 확인하지 못했습니다. 재전송하지 않습니다.")}}
 }
 @objc private func cancel(){key=nil;input.stringValue="";input.isEnabled=false;sendButton.isEnabled=false;started=true;engine.cancel();status.stringValue="취소 · 키 참조 해제. 진행 중이었다면 수신 여부는 판정 불가이며 재시도하지 않습니다."}
 func windowWillClose(_ notification:Notification){timer?.invalidate();localSession.invalidateAndCancel();cancel();NSApp.terminate(nil)}
}
@main enum Main {static func main(){let delegate=ConsoleApp();let app=NSApplication.shared;app.setActivationPolicy(.regular);app.delegate=delegate;app.run()}}
