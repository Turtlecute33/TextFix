// SPDX-License-Identifier: GPL-3.0-only
import AppKit

final class PasteboardSnapshot {
    /// One dictionary per pasteboard item, mapping type to the bytes we copied out.
    var items: [[NSPasteboard.PasteboardType: Data]] = []

    /// False when something on the pasteboard could not be captured and will be lost.
    var complete = true

    var isEmpty: Bool { items.allSatisfy(\.isEmpty) }
}

/// Every pasteboard operation the fix pipeline needs.
///
/// The macOS pasteboard is friendlier than the Windows clipboard - no open/close handshake, no
/// global memory handles, and `changeCount` is a reliable sequence number - but the two problems
/// that shaped the Windows code are the same here: a snapshot must not force every lazy promise on
/// the pasteboard to be rendered, and a payload that exists for one paste has no business being
/// archived by the user's clipboard manager.
enum PasteboardBridge {
    /// Total ceiling on what we are willing to copy out and back in. A 40 MB screenshot on the
    /// pasteboard is not worth two 40 MB copies on every fix; above the cap the item is skipped and
    /// the user is told the pasteboard could not be fully restored.
    private static let maxSnapshotBytes = 4 * 1024 * 1024

    /// Deliberately an allow-list rather than an enumeration of everything on the pasteboard -
    /// asking an app like Numbers for all forty types it advertises forces it to render every one
    /// of them, which costs seconds, and the exotic ones are never what the user is holding on to.
    private static let wantedTypes: [NSPasteboard.PasteboardType] = [
        .string, .rtf, .rtfd, .html, .fileURL, .URL, .png, .tiff, .pdf,
    ]

    /// The community convention that clipboard managers honour: an item carrying this type is a
    /// one-paste scratch value and must not be added to their history. Windows has three documented
    /// format names for the same idea; macOS has this.
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    static var changeCount: Int { NSPasteboard.general.changeCount }

    static func text() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    /// Puts `text` on the pasteboard. When `transient` is set the payload is flagged so clipboard
    /// managers leave it alone - correct for the one-paste buffer, wrong when we are deliberately
    /// handing the user their fixed text to paste themselves.
    @discardableResult
    static func setText(_ text: String, transient: Bool, concealed: Bool = false) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string) else { return false }
        if transient {
            item.setString(Self.timestamp(), forType: transientType)
            if concealed { item.setString(Self.timestamp(), forType: concealedType) }
        }
        return pasteboard.writeObjects([item])
    }

    private static func timestamp() -> String {
        String(Int(Date().timeIntervalSince1970))
    }

    static func snapshot() -> PasteboardSnapshot {
        let snapshot = PasteboardSnapshot()
        var budget = maxSnapshotBytes
        guard let items = NSPasteboard.general.pasteboardItems else { return snapshot }

        for item in items {
            var saved: [NSPasteboard.PasteboardType: Data] = [:]
            for type in wantedTypes where item.types.contains(type) {
                guard let data = item.data(forType: type) else {
                    // A promise the owner could not or would not render.
                    snapshot.complete = false
                    continue
                }
                if data.count > budget {
                    snapshot.complete = false
                    continue
                }
                saved[type] = data
                budget -= data.count
            }
            // An item that advertised something we did not ask for still loses that type on
            // restore, and the user deserves to know their clipboard came back thinner.
            if saved.isEmpty && !item.types.isEmpty { snapshot.complete = false }
            snapshot.items.append(saved)
        }
        return snapshot
    }

    static func restore(_ snapshot: PasteboardSnapshot) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        var objects: [NSPasteboardWriting] = []
        for saved in snapshot.items where !saved.isEmpty {
            let item = NSPasteboardItem()
            for (type, data) in saved { item.setData(data, forType: type) }
            objects.append(item)
        }
        if !objects.isEmpty { pasteboard.writeObjects(objects) }
    }

    /// Puts a snapshot back, or clears the pasteboard when the snapshot recorded that there was
    /// nothing there to begin with - leaving our own scratch content behind would be a change the
    /// user never asked for.
    static func restoreOrClear(_ snapshot: PasteboardSnapshot) {
        if snapshot.isEmpty { clear() } else { restore(snapshot) }
    }

    static func clear() {
        NSPasteboard.general.clearContents()
    }

    /// A value nothing else will ever put on the pasteboard. Written before a probing Cmd+C so that
    /// "did the copy happen" becomes "is the marker still there", which is decidable.
    static func newProbeMarker() -> String {
        "TextFixprobe" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    /// Waits for a Cmd+C to land, and returns what it copied.
    ///
    /// `changeCount` alone cannot answer this: it moves on *any* pasteboard write, and on a normal
    /// desktop there are other writers - a clipboard manager, Universal Clipboard - so a bump
    /// proves nothing about our copy. Comparing content cannot answer it either, because copying
    /// the same text twice leaves the pasteboard byte-identical. Writing our own marker first makes
    /// it decidable: if the pasteboard still holds the marker the copy did not happen (the
    /// selection was empty); anything else is what the host copied.
    static func waitForCopy(marker: String, baseline: Int, timeoutMs: Int) -> String? {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        var lastSeen = baseline
        while true {
            let current = changeCount
            if current != lastSeen {
                lastSeen = current
                if let copied = text(), !copied.isEmpty, copied != marker { return copied }
            }
            if Date() >= deadline { return nil }
            // The main thread owns the pasteboard for the length of a capture, so this is a sleep
            // rather than a run-loop spin: letting the run loop turn here would let a second
            // hotkey press re-enter the pipeline mid-probe.
            Thread.sleep(forTimeInterval: 0.004)
        }
    }
}
