import AppKit

// Presentation only: observes the existing controller; does not authorize or dispatch.
struct PresentationObservation {
 var appleMode = false, registered = false, busy = false
 var policyVersion: Int? = nil
 var localDecision: String? = nil, localDelivery: String? = nil, cloudDecision: String? = nil
 var calls = 0, auditRecords = 0
 var isolationObserved = false
 var localTitle: String {
  guard appleMode else { return "경로 확인 모드" }
  guard let decision = localDecision else { return "로컬 · 미실행" }
  if decision == "allow" && localDelivery == "received" { return "로컬 · 허용 / 응답 수신" }
  return decision == "deny" ? "로컬 · 차단" : "로컬 · 판정 불가"
 }
 var cloudTitle: String {
  guard let decision = cloudDecision else { return "Cloud · 미실행" }
  return decision == "deny" ? "Cloud · 호출 전 차단" : "Cloud · 결과 확인 필요"
 }
 var step: String { busy ? "02 / 정책 재확인 · 실행 중" : localDecision != nil || cloudDecision != nil ? "03 / 결과와 감사 기록 검토" : registered ? "02 / 모델 경로 선택" : "01 / 합성 파일 선택·등급 등록" }
}
final class PresentationView: NSView {
 override var isFlipped: Bool { true }
 let ledgerValue = NSTextField(wrappingLabelWithString:"허가형 체인: 이 세션 연결·검증 없음")
 let localValue = NSTextField(labelWithString: "")
 let cloudValue = NSTextField(labelWithString: "")
 let auditValue = NSTextField(labelWithString: "")
 let progress = NSTextField(labelWithString: "")
 let policy = NSTextField(labelWithString: "")
 let detail: NSTextField
 let actions: [NSButton]
 private let ink = NSColor(calibratedRed:0.91,green:0.95,blue:0.98,alpha:1)
 private let muted = NSColor(calibratedRed:0.69,green:0.76,blue:0.82,alpha:1)
 private let accent = NSColor(calibratedRed:0.39,green:0.91,blue:0.78,alpha:1)
 init(grade: NSPopUpButton, detail: NSTextField, actions: [NSButton]) {
  self.detail = detail; self.actions = actions
  super.init(frame:NSRect(x:0,y:0,width:1120,height:1000))
  appearance = NSAppearance(named:.darkAqua)
  wantsLayer = true; layer?.backgroundColor = NSColor(calibratedRed:0.035,green:0.065,blue:0.10,alpha:1).cgColor
  let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 20
  stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
  NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:leadingAnchor,constant:36),stack.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-36),stack.topAnchor.constraint(equalTo:topAnchor,constant:30),stack.bottomAnchor.constraint(lessThanOrEqualTo:bottomAnchor,constant:-28)])
  func add(_ view:NSView) { stack.addArrangedSubview(view);view.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive = true }
  add(label("VAPE   /   POLICY & EVIDENCE",size:15,color:accent))
  add(label("읽기 허용 ≠ 반출 허용",size:38,bold:true))
  add(label("같은 파일, 다른 권한. 로컬 처리부터 외부 송신·쓰기까지 독립적으로 확인합니다.",size:18,color:muted))
  policy.font = .monospacedSystemFont(ofSize:15,weight:.medium);policy.textColor = accent;add(policy)
  add(label("정책 매트릭스   /   설명은 승인이나 실행 결과가 아닙니다",size:16,bold:true))
  let rows = NSStackView();rows.orientation = .vertical;rows.alignment = .leading;rows.spacing = 12
  for text in ["L1   로컬 전용       로컬 모델 처리  ·  Cloud 반출 차단", "L2   권한 분리       읽기 허용과 외부 송신 승인은 별개", "L3   행동 분리       원본 쓰기·도구 실행은 별도 승인 필요"] { rows.addArrangedSubview(label(text,size:20,bold:true)) }
  add(panel(rows))
  add(label("이 앱: Cloud 전송·원본 쓰기·도구 실행 비활성. L2/L3 등급만으로 활성화되지 않습니다.",size:15,color:muted))
  progress.font = .boldSystemFont(ofSize:21);progress.textColor = accent;add(progress)
  add(label("01  파일·등급 등록     →     02  정책·모델 경로 확인     →     03  결과·증거 검토",size:16,color:muted))
  let controls = NSStackView();controls.spacing = 12;controls.addArrangedSubview(grade)
  grade.font = .systemFont(ofSize:16);grade.setAccessibilityLabel("등록 또는 변경할 분류 등급")
  for (i,button) in actions.enumerated() {button.bezelStyle = .rounded;button.font = .systemFont(ofSize:15,weight:.semibold);button.setAccessibilityLabel(button.title);if i == 0 {button.keyEquivalent = "o";button.keyEquivalentModifierMask = [.command]};controls.addArrangedSubview(button)}
  add(controls)
  let cards = NSStackView();cards.distribution = .fillEqually;cards.spacing = 14
  for (title,value,caption) in [("실제 실행 관측",localValue,"현재 세션의 모델 결과 · 수신 상태"),("외부 반출 경계",cloudValue,"현재 세션의 Cloud 경로 판정"),("로컬 감사 기록",auditValue,"Ed25519 서명 기록 · 검증 완료와 별개")] {
   let column = NSStackView();column.orientation = .vertical;column.alignment = .leading;column.spacing = 12
   column.addArrangedSubview(label(title,size:14,color:muted));value.font = .boldSystemFont(ofSize:19);value.textColor = ink;column.addArrangedSubview(value);column.addArrangedSubview(label(caption,size:12,color:muted));cards.addArrangedSubview(panel(column))
  };add(cards)
  ledgerValue.font = .boldSystemFont(ofSize:17);ledgerValue.textColor = accent;add(ledgerValue)
  add(label("상태 구분: 실제 = 이번 실행 관측 / 기록된 시연 = 별도 과거 증거 / 미검증 = 확인 없음 / 모의 = 합성 대역\n이 화면은 과거 시연이나 모의 수신을 실제 성공으로 대체하지 않습니다. 통합 모드의 체인 결과는 같은 실행의 서명 검증 후에만 표시합니다.",size:14,color:muted))
  detail.font = .monospacedSystemFont(ofSize:15,weight:.regular);detail.textColor = ink;detail.isSelectable = true
  add(panel(detail))
  add(label("합성 파일만 시연 · UTF-8 .txt ≤ 64 KiB · 파일명·경로·본문은 감사 기록에 포함하지 않음",size:13,color:muted))
  update(PresentationObservation())
 }
 required init?(coder:NSCoder) {fatalError("init(coder:) unavailable")}
 private func label(_ text:String,size:CGFloat,bold:Bool=false,color:NSColor?=nil)->NSTextField {
  let v=NSTextField(wrappingLabelWithString:text);v.font = .systemFont(ofSize:size,weight:bold ? .bold:.regular);v.textColor = color ?? ink;return v
 }
 private func panel(_ body:NSView)->NSView {
  let v=NSView();v.wantsLayer=true;v.layer?.backgroundColor=NSColor(calibratedRed:0.075,green:0.115,blue:0.16,alpha:1).cgColor;v.layer?.cornerRadius=12
  body.translatesAutoresizingMaskIntoConstraints=false;v.addSubview(body)
  NSLayoutConstraint.activate([body.leadingAnchor.constraint(equalTo:v.leadingAnchor,constant:18),body.trailingAnchor.constraint(equalTo:v.trailingAnchor,constant:-18),body.topAnchor.constraint(equalTo:v.topAnchor,constant:16),body.bottomAnchor.constraint(equalTo:v.bottomAnchor,constant:-16)])
  return v
 }
 func update(_ value:PresentationObservation) {
  localValue.stringValue=value.localTitle;cloudValue.stringValue=value.cloudTitle
  auditValue.stringValue="\(value.auditRecords)건 · 검증 미실행"
  policy.stringValue="\(value.appleMode ? "APPLE ON-DEVICE · 실모델 경로" : "METADATA ONLY · 추론 미연결")   |   정책 \(value.policyVersion.map {"v\($0)"} ?? "등록 후 확인")   |   직접 TCP \(value.isolationObserved ? "OS 거부 관측" : "미검증")"
  progress.stringValue=value.step
  for (i,button) in actions.enumerated() {button.isEnabled = !value.busy && (i == 0 || value.registered)}
  layoutSubtreeIfNeeded()
  setFrameSize(NSSize(width:frame.width,height:max(1000,fittingSize.height)))
 }
}
