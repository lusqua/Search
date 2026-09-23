import AppKit
import SwiftUI
import WebKit

// Rows of tabs that don't share a cookie.
//
// The same sites, signed in as different people — yours, and a client's or
// two — is what a second browser profile is usually for. A Space is that
// without the second window: a name, a row of tabs, and a WebKit store of its
// own, so a sign-in in one is nobody in the others. Switching swaps the row
// and nothing else; the window, the settings, the history, the bookmarks and
// the passwords are the same ones in every Space.
//
// Somebody who never makes a second Space never meets any of this. The first
// one is the store and the session file the browser always had — nothing
// moves, and nothing has to be carried over.

struct Space: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String

    /// The Space that was there before there were Spaces. Its store is
    /// `Store.websites` and its session is session.json, as they always were.
    static let homeID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    static let home = Space(id: homeID, name: "Personal")

    var isHome: Bool { id == Space.homeID }
}

@MainActor
enum Spaces {
    private static var file: URL { Store.file("spaces.json") }

    /// The one new tabs are made in. Kept here rather than handed to every
    /// place that makes a tab, because a tab takes its store when its
    /// configuration is made and keeps it: switching later changes where the
    /// next tab goes, never where an open one already is.
    static var current = Space.homeID

    /// Always at least the first one, and the first one always first.
    static func read() -> [Space] {
        guard let data = try? Data(contentsOf: file) else { return [.home] }
        guard let spaces = try? JSONDecoder().decode([Space].self, from: data) else {
            Store.quarantine(file)
            return [.home]
        }
        let home = spaces.first(where: \.isHome) ?? .home
        return [home] + spaces.filter { !$0.isHome }
    }

    /// A handful of names — written straight away, since a Space made just
    /// before quitting is still a Space the next morning.
    static func write(_ spaces: [Space]) {
        guard let data = try? JSONEncoder().encode(spaces) else { return }
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: file, options: .atomic)
    }

    /// One object per store for the whole run. WebKit shares a warm content
    /// process between views that ask for the same store object, and a fresh
    /// one per tab would cost every tab a process of its own.
    private static var stores: [UUID: WKWebsiteDataStore] = [:]

    static func store(for id: UUID) -> WKWebsiteDataStore {
        if id == Space.homeID { return Store.websites }
        if let known = stores[id] { return known }
        let made = WKWebsiteDataStore(forIdentifier: id)
        stores[id] = made
        return made
    }

    /// Where the tab about to be made keeps its cookies.
    static var store: WKWebsiteDataStore { store(for: current) }

    /// Everything a Space's sites kept, gone with it. WebKit refuses while a
    /// view still holds the store, so this comes after its tabs have closed —
    /// and a refusal leaves the folder behind rather than anything broken.
    static func forget(_ id: UUID) {
        guard id != Space.homeID else { return }
        stores[id] = nil
        Task {
            // A beat for the closed views' processes to let the store go.
            try? await Task.sleep(for: .seconds(1))
            do {
                try await WKWebsiteDataStore.remove(forIdentifier: id)
            } catch {
                NSLog("Spaces: couldn't remove the store of %@: %@", id.uuidString, error.localizedDescription)
            }
        }
    }

    // MARK: - asking

    /// A name, typed. Nil when the question was dismissed or left empty.
    static func askName(title: String, info: String, button: String, filled: String = "") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: filled)
        field.placeholderString = "Work"
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Deleting one takes its sign-ins with it, which is worth a second look.
    static func confirmDelete(_ space: Space) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Delete “\(space.name)”?"
        alert.informativeText = "Its tabs close, and everything its sites kept on this Mac — cookies, sign-ins, caches — is deleted. History, bookmarks and passwords stay."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        return alert.runModal() == .alertFirstButtonReturn
    }
}

// MARK: - at the foot of the column

/// The Spaces along the bottom of the sidebar, a letter each, the way a pin
/// is a letter — the one you're in lit. Only a "+" until there is a second
/// Space to switch to: nobody who never makes one should be made to look at
/// a row of one.
struct SpaceRow: View {
    @ObservedObject var browser: Browser

    var body: some View {
        HStack(spacing: 2) {
            if browser.spaces.count > 1 {
                ForEach(Array(browser.spaces.enumerated()), id: \.element.id) { index, space in
                    SpaceMark(space: space, number: index + 1, live: space.id == browser.spaceID) {
                        browser.enter(space)
                    }
                    .contextMenu {
                        Button("Rename…") { SpaceRow.rename(space, in: browser) }
                        if !space.isHome {
                            Button("Delete…") { if Spaces.confirmDelete(space) { browser.delete(space) } }
                        }
                    }
                }
            }
            Door(icon: "plus", help: "New Space") { SpaceRow.create(in: browser) }
        }
    }

    static func create(in browser: Browser) {
        guard let name = Spaces.askName(
            title: "New Space",
            info: "A row of tabs with sign-ins of its own. History, bookmarks and passwords are shared.",
            button: "Create"
        ) else { return }
        browser.newSpace(named: name)
    }

    static func rename(_ space: Space, in browser: Browser) {
        guard let name = Spaces.askName(
            title: "Rename “\(space.name)”", info: "", button: "Rename", filled: space.name
        ) else { return }
        browser.rename(space, to: name)
    }
}

/// One Space: the first letter of its name, in the same square a Door is.
private struct SpaceMark: View {
    let space: Space
    let number: Int
    let live: Bool
    let act: () -> Void

    @State private var hovering = false

    private var letter: String { space.name.first.map { String($0).uppercased() } ?? "·" }

    var body: some View {
        Button(action: act) {
            Text(letter)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(live ? Palette.ink : (hovering ? Palette.ink.opacity(0.7) : Palette.muted))
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(live ? Palette.wash : (hovering ? Palette.hover : .clear))
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(number <= 9 ? "\(space.name) — ⌃\(number)" : space.name)
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: live)
    }
}
