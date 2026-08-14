import Foundation
import ImageIO
import SwiftUI
import UIKit

// MARK: - Frame assembly

/// Pulls whole JPEGs out of a `multipart/x-mixed-replace` byte stream.
///
/// Two things in here are the difference between a live picture and a frozen
/// app, and both of them used to be wrong.
///
/// **Every byte is scanned once.** The old reader searched for the end-of-image
/// marker from the beginning of the buffer on every chunk that arrived, so a
/// frame delivered in a hundred chunks was scanned a hundred times - quadratic
/// in the frame size. A 200 KB webcam frame survives that. A 2 MB frame from a
/// higher-resolution camera does not: it becomes hundreds of megabytes of
/// `memcmp` per second, and everything else in the app stops.
///
/// **Only the newest frame survives.** When several complete frames arrive in
/// one read, the older ones are dropped without ever being decoded. They were
/// about to be painted over anyway, and decoding them is exactly how a stream
/// that falls behind once never catches up.
final class MJPEGFrameAssembler {

    private static let soi = Data([0xFF, 0xD8])   // JPEG start of image
    private static let eoi = Data([0xFF, 0xD9])   // JPEG end of image

    /// A stream that never produces a frame must not grow without limit. This is
    /// generous enough for a 4K JPEG and small enough to notice.
    static let maxBuffer = 16 * 1024 * 1024

    private var buffer = Data()
    /// Index of the start marker of the frame being assembled, once found.
    private var frameStart: Int?
    /// How far the marker search has already reached, so it is never repeated
    /// over bytes that have already been examined.
    private var scanned = 0

    /// Frames thrown away because a newer one arrived in the same read.
    private(set) var dropped = 0

    /// Set when the buffer had to be discarded - the source is almost certainly
    /// not MJPEG.
    private(set) var overflowed = false

    func reset() {
        buffer.removeAll(keepingCapacity: false)
        frameStart = nil
        scanned = 0
        overflowed = false
    }

    /// Feeds in the bytes just read and returns the newest complete JPEG, if the
    /// stream produced one.
    func consume(_ data: Data) -> Data? {
        buffer.append(data)

        if buffer.count > Self.maxBuffer {
            reset()
            overflowed = true
            return nil
        }

        var newest: Data?

        while true {
            if let start = frameStart {
                // Looking for the end of the current frame. The search resumes
                // where it stopped, minus one byte in case the two-byte marker
                // straddles the boundary between two reads.
                let from = max(start + 2, scanned - 1)
                guard from < buffer.count,
                      let end = buffer.range(
                          of: Self.eoi, options: [], in: from..<buffer.endIndex
                      )
                else {
                    scanned = buffer.count
                    break
                }

                if newest != nil { dropped += 1 }
                newest = buffer.subdata(in: start..<end.upperBound)
                buffer.removeSubrange(buffer.startIndex..<end.upperBound)
                frameStart = nil
                scanned = 0
            } else {
                let from = max(0, scanned - 1)
                guard from < buffer.count,
                      let start = buffer.range(
                          of: Self.soi, options: [], in: from..<buffer.endIndex
                      )
                else {
                    // Nothing here begins a frame. Everything but the last byte
                    // is multipart boundary and header noise and can go, which
                    // is what stops the buffer creeping upwards over hours.
                    if buffer.count > 1 {
                        buffer.removeSubrange(buffer.startIndex..<(buffer.endIndex - 1))
                    }
                    scanned = buffer.count
                    break
                }
                frameStart = start.lowerBound
                scanned = start.upperBound
            }
        }

        return newest
    }
}

// MARK: - Decoding

enum MJPEGDecoder {

    /// Decodes to a bitmap no larger than it will be drawn, on whatever thread
    /// calls this - which is never the main one.
    ///
    /// `UIImage(data:)` is the obvious way to do this and the wrong one: it is
    /// lazy, so the real decompression happens later, inside the render pass, on
    /// the main thread. Ten frames a second of a 2 MB JPEG decoded there is an
    /// app that stops responding to touches. ImageIO's thumbnail path does the
    /// work here, at the size actually needed, and hands back something the
    /// renderer can put straight on the screen.
    static func decode(_ data: Data, maxPixelSize: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary
        ) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

// MARK: - The background half

/// Everything that happens on the URLSession delegate queue.
///
/// Kept as its own object so the compiler cannot be talked into letting any of
/// it run on the main actor. `@unchecked Sendable` is honest here and nowhere
/// else: the delegate queue for a single task is serial, and nothing outside the
/// delegate methods ever touches an instance.
private final class MJPEGPipeline: @unchecked Sendable {
    let assembler = MJPEGFrameAssembler()
    private var lastDecodeTime: CFTimeInterval = 0

    let maxPixelSize: CGFloat
    let minimumInterval: CFTimeInterval

    init(maxPixelSize: CGFloat, maxFrameRate: Double) {
        self.maxPixelSize = maxPixelSize
        self.minimumInterval = 1.0 / max(maxFrameRate, 1)
    }

    /// The finished picture, or nil when this read did not complete a frame or
    /// the frame arrived too soon after the last one.
    func consume(_ data: Data) -> UIImage? {
        guard let frame = assembler.consume(data) else { return nil }

        // Rate limit *before* decoding, not after: a frame skipped here costs
        // nothing, and a frame decoded then discarded costs the whole decode.
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastDecodeTime >= minimumInterval else { return nil }
        lastDecodeTime = now

        return MJPEGDecoder.decode(frame, maxPixelSize: maxPixelSize)
    }

    func reset() {
        assembler.reset()
        lastDecodeTime = 0
    }
}

/// Whether a response can possibly contain JPEG frames.
///
/// Checked before a single byte is buffered. An RTSP, HLS or H.264 URL pasted
/// into the MJPEG field used to buffer megabytes in silence and spin forever;
/// now it says what is wrong in one line.
private func mjpegRejection(for response: URLResponse) -> String? {
    let type = (response as? HTTPURLResponse)?
        .value(forHTTPHeaderField: "Content-Type")?
        .lowercased() ?? ""
    guard !type.isEmpty else { return nil }
    if type.contains("multipart") || type.contains("mjpeg") { return nil }
    // A plain image/jpeg is a working camera on the wrong setting - it serves
    // snapshots, not a stream - and that is worth saying separately, because the
    // fix is one tap away rather than a different camera.
    if type.hasPrefix("image/") { return "camera.error.single_image" }
    return "camera.error.not_mjpeg"
}

/// One connection's delegate, owning that connection's pipeline.
///
/// A delegate per connection rather than one shared with the view model, so the
/// buffer and the decoder are reachable *only* from the delegate queue. There is
/// then no shared mutable state to reason about and no isolation to assume: the
/// callbacks do their work where they are called, and hand the result over
/// through these closures.
private final class MJPEGConnectionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    private let pipeline: MJPEGPipeline
    private let onFrame: @Sendable (UIImage, Int) -> Void
    private let onReject: @Sendable (String) -> Void
    private let onFinish: @Sendable (Error?) -> Void

    init(
        maxPixelSize: CGFloat,
        maxFrameRate: Double,
        onFrame: @escaping @Sendable (UIImage, Int) -> Void,
        onReject: @escaping @Sendable (String) -> Void,
        onFinish: @escaping @Sendable (Error?) -> Void
    ) {
        self.pipeline = MJPEGPipeline(maxPixelSize: maxPixelSize, maxFrameRate: maxFrameRate)
        self.onFrame = onFrame
        self.onReject = onReject
        self.onFinish = onFinish
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let key = mjpegRejection(for: response) else {
            completionHandler(.allow)
            return
        }
        completionHandler(.cancel)
        onReject(key)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        // The scan and the JPEG decode both happen right here, on the serial
        // delegate queue. Only the finished bitmap leaves.
        guard let frame = pipeline.consume(data) else {
            if pipeline.assembler.overflowed { onReject("camera.error.not_mjpeg") }
            return
        }
        onFrame(frame, pipeline.assembler.dropped)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        onFinish(error)
    }
}

/// Holds notification observers and unregisters them when it is released.
///
/// A `@MainActor` class cannot tidy up in its own `deinit` - `deinit` is not
/// isolated, so it cannot touch the isolated properties. Handing the tokens to a
/// plain object that dies at the same moment solves that without leaving a
/// registration behind for every camera view that has ever been on screen.
private final class NotificationObserverBag {
    var tokens: [NSObjectProtocol] = []

    deinit {
        let center = NotificationCenter.default
        for token in tokens { center.removeObserver(token) }
    }
}

// MARK: - The stream

/// A live MJPEG view model.
///
/// The public surface is unchanged - `start(url:)`, `stop()`, `image`,
/// `isConnected`, `errorMessage`, `framesReceived` - but nothing behind it runs
/// on the main thread any more except assigning the finished picture.
///
/// It also stops itself when the app leaves the screen and starts again when it
/// comes back. iOS gives a backgrounded app a few seconds of runway, and a
/// decoder still chewing through frames in that window is a way to be killed by
/// the watchdog and look, from the outside, like an app that will not load.
@MainActor
final class MJPEGStream: ObservableObject {

    @Published private(set) var image: UIImage?
    @Published private(set) var isConnected = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var framesReceived = 0
    /// Frames the network delivered that were never drawn because a newer one
    /// had already arrived. A high number is healthy; a high number *while the
    /// picture stutters* means something downstream is too slow.
    @Published private(set) var framesDropped = 0

    /// Longest edge of the decoded bitmap. A 150-point card on a 3x screen needs
    /// 450 pixels, not 4000, and decoding the other fifteen sixteenths of the
    /// image is work whose only product is heat.
    private let maxPixelSize: CGFloat
    /// Ceiling on frames per second actually decoded. A camera happily sending
    /// 30 is sending 30 more than a progress card needs.
    private let maxFrameRate: Double

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var url: URL?

    private var watchdog: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var lastFrameAt = Date.distantPast
    private var retryCount = 0
    private var wantsToRun = false
    private var isSuspendedForBackground = false
    private let lifecycleObservers = NotificationObserverBag()

    /// No frame for this long, on a connection that is still nominally open,
    /// means the camera stopped sending. Reconnecting is the only cure and it is
    /// cheap, so it happens without being asked.
    private static let stallTimeout: TimeInterval = 12

    init(maxPixelSize: CGFloat = 1280, maxFrameRate: Double = 15) {
        self.maxPixelSize = maxPixelSize
        self.maxFrameRate = maxFrameRate
        observeAppLifecycle()
    }

    // MARK: - Control

    func start(url: URL) {
        self.url = url
        wantsToRun = true
        isSuspendedForBackground = false
        retryCount = 0
        errorMessage = nil
        connect()
    }

    func stop() {
        wantsToRun = false
        teardown()
        image = nil
    }

    func snapshot() -> UIImage? { image }

    private func teardown() {
        watchdog?.cancel()
        watchdog = nil
        retry?.cancel()
        retry = nil
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        isConnected = false
    }

    private func connect() {
        guard let url, wantsToRun else { return }
        teardown()
        lastFrameAt = Date()

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        // An MJPEG response never ends, so a resource timeout would kill a
        // perfectly healthy stream on a timer.
        configuration.timeoutIntervalForResource = .greatestFiniteMagnitude
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.networkServiceType = .video

        // All parsing and decoding happens on this queue, which is explicitly
        // not the main one.
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated

        let delegate = MJPEGConnectionDelegate(
            maxPixelSize: maxPixelSize,
            maxFrameRate: maxFrameRate,
            onFrame: { [weak self] frame, dropped in
                Task { @MainActor in self?.deliver(frame, dropped: dropped) }
            },
            onReject: { [weak self] key in
                Task { @MainActor in self?.reject(key) }
            },
            onFinish: { [weak self] error in
                Task { @MainActor in self?.finish(error) }
            }
        )
        // The session retains its delegate until it is invalidated, which
        // `teardown()` always does - so the delegate lives exactly as long as
        // the connection it belongs to.
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
        self.session = session

        var request = URLRequest(url: url)
        request.setValue("multipart/x-mixed-replace", forHTTPHeaderField: "Accept")
        task = session.dataTask(with: request)
        task?.resume()

        startWatchdog()
    }

    /// Reconnects a stalled stream rather than showing a frame from five minutes
    /// ago as though it were live.
    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard let self, !Task.isCancelled else { return }
                guard self.wantsToRun, self.isConnected else { continue }
                guard Date().timeIntervalSince(self.lastFrameAt) > Self.stallTimeout else { continue }
                self.errorMessage = L.t("camera.error.stalled")
                self.isConnected = false
                self.connect()
                return
            }
        }
    }

    private func scheduleRetry() {
        guard wantsToRun, !isSuspendedForBackground else { return }
        retryCount += 1
        let delay = min(pow(2.0, Double(min(retryCount, 4))), 16)
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            guard self.wantsToRun, !self.isSuspendedForBackground else { return }
            self.connect()
        }
    }

    // MARK: - App lifecycle

    /// Handled here rather than at each of the seven call sites, because six of
    /// them would have forgotten.
    private func observeAppLifecycle() {
        let center = NotificationCenter.default
        lifecycleObservers.tokens.append(
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.wantsToRun else { return }
                    self.isSuspendedForBackground = true
                    self.teardown()
                }
            }
        )
        lifecycleObservers.tokens.append(
            center.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.wantsToRun, self.isSuspendedForBackground else { return }
                    self.isSuspendedForBackground = false
                    self.retryCount = 0
                    self.connect()
                }
            }
        )
    }

    // MARK: - Results from the delegate queue

    fileprivate func deliver(_ frame: UIImage, dropped: Int) {
        image = frame
        framesReceived += 1
        framesDropped = dropped
        lastFrameAt = Date()
        isConnected = true
        errorMessage = nil
        retryCount = 0
    }

    fileprivate func reject(_ key: String) {
        errorMessage = L.t(key)
        isConnected = false
        // Not retried: a wrong content type will still be wrong in eight
        // seconds, and reconnecting in a loop would hide the message that says
        // what to change.
        wantsToRun = false
        teardown()
    }

    fileprivate func finish(_ error: Error?) {
        isConnected = false
        guard let error else {
            // A stream that ends cleanly has ended for a reason worth retrying:
            // crowsnest restarting, the Pi rebooting.
            scheduleRetry()
            return
        }
        if (error as NSError).code == NSURLErrorCancelled { return }
        errorMessage = APIError.from(error, host: url?.host ?? "").localizedDescription
        scheduleRetry()
    }
}

// MARK: - Reusable live view

/// Self-contained MJPEG live view, for screens that just want a picture and do
/// not need to own the stream object (the printing screen, the ROI picker).
struct MJPEGView: View {
    let url: URL
    var contentMode: ContentMode = .fit

    @StateObject private var stream: MJPEGStream

    /// Sized for the space it is going into, so a thumbnail does not decode a
    /// full-resolution bitmap it is about to shrink anyway.
    init(
        url: URL,
        contentMode: ContentMode = .fit,
        maxPixelSize: CGFloat = 1280,
        maxFrameRate: Double = 15
    ) {
        self.url = url
        self.contentMode = contentMode
        _stream = StateObject(
            wrappedValue: MJPEGStream(maxPixelSize: maxPixelSize, maxFrameRate: maxFrameRate)
        )
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.06)
            if let image = stream.image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if let message = stream.errorMessage {
                VStack(spacing: 8) {
                    Image(systemName: "video.slash")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                }
            } else {
                ProgressView()
            }
        }
        .task(id: url) {
            stream.start(url: url)
        }
        .onDisappear { stream.stop() }
    }
}
