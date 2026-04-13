import Foundation
import CoreServices

final class DirectoryWatcher {
    typealias Callback = ([URL]) -> Void

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
            { _, info, numEvents, eventPathsPointer, eventFlags, _ in
                guard let info = info else { return }
                let box = Unmanaged<DirectoryWatcher.WatcherBox>.fromOpaque(info).takeUnretainedValue()

                let shouldReload = (0 ..< Int(numEvents)).contains { index in
                    let flags = eventFlags[index]
                    let rescanFlags = UInt32(
                        kFSEventStreamEventFlagMustScanSubDirs |
                        kFSEventStreamEventFlagKernelDropped |
                        kFSEventStreamEventFlagUserDropped |
                        kFSEventStreamEventFlagRootChanged
                    )
                    let contentFlags = UInt32(
                        kFSEventStreamEventFlagItemCreated |
                        kFSEventStreamEventFlagItemRemoved |
                        kFSEventStreamEventFlagItemRenamed |
                        kFSEventStreamEventFlagItemModified |
                        kFSEventStreamEventFlagItemFinderInfoMod |
                        kFSEventStreamEventFlagItemXattrMod
                    )
                    return (flags & rescanFlags) != 0 || (flags & contentFlags) != 0
                }

                guard shouldReload else { return }

                let eventPaths = (unsafeBitCast(eventPathsPointer, to: NSArray.self) as? [String] ?? []).map {
                    URL(fileURLWithPath: $0)
                }
                DispatchQueue.main.async {
                    box.watcher?.callback(eventPaths)
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
