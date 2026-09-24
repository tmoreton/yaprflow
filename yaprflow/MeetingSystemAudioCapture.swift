@preconcurrency import AVFoundation
import AppKit
import CoreMedia
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

enum MeetingSystemAudioError: LocalizedError {
    case permissionDenied
    case noDisplay
    case invalidAudioBuffer

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Screen & System Audio access is not active. Turn it on for Yaprflow in System Settings, then restart Yaprflow."
        case .noDisplay:
            "No display is available for system-audio capture."
        case .invalidAudioBuffer:
            "Mac system audio arrived in an unsupported format."
        }
    }
}

nonisolated struct CapturedSystemAudioBuffer: @unchecked Sendable {
    let sampleBuffer: CMSampleBuffer
}

/// ScreenCaptureKit delivers audio on its own queue. This bounded stream keeps
/// a slow recognizer from creating an unbounded number of main-actor tasks.
nonisolated final class BoundedSystemAudioIngress: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Int
    private var continuation: AsyncStream<CapturedSystemAudioBuffer>.Continuation?
    private var droppedAudio = false

    init(capacity: Int = 512) {
        self.capacity = capacity
    }

    func beginSession() -> AsyncStream<CapturedSystemAudioBuffer> {
        let pair = AsyncStream<CapturedSystemAudioBuffer>.makeStream(
            bufferingPolicy: .bufferingOldest(capacity)
        )
        lock.lock()
        let previous = continuation
        continuation = pair.continuation
        droppedAudio = false
        lock.unlock()
        previous?.finish()
        return pair.stream
    }

    func enqueue(_ buffer: CapturedSystemAudioBuffer) {
        lock.lock()
        if case .dropped = continuation?.yield(buffer) {
            droppedAudio = true
        }
        lock.unlock()
    }

    @discardableResult
    func finishSession() -> Bool {
        lock.lock()
        let current = continuation
        continuation = nil
        let dropped = droppedAudio
        droppedAudio = false
        lock.unlock()
        current?.finish()
        return dropped
    }
}

nonisolated final class SystemAudioStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let handler: @Sendable (CapturedSystemAudioBuffer) -> Void

    init(handler: @escaping @Sendable (CapturedSystemAudioBuffer) -> Void) {
        self.handler = handler
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio, sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }
        handler(CapturedSystemAudioBuffer(sampleBuffer: sampleBuffer))
    }
}

@MainActor
final class MeetingSystemAudioCapture {
    private let output: SystemAudioStreamOutput
    private let callbackQueue = DispatchQueue(label: "com.tmoreton.yaprflow.meeting-system-audio")
    private var stream: SCStream?

    init(handler: @escaping @Sendable (CapturedSystemAudioBuffer) -> Void) {
        output = SystemAudioStreamOutput(handler: handler)
    }

    static var isAuthorized: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Registers Yaprflow with macOS and presents the native permission prompt
    /// the first time Meeting Notes needs Screen & System Audio access.
    ///
    /// `CGPreflightScreenCaptureAccess()` is advisory here. macOS can briefly
    /// report `false` after Sparkle replaces and relaunches an authorized app,
    /// even though ScreenCaptureKit can use the existing grant. The capture
    /// attempt below is the authoritative check.
    static func requestAuthorizationIfNeeded() {
        guard !isAuthorized else { return }
        _ = CGRequestScreenCaptureAccess()
    }

    static func openPrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func start() async throws {
        guard stream == nil else { return }
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let display = content.displays.first else { throw MeetingSystemAudioError.noDisplay }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 600)
        configuration.queueDepth = 3
        configuration.showsCursor = false

        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: callbackQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
        try? stream.removeStreamOutput(output, type: .audio)
        // `stopCapture()` prevents new buffers, and this barrier lets any
        // callback already queued finish enqueueing before the controller
        // closes its bounded ingress stream.
        callbackQueue.sync {}
    }

    static func pcmBuffer(from captured: CapturedSystemAudioBuffer) throws -> AVAudioPCMBuffer {
        let sampleBuffer = captured.sampleBuffer
        guard let formatDescription = sampleBuffer.formatDescription,
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let format = AVAudioFormat(streamDescription: description) else {
            throw MeetingSystemAudioError.invalidAudioBuffer
        }

        var requiredSize = 0
        var blockBuffer: CMBlockBuffer?
        let sizeStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &requiredSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &blockBuffer
        )
        guard sizeStatus == noErr, requiredSize >= MemoryLayout<AudioBufferList>.size else {
            throw MeetingSystemAudioError.invalidAudioBuffer
        }

        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: requiredSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        let sourceList = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
        let listStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: sourceList,
            bufferListSize: requiredSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &blockBuffer
        )
        let sampleCount = sampleBuffer.numSamples
        guard sampleCount > 0,
              sampleCount <= Int(AVAudioFrameCount.max) else {
            throw MeetingSystemAudioError.invalidAudioBuffer
        }
        let frameCount = AVAudioFrameCount(sampleCount)
        guard listStatus == noErr,
              let destination = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw MeetingSystemAudioError.invalidAudioBuffer
        }
        destination.frameLength = frameCount

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(sourceList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(destination.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else {
            throw MeetingSystemAudioError.invalidAudioBuffer
        }
        for index in sourceBuffers.indices {
            guard let sourceData = sourceBuffers[index].mData,
                  let destinationData = destinationBuffers[index].mData else {
                throw MeetingSystemAudioError.invalidAudioBuffer
            }
            let byteCount = min(
                Int(sourceBuffers[index].mDataByteSize),
                Int(destinationBuffers[index].mDataByteSize)
            )
            memcpy(destinationData, sourceData, byteCount)
            destinationBuffers[index].mDataByteSize = UInt32(byteCount)
        }
        return destination
    }
}
