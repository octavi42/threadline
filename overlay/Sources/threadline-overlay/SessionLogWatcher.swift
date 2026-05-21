import Foundation

/// Watches agent JSONL roots and triggers a refresh when transcripts change.
final class SessionLogWatcher {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "threadline.overlay.fsevents", qos: .utility)
    private var debounce: DispatchWorkItem?
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    func start() {
        stop()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.claude/projects",
            "\(home)/.codex/sessions",
            "\(home)/.cursor/projects",
        ]
        let paths = candidates.filter { FileManager.default.fileExists(atPath: $0) }
        guard !paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagWatchRoot
        )

        guard let stream = FSEventStreamCreate(
            nil,
            { _, info, _, _, _, _ in
                guard let info = info else { return }
                let watcher = Unmanaged<SessionLogWatcher>.fromOpaque(info).takeUnretainedValue()
                watcher.scheduleRefresh()
            },
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            flags
        ) else { return }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stop() {
        debounce?.cancel()
        debounce = nil
        if let stream = stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    private func scheduleRefresh() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.onChange()
        }
        debounce = work
        queue.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
}
