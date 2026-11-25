import AppKit
@main enum PasteTests {
 static func main(){
  _ = NSApplication.shared // No window, activation, clipboard or key event.
  let menu=SecurePaste.menu();let edit=menu.items[1].submenu!;let paste=edit.items[0]
  precondition(paste.action==Selector(("paste:")) && paste.target==nil && paste.keyEquivalent=="v" && paste.keyEquivalentModifierMask == .command)
  var focuses=0,dispatches=0
  SecurePaste.userAction(enabled:false,focusSecureField:{focuses+=1;return true},dispatchStandardPaste:{dispatches+=1})
  precondition(focuses==0 && dispatches==0)
  SecurePaste.userAction(enabled:true,focusSecureField:{focuses+=1;return false},dispatchStandardPaste:{dispatches+=1})
  precondition(focuses==1 && dispatches==0)
  SecurePaste.userAction(enabled:true,focusSecureField:{focuses+=1;return true},dispatchStandardPaste:{dispatches+=1})
  precondition(focuses==2 && dispatches==1)
  print("PASS secure paste: 4 checks; menu wiring + focus/disabled stubs; no clipboard or OS shortcut used")
 }
}
