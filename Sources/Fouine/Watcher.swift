import Foundation
import CoreServices

/// Flux FSEvents sur une arborescence (tout le disque en pratique), au niveau fichier.
/// Repart de `since` : les changements survenus pendant que l'app était fermée sont rejoués.
final class Watcher {
    typealias Handler = (_ events: [(path: String, flags: UInt32)], _ lastID: UInt64) -> Void

    private var stream: FSEventStreamRef?
    private let handler: Handler

    init(handler: @escaping Handler) { self.handler = handler }

    deinit { stop() }

    func start(path: String, since: UInt64, queue: DispatchQueue) {
        stop()
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
            guard let info, count > 0 else { return }
            let watcher = Unmanaged<Watcher>.fromOpaque(info).takeUnretainedValue()
            let cPaths = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            var events: [(path: String, flags: UInt32)] = []
            events.reserveCapacity(count)
            for i in 0..<count {
                events.append((String(cString: cPaths[i]), flags[i]))
            }
            watcher.handler(events, ids[count - 1])
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(
            nil, callback, &context, [path] as CFArray, since, 1.0, flags) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }
}
