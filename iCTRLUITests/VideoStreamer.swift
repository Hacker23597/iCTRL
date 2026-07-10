import Foundation
import Network
import VideoToolbox
import CoreVideo
import CoreMedia
import UIKit

/// Live H.264-in-MPEG-TS screen stream, playable in VLC / QuickTime.
///
/// Architecture for MULTIPLE clients without duplicate work:
///   - `VideoBroadcaster` (singleton) owns ONE capture timer + ONE
///     VTCompressionSession + ONE TSMuxer. It screenshots, encodes, muxes, and
///     fans the resulting TS bytes out to every subscriber. Encoding starts when
///     the first client connects and stops when the last one disconnects.
///   - `VideoStreamer` is a thin per-connection subscriber: it writes the HTTP
///     header, then forwards broadcast TS packets to its own NWConnection, and
///     unsubscribes the instant that connection drops.
///
/// The screenshot source is injected (the test provides a UIImage grabber), so
/// this file has no XCTest dependency.

// MARK: - Broadcaster (shared encoder, one per process)

final class VideoBroadcaster {
    static let shared = VideoBroadcaster()

    /// Sink for lifecycle events — the host wires this to its logBuffer so
    /// `GET /logs` shows encoder starts/stops/failures alongside RPC calls.
    static var onLog: ((String) -> Void)?
    private func log(_ msg: String) {
        NSLog("iCTRL video: %@", msg)
        Self.onLog?("🎥 " + msg)
    }

    private let queue = DispatchQueue(label: "com.openminis.ictrl.video.broadcast")
    private var subscribers: [ObjectIdentifier: (Data) -> Void] = [:]
    private var grabFrame: (() -> UIImage?)?
    private var fps: Double = 2

    private var timer: DispatchSourceTimer?
    private var session: VTCompressionSession?
    private var muxer: TSMuxer?
    private var width = 0, height = 0
    private var frameIndex: Int64 = 0
    /// Cached SPS/PPS from the format description so a client joining mid-stream
    /// (and each keyframe) gets parameter sets.
    private var parameterSets: [Data] = []

    /// Configure the frame source + rate. If encoding is already running with a
    /// different fps, restart the pipeline so the new rate takes effect
    /// immediately (existing subscribers see a fresh keyframe and continue).
    func configure(fps: Double, grabFrame: @escaping () -> UIImage?) {
        queue.async {
            let newFps = max(0.5, min(fps, 10))
            let restart = (self.timer != nil) && (self.fps != newFps)
            self.fps = newFps
            self.grabFrame = grabFrame
            if restart {
                self.log("fps changed to \(newFps) — restarting encoder")
                self.stopEncoding()
                self.startEncoding()
            }
        }
    }

    /// Subscribe a sink (a per-connection sender). Starts the encoder if it's the
    /// first subscriber. Returns a token used to unsubscribe.
    func subscribe(_ sink: @escaping (Data) -> Void, token: ObjectIdentifier) {
        queue.async {
            let wasEmpty = self.subscribers.isEmpty
            self.subscribers[token] = sink
            if wasEmpty { self.startEncoding() }
        }
    }

    func unsubscribe(_ token: ObjectIdentifier) {
        queue.async {
            self.subscribers.removeValue(forKey: token)
            if self.subscribers.isEmpty { self.stopEncoding() }
        }
    }

    // MARK: encoding lifecycle (queue-confined)

    private func startEncoding() {
        guard timer == nil, let grab = grabFrame, let first = grab(), let cg = first.cgImage else {
            log("no first frame — cannot start encoding (grabFrame returned nil)")
            return
        }
        width = cg.width; height = cg.height
        guard setupEncoder(width: width, height: height) else { return }
        muxer = TSMuxer()
        frameIndex = 0
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0 / fps)
        t.setEventHandler { [weak self] in self?.captureAndEncode() }
        timer = t
        t.resume()
        log("encoding started \(width)x\(height) @\(fps)fps")
    }

    private func stopEncoding() {
        timer?.cancel(); timer = nil
        if let s = session { VTCompressionSessionInvalidate(s); session = nil }
        muxer = nil
        parameterSets = []
        log("encoding stopped (no subscribers)")
    }

    private func captureAndEncode() {
        guard let session = session, let grab = grabFrame,
              let image = grab(), let pb = pixelBuffer(from: image) else { return }
        let pts = CMTime(value: frameIndex, timescale: Int32(max(1, fps.rounded())))
        frameIndex += 1
        VTCompressionSessionEncodeFrame(session, imageBuffer: pb, presentationTimeStamp: pts,
                                        duration: .invalid, frameProperties: nil,
                                        sourceFrameRefcon: nil, infoFlagsOut: nil)
    }

    private func fanout(_ data: Data) {
        for sink in subscribers.values { sink(data) }
    }

    // MARK: VideoToolbox

    private func setupEncoder(width: Int, height: Int) -> Bool {
        var s: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: Self.encodeCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(), compressionSessionOut: &s)
        guard status == noErr, let session = s else {
            log("VTCompressionSessionCreate failed status=\(status)")
            return false
        }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_H264_Baseline_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        let kfInterval = max(1, Int(fps * 2))   // keyframe ~every 2s for quick join
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                             value: NSNumber(value: kfInterval))
        VTCompressionSessionPrepareToEncodeFrames(session)
        self.session = session
        return true
    }

    private static let encodeCallback: VTCompressionOutputCallback = { refcon, _, status, _, sampleBuffer in
        guard status == noErr, let refcon = refcon, let sb = sampleBuffer,
              CMSampleBufferDataIsReady(sb) else { return }
        Unmanaged<VideoBroadcaster>.fromOpaque(refcon).takeUnretainedValue().handleEncoded(sb)
    }

    private func handleEncoded(_ sb: CMSampleBuffer) {
        guard let muxer = muxer else { return }
        let notSync = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false)
            as? [[CFString: Any]])?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let isKeyframe = !notSync

        var nalus: [Data] = []
        if isKeyframe {
            if parameterSets.isEmpty, let fmt = CMSampleBufferGetFormatDescription(sb) {
                parameterSets = extractParameterSets(from: fmt)
            }
            nalus.append(contentsOf: parameterSets)
        }
        if let block = CMSampleBufferGetDataBuffer(sb) {
            var lenAt = 0, total = 0; var ptr: UnsafeMutablePointer<Int8>?
            if CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &lenAt,
                                           totalLengthOut: &total, dataPointerOut: &ptr) == noErr, let p = ptr {
                nalus.append(contentsOf: annexBNalus(fromAVCC: p, length: total))
            }
        }
        guard !nalus.isEmpty else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        fanout(muxer.package(nalus: nalus, pts: pts, keyframe: isKeyframe))
    }

    private func extractParameterSets(from fmt: CMFormatDescription) -> [Data] {
        var out: [Data] = []; var count = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0,
            parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        for i in 0..<count {
            var psPtr: UnsafePointer<UInt8>?; var psSize = 0
            if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: i,
                parameterSetPointerOut: &psPtr, parameterSetSizeOut: &psSize,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let p = psPtr {
                out.append(Data(bytes: p, count: psSize))
            }
        }
        return out
    }

    private func annexBNalus(fromAVCC ptr: UnsafeMutablePointer<Int8>, length: Int) -> [Data] {
        var out: [Data] = []
        let u = UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self)
        var i = 0
        while i + 4 <= length {
            let n = Int(u[i]) << 24 | Int(u[i+1]) << 16 | Int(u[i+2]) << 8 | Int(u[i+3])
            i += 4
            if n <= 0 || i + n > length { break }
            out.append(Data(bytes: u + i, count: n))
            i += n
        }
        return out
    }

    private func pixelBuffer(from image: UIImage) -> CVPixelBuffer? {
        guard let cg = image.cgImage else { return nil }
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary, &pb) == kCVReturnSuccess, let buffer = pb else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
                                        CGBitmapInfo.byteOrder32Little.rawValue)
        ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}

// MARK: - Per-connection subscriber

final class VideoStreamer: Hashable {
    static func == (l: VideoStreamer, r: VideoStreamer) -> Bool { l === r }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }

    private let connection: NWConnection
    private var stopped = false
    private var onStop: (() -> Void)?
    private var token: ObjectIdentifier { ObjectIdentifier(self) }

    init(connection: NWConnection) {
        self.connection = connection
    }

    /// Send HTTP headers, then subscribe to the shared broadcast. `onStop` fires
    /// when the client disconnects (server drops the connection then).
    func start(onStop: @escaping () -> Void) {
        self.onStop = onStop
        let header = """
        HTTP/1.1 200 OK\r
        Content-Type: video/mp2t\r
        Cache-Control: no-cache, no-store\r
        Connection: close\r
        Access-Control-Allow-Origin: *\r
        \r

        """
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.stop()
            default: break
            }
        }
        connection.send(content: header.data(using: .utf8), completion: .contentProcessed { [weak self] err in
            guard let self = self else { return }
            if err != nil { self.stop(); return }
            VideoBroadcaster.shared.subscribe({ [weak self] data in self?.send(data) }, token: self.token)
        })
    }

    private func send(_ data: Data) {
        guard !stopped, !data.isEmpty else { return }
        connection.send(content: data, completion: .contentProcessed { [weak self] err in
            if err != nil { self?.stop() }
        })
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        VideoBroadcaster.shared.unsubscribe(token)
        connection.cancel()
        let cb = onStop; onStop = nil
        cb?()
    }
}
