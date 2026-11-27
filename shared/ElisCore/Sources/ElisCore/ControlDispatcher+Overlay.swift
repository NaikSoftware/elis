import Foundation

extension ControlDispatcher {
    /// Validates the overlay commands before the host resolves the session or touches its slots.
    func dispatchSessionOverlayCommand(_ request: ControlRequest) -> ControlResponse {
        switch request.cmd {
        case .sessionOverlayOpen:
            let command = request.args?.command ?? ""
            let page: HtmlSource?
            switch Self.overlayContent(command: command, args: request.args) {
            case .rejected(let response): return response
            case .program: page = nil
            case .page(let source): page = source
            }
            if let color = request.args?.color, !WatermarkConfig.isValidColorHex(color) {
                return ControlResponse(ok: false, error: "invalid color: \(color) (#rrggbb)")
            }
            let pane: OverlayPane?
            switch parseOverlayPane(request.args?.pane) {
            case .rejected(let response): return response
            case .pane(let parsed): pane = parsed
            }
            if pane != nil, request.args?.sizePercent != nil {
                return ControlResponse(ok: false, error: PaneOverlayError.sizePercentConflict)
            }
            let points = OverlayPointSize(width: request.args?.width, height: request.args?.height)
            if pane != nil, !points.isEmpty {
                return ControlResponse(ok: false, error: PaneOverlayError.pointsConflict)
            }
            if let percent = request.args?.sizePercent, !(1...100).contains(percent) {
                return ControlResponse(ok: false, error: "session.overlay.open: --size-percent must be 1...100")
            }
            if let failure = Self.overlayPointFailure(points) { return failure }
            if !points.isEmpty, request.args?.sizePercent == nil {
                return ControlResponse(ok: false, error: OverlayPointError.needsPercent)
            }
            let textLog = page?.textPath == nil ? nil : Self.textLog(request.args)
            return actions.openSessionOverlay(request.target, window: request.args?.window,
                                              options: ControlSessionOverlayOpenOptions(
                                                command: command,
                                                cwd: page == nil ? request.args?.cwd : nil,
                                                wait: request.args?.wait ?? false,
                                                sizePercent: request.args?.sizePercent,
                                                backgroundColor: request.args?.color,
                                                follow: request.args?.follow ?? false,
                                                pane: pane,
                                                page: page,
                                                navigation: request.args?.navigation ?? false,
                                                javascript: request.args?.javascript ?? false,
                                                chromeless: request.args?.chromeless ?? false,
                                                persistent: request.args?.persistent ?? false,
                                                browse: request.args?.browse ?? false,
                                                points: points,
                                                textLog: textLog
                                              ))
        case .sessionOverlayReload:
            switch parseOverlayPane(request.args?.pane) {
            case .rejected(let response): return response
            case .pane(let pane):
                return actions.reloadSessionOverlay(request.target, window: request.args?.window, pane: pane,
                                                    current: request.args?.current ?? false)
            }
        case .sessionOverlayNavigate:
            guard let navigation = request.args?.to.flatMap(HtmlNavigation.init(rawValue:)) else {
                return ControlResponse(ok: false, error: OverlayHtmlError.navigation)
            }
            switch parseOverlayPane(request.args?.pane) {
            case .rejected(let response): return response
            case .pane(let pane):
                return actions.navigateSessionOverlay(request.target, window: request.args?.window, pane: pane,
                                                      navigation: navigation)
            }
        case .sessionOverlayClose:
            switch parseOverlayPane(request.args?.pane) {
            case .rejected(let response): return response
            case .pane(let pane):
                return actions.closeSessionOverlay(request.target, window: request.args?.window, pane: pane)
            }
        case .sessionOverlayResize:
            // pane overlays are always full, so ANY `--pane` is refused here, valid spelling or not.
            if request.args?.pane != nil {
                return ControlResponse(ok: false, error: PaneOverlayError.resizeUnsupported)
            }
            let wantsFull = request.args?.full == true
            let percent = request.args?.sizePercent
            let points = OverlayPointSize(width: request.args?.width, height: request.args?.height)
            if wantsFull, percent != nil {
                return ControlResponse(ok: false, error: "session.overlay.resize: --full is mutually exclusive with --size-percent")
            }
            if wantsFull, !points.isEmpty {
                return ControlResponse(ok: false, error: OverlayPointError.fullConflict)
            }
            if !wantsFull, percent == nil, points.isEmpty {
                return ControlResponse(ok: false, error: "session.overlay.resize requires --size-percent, --width/--height or --full")
            }
            if let percent, !(1...100).contains(percent) {
                return ControlResponse(ok: false, error: "session.overlay.resize: --size-percent must be 1...100")
            }
            if let failure = Self.overlayPointFailure(points) { return failure }
            if points.isEmpty {
                return actions.resizeSessionOverlay(request.target, window: request.args?.window,
                                                    sizePercent: wantsFull ? nil : percent)
            }
            return actions.resizeSessionOverlay(request.target, window: request.args?.window,
                                                sizePercent: percent, points: points)
        case .sessionOverlayResult:
            if let page = request.args?.page {
                guard let id = UUID(uuidString: page) else { return ControlResponse(ok: false, error: OverlayHtmlError.invalidPageID) }
                return actions.htmlPageResult(id)
            }
            switch parseOverlayPane(request.args?.pane) {
            case .rejected(let response): return response
            case .pane(let pane):
                return actions.sessionOverlayResult(request.target, window: request.args?.window, pane: pane)
            }
        case .sessionOverlaySubmit:
            guard let value = request.args?.value else { return ControlResponse(ok: false, error: OverlayHtmlError.submitValue) }
            switch parseOverlayPane(request.args?.pane) {
            case .rejected(let response): return response
            case .pane(let pane):
                return actions.submitSessionOverlay(request.target, window: request.args?.window, pane: pane, value: value)
            }
        case .sessionOverlayCopy:
            switch parseOverlayPane(request.args?.pane) {
            case .rejected(let response): return response
            case .pane(let pane):
                return actions.copySessionOverlaySelection(request.target, window: request.args?.window, pane: pane)
            }
        case .sessionOverlayText:
            return dispatchSessionOverlayText(request)
        case .sessionOverlayHide, .sessionOverlayShow, .sessionOverlayToggle:
            let mode: OverlayVisibilityMode = request.cmd == .sessionOverlayHide ? .hide
                : (request.cmd == .sessionOverlayShow ? .show : .toggle)
            switch parseOverlayPane(request.args?.pane) {
            case .rejected(let response): return response
            case .pane(let pane):
                return actions.setSessionOverlayVisibility(request.target, window: request.args?.window, pane: pane,
                                                           mode: mode)
            }
        case .sessionOverlayJobRun:
            guard let job = request.target?.trimmedOrNil else {
                return ControlResponse(ok: false, error: "session.overlay.job.run requires a job id")
            }
            guard UUID(uuidString: job) != nil else { return ControlResponse(ok: false, error: "invalid job id") }
            return actions.claimOverlayJob(job, token: request.args?.token)
        case .sessionOverlayPageServe:
            guard let token = request.target?.trimmedOrNil else {
                return ControlResponse(ok: false, error: "session.overlay.page.serve requires a page token")
            }
            guard UUID(uuidString: token) != nil else { return ControlResponse(ok: false, error: "invalid page token") }
            return actions.claimPageServe(token)
        default:
            preconditionFailure("dispatchSessionOverlayCommand called for \(request.cmd.rawValue)")
        }
    }

    enum OverlayContent {
        case rejected(ControlResponse)
        case program
        case page(HtmlSource)
    }

    private static func overlayPointFailure(_ points: OverlayPointSize) -> ControlResponse? {
        guard [points.width, points.height].allSatisfy({ ($0 ?? 1) > 0 }) else {
            return ControlResponse(ok: false, error: OverlayPointError.notPositive)
        }
        return nil
    }

    // the options only a text page takes, refused ahead of any source so a request with no text file is answered
    nonisolated private static func textOnlyRefusal(_ args: ControlArgs?) -> String? {
        guard args?.textFile == nil else { return nil }
        if args?.line != nil { return OverlayHtmlError.lineWithoutText }
        if args?.tail != nil || args?.followFile == true { return OverlayHtmlError.tailWithoutText }
        return nil
    }

    /// overlayPage is `overlayContent` for a host without this dispatcher (the Linux bridge): the page source, nil
    /// for a program, or the refusal text.
    nonisolated public static func overlayPage(command: String, args: ControlArgs?) -> (page: HtmlSource?, error: String?) {
        switch overlayContent(command: command, args: args) {
        case .rejected(let response): return (nil, response.error ?? "invalid arguments")
        case .program: return (nil, nil)
        case .page(let source): return (source, nil)
        }
    }

    nonisolated static func overlayContent(command: String, args: ControlArgs?) -> OverlayContent {
        let reject = { (error: String) in OverlayContent.rejected(ControlResponse(ok: false, error: error)) }
        if let error = textOnlyRefusal(args) { return reject(error) }
        if let image = args?.image {
            guard command.isEmpty, args?.html == nil, args?.url == nil, args?.markdownFile == nil, args?.textFile == nil else {
                return reject(OverlayHtmlError.oneSource)
            }
            return imageContent(image, args: args)
        }
        if let markdown = args?.markdownFile {
            guard command.isEmpty, args?.html == nil, args?.url == nil, args?.textFile == nil else {
                return reject(OverlayHtmlError.oneSource)
            }
            return markdownContent(markdown, args: args)
        }
        if let text = args?.textFile {
            guard command.isEmpty, args?.html == nil, args?.url == nil else { return reject(OverlayHtmlError.oneSource) }
            return textContent(text, args: args)
        }
        switch (args?.html, args?.url) {
        case (nil, nil):
            if args?.navigation == true { return reject(OverlayHtmlError.navigationWithoutPage) }
            if args?.javascript == true { return reject(OverlayHtmlError.javascriptWithoutPage) }
            if args?.chromeless == true { return reject(OverlayHtmlError.chromelessRequiresFile) }
            if args?.persistent == true { return reject(OverlayHtmlError.persistentRequiresURL) }
            if args?.browse == true { return reject(OverlayHtmlError.browseRequiresURL) }
            return command.isEmpty ? reject("session.overlay.open requires a command") : .program
        case (.some, .some):
            return reject(OverlayHtmlError.htmlAndURL)
        case (.some(let html), nil):
            if !command.isEmpty { return reject(OverlayHtmlError.commandAndHtml) }
            if args?.wait == true { return reject(OverlayHtmlError.waitWithHtml) }
            if args?.chromeless == true, args?.navigation == true { return reject(OverlayHtmlError.chromelessWithNavigation) }
            if args?.persistent == true { return reject(OverlayHtmlError.persistentRequiresURL) }
            if args?.browse == true { return reject(OverlayHtmlError.browseRequiresURL) }
            if let error = HtmlOverlay.grantError(file: html, grantRoot: args?.cwd) {
                return reject("session.overlay.open: \(error)")
            }
            return .page(.file(path: html, grantRoot: args?.cwd))
        case (nil, .some(let text)):
            if !command.isEmpty { return reject(OverlayHtmlError.commandAndURL) }
            if args?.wait == true { return reject(OverlayHtmlError.waitWithURL) }
            if args?.cwd != nil { return reject(OverlayHtmlError.cwdWithURL) }
            if args?.chromeless == true, args?.navigation == true { return reject(OverlayHtmlError.chromelessWithNavigation) }
            if args?.chromeless == true, args?.browse == true { return reject(OverlayHtmlError.chromelessWithBrowse) }
            guard let url = HtmlSource.webURL(text) else { return reject(OverlayHtmlError.invalidURL) }
            if args?.chromeless == true, !HtmlSource.isLoopback(text) { return reject(OverlayHtmlError.chromelessRequiresLoopback) }
            return .page(.url(url))
        }
    }

    nonisolated private static func imageContent(_ path: String, args: ControlArgs?) -> OverlayContent {
        let reject = { (error: String) in OverlayContent.rejected(ControlResponse(ok: false, error: error)) }
        let flags = [args?.wait, args?.navigation, args?.javascript, args?.chromeless, args?.persistent, args?.browse]
        if args?.cwd != nil || flags.contains(true) { return reject(OverlayHtmlError.imageOptions) }
        guard path.hasPrefix("/") else { return reject(OverlayHtmlError.imageNotAbsolute) }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard LinkPolicy.imageExtensions.contains(url.pathExtension.lowercased()) else {
            return reject(OverlayHtmlError.imageType)
        }
        return .page(.image(path: url.path))
    }

    nonisolated private static func markdownContent(_ path: String, args: ControlArgs?) -> OverlayContent {
        let reject = { (error: String) in OverlayContent.rejected(ControlResponse(ok: false, error: error)) }
        let flags = [args?.wait, args?.javascript, args?.chromeless, args?.persistent, args?.browse]
        if args?.cwd != nil || flags.contains(true) { return reject(OverlayHtmlError.markdownOptions) }
        guard path.hasPrefix("/") else { return reject(OverlayHtmlError.markdownNotAbsolute) }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard LinkPolicy.markdownExtensions.contains(url.pathExtension.lowercased()) else {
            return reject(OverlayHtmlError.markdownType)
        }
        return .page(.markdown(path: url.path))
    }

    nonisolated private static func textContent(_ path: String, args: ControlArgs?) -> OverlayContent {
        let reject = { (error: String) in OverlayContent.rejected(ControlResponse(ok: false, error: error)) }
        let flags = [args?.wait, args?.navigation, args?.javascript, args?.chromeless, args?.persistent, args?.browse]
        if args?.cwd != nil || flags.contains(true) { return reject(OverlayHtmlError.textOptions) }
        guard path.hasPrefix("/") else { return reject(OverlayHtmlError.textNotAbsolute) }
        if let line = args?.line, line < 1 { return reject(OverlayHtmlError.lineNotPositive) }
        if args?.tail != nil || args?.followFile == true, args?.line != nil { return reject(OverlayHtmlError.tailWithLine) }
        if let tail = args?.tail, !(1...TextPage.maxTail).contains(tail) { return reject(OverlayHtmlError.tailRange) }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard TextPage.isEligible(file: url.path) else { return reject(OverlayHtmlError.textType) }
        return .page(.text(path: url.path, line: args?.line))
    }

    /// textLog is a validated text request's log options, nil for none: a tail alone shows it once, follow-file follows it.
    nonisolated public static func textLog(_ args: ControlArgs?) -> TextLog? {
        let follow = args?.followFile == true
        guard args?.tail != nil || follow else { return nil }
        return TextLog(tail: args?.tail ?? TextPage.defaultTail, follow: follow)
    }

    /// The extent is checked before the pane, so the same flags produce the same first error here and on
    /// `session.text`.
    private func dispatchSessionOverlayText(_ request: ControlRequest) -> ControlResponse {
        let all: Bool
        let lines: Int?
        switch parseBufferExtent(request.args) {
        case .rejected(let response): return response
        case .extent(let parsedAll, let parsedLines):
            all = parsedAll
            lines = parsedLines
        }
        switch parseOverlayPane(request.args?.pane) {
        case .rejected(let response): return response
        case .pane(let pane):
            return actions.readSessionOverlayText(request.target, window: request.args?.window,
                                                  options: ControlSessionOverlayTextOptions(pane: pane,
                                                                                            all: all,
                                                                                            lines: lines))
        }
    }

    /// textPageAction reads `session.overlay.search|follow|wrap|changes|files` arguments ahead of the pane, for this
    /// dispatcher and for a host without it (the Linux bridge): the action, or the refusal text.
    nonisolated public static func textPageAction(_ cmd: Command, args: ControlArgs?) -> (action: TextPageAction?, error: String?) {
        let refuse = { (error: String) in (action: TextPageAction?.none, error: Optional(error)) }
        switch cmd {
        case .sessionOverlaySearch:
            switch (args?.text, args?.to) {
            case (nil, nil): return refuse(OverlayHtmlError.searchRequest)
            case (.some, .some): return refuse(OverlayHtmlError.searchTextWithStep)
            case (let text?, nil):
                return text.isEmpty ? refuse("session.overlay.search: text must not be empty") : (.search(.query(text)), nil)
            case (nil, let to?):
                switch to {
                case "next": return (.search(.next), nil)
                case "prev": return (.search(.previous), nil)
                case "close": return (.search(.close), nil)
                default: return refuse("invalid overlay search direction: \(to)")
                }
            }
        case .sessionOverlayFollow, .sessionOverlayWrap:
            let name = cmd == .sessionOverlayFollow ? "follow" : "wrap"
            guard let mode = ControlToggleMode.parse(args?.mode) else {
                return refuse("invalid overlay \(name) mode: \(args?.mode ?? "toggle")")
            }
            return (cmd == .sessionOverlayFollow ? .follow(mode) : .wrap(mode), nil)
        case .sessionOverlayChanges:
            switch args?.to {
            case "next": return (.changes(forward: true), nil)
            case "prev": return (.changes(forward: false), nil)
            case nil: return refuse("session.overlay.changes requires to next or prev")
            case let to?: return refuse("invalid overlay changes direction: \(to)")
            }
        case .sessionOverlayFiles:
            guard let to = args?.to, !to.isEmpty else { return refuse("session.overlay.files requires to, a file number or path") }
            return (.files(to), nil)
        default:
            return refuse("\(cmd.rawValue) is not a text page command")
        }
    }

    /// dispatchSessionOverlayTextPage runs a text-page command once `textPageAction` and the pane accept it.
    func dispatchSessionOverlayTextPage(_ request: ControlRequest) async -> ControlResponse {
        let parsed = Self.textPageAction(request.cmd, args: request.args)
        guard let action = parsed.action else { return ControlResponse(ok: false, error: parsed.error) }
        let pane: OverlayPane?
        switch parseOverlayPane(request.args?.pane) {
        case .rejected(let response): return response
        case .pane(let parsed): pane = parsed
        }
        let target = request.target, window = request.args?.window
        switch action {
        case .search(let search): return await actions.searchSessionOverlay(target, window: window, pane: pane, request: search)
        case .follow(let mode): return await actions.setSessionOverlayFollow(target, window: window, pane: pane, mode: mode)
        case .wrap(let mode): return await actions.setSessionOverlayWrap(target, window: window, pane: pane, mode: mode)
        case .changes(let forward): return await actions.stepSessionOverlayChanges(target, window: window, pane: pane, forward: forward)
        case .files(let to): return await actions.goSessionOverlayFiles(target, window: window, pane: pane, to: to)
        }
    }
}
