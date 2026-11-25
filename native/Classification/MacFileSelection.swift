import AppKit
import Foundation

struct MacUserFileSelection: UserFileSelection {
    func chooseFile() throws -> URL? {
        guard Thread.isMainThread else { throw RegistryError.invalidRequest }
        let panel = NSOpenPanel()
        panel.title = "파일 등록 및 등급 지정"
        panel.message = "선택한 파일을 읽기 전용으로 등록합니다. 등록은 모델 전송 승인이 아닙니다."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
struct MacSelectedFileAccess: SelectedFileAccess {
    func begin(_ url: URL) -> Bool { url.startAccessingSecurityScopedResource() }
    func end(_ url: URL) { url.stopAccessingSecurityScopedResource() }
    func makeBookmark(_ url: URL) throws -> Data {
        do { return try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil) }
        catch { throw RegistryError.unavailable }
    }
    func resolve(_ bookmark: Data) throws -> (url: URL, stale: Bool) {
        var stale = false
        let url: URL
        do { url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale) }
        catch { throw RegistryError.unavailable }
        return (url, stale)
    }
}
