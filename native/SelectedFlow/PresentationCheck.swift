import AppKit

@main enum PresentationCheck {
 static func main() throws {
  var observation = PresentationObservation()
  precondition(observation.localTitle == "경로 확인 모드")
  observation.appleMode=true
  precondition(observation.localTitle == "로컬 · 미실행" && observation.cloudTitle == "Cloud · 미실행")
  observation.localDecision="allow";observation.localDelivery="unknown"
  precondition(observation.localTitle == "로컬 · 판정 불가")
  observation.localDelivery="received"
  precondition(observation.localTitle == "로컬 · 허용 / 응답 수신")
  observation.localDecision="indeterminate"
  precondition(observation.localTitle == "로컬 · 판정 불가")
  observation.cloudDecision="deny"
  precondition(observation.cloudTitle == "Cloud · 호출 전 차단")
  observation.busy=true;precondition(observation.step.contains("실행 중"))
  print("PASS: presentation state assertions; no models, servers, files or credentials accessed")
  guard CommandLine.arguments.count > 1 else{return}
  let app=NSApplication.shared;app.setActivationPolicy(.prohibited)
  let grade=NSPopUpButton();grade.addItems(withTitles:["L1 · 로컬 전용","L2 · 읽기/반출 분리","L3 · 쓰기 별도 승인"])
  let detail=NSTextField(wrappingLabelWithString:"OFFSCREEN DESIGN FIXTURE · 실제 실행 아님\n등록 전 · 이번 실행의 새 합성 파일을 선택하세요.\n파일명·경로·본문은 감사 기록에 표시하지 않습니다.")
  let actions=["파일 등록","등급 변경","로컬 실제 추론","Cloud 차단 확인"].map {NSButton(title:$0,target:nil,action:nil)}
  let view=PresentationView(grade:grade,detail:detail,actions:actions)
  var initial=PresentationObservation();initial.appleMode=true;view.update(initial)
  precondition(actions[0].isEnabled && !actions[1].isEnabled && !actions[2].isEnabled)
  initial.registered=true;initial.busy=true;view.update(initial)
  precondition(actions.allSatisfy {!$0.isEnabled})
  initial.busy=false;initial.registered=false;view.update(initial)
  view.layoutSubtreeIfNeeded()
  guard let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) else {fatalError("Offscreen bitmap unavailable")}
  view.cacheDisplay(in:view.bounds,to:bitmap)
  guard let png=bitmap.representation(using:.png,properties:[:]) else {fatalError("PNG unavailable")}
  try png.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
  initial.registered=true;initial.policyVersion=1;initial.localDecision="allow";initial.localDelivery="received";initial.cloudDecision="deny";initial.auditRecords=3
  view.update(initial)
  detail.stringValue="OFFSCREEN DESIGN FIXTURE · 합성 상태 입력 / 실제 추론 증거 아님\n허용·수신 및 차단 카드의 긴 문구 배치를 확인하는 디자인 테스트입니다."
  view.layoutSubtreeIfNeeded()
  guard let resultBitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) else {fatalError("bitmap unavailable")}
  view.cacheDisplay(in:view.bounds,to:resultBitmap)
  try resultBitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[1]+".result.png"))
  detail.stringValue=String(repeating:"합성 긴 응답 · 스크롤 검증\n",count:80)
  view.update(initial)
  precondition(view.frame.height > 1000, "Long output must expand the scroll document")
  print("PASS: long output expands scroll document")
  print("PASS: offscreen fixture rendered; no visible window, CUA, AX or screen capture")
 }
}
