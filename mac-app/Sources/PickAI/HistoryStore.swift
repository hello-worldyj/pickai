import Foundation

/// Persists every answered query to disk so past screenshots/questions and their answers
/// can be revisited later — separate from the in-memory conversation, which is lost as soon
/// as the popup is dismissed.
enum HistoryStore {
    static let directoryURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pick AI/History", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private struct Entry: Encodable {
        let timestamp: Date
        let mode: String
        let question: String?
        let answer: String
        let imageFile: String?
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        return formatter
    }()

    /// - Parameter imagePNGData: pass only for the first exchange of a session (the
    ///   screenshot that kicked it off) — follow-up questions in the same conversation
    ///   are saved text-only rather than re-saving the same image every time.
    static func save(mode: QueryMode, question: String?, answer: String, imagePNGData: Data?) {
        let timestamp = Date()
        let stamp = stampFormatter.string(from: timestamp)

        var imageFile: String?
        if let imagePNGData {
            let name = "\(stamp).png"
            try? imagePNGData.write(to: directoryURL.appendingPathComponent(name))
            imageFile = name
        }

        let entry = Entry(timestamp: timestamp, mode: mode.rawValue, question: question, answer: answer, imageFile: imageFile)
        let jsonEncoder = JSONEncoder()
        jsonEncoder.dateEncodingStrategy = .iso8601
        jsonEncoder.outputFormatting = .prettyPrinted
        guard let data = try? jsonEncoder.encode(entry) else { return }
        try? data.write(to: directoryURL.appendingPathComponent("\(stamp).json"))
    }
}
