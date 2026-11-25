import Foundation

/// The short built-in macOS sounds dictation plays around a session (Settings -> Output -> Sound effects), and how long
/// auto-mute waits for the start cue.
public enum SessionCues {
    public struct Cue: Equatable, Sendable {
        /// Name of a sound in `/System/Library/Sounds` (loaded with `NSSound(named:)`).
        public let soundName: String
        /// Relative to the system output volume.
        public let volume: Float
    }

    /// Recording started.
    public static let start = Cue(soundName: "Tink", volume: 0.5)
    /// Recording stopped. The output is given back before it plays, so it is heard even with "Mute speakers while dictating".
    public static let stop = Cue(soundName: "Pop", volume: 0.5)
    /// Dictation cancelled with Esc.
    public static let cancel = Cue(soundName: "Funk", volume: 0.22)

    /// Every built-in sound the app plays. All of them are stopped before a cue starts, so a quick second press never lands on
    /// a sound that is still ringing out (the files carry a silent tail) and goes silent.
    public static let allSoundNames = [start.soundName, stop.soundName, cancel.soundName]

    /// Auto-mute silences the whole output device, the start cue included, so it waits this long after the cue begins. "Tink" is
    /// audible for about 50 ms (its file is 0.56 s long, the rest is a silent tail); 0.2 s leaves room for the output device's
    /// start-up latency. There is nothing to wait for when sound effects are off.
    public static let startMuteDelay: TimeInterval = 0.2

    /// Seconds auto-mute waits after the start cue begins: `startMuteDelay`, or 0 when "Sound effects" is off.
    public static func muteDelayAfterStartCue(soundEffectsEnabled: Bool) -> TimeInterval {
        soundEffectsEnabled ? startMuteDelay : 0
    }
}
