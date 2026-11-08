import Foundation

/// All scene, playback and hand-off times live here. Retune this table only.
public enum IntroTimeline {
    public struct Beat: Sendable {
        public let name: String
        public let start: Double
        public let end: Double
    }
    public static let beats: [Beat] = [
        .init(name: "introAnimation", start: 0, end: 3.3),
        .init(name: "sellIntro", start: 3.3, end: 9.8),
        .init(name: "sellCompleted", start: 9.8, end: 9.8),
        .init(name: "room", start: 0, end: 1),
        .init(name: "dim", start: 0, end: 1.5),
        .init(name: "dimFinish", start: 0, end: 2.5),
        .init(name: "door", start: 0.3, end: 1.9),
        .init(name: "sun", start: 1.7, end: 2.7),
        .init(name: "bellPair", start: 2.3, end: 2.47),
        .init(name: "spill", start: 2.4, end: 3.3),
        .init(name: "markMove", start: 3.3, end: 4.1),
        .init(name: "wordmark", start: 3.3, end: 4.1),
        .init(name: "line", start: 4.3, end: 4.9),
        .init(name: "value1", start: 5.6, end: 6.8),
        .init(name: "value2", start: 6.8, end: 8),
        .init(name: "value3", start: 8, end: 9.2),
        .init(name: "button", start: 9.8, end: 10.2),
        .init(name: "buttonSpring", start: 9.8, end: 11.05),
        .init(name: "plateau", start: 5, end: 15),
        .init(name: "subEntry", start: 3.3, end: 5.3),
        .init(name: "airSweep", start: 2.4, end: 3.3),
        .init(name: "sound", start: 0, end: 20),
        .init(name: "soundFade", start: 15, end: 19.5),
        .init(name: "idlePause", start: 23.5, end: 23.5),
        .init(name: "reduceFade", start: 0, end: 0.6),
        .init(name: "reduceButton", start: 1, end: 1),
        .init(name: "handoff", start: 0, end: 0.45),
        .init(name: "handoffSound", start: 0, end: 0.8),
        .init(name: "syncLead", start: 0, end: 0.08),
        .init(name: "soundDeadline", start: 0, end: 0.3),
        .init(name: "measureFrames", start: 0, end: 8),
        .init(name: "measureMemory", start: 3, end: 3),
        .init(name: "orbBlue", start: 0, end: 18),
        .init(name: "orbPurple", start: 0, end: 22),
        .init(name: "orbWarm", start: 0, end: 26),
    ]
    public static func beat(_ name: String) -> Beat { beats.first { $0.name == name }! }
    public static func phase(at time: Double, reduceMotion: Bool) -> String {
        if reduceMotion { return time < beat("reduceButton").end ? "introAnimation" : "sellCompleted" }
        return time < beat("introAnimation").end ? "introAnimation" : time < beat("sellIntro").end ? "sellIntro" : "sellCompleted"
    }
}
