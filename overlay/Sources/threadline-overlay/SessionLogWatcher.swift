import Foundation
import CoreServices

/// Watches agent JSONL roots and triggers a hot reload when transcripts change.
final class SessionLogWatcher {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "threadline.overlay.fsevents", qos: .userInitiated)
    private var debounce: DispatchWorkItem?
    private var pendingPaths: Set<String> = []
    private let onChange: ([String]) -> Void

    init(onChange: @escaping ([String]) -> Void) {
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
            { _, info, numEvents, eventPaths, _, _ in
                guard let info = info, numEvents > 0 else { return }
                let watcher = Unmanaged<SessionLogWatcher>.fromOpaque(info).takeUnretainedValue()
                let cfArray = unsafeBitCast(eventPaths, to: CFArray.self)
                var paths: [String] = []
                paths.reserveCapacity(numEvents)
                for index in 0..<numEvents {
                    let value = CFArrayGetValueAtIndex(cfArray, index)
                    let path = Unmanaged<CFString>.fromOpaque(value!).takeUnretainedValue() as String
                    paths.append(path)
                }
                watcher.scheduleRefresh(paths: paths)
            },
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.05,
            flags
        ) else { return }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stop() {
        debounce?.cancel()
        debounce = nil
        pendingPaths.removeAll()
        if let stream = stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    private func scheduleRefresh(paths: [String]) {
        guard !paths.isEmpty else { return }
        pendingPaths.formUnion(paths)
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let batch = self.pendingPaths
            self.pendingPaths.removeAll()
            self.onChange(Array(batch))
        }
        debounce = work
        queue.asyncAfter(deadline: .now() + 0.05, execute: work)
    }
}
