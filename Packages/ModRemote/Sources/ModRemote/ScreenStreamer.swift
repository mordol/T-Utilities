import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import ScreenCaptureKit
import VideoToolbox

/// Host side video: captures the main display with ScreenCaptureKit (only changed frames arrive, so an idle screen
/// costs almost nothing), encodes H.264 for low latency and hands the messages to `send`.
///
/// Latest frame wins: one frame is encoded/sent at a time. Frames arriving meanwhile replace each other, and the
/// newest is encoded once the previous one is on its way, so a slow link drops frames instead of piling up delay.
/// Everything below runs on `queue`.
final class ScreenStreamer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static let frameRate: Int32 = 30

    typealias Send = @Sendable (RemoteMessage, _ completion: @escaping @Sendable () -> Void) -> Void

    private let queue = DispatchQueue(label: "com.taegyu.tutilities.remote.capture", qos: .userInteractive)
    private let send: Send
    private let onFailure: @Sendable (String) -> Void

    private var stream: SCStream?
    private var encoder: VTCompressionSession?
    private var maxWidth = 1920
    private var size = (width: 0, height: 0)
    private var isBusy = false
    private var pending: CVPixelBuffer?
    private var lastFrame: CVPixelBuffer?
    private var forceKeyFrame = true
    private var sentConfig: (width: Int, height: Int, parameterSets: [Data])?
    private var isStopped = false

    init(send: @escaping Send, onFailure: @escaping @Sendable (String) -> Void) {
        self.send = send
        self.onFailure = onFailure
    }

    func start(maxWidth: Int) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mainID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first else {
            throw RemoteProtocolError(message: "캡처할 디스플레이가 없습니다")
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let scale = CGFloat(filter.pointPixelScale)
        let pixels = (width: Int(filter.contentRect.width * scale), height: Int(filter.contentRect.height * scale))
        let configuration = queue.sync {
            self.maxWidth = maxWidth
            self.displayPixelSize = pixels
            return self.makeConfiguration()
        }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        queue.async {
            if self.isStopped {
                stream.stopCapture { _ in }
            } else {
                self.stream = stream
            }
        }
    }

    func stop() {
        queue.async {
            self.isStopped = true
            self.stream?.stopCapture { _ in }
            self.stream = nil
            self.tearDownEncoder()
            self.pending = nil
            self.lastFrame = nil
        }
    }

    func setMaxWidth(_ width: Int) {
        queue.async {
            guard width != self.maxWidth, let stream = self.stream else { return }
            self.maxWidth = width
            self.tearDownEncoder()
            self.pending = nil
            self.lastFrame = nil
            stream.updateConfiguration(self.makeConfiguration()) { _ in }
        }
    }

    /// The client lost sync: re-send the current picture as a key frame even if the screen is idle.
    func requestKeyFrame() {
        queue.async {
            self.forceKeyFrame = true
            if !self.isBusy, self.pending == nil, let lastFrame = self.lastFrame {
                self.encode(lastFrame)
            }
        }
    }

    // MARK: - Capture

    private var displayPixelSize = (width: 0, height: 0)

    private func makeConfiguration() -> SCStreamConfiguration {
        size = Self.streamSize(display: displayPixelSize, maxWidth: maxWidth)
        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: Self.frameRate)
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.showsCursor = true
        configuration.queueDepth = 5
        return configuration
    }

    /// Display pixels scaled down to `maxWidth`, rounded to even numbers (H.264 4:2:0).
    static func streamSize(display: (width: Int, height: Int), maxWidth: Int) -> (width: Int, height: Int) {
        guard display.width > 0, display.height > 0 else { return (maxWidth & ~1, (maxWidth * 9 / 16) & ~1) }
        let width = min(display.width, maxWidth)
        let height = Int((Double(width) * Double(display.height) / Double(display.width)).rounded())
        return (max(width & ~1, 2), max(height & ~1, 2))
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !isStopped, Self.isComplete(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard CVPixelBufferGetWidth(pixelBuffer) == size.width, CVPixelBufferGetHeight(pixelBuffer) == size.height else {
            return // A frame from before a size change.
        }
        lastFrame = pixelBuffer
        if isBusy {
            pending = pixelBuffer
        } else {
            encode(pixelBuffer)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        queue.async {
            guard !self.isStopped else { return }
            self.onFailure("화면 캡처가 멈췄습니다: \(error.localizedDescription)")
        }
    }

    private static func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
            let raw = attachments.first?[.status] as? Int else { return false }
        return SCFrameStatus(rawValue: raw) == .complete
    }

    // MARK: - Encoding

    private func makeEncoder() -> VTCompressionSession? {
        // Low-latency rate control where the hardware has it, otherwise a plain real-time encoder.
        let lowLatency = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary
        var created: VTCompressionSession?
        for specification in [lowLatency, nil] where created == nil {
            VTCompressionSessionCreate(
                allocator: nil, width: Int32(size.width), height: Int32(size.height), codecType: kCMVideoCodecType_H264,
                encoderSpecification: specification, imageBufferAttributes: nil, compressedDataAllocator: nil,
                outputCallback: nil, refcon: nil, compressionSessionOut: &created
            )
        }
        guard let session = created else { return nil }
        // Text-heavy desktops need more bits than video; ~0.12 bit per pixel at 30 fps.
        let bitRate = Int(Double(size.width * size.height) * Double(Self.frameRate) * 0.12)
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_ConstrainedHigh_AutoLevel,
            kVTCompressionPropertyKey_AverageBitRate: bitRate,
            kVTCompressionPropertyKey_ExpectedFrameRate: Self.frameRate,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 10,
        ]
        for (key, value) in properties {
            VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
        return session
    }

    private func tearDownEncoder() {
        if let encoder {
            // Flush first: every submitted frame must reach `deliver`, or `isBusy` would never clear.
            VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(encoder)
        }
        encoder = nil
        forceKeyFrame = true
    }

    private func encode(_ pixelBuffer: CVPixelBuffer) {
        if encoder == nil { encoder = makeEncoder() }
        guard let encoder else {
            onFailure("H.264 인코더를 만들 수 없습니다")
            return
        }
        isBusy = true
        let options = forceKeyFrame ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        forceKeyFrame = false
        let time = CMClockGetTime(CMClockGetHostTimeClock())
        let status = VTCompressionSessionEncodeFrame(
            encoder, imageBuffer: pixelBuffer, presentationTimeStamp: time, duration: .invalid,
            frameProperties: options, infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            let frame = status == noErr ? sampleBuffer.flatMap(EncodedFrame.init) : nil
            guard let self else { return }
            self.queue.async { self.deliver(frame) }
        }
        if status != noErr {
            isBusy = false
            forceKeyFrame = true
        }
    }

    private func deliver(_ frame: EncodedFrame?) {
        guard !isStopped, let frame else {
            finishFrame()
            return
        }
        if let parameterSets = frame.parameterSets,
           sentConfig.map({ $0.parameterSets != parameterSets || $0.width != frame.width || $0.height != frame.height }) ?? true {
            sentConfig = (frame.width, frame.height, parameterSets)
            send(.videoConfig(width: UInt16(frame.width), height: UInt16(frame.height), parameterSets: parameterSets)) {}
        }
        send(.videoFrame(isKeyFrame: frame.isKeyFrame, data: frame.data)) { [weak self] in
            guard let self else { return }
            self.queue.async { self.finishFrame() }
        }
    }

    private func finishFrame() {
        isBusy = false
        if let pending {
            self.pending = nil
            encode(pending)
        }
    }
}

/// One compressed access unit, copied out of VideoToolbox so it can cross threads.
private struct EncodedFrame: Sendable {
    let data: Data
    let isKeyFrame: Bool
    /// SPS/PPS, read from key frames only.
    let parameterSets: [Data]?
    let width: Int
    let height: Int

    init?(_ sampleBuffer: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer),
              let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: bytes.baseAddress!)
        }
        guard status == noErr else { return nil }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[String: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool ?? false
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        self.data = data
        isKeyFrame = !notSync
        parameterSets = notSync ? nil : Self.parameterSets(of: format)
        width = Int(dimensions.width)
        height = Int(dimensions.height)
    }

    private static func parameterSets(of format: CMFormatDescription) -> [Data] {
        var count = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil
        ) == noErr else { return [] }
        return (0 ..< count).compactMap { index in
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
            ) == noErr, let pointer else { return nil }
            return Data(bytes: pointer, count: size)
        }
    }
}
