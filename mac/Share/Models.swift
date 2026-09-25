import Foundation

struct DriveEntry: Codable, Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String
    let type: EntryType
    let size: Int64?
    let modified: Date
    var isDirectory: Bool { type == .dir }
}

enum EntryType: String, Codable, Sendable { case file, dir }

struct ListResponse: Codable, Sendable {
    let path: String
    let entries: [DriveEntry]
}

struct LinkResponse: Codable, Sendable {
    let url: String
    let expires: Date
}

struct UploadCreated: Codable, Sendable {
    let id: String
    let chunkSize: Int64
    let received: Int64
}

struct UploadStatus: Codable, Sendable {
    let id: String
    let path: String
    let size: Int64
    let received: Int64
}

struct UploadProgress: Identifiable, Sendable {
    let id: UUID
    let name: String
    var sent: Int64
    let total: Int64
    var status: UploadState = .queued
    var bytesPerSecond: Double = 0
    var fraction: Double { total == 0 ? 1 : Double(sent) / Double(total) }
    var detail: String {
        switch status {
        case .queued: return "Waiting"
        case .uploading:
            let amount = "\(sent.fileSizeText) of \(total.fileSizeText)"
            guard bytesPerSecond > 0 else { return amount }
            let speed = Int64(bytesPerSecond).fileSizeText + "/s"
            let seconds = Int(Double(total - sent) / bytesPerSecond)
            let remaining = seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
            return "\(amount) · \(speed) · \(remaining) left"
        case .cancelling: return "Cancelling…"
        case .cancelled: return "Cancelled"
        case .completed: return "Complete"
        case .failed(let message): return "Failed: \(message)"
        }
    }
}

enum UploadState: Sendable {
    case queued, uploading, cancelling, cancelled, completed, failed(String)
    var canCancel: Bool {
        switch self {
        case .queued, .uploading: return true
        default: return false
        }
    }
    var canRetry: Bool {
        if case .failed = self { return true }
        return false
    }
}

struct ServerErrorBody: Codable, Sendable {
    let error: String
    let message: String
    let received: Int64?
}

enum ShareError: LocalizedError {
    case invalidURL
    case unauthorized
    case server(String, String, Int64?)
    case externalPlayerMissing
    case finderMountFailed(Int)
    case finderAccessUnsupported

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Enter a valid HTTPS server URL."
        case .unauthorized: return "Access key rejected."
        case .server(_, let message, _): return message
        case .externalPlayerMissing: return "Install IINA or VLC to stream this format, or download it instead."
        case .finderMountFailed(let code): return "Could not mount Share in Finder (error \(code)). Check the server address and access key."
        case .finderAccessUnsupported: return "Finder cannot supply Cloudflare Access service tokens. Connect on the local network or exempt /Share/ from that Access policy."
        }
    }
}

extension Int64 {
    var fileSizeText: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
