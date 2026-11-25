import AppKit

// Display-only, process-memory history. Never Codable, persisted, or used to build model input.
struct ChatMessage {
 let id=UUID();let sender:String;let route:String;var text:String
}
struct ChatConversation {
 let id=UUID();var title="새 대화";var messages=[ChatMessage]()
}
final class ChatDocument:NSView {
 override var isFlipped:Bool{true}
}
final class ChatWorkspace:NSView {
 private(set) var conversations=[ChatConversation()]
 private(set) var selected=0
 private var responseID:UUID?
 var canNavigate:()->Bool={true};var didNavigate:()->Void={}
 let composer=NSStackView()
 private let timeline=NSScrollView(),document=ChatDocument(),sidebar=NSStackView()
 private let historyScroll=NSScrollView(),historyDocument=ChatDocument()
 private var renderedWidth:CGFloat=0
 override init(frame:NSRect){super.init(frame:frame)
  let left=NSStackView();left.orientation = .vertical;left.alignment = .leading;left.spacing=14
  let title=NSTextField(labelWithString:"VAPE");title.font = .boldSystemFont(ofSize:25);left.addArrangedSubview(title)
  let fresh=NSButton(title:"＋ 새 대화",target:self,action:#selector(newChat));fresh.bezelStyle = .rounded;left.addArrangedSubview(fresh)
  let note=NSTextField(wrappingLabelWithString:"이 세션의 대화\n앱 종료 시 사라집니다.");note.font = .systemFont(ofSize:12);note.textColor = .secondaryLabelColor;left.addArrangedSubview(note)
  sidebar.orientation = .vertical;sidebar.alignment = .leading;sidebar.spacing=8
  historyScroll.hasVerticalScroller=true;historyScroll.drawsBackground=false;historyScroll.documentView=historyDocument;left.addArrangedSubview(historyScroll)
  let right=NSStackView();right.orientation = .vertical;right.alignment = .leading;right.spacing=12
  let heading=NSTextField(labelWithString:"대화");heading.font = .boldSystemFont(ofSize:24);right.addArrangedSubview(heading)
  let privacy=NSTextField(wrappingLabelWithString:"이력은 화면 표시용입니다. 이전 대화는 다음 요청에 자동 전송되지 않습니다.");privacy.font = .systemFont(ofSize:12);privacy.textColor = .secondaryLabelColor;right.addArrangedSubview(privacy)
  timeline.hasVerticalScroller=true;timeline.drawsBackground=false;timeline.documentView=document;right.addArrangedSubview(timeline)
  composer.orientation = .vertical;composer.alignment = .leading;composer.spacing=8;right.addArrangedSubview(composer)
  for view in [left,right]{view.translatesAutoresizingMaskIntoConstraints=false;addSubview(view)}
  NSLayoutConstraint.activate([left.leadingAnchor.constraint(equalTo:leadingAnchor,constant:12),left.topAnchor.constraint(equalTo:topAnchor,constant:16),left.bottomAnchor.constraint(equalTo:bottomAnchor,constant:-16),left.widthAnchor.constraint(equalToConstant:185),right.leadingAnchor.constraint(equalTo:left.trailingAnchor,constant:22),right.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-16),right.topAnchor.constraint(equalTo:topAnchor,constant:16),right.bottomAnchor.constraint(equalTo:bottomAnchor,constant:-16),timeline.widthAnchor.constraint(equalTo:right.widthAnchor),timeline.heightAnchor.constraint(greaterThanOrEqualToConstant:200),composer.widthAnchor.constraint(equalTo:right.widthAnchor),historyScroll.widthAnchor.constraint(equalTo:left.widthAnchor),historyScroll.heightAnchor.constraint(greaterThanOrEqualToConstant:200)])
  timeline.setContentHuggingPriority(.defaultLow,for:.vertical);historyScroll.setContentHuggingPriority(.defaultLow,for:.vertical)
  updateHistory()
 }
 required init?(coder:NSCoder){fatalError("Not supported")}
 override func layout(){super.layout();if abs(timeline.contentSize.width-renderedWidth)>1{render(scrollToEnd:false)}}
 @objc func newChat(){guard canNavigate() else{return};conversations.append(ChatConversation());selected=conversations.count-1;responseID=nil;didNavigate();updateHistory();render()}
 @objc private func choose(_ button:NSButton){open(button.tag)}
 func open(_ index:Int){guard canNavigate(),conversations.indices.contains(index) else{return};selected=index;responseID=nil;didNavigate();updateHistory();render()}
 func begin(_ text:String,route:String,attachment:String){
  if conversations[selected].messages.isEmpty{conversations[selected].title=String(text.replacingOccurrences(of:"\n",with:" ").prefix(24))}
  conversations[selected].messages.append(ChatMessage(sender:"나",route:route+(attachment.isEmpty ? "":" · "+attachment),text:text))
  let response=ChatMessage(sender:"VAPE",route:route,text:"요청 확인 중…");conversations[selected].messages.append(response);responseID=response.id;updateHistory();render()
 }
 func beginEvidence(){let message=ChatMessage(sender:"검증",route:"같은 실행 · 로컬 Besu",text:"검증 준비 중…");conversations[selected].messages.append(message);responseID=message.id;render()}
 func notice(_ text:String){responseID=nil;update(text)}
 func update(_ text:String){
  if let id=responseID,let index=conversations[selected].messages.firstIndex(where:{$0.id==id}){conversations[selected].messages[index].text=text}
  else {let message=ChatMessage(sender:"VAPE",route:"안내",text:text);conversations[selected].messages.append(message);responseID=message.id}
  render()
 }
 private func updateHistory(){
  historyDocument.subviews.forEach{$0.removeFromSuperview()}
  for (index,conversation) in conversations.enumerated(){let button=NSButton(title:(index==selected ? "● ":"")+"\(index+1). "+conversation.title,target:self,action:#selector(choose(_:)));button.tag=index;button.bezelStyle = .rounded;button.alignment = .left;button.setAccessibilityLabel("대화 \(index+1): "+conversation.title);button.frame=NSRect(x:0,y:CGFloat(index)*40+4,width:175,height:32);historyDocument.addSubview(button)}
  historyDocument.frame=NSRect(x:0,y:0,width:185,height:max(220,CGFloat(conversations.count)*40+8))
 }
 private func render(scrollToEnd:Bool=true){
  let width=max(400,timeline.contentSize.width);renderedWidth=timeline.contentSize.width
  document.subviews.forEach{$0.removeFromSuperview()};var y:CGFloat=12
  let messages=conversations[selected].messages
  if messages.isEmpty{let empty=NSTextField(wrappingLabelWithString:"무엇을 도와드릴까요?\n아래에 질문을 입력하세요. 등록 파일은 감사자가 허용한 목록에서만 첨부할 수 있습니다.");empty.font = .systemFont(ofSize:19);empty.frame=NSRect(x:20,y:24,width:width-40,height:100);document.addSubview(empty);y=150}
  for message in messages {
   let mine=message.sender=="나",cardWidth=width-44,x:CGFloat=mine ? 32:8
   let card=NSView();card.wantsLayer=true;card.layer?.cornerRadius=12;card.layer?.backgroundColor=(mine ? NSColor.controlAccentColor.withAlphaComponent(0.12):NSColor.controlBackgroundColor).cgColor
   let blocked=message.text.contains("차단") || message.text.contains("판정 불가") || message.text.contains("거부")
   let header=NSTextField(labelWithString:message.sender+"  ·  "+message.route+(blocked ? "  ·  차단/확인 필요":""));header.font = .systemFont(ofSize:12,weight:.semibold);header.textColor=blocked ? .systemOrange:.secondaryLabelColor
   let body=NSTextField(wrappingLabelWithString:message.text);body.font = .systemFont(ofSize:16);body.isSelectable=true
   let bodyWidth=cardWidth-28,height=max(24,body.cell!.cellSize(forBounds:NSRect(x:0,y:0,width:bodyWidth,height:100000)).height)
   card.frame=NSRect(x:x,y:y,width:cardWidth,height:height+54);header.frame=NSRect(x:14,y:height+27,width:bodyWidth,height:18);body.frame=NSRect(x:14,y:14,width:bodyWidth,height:height);card.addSubview(header);card.addSubview(body);document.addSubview(card);y+=card.frame.height+14
  }
  document.frame=NSRect(x:0,y:0,width:width,height:max(y,timeline.contentSize.height))
  if scrollToEnd{timeline.contentView.scroll(to:NSPoint(x:0,y:max(0,y-timeline.contentSize.height)));timeline.reflectScrolledClipView(timeline.contentView)}
 }
}
