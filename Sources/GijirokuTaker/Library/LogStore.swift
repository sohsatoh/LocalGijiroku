import Foundation
import SwiftUI

/// Live ring buffer of stderr output from the running app, exposed to the
/// SwiftUI Log Viewer window. We hook stderr at process start via a pipe and
/// fan the data out to (a) the original stderr (so Console.app / a parent
/// shell still see it), and (b) this @Published `entries` array.
///
/// Why stderr specifically: the codebase already routes the messages we care
/// about (`startRecording`, `MLXClient.chat`, `SummaryEngine.ingest`, audio
/// lifecycle) through `fputs(stderr)` because OSLog `.info`/`.notice` is
/// reliably suppressed when launched from a SwiftPM-built bundle. Hooking
/// the FD lets us surface them in-app without rewriting every call site.
@MainActor
final class LogStore: ObservableObject {
    static let shared = LogStore()

    struct Entry: Identifiable, Hashable {
        let id: UUID
        let timestamp: Date
        let message: String
    }

    @Published private(set) var entries: [Entry] = []

    /// Cap the ring buffer at this many entries; older lines are evicted.
    /// 2000 entries × ~80 chars ≈ 160 KB resident.
    private let maxEntries = 2000

    private var installed = false
    // Retain the pipe + original stderr FD for the lifetime of the process.
    // If the Pipe is released, its FileHandle deinit closes the read end,
    // and the next fputs(stderr) raises SIGPIPE and terminates the app —
    // which is what crashed the Record button after we shipped log capture.
    private var capturePipe: Pipe?
    private var originalStderrFD: Int32 = -1

    private init() {}

    /// Idempotent — safe to call multiple times. Must be called early in the
    /// app lifecycle (App.init) so we don't miss the first burst of fputs
    /// output from MLXClient / SummaryEngine / WhisperTranscription.
    func installStderrCapture() {
        guard !installed else { return }
        installed = true

        // Defensive: even with pipe retention, SIG_IGN'ing SIGPIPE means a
        // write to a broken pipe just returns -1/EPIPE instead of killing
        // the process. Cheap insurance against future regressions.
        signal(SIGPIPE, SIG_IGN)

        originalStderrFD = dup(STDERR_FILENO)
        // Line-buffer so partial writes don't get held in libc buffers when
        // the app isn't attached to a terminal.
        setvbuf(stderr, nil, _IOLBF, 0)

        let pipe = Pipe()
        capturePipe = pipe
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)

        let originalFD = originalStderrFD
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            // Tee to the saved original stderr so the data is still visible
            // outside the app (Console.app routes process stderr).
            data.withUnsafeBytes { ptr in
                _ = write(originalFD, ptr.baseAddress, data.count)
            }
            guard let s = String(data: data, encoding: .utf8) else { return }
            let lines = s.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" }).map(String.init)
            Task { @MainActor [weak self] in
                self?.appendLines(lines)
            }
        }
    }

    private func appendLines(_ lines: [String]) {
        let now = Date()
        for line in lines {
            entries.append(Entry(id: UUID(), timestamp: now, message: line))
        }
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    func clear() {
        entries.removeAll()
    }
}
