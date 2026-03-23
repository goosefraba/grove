import Foundation
import CoreServices

final class DirectoryWatcher {
    typealias Callback = () -> Void

    private var stream: FSEventStreamRef?
    private let callback: Callback
    private let box = WatcherBox()

    private final class WatcherBox {
        weak var watcher: DirectoryWatcher?
    }

    init(url: URL, callback: @escaping Callback) {
        self.callback = callback
        box.watcher = self
        start(url: url)
    }

    deinit {
        stop()
    }

    private func start(url: URL) {
        let path = url.path as CFString
        let paths = [path] as CFArray

        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(box).toOpaque()

        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer
        )

        guard let stream = FSEventStreamCreate(
            nil,
            { _, info, _, _, _, _ in
                guard let info = info else { return }
                let box = Unmanaged<DirectoryWatcher.WatcherBox>.fromOpaque(info).takeUnretainedValue()
                DispatchQueue.main.async {
                    box.watcher?.callback()
                }
            },
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            FSEventStreamCreateFlags(flags)
        ) else { return }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream = stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
