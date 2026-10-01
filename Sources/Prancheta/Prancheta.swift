import AppKit
import CryptoKit
import ImageIO
import ServiceManagement
import SQLite3
import SwiftUI

extension NSPasteboard.PasteboardType {
    static let concealed = Self("org.nspasteboard.ConcealedType")
    static let transient = Self("org.nspasteboard.TransientType")
}

extension SHA256.Digest {
    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

struct Item: Identifiable {
    enum Kind: Int32 {
        case text, file, image
    }

    let id: Int64
    let kind: Kind
    let title: String
    let size: Int64
    let folder: URL
    let preview: URL?

    var detail: String {
        kind == .text ? "" : size.formatted(.byteCount(style: .file))
    }
}

@MainActor
@Observable
final class History {
    static let directory = URL.applicationSupportDirectory.appending(path: "Prancheta")
    static let data = directory.appending(path: "data")
    static let files = data.appending(path: "files")
    static let images = data.appending(path: "images")

    private static let schema: Int32 = 5

    var items: [Item] = []

    var query = "" { didSet { reload() } }

    @ObservationIgnored private var changeCount = NSPasteboard.general.changeCount
    @ObservationIgnored private var pending = NSPasteboard.general.changeCount
    @ObservationIgnored private var busy = false

    private let database: OpaquePointer?
    private let insert: OpaquePointer?
    private let known: OpaquePointer?
    private let trim: OpaquePointer?
    private let touch: OpaquePointer?
    private let recent: OpaquePointer?
    private let fetch: OpaquePointer?

    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init() {
        try! FileManager.default.createDirectory(at: History.data, withIntermediateDirectories: true)

        var database: OpaquePointer?
        sqlite3_open(History.directory.appending(path: "history.sqlite").path, &database)

        func prepare(_ sql: String) -> OpaquePointer? {
            var statement: OpaquePointer?
            sqlite3_prepare_v3(database, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &statement, nil)
            return statement
        }

        let version = prepare("PRAGMA user_version")
        sqlite3_step(version)
        let current = sqlite3_column_int(version, 0)
        sqlite3_finalize(version)

        if current != History.schema {
            sqlite3_exec(database, "DROP TABLE IF EXISTS items_fts; DROP TABLE IF EXISTS items; VACUUM; PRAGMA user_version = \(History.schema)", nil, nil, nil)
            History.resetData()
        }

        sqlite3_exec(database, """
            CREATE TABLE IF NOT EXISTS items(id INTEGER PRIMARY KEY, kind INTEGER NOT NULL, content TEXT NOT NULL, size INTEGER NOT NULL, hash TEXT NOT NULL, modified REAL NOT NULL, UNIQUE(kind, hash));
            CREATE VIRTUAL TABLE IF NOT EXISTS items_fts USING fts5(content, content='items', content_rowid='id', tokenize='trigram remove_diacritics 1');
            CREATE TRIGGER IF NOT EXISTS items_ai AFTER INSERT ON items WHEN new.kind != 2 BEGIN
              INSERT INTO items_fts(rowid, content) VALUES (new.id, new.content);
            END;
            CREATE TRIGGER IF NOT EXISTS items_ad AFTER DELETE ON items WHEN old.kind != 2 BEGIN
              INSERT INTO items_fts(items_fts, rowid, content) VALUES ('delete', old.id, old.content);
            END;
            CREATE TRIGGER IF NOT EXISTS items_au AFTER UPDATE ON items WHEN new.kind != 2 BEGIN
              INSERT INTO items_fts(items_fts, rowid, content) VALUES ('delete', old.id, old.content);
              INSERT INTO items_fts(rowid, content) VALUES (new.id, new.content);
            END;
            """, nil, nil, nil)

        insert = prepare("""
            INSERT INTO items(kind, content, size, hash, modified) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(kind, hash) DO UPDATE SET id = (SELECT max(id) FROM items) + 1, content = excluded.content, size = excluded.size, modified = excluded.modified
            """)
        known = prepare("SELECT hash FROM items WHERE kind = 1 AND content = ? AND size = ? AND modified = ?")
        trim = prepare("DELETE FROM items WHERE id <= (SELECT id FROM items ORDER BY id DESC LIMIT 1 OFFSET 1000) RETURNING kind, hash")
        touch = prepare("UPDATE items SET id = (SELECT max(id) FROM items) + 1 WHERE id = ?")
        recent = prepare("SELECT id, kind, iif(kind = 1, content, substr(content, 1, 200)), size, hash, '' FROM items ORDER BY id DESC LIMIT 100")
        fetch = prepare("SELECT content FROM items WHERE id = ?")

        self.database = database

        reload()

        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.busy else { return }

                let pasteboard = NSPasteboard.general
                let count = pasteboard.changeCount
                guard count != self.changeCount else { return }
                guard count == self.pending else { self.pending = count; return }

                self.changeCount = count

                guard pasteboard.availableType(from: [.concealed, .transient]) == nil else { return }

                var jobs: [String] = []
                var entries: [(kind: Item.Kind, content: String, size: Int64, hash: String, modified: Double)] = []

                if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
                    for url in urls.reversed() {
                        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                        let size = Int64(values?.fileSize ?? 0)
                        let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0

                        sqlite3_bind_text(self.known, 1, url.path, -1, self.transient)
                        sqlite3_bind_int64(self.known, 2, size)
                        sqlite3_bind_double(self.known, 3, modified)
                        let hash = sqlite3_step(self.known) == SQLITE_ROW ? String(cString: sqlite3_column_text(self.known, 0)) : ""
                        sqlite3_reset(self.known)

                        if hash.isEmpty {
                            jobs += ["file", url.path]
                        }

                        entries.append((.file, url.path, size, hash, modified))
                    }
                } else if let text = pasteboard.string(forType: .string), !text.isEmpty {
                    entries.append((.text, text, Int64(text.utf8.count), SHA256.hash(data: Data(text.utf8)).hex, 0))
                } else {
                    for (index, item) in pasteboard.pasteboardItems!.enumerated().reversed() {
                        guard let type = item.availableType(from: [.png, .tiff]) else { continue }

                        jobs += ["image", String(index)]
                        entries.append((.image, type.rawValue, 0, "", 0))
                    }
                }

                var hashes = [Substring]().makeIterator()

                if !jobs.isEmpty {
                    let output = History.data.appending(path: "hashes")
                    FileManager.default.createFile(atPath: output.path, contents: nil)

                    let process = Process()
                    process.executableURL = Bundle.main.executableURL
                    process.arguments = jobs
                    process.standardOutput = try! FileHandle(forWritingTo: output)
                    try! process.run()

                    self.busy = true
                    process.waitUntilExit()
                    self.busy = false

                    hashes = try! String(contentsOf: output, encoding: .utf8).split(separator: "\n").makeIterator()
                }

                sqlite3_exec(self.database, "BEGIN", nil, nil, nil)

                for entry in entries {
                    let hash = entry.hash.isEmpty ? String(hashes.next()!) : entry.hash
                    let image = History.images.appending(path: hash).appending(path: "image")
                    let size = entry.kind == .image ? Int64((try? image.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) : entry.size

                    sqlite3_bind_int(self.insert, 1, entry.kind.rawValue)
                    sqlite3_bind_text(self.insert, 2, entry.content, -1, self.transient)
                    sqlite3_bind_int64(self.insert, 3, size)
                    sqlite3_bind_text(self.insert, 4, hash, -1, self.transient)
                    sqlite3_bind_double(self.insert, 5, entry.modified)
                    sqlite3_step(self.insert)
                    sqlite3_reset(self.insert)
                }

                while sqlite3_step(self.trim) == SQLITE_ROW {
                    let kind = Item.Kind(rawValue: sqlite3_column_int(self.trim, 0))!
                    let hash = String(cString: sqlite3_column_text(self.trim, 1))

                    if kind != .text {
                        try? FileManager.default.removeItem(at: (kind == .file ? History.files : History.images).appending(path: hash))
                    }
                }

                sqlite3_reset(self.trim)

                sqlite3_exec(self.database, "COMMIT", nil, nil, nil)

                self.reload()
            }
        }
    }

    func copy(_ item: Item) {
        sqlite3_bind_int64(fetch, 1, item.id)
        sqlite3_step(fetch)
        let content = String(cString: sqlite3_column_text(fetch, 0))
        sqlite3_reset(fetch)

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch item.kind {
        case .text:
            pasteboard.setString(content, forType: .string)
        case .file:
            let clone = try? FileManager.default.contentsOfDirectory(at: item.folder, includingPropertiesForKeys: nil).first { $0.lastPathComponent != "thumbnail.png" }

            pasteboard.writeObjects([(clone ?? URL(filePath: content)) as NSURL])
        case .image:
            busy = true
            try! Process.run(Bundle.main.executableURL!, arguments: ["copy", item.folder.appending(path: "image").path, content]).waitUntilExit()
            busy = false
        }

        changeCount = pasteboard.changeCount

        sqlite3_bind_int64(touch, 1, item.id)
        sqlite3_step(touch)
        sqlite3_reset(touch)

        reload()

        NSApp.keyWindow?.close()
    }

    func clear() {
        let alert = NSAlert()
        alert.messageText = "Clear the history?"
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")

        NSApp.activate()

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        sqlite3_exec(database, "DELETE FROM items; VACUUM", nil, nil, nil)
        History.resetData()

        reload()
    }

    private func reload() {
        let terms = query.split(separator: " ")
        let long = terms.filter { $0.count >= 3 }
        let short = terms.filter { $0.count < 3 }

        var statement = recent

        if !terms.isEmpty {
            var sql = "SELECT items.id, items.kind, iif(items.kind = 1, items.content, substr(items.content, 1, 200)), items.size, items.hash, "
            sql += long.isEmpty ? "'' FROM items WHERE items.kind != 2" : "snippet(items_fts, 0, '', '', '…', 64) FROM items JOIN items_fts ON items_fts.rowid = items.id WHERE items.kind != 2 AND items_fts MATCH ?"
            sql += String(repeating: " AND items.content LIKE ? ESCAPE '\\'", count: short.count)
            sql += " ORDER BY items.id DESC LIMIT 100"

            sqlite3_prepare_v2(database, sql, -1, &statement, nil)

            var index: Int32 = 1

            if !long.isEmpty {
                let match = long.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: " ")
                sqlite3_bind_text(statement, index, match, -1, transient)
                index += 1
            }

            for term in short {
                let pattern = term.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
                sqlite3_bind_text(statement, index, "%\(pattern)%", -1, transient)
                index += 1
            }
        }

        var items: [Item] = []
        items.reserveCapacity(100)

        while sqlite3_step(statement) == SQLITE_ROW {
            let kind = Item.Kind(rawValue: sqlite3_column_int(statement, 1))!
            let content = String(cString: sqlite3_column_text(statement, 2))
            let snippet = String(cString: sqlite3_column_text(statement, 5))

            let title = switch kind {
            case .text: (snippet.isEmpty ? content : snippet).replacing(/\s/, with: " ")
            case .file: URL(filePath: content).lastPathComponent
            case .image: ""
            }

            let folder = (kind == .file ? History.files : History.images).appending(path: String(cString: sqlite3_column_text(statement, 4)))
            let thumbnail = folder.appending(path: "thumbnail.png")
            let preview = kind == .image || (kind == .file && FileManager.default.fileExists(atPath: thumbnail.path)) ? thumbnail : nil

            items.append(Item(
                id: sqlite3_column_int64(statement, 0),
                kind: kind,
                title: title,
                size: sqlite3_column_int64(statement, 3),
                folder: folder,
                preview: preview
            ))
        }

        if statement == recent {
            sqlite3_reset(statement)
        } else {
            sqlite3_finalize(statement)
        }

        self.items = items
    }

    private static func resetData() {
        try! FileManager.default.removeItem(at: data)
        try! FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
    }
}

struct Row: View {
    let title: String
    var detail = ""
    var preview: URL?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                if let preview {
                    Image(nsImage: NSImage(byReferencing: preview))
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 240, maxHeight: 60, alignment: .leading)
                }

                Text(title).lineLimit(1)

                Spacer()

                Text(detail).foregroundStyle(selected ? .white : .secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .frame(minHeight: 22)
            .foregroundStyle(selected ? .white : .primary)
            .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ContentView: View {
    @Bindable var history: History
    @State private var selection: Int64?
    @State private var hovered: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)

                TextField("Search", text: $history.query)
                    .textFieldStyle(.plain)
                    .focused($focused)
            }
            .padding(6)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(history.items) { item in
                            Row(title: item.title, detail: item.detail, preview: item.preview, selected: item.id == selection) { history.copy(item) }
                                .id(item.id)
                                .onHover { if $0 { selection = item.id } }
                        }
                    }
                }
                .onChange(of: selection) { proxy.scrollTo(selection) }
            }

            Divider()

            Row(title: "Clear…", detail: "⌥⌘⌫", selected: hovered == "clear") { history.clear() }
                .keyboardShortcut(.delete, modifiers: [.option, .command])
                .onHover { hovered = $0 ? "clear" : nil }

            Row(title: "Quit", detail: "⌘Q", selected: hovered == "quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
                .onHover { hovered = $0 ? "quit" : nil }
        }
        .padding(6)
        .frame(width: 360, height: 420)
        .onAppear {
            history.query = ""
            focused = true
            selection = history.items.first?.id
        }
        .onChange(of: history.items.first?.id) { selection = history.items.first?.id }
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.return) {
            if let item = history.items.first(where: { $0.id == selection }) { history.copy(item) }

            return .handled
        }
    }

    private func move(_ offset: Int) -> KeyPress.Result {
        let index = history.items.firstIndex { $0.id == selection } ?? -1
        let next = min(max(index + offset, 0), history.items.count - 1)

        if next >= 0 { selection = history.items[next].id }

        return .handled
    }
}

@main
enum Main {
    @MainActor
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count > 1 else { return PranchetaApp.main() }

        let pasteboard = NSPasteboard.general

        if arguments[1] == "copy" {
            pasteboard.clearContents()
            pasteboard.setData(try! Data(contentsOf: URL(filePath: arguments[2]), options: .alwaysMapped), forType: .init(arguments[3]))
            return
        }

        for job in stride(from: 1, to: arguments.count, by: 2) {
            let image = arguments[job] == "image"
            var source = URL(filePath: arguments[job + 1])
            var data: Data?
            var hasher = SHA256()

            if image {
                let item = pasteboard.pasteboardItems![Int(arguments[job + 1])!]
                data = item.data(forType: item.availableType(from: [.png, .tiff])!)!
                hasher.update(data: data!)
            } else if (try? source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                let handle = try! FileHandle(forReadingFrom: source)
                _ = fcntl(handle.fileDescriptor, F_NOCACHE, 1)

                var done = false

                while !done {
                    autoreleasepool {
                        let chunk = try! handle.read(upToCount: 1 << 20) ?? Data()
                        done = chunk.isEmpty
                        hasher.update(data: chunk)
                    }
                }
            } else {
                hasher.update(data: Data(source.path.utf8))
            }

            let hash = hasher.finalize().hex
            print(hash)

            let folder = (image ? History.images : History.files).appending(path: hash)
            guard !FileManager.default.fileExists(atPath: folder.path) else { continue }

            try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

            if image {
                source = folder.appending(path: "image")
                try! data!.write(to: source)
            } else {
                clonefile(source.path, folder.appending(path: source.lastPathComponent).path, 0)
            }

            let options = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 240,
            ] as CFDictionary

            guard let thumbnail = CGImageSourceCreateWithURL(source as CFURL, nil).flatMap({ CGImageSourceCreateThumbnailAtIndex($0, 0, options) }) else { continue }

            let destination = CGImageDestinationCreateWithURL(folder.appending(path: "thumbnail.png") as CFURL, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, thumbnail, nil)
            CGImageDestinationFinalize(destination)
        }
    }
}

struct PranchetaApp: App {
    @State private var history = History()

    init() {
        try? SMAppService.mainApp.register()
    }

    var body: some Scene {
        MenuBarExtra("Prancheta", systemImage: "list.clipboard") {
            ContentView(history: history)
        }
        .menuBarExtraStyle(.window)
    }
}
