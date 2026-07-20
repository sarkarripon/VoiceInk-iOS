//
//  RiffWaveUtils.swift
//  VoiceInk-ios
//
//  Audio decoding for Whisper: loads any WAV and resamples to the
//  16 kHz mono float samples whisper.cpp expects.
//

import Foundation
import AVFoundation

/// Decode an audio file to 16 kHz mono float samples for Whisper.
///
/// The foreground recorder writes 16 kHz WAV, but the background engine
/// capture writes at the hardware input rate (typically 48 kHz). Feeding
/// those samples to Whisper unresampled makes it see 3x the duration —
/// slow transcription and degraded accuracy — so everything is converted
/// to 16 kHz here.
func decodeWaveFile(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let sourceFormat = file.processingFormat
    let frameCount = AVAudioFrameCount(file.length)

    guard frameCount > 0 else { return [] }

    guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
        throw NSError(domain: "RiffWaveUtils", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not allocate audio buffer"])
    }
    // AVAudioFile.read(into:) can throw a spurious error at exact EOF, so
    // read while tracking framePosition instead of a single full-length read
    while file.framePosition < file.length {
        try file.read(into: sourceBuffer)
    }

    guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false) else {
        throw NSError(domain: "RiffWaveUtils", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not create target audio format"])
    }

    // Already in Whisper's format — no conversion needed
    if sourceFormat.sampleRate == targetFormat.sampleRate,
       sourceFormat.channelCount == 1,
       sourceFormat.commonFormat == .pcmFormatFloat32,
       let channelData = sourceBuffer.floatChannelData {
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(sourceBuffer.frameLength)))
    }

    guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
        throw NSError(domain: "RiffWaveUtils", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not create audio converter"])
    }

    let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
    let targetCapacity = AVAudioFrameCount((Double(sourceBuffer.frameLength) * ratio).rounded(.up)) + 1024
    guard let targetBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: targetCapacity) else {
        throw NSError(domain: "RiffWaveUtils", code: 4, userInfo: [NSLocalizedDescriptionKey: "Could not allocate output buffer"])
    }

    var fed = false
    var conversionError: NSError?
    converter.convert(to: targetBuffer, error: &conversionError) { _, outStatus in
        if fed {
            outStatus.pointee = .endOfStream
            return nil
        }
        fed = true
        outStatus.pointee = .haveData
        return sourceBuffer
    }
    if let conversionError {
        throw conversionError
    }

    guard let channelData = targetBuffer.floatChannelData else {
        throw NSError(domain: "RiffWaveUtils", code: 5, userInfo: [NSLocalizedDescriptionKey: "Converted buffer has no channel data"])
    }
    return Array(UnsafeBufferPointer(start: channelData[0], count: Int(targetBuffer.frameLength)))
}
