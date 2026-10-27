extension PasteboardPutter {
    static func checkRestoration() -> Bool {
        let board = NSPasteboard(name: .init("DictateChecks-\(UUID())"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("dictation", forType: .string)
        restore("previous", on: board, expectedChangeCount: board.changeCount)
        guard board.string(forType: .string) == "previous" else { return false }

        board.clearContents()
        board.setString("dictation", forType: .string)
        let pastedCount = board.changeCount
        board.clearContents()
        board.setString("newly copied text", forType: .string)
        restore("previous", on: board, expectedChangeCount: pastedCount)
        guard board.string(forType: .string) == "newly copied text" else { return false }

        board.clearContents()
        board.setString("dictation", forType: .string)
        restore(nil, on: board, expectedChangeCount: board.changeCount)
        return board.string(forType: .string) == nil
    }
}

@main
struct PasteboardChecks {
    static func main() {
        guard PasteboardPutter.checkRestoration() else {
            FileHandle.standardError.write(Data("Clipboard restoration changed newer content\n".utf8))
            Foundation.exit(1)
        }
        print("Clipboard restoration passed on a private pasteboard; no paste events were sent")
    }
}
