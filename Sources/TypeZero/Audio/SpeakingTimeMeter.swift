import Foundation
import AVFoundation

/// How long somebody is really speaking in a recording, with the pauses left out.
///
/// The Home page's "Average dictation speed" is words divided by this, not by the recording time. Pauses do not count, so a
/// dictation with long pauses is not slowed down by them. The constants were chosen so that, on real dictations recorded by
/// Typeless, the speed comes out close to the figure Typeless itself shows:
///
///  1. The audio is cut into 10 ms frames; a final partial frame counts as a frame. A frame's level is
///     `20 * log10(max(rms, 1e-5))` dBFS, with the rms taken over every sample of the frame.
///  2. Digital silence, a frame whose level sits at that -100 dBFS clamp (the zeros an Opus file starts with, or a microphone
///     that has not warmed up), is left out of both percentiles below. It still counts as quiet when pauses are looked for.
///  3. The noise floor is the 10th-percentile level of the other frames, the loud level their 95th-percentile level (nearest rank).
///  4. A frame is speech when its level is above the lower of "noise floor + 13 dB" and "loud level - 10 dB"; otherwise it is
///     quiet. The second limit keeps a recording with almost no pauses from losing its soft passages: a frame less than 10 dB
///     below the loud level is never quiet, however narrow the recording's range is.
///  5. A run of quiet frames lasting at least 0.3 s is a pause. Shorter quiet runs count as speaking.
///  6. Speaking time is the recording time minus the pauses. A recording shorter than 1 s counts in full, and one that is
///     digital silence all through has no speaking time.
///
/// Everything is relative to the recording's own levels, so the result does not depend on the microphone's gain.
///
/// The meter is a value type that is fed samples as they arrive. It keeps the unfinished frame between calls and one `Float`
/// level per finished frame (about 100 per second), so appending is cheap enough for the audio tap and the result does not
/// depend on how the samples were split into appends.
struct SpeakingTimeMeter {
    // MARK: The calibrated rule

    /// Analysis frames per second: a frame is 10 ms.
    static let framesPerSecond: Double = 100
    /// The noise floor is this quantile of the levels of the frames that are not digital silence (nearest rank).
    static let noiseFloorPercentile: Double = 0.10
    /// The loud level is this quantile of the same levels (nearest rank).
    static let loudLevelPercentile: Double = 0.95
    /// A frame is speech when its level is more than this many dB above the noise floor, but see `loudMarginDB`.
    static let speechMarginDB: Float = 13
    /// A frame less than this many dB below the loud level is speech whatever the noise floor is.
    static let loudMarginDB: Float = 10
    /// A quiet stretch of at least this many seconds is a pause. Shorter ones count as speaking.
    static let minimumPauseSeconds: Double = 0.3
    /// A recording shorter than this counts in full: there is too little audio to tell a pause from the noise floor.
    static let minimumMeasurableSeconds: Double = 1.0
    /// The quietest rms a frame can have, so a digital silence has a finite level (-100 dBFS).
    static let minimumRMS: Double = 1e-5
    /// The level of a frame at the `minimumRMS` clamp, which is what digital silence (rms at or below the clamp) comes out as.
    static let digitalSilenceLevel: Float = Float(20 * log10(minimumRMS))

    /// True for a frame level at the clamp: the frame was digital silence.
    static func isDigitalSilence(_ level: Float) -> Bool { level <= digitalSilenceLevel }

    typealias Measurement = (recordingSeconds: Double, speakingSeconds: Double)

    // MARK: Feeding samples

    let sampleRate: Double
    /// Samples per frame: 10 ms, rounded, but at least one.
    let frameLength: Int
    /// Level in dBFS of every finished frame, in order.
    private(set) var frameLevels: [Float] = []
    /// Samples appended so far.
    private(set) var sampleCount = 0
    private var partialSumSquares = 0.0
    private var partialCount = 0

    /// `sampleRate` is in samples per second. A value that is not a positive, finite number is treated as 1, so the meter
    /// can never trap; its answer is meaningless then.
    init(sampleRate: Double) {
        let rate = (sampleRate.isFinite && sampleRate > 0) ? min(sampleRate, 1_000_000_000) : 1
        self.sampleRate = rate
        self.frameLength = max(1, Int((rate / Self.framesPerSecond).rounded()))
    }

    var frameSeconds: Double { Double(frameLength) / sampleRate }

    /// Adds mono samples. Safe to call from the audio tap: no allocation per sample, and the work is one pass over `samples`.
    mutating func append(_ samples: UnsafeBufferPointer<Float>) {
        guard let base = samples.baseAddress, samples.count > 0 else { return }
        sampleCount += samples.count
        var offset = 0
        while offset < samples.count {
            let take = min(frameLength - partialCount, samples.count - offset)
            var sum = partialSumSquares
            for index in offset..<(offset + take) {
                let value = Double(base[index])
                sum += value * value
            }
            partialSumSquares = sum
            partialCount += take
            offset += take
            if partialCount == frameLength {
                frameLevels.append(Self.level(sumSquares: sum, count: frameLength))
                partialSumSquares = 0
                partialCount = 0
            }
        }
    }

    mutating func append(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { append($0) }
    }

    /// The recording time so far and the speaking time inside it. The unfinished frame counts as a frame.
    var result: Measurement {
        let total = Double(sampleCount) / sampleRate
        var levels = frameLevels
        if partialCount > 0 {
            levels.append(Self.level(sumSquares: partialSumSquares, count: partialCount))
        }
        return (total, Self.speakingSeconds(levels: levels, frameSeconds: frameSeconds, totalSeconds: total))
    }

    // MARK: The rule

    /// `20 * log10(max(rms, 1e-5))` for a frame of `count` samples whose squares add up to `sumSquares`.
    private static func level(sumSquares: Double, count: Int) -> Float {
        let mean = sumSquares / Double(count)
        let rms = mean.isFinite ? mean.squareRoot() : 0
        return Float(20 * log10(max(rms, minimumRMS)))
    }

    /// The rule itself, on frame levels: `totalSeconds` minus the pauses. `frameSeconds` is the length of one frame.
    static func speakingSeconds(levels: [Float], frameSeconds: Double, totalSeconds: Double) -> Double {
        guard totalSeconds >= minimumMeasurableSeconds, !levels.isEmpty else { return totalSeconds }
        // Digital silence says nothing about how loud the room or the speech is, so it takes no part in the percentiles.
        let sounding = levels.filter { !isDigitalSilence($0) }.sorted()
        guard !sounding.isEmpty else { return 0 }
        func percentile(_ quantile: Double) -> Float { sounding[Int((quantile * Double(sounding.count - 1)).rounded())] }
        let noiseFloor = percentile(noiseFloorPercentile)
        let loudLevel = percentile(loudLevelPercentile)
        let quietThreshold = min(noiseFloor + speechMarginDB, loudLevel - loudMarginDB)

        var pauseSeconds = 0.0
        var quietFrames = 0
        func endRun() {
            let length = Double(quietFrames) * frameSeconds
            if length >= minimumPauseSeconds { pauseSeconds += length }
            quietFrames = 0
        }
        for level in levels {
            // Digital silence is quiet whatever the threshold is.
            if !isDigitalSilence(level) && level > quietThreshold { endRun() } else { quietFrames += 1 }
        }
        endRun()
        return max(0, totalSeconds - pauseSeconds)
    }

    // MARK: Audio files

    /// Frames read from a file at a time.
    private static let fileChunkFrames: AVAudioFrameCount = 32_768

    /// Measures an audio file (channel 0). The file is opened read-only and decoded in chunks, so a long recording never sits in
    /// memory whole. nil when the file is missing, cannot be opened, or nothing at all could be read from it. A file that goes
    /// bad part-way (cut short, damaged) gives the measurement of what was read before that. Reads from disk: call it off the
    /// main thread.
    static func measure(fileAt url: URL) -> Measurement? {
        autoreleasepool {
            guard let file = try? AVAudioFile(forReading: url) else { return nil }
            let format = file.processingFormat
            guard format.sampleRate > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: fileChunkFrames) else { return nil }
            var meter = SpeakingTimeMeter(sampleRate: format.sampleRate)
            // A compressed file's `length` is only an estimate, so it is not what the loop waits for: read until a read fails
            // (it does at the end of the file, and at a damaged spot) or comes back empty, and keep what was read.
            while true {
                do { try file.read(into: buffer, frameCount: fileChunkFrames) } catch { break }
                guard buffer.frameLength > 0, let channel0 = buffer.floatChannelData?[0] else { break }
                meter.append(UnsafeBufferPointer(start: channel0, count: Int(buffer.frameLength)))
            }
            return meter.sampleCount > 0 ? meter.result : nil
        }
    }

    // MARK: Developer check

    static let cliUsage = "usage: \(AppBrand.name) --speaking-time <file> [<file> ...]"

    /// The lines `--speaking-time` prints: one per file (`recording=<s>`, `speaking=<s>` and the file name, tab separated; an
    /// unreadable file is `error` and its name), then the totals over the files that could be read. Names only, never a path.
    static func report(forFiles paths: [String]) -> [String] {
        func seconds(_ value: Double) -> String { String(format: "%.2f", value) }
        var lines: [String] = []
        var totalRecording = 0.0
        var totalSpeaking = 0.0
        var measured = 0
        for path in paths {
            let url = URL(fileURLWithPath: path)
            if let m = measure(fileAt: url) {
                lines.append("recording=\(seconds(m.recordingSeconds))\tspeaking=\(seconds(m.speakingSeconds))\t\(url.lastPathComponent)")
                totalRecording += m.recordingSeconds
                totalSpeaking += m.speakingSeconds
                measured += 1
            } else {
                lines.append("error\t\(url.lastPathComponent)")
            }
        }
        lines.append("total recording=\(seconds(totalRecording)) speaking=\(seconds(totalSpeaking)) files=\(measured)")
        return lines
    }

    /// `Nevertype --speaking-time <file> [<file> ...]`: prints `report(forFiles:)` for the files after the flag. Reads the files
    /// and writes nothing. `arguments` are the process arguments without the executable path.
    static func runCLI(arguments: [String]) -> Int32 {
        guard let flag = arguments.firstIndex(of: "--speaking-time"), flag + 1 < arguments.count else {
            FileHandle.standardError.write(Data("error: missing audio files\n\(cliUsage)\n".utf8))
            return 2
        }
        for line in report(forFiles: Array(arguments[(flag + 1)...])) { print(line) }
        return 0
    }
}
