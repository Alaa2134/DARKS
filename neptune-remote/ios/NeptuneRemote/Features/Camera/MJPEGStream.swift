import Foundation
import SwiftUI
import UIKit

/// Minimal multipart/x-mixed-replace (MJPEG) reader.
///
/// crowsnest / ustreamer / mjpg-streamer all serve `multipart/x-mixed-replace`
/// with JPEG parts. `URLSession` cannot decode that itself, so we scan the byte
/// stream for JPEG SOI/EOI markers and publish each complete frame.
@MainActor
final class MJPEGStream: NSObject, ObservableObject {

    @Published private(set) var image: UIImage?
    @Published private(set) var isConnected = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var framesReceived = 0

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var buffer = Data()
    private var url: URL?

    private static let soi = Data([0xFF, 0xD8])   // JPEG start of image
    private static let eoi = Data([0xFF, 0xD9])   // JPEG end of image
    private static let maxBuffer = 12 * 1024 * 1024

    func start(url: URL) {
        stop()
        self.url = url
        errorMessage = nil
        buffer = Data()

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = .greatestFiniteMagnitude
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session

        var request = URLRequest(url: url)
        request.setValue("multipart/x-mixed-replace", forHTTPHeaderField: "Accept")
        task = session.dataTask(with: request)
        task?.resume()
    }

    func stop() {
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        isConnected = false
        buffer = Data()
    }

    func snapshot() -> UIImage? { image }

    fileprivate func append(_ data: Data) {
        buffer.append(data)
        if buffer.count > Self.maxBuffer {
            // Runaway stream (not actually MJPEG): reset instead of growing forever.
            buffer.removeAll(keepingCapacity: false)
            errorMessage = L.t("camera.error.not_mjpeg")
            return
        }

        while let start = buffer.range(of: Self.soi),
              let end = buffer.range(of: Self.eoi, options: [], in: start.upperBound..<buffer.endIndex) {
            let frameData = buffer.subdata(in: start.lowerBound..<end.upperBound)
            buffer.removeSubrange(buffer.startIndex..<end.upperBound)
            if let frame = UIImage(data: frameData) {
                image = frame
                framesReceived += 1
                isConnected = true
                errorMessage = nil
            }
        }
    }

    fileprivate func fail(_ error: Error?) {
        isConnected = false
        guard let error else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        errorMessage = APIError.from(error, host: url?.host ?? "").localizedDescription
    }
}

extension MJPEGStream: URLSessionDataDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        Task { @MainActor [weak self] in
            self?.append(data)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        Task { @MainActor [weak self] in
            self?.fail(error)
        }
    }
}

// MARK: - Reusable live view

/// Self-contained MJPEG live view, for screens that just want a picture and do
/// not need to own the stream object (the printing screen, the ROI picker).
struct MJPEGView: View {
    let url: URL
    var contentMode: ContentMode = .fit

    @StateObject private var stream = MJPEGStream()

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
