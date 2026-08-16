import AppKit
import AVFoundation
import ScreenCaptureKit

// 디버그 모드(버그 수집) 구간의 앱 창 화면 녹화 → screen.mp4.
//
// WHY: 로그는 "무엇을 눌렀는가"는 말해주지만 "화면에 무엇이 보였는가"는 말해주지 않는다.
// 실제로 첫 자동 리포트가 쓸모없었던 이유가 정확히 그것이었다 — 조작 기록만으로는 아무도
// 무슨 일이 있었는지 재구성하지 못했다. 영상 한 개가 있으면 리포트를 AI가 복원할 필요조차
// 없다: 사람이 20초 돌려보면 끝난다.
//
// 두 가지 소스, 같은 인코더:
//   1) ScreenCaptureKit — 그 창 자체를 잡는다(네이티브 메뉴·다이얼로그·드로우 오버레이 포함).
//      화면 기록 권한이 필요하다.
//   2) 권한이 없거나 SCK가 창을 못 찾으면 → 웹뷰 스냅샷(권한 불필요)을 2fps로 이어 붙인다.
//      네이티브 크롬은 안 보이지만 "그때 화면이 뭐였나"는 그대로 남는다.
//
// 경계: 잡는 대상은 언제나 이 앱이 소유한 창 하나뿐이다. 다른 앱 창이나 바탕화면은 절대
// 프레임에 들어오지 않는다(SCContentFilter가 창 단위). 키 수집이 앱 안으로 한정된 것과 같은 선.
final class WindowRecorder: NSObject, SCStreamOutput, SCStreamDelegate {

    // 8fps · 최대 1280px 폭 · ~1.2Mbps. 10분이면 대략 60~90MB.
    private static let fps: Int32 = 8
    private static let maxWidth = 1280
    private static let bitrate = 1_200_000
    // 무한정 커지지 않도록: 이 크기를 넘으면 녹화만 멈춘다(수집 자체는 계속된다).
    private static let maxBytes: UInt64 = 400 * 1024 * 1024

    private let queue = DispatchQueue(label: "cm.windowrecorder")
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var started = false
    private var firstPTS: CMTime?
    private var lastPTS: CMTime = .zero
    private var frames = 0
    private var outputURL: URL?
    private var fallbackActive = false
    private var fallbackFrame: (() -> Data?)?
    private var usingFallback = false
    private var warnedNoFrame = false
    private(set) var startNote = ""      // 번들 report.md에 남길 한 줄(무엇으로 찍었는지 / 왜 못 찍었는지)

    var isRecording: Bool { queue.sync { writer != nil } }

    // MARK: - Start

    /// `url`(…/screen.mp4)에 녹화를 시작한다. `fallbackFrame`은 화면 기록 권한이 없을 때
    /// 쓰는 PNG 프레임 공급자(앱 웹뷰 스냅샷). 실패해도 예외를 던지지 않는다 — 수집은
    /// 녹화 없이도 계속되어야 하고, 실패 사유는 startNote로 번들에 남는다.
    func start(to url: URL, fallbackFrame: (() -> Data?)?) {
        queue.async { [weak self] in
            guard let self, self.writer == nil else { return }
            self.outputURL = url
            self.fallbackFrame = fallbackFrame
            Task { await self.beginSCK(url: url) }
        }
    }

    private func beginSCK(url: URL) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                              onScreenWindowsOnly: true)
            let pid = ProcessInfo.processInfo.processIdentifier
            // 이 앱이 소유한 창 중 가장 큰 것 = 앱 창(젠 상태여도 가장 큼). 드로우 오버레이나
            // 상태바 팝업 같은 작은 창은 자연히 걸러진다.
            let mine = content.windows.filter { $0.owningApplication?.processID == pid }
                .filter { $0.frame.width > 200 && $0.frame.height > 200 }
                .sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
            guard let win = mine.first else {
                startNote = "창을 찾지 못해 웹뷰 스냅샷으로 녹화(앱 창이 닫혀 있었음)"
                queue.async { self.beginFallback(url: url) }
                return
            }
            let scale = min(1.0, Double(Self.maxWidth) / max(1, win.frame.width))
            let w = Int((win.frame.width * scale / 2).rounded()) * 2      // 짝수 폭/높이 (H.264)
            let h = Int((win.frame.height * scale / 2).rounded()) * 2

            let cfg = SCStreamConfiguration()
            cfg.width = max(2, w)
            cfg.height = max(2, h)
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: Self.fps)
            cfg.queueDepth = 5
            cfg.showsCursor = true
            cfg.pixelFormat = kCVPixelFormatType_32BGRA

            let filter = SCContentFilter(desktopIndependentWindow: win)
            let s = SCStream(filter: filter, configuration: cfg, delegate: self)
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await s.startCapture()
            queue.async {
                guard self.prepareWriter(url: url, width: cfg.width, height: cfg.height) else { return }
                self.stream = s
                self.usingFallback = false
                self.startNote = "ScreenCaptureKit로 앱 창 녹화 (\(cfg.width)×\(cfg.height) · \(Self.fps)fps)"
                AppLog.log("debug-capture recorder: SCK started \(cfg.width)x\(cfg.height)")
            }
        } catch {
            // 화면 기록 권한 미허용이 가장 흔한 실패다. 배너를 띄우지 않고 조용히 스냅샷으로 내려간다.
            startNote = "화면 기록 권한이 없어 웹뷰 스냅샷으로 녹화 " +
                        "(시스템 설정 > 개인정보 보호 및 보안 > 화면 기록에서 허용하면 창 전체가 녹화됩니다)"
            AppLog.log("debug-capture recorder: SCK unavailable (\(error.localizedDescription)) -> snapshot fallback")
            queue.async { self.beginFallback(url: url) }
        }
    }

    // 권한 없이 쓰는 대체 경로: 앱 웹뷰 스냅샷 PNG를 2fps로 이어 붙인다.
    private func beginFallback(url: URL) {
        guard writer == nil else { return }
        guard let provider = fallbackFrame else {
            AppLog.log("debug-capture recorder: 스냅샷 공급자가 없어 녹화 불가")
            startNote = "녹화 소스가 없어 녹화하지 못했습니다"
            return
        }
        usingFallback = true
        var size = CGSize(width: 1280, height: 800)
        if let png = provider(), let img = NSImage(data: png), img.size.width > 1 {
            let scale = min(1.0, Double(Self.maxWidth) / img.size.width)
            size = CGSize(width: (img.size.width * scale / 2).rounded() * 2,
                          height: (img.size.height * scale / 2).rounded() * 2)
        }
        guard prepareWriter(url: url, width: Int(size.width), height: Int(size.height)) else { return }
        AppLog.log("debug-capture recorder: snapshot fallback started \(Int(size.width))x\(Int(size.height))")
        fallbackActive = true
        fallbackTick(size: size)
    }

    // 2fps 프레임 루프. 메인 런루프 Timer가 아니라 녹화 큐의 self-scheduling 루프다 —
    // Timer는 창 애니메이션(젠 접힘/펼침)이나 드래그 중 런루프가 tracking 모드로 들어가면
    // 통째로 굶는다. 실제로 그 구간에서 프레임이 0이 되는 것을 재현했다.
    private func fallbackTick(size: CGSize) {
        guard fallbackActive, writer != nil else { return }
        if let png = fallbackFrame?(), let img = NSImage(data: png) {
            appendImage(img, size: size)
        } else if !warnedNoFrame {
            warnedNoFrame = true
            AppLog.log("debug-capture recorder: 스냅샷을 얻지 못함 — 앱 창이 닫혀 있는 동안은 녹화되지 않는다")
        }
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.fallbackTick(size: size) }
    }

    private func prepareWriter(url: URL, width: Int, height: Int) -> Bool {
        try? FileManager.default.removeItem(at: url)
        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mp4) else {
            AppLog.log("debug-capture recorder: AVAssetWriter 생성 실패")
            return false
        }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: Self.bitrate],
        ]
        let i = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        i.expectsMediaDataInRealTime = true
        guard w.canAdd(i) else {
            AppLog.log("debug-capture recorder: writer input 추가 불가 (\(width)x\(height))")
            return false
        }
        w.add(i)
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: i, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer = w
        input = i
        return true
    }

    // MARK: - Frames

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // SCK는 변화가 없을 때도 상태 프레임을 보낸다 — complete가 아닌 것은 버린다.
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = arr.first?[.status] as? Int, SCFrameStatus(rawValue: raw) != .complete {
            return
        }
        append(pb, pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        AppLog.log("debug-capture recorder: stream stopped (\(error.localizedDescription))")
        queue.async { self.stream = nil }
    }

    private func appendImage(_ img: NSImage, size: CGSize) {
        var rect = CGRect(origin: .zero, size: size)
        guard let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return }
        var pbOut: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferCGImageCompatibilityKey as String: true,
                                    kCVPixelBufferCGBitmapContextCompatibilityKey as String: true]
        CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA,
                            attrs as CFDictionary, &pbOut)
        guard let pb = pbOut else { return }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb),
                                  width: Int(size.width), height: Int(size.height),
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        ctx.draw(cg, in: CGRect(origin: .zero, size: size))
        // 스냅샷 경로는 벽시계 기준으로 타임스탬프를 만든다(2fps 고정이 아니라 실제 도착 시각).
        append(pb, pts: CMClockGetTime(CMClockGetHostTimeClock()))
    }

    private func append(_ pb: CVPixelBuffer, pts: CMTime) {
        guard let writer, let input, let adaptor else { return }
        if firstPTS == nil {
            firstPTS = pts
            writer.startWriting()
            writer.startSession(atSourceTime: .zero)
        }
        guard let first = firstPTS, input.isReadyForMoreMediaData else {
            if frames == 0 { AppLog.log("debug-capture recorder: input not ready (status=\(writer.status.rawValue) err=\(String(describing: writer.error)))") }
            return
        }
        let t = CMTimeSubtract(pts, first)
        guard t >= .zero, t > lastPTS || frames == 0 else { return }
        lastPTS = t
        let ok = adaptor.append(pb, withPresentationTime: t)
        if !ok, frames == 0 {
            AppLog.log("debug-capture recorder: append 실패 (status=\(writer.status.rawValue) err=\(String(describing: writer.error)))")
        }
        frames += 1
        // 400MB를 넘으면 녹화만 멈춘다(수집은 계속). 파일 확인은 100프레임마다.
        if frames % 100 == 0, let url = outputURL,
           let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = (attrs[.size] as? NSNumber)?.uint64Value, size > Self.maxBytes {
            AppLog.log("debug-capture recorder: size cap reached — stop recording")
            stop { }
        }
    }

    // MARK: - Stop

    /// 녹화를 끝내고 파일을 닫는다. 완료(또는 녹화 중이 아님)를 completion으로 알린다.
    func stop(_ completion: @escaping () -> Void) {
        queue.async { [weak self] in
            guard let self else { completion(); return }
            self.fallbackActive = false
            if let s = self.stream {
                self.stream = nil
                s.stopCapture { _ in }
            }
            guard let writer = self.writer, let input = self.input else {
                self.reset(); completion(); return
            }
            self.writer = nil
            self.input = nil
            self.adaptor = nil
            guard self.frames > 0, writer.status == .writing else {
                writer.cancelWriting()
                self.startNote = "녹화된 프레임이 없습니다 — 캡처 내내 앱 창이 닫혀 있었거나"
                    + " 화면 기록 권한이 없어 창을 잡지 못했습니다"
                    + " (시스템 설정 > 개인정보 보호 및 보안 > 화면 기록에서 이 앱을 허용하면 창 전체가 녹화됩니다)"
                AppLog.log("debug-capture recorder: 프레임 0 — 녹화 파일 없음")
                self.reset()
                completion()
                return
            }
            input.markAsFinished()
            writer.endSession(atSourceTime: self.lastPTS)
            writer.finishWriting { [weak self] in
                AppLog.log("debug-capture recorder: finished frames=\(self?.frames ?? 0)")
                self?.reset()
                completion()
            }
        }
    }

    private func reset() {
        fallbackActive = false
        warnedNoFrame = false
        firstPTS = nil
        lastPTS = .zero
        frames = 0
        usingFallback = false
        fallbackFrame = nil
        outputURL = nil
    }
}
