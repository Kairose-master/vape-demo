import AppKit
// Standard responder-chain actions only. Never reads NSPasteboard directly.
enum SecurePaste {
 static func menu()->NSMenu {
  let root=NSMenu()
  let appItem=NSMenuItem();let appMenu=NSMenu();appMenu.addItem(withTitle:"종료",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q");appItem.submenu=appMenu;root.addItem(appItem)
  let editItem=NSMenuItem(title:"편집",action:nil,keyEquivalent:"");let edit=NSMenu(title:"편집")
  let paste=NSMenuItem(title:"붙여넣기",action:Selector(("paste:")),keyEquivalent:"v");paste.keyEquivalentModifierMask = .command;edit.addItem(paste)
  let select=NSMenuItem(title:"전체 선택",action:Selector(("selectAll:")),keyEquivalent:"a");select.keyEquivalentModifierMask = .command;edit.addItem(select)
  editItem.submenu=edit;root.addItem(editItem);return root
 }
 static func userAction(enabled:Bool,focusSecureField:()->Bool,dispatchStandardPaste:()->Void){
  guard enabled,focusSecureField() else{return}
  dispatchStandardPaste()
 }
}
