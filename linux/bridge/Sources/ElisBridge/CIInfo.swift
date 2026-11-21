import ElisCore
import Foundation
#if canImport(Glibc)
import Glibc
#endif

private let tracker = CITracker()

private struct CIReply: Encodable {
    let ci: CIStatus?
    let spans: [CISpan]
}

private struct CISpan: Encodable {
    let text: String
    let bold, italic, code, dim: Bool
    let color: String?
}

/// Each cwd's GitHub CI status and its sidebar line, in order: `[{"ci"?:{…},"spans":[…]}]`, `ci` absent for none.
/// Blocks on `gh` and the filesystem, so the caller runs it off the GUI thread, one call at a time.
@_cdecl("elis_ci_statuses")
public func elisCIStatuses(_ cwdsJSON: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    let cwds = (try? JSONDecoder().decode([String].self, from: Data(String(cString: cwdsJSON).utf8))) ?? []
    let replies = tracker.statuses(cwds: cwds).map { ci in
        CIReply(ci: ci, spans: (ci?.spans ?? []).map {
            CISpan(text: $0.text, bold: $0.bold, italic: $0.italic, code: $0.code, dim: $0.dim, color: $0.color?.rawValue)
        })
    }
    let data = (try? JSONEncoder().encode(replies)) ?? Data("[]".utf8)
    return strdup(String(decoding: data, as: UTF8.self))
}
