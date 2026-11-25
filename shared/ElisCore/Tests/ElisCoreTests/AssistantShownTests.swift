import Foundation
import Testing
@testable import ElisCore

@MainActor
struct AssistantShownTests {
    @Test func selectingASessionHidesTheChat() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.selectedSessionID = nil
        store.assistantShown = true

        store.selectedSessionID = session.id

        #expect(store.assistantShown == false)
    }

    @Test func clearingTheSelectionKeepsTheChat() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.selectedSessionID = session.id
        store.assistantShown = true

        store.selectedSessionID = nil

        #expect(store.assistantShown)
    }

    @Test func aRemoteChangeThatSelectsKeepsTheChatAndNoSelection() async {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.selectedSessionID = nil
        store.assistantShown = true

        await store.preservingSelection { store.selectedSessionID = session.id }

        #expect(store.assistantShown)
        #expect(store.selectedSessionID == nil)
    }

    @Test func treeReadsBackAssistantShownOnlyWhenTrue() throws {
        let store = makeStore()
        store.assistantShown = true
        let shown = try String(decoding: JSONEncoder().encode(store.controlTree(paneForeground: { _ in nil })), as: UTF8.self)
        store.assistantShown = false
        let hidden = try String(decoding: JSONEncoder().encode(store.controlTree(paneForeground: { _ in nil })), as: UTF8.self)

        #expect(shown.contains("\"assistantShown\":true"))
        #expect(!hidden.contains("assistantShown"))
    }

    @Test func nilSelectionPersistsTheMostRecentSession() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        store.selectSession(a.id)
        store.selectSession(b.id)

        store.selectedSessionID = nil

        #expect(store.snapshot().selectedSessionID == b.id)
    }
}
