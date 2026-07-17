//
//  AudioUploadCompressor.swift
//

import AVFoundation

/// Converts WAV recordings to compact AAC (.m4a) files before cloud upload.
/// Uncompressed WAV is ~5.6 MB/min; 64 kbps mono AAC is ~0.45 MB/min with no
/// practical accuracy loss (providers resample to 16 kHz mono internally).
enum AudioUploadCompressor {

    /// Returns a temporary .m4a copy of the recording, or nil when conversion
    /// fails — callers should fall back to uploading the original file.
    /// The caller is responsible for deleting the returned temp file.
    static func compressForUpload(_ sourceURL: URL) -> URL? {
        // Already compressed — nothing to gain.
        guard sourceURL.pathExtension.lowercased() == "wav" else { return nil }

        do {
            let input = try AVAudioFile(forReading: sourceURL)
            let format = input.processingFormat

            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("upload-\(UUID().uuidString)")
                .appendingPathExtension("m4a")

            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVEncoderBitRateKey: 64_000,
            ]
            let output = try AVAudioFile(forWriting: outputURL, settings: settings)

            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_768) else {
                return nil
            }
            // read(into:) throws at exact EOF, so gate on framePosition instead
            while input.framePosition < input.length {
                try input.read(into: buffer)
                if buffer.frameLength == 0 { break }
                try output.write(from: buffer)
            }
            return outputURL
        } catch {
            print("AudioUploadCompressor: falling back to WAV (\(error.localizedDescription))")
            return nil
        }
    }
}
