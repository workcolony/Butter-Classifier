import Foundation
import AVFoundation
import CoreServices

/// Extracts free-text tag clues from embedded audio metadata that filenames miss:
/// RIFF INFO / BEXT, AIFF annotation chunks, ID3/common AV metadata, Finder comments.
enum AudioFileMetadataHints {
    /// Soft cap per text field — INFO/comment blobs are small.
    private static let maxFieldBytes = 8 * 1024

    /// RIFF INFO keys that often carry instrument / genre / style wording.
    private static let riffInfoKeys: Set<String> = [
        "ICMT", "INAM", "IGNR", "IART", "ISBJ", "IKEY", "IPRD", "ISFT", "ICOP", "IENG",
    ]

    static func clueText(forAudioPath path: String) -> String {
        let url = URL(fileURLWithPath: path)
        var parts: [String] = []

        if let embedded = readEmbeddedText(url: url), !embedded.isEmpty {
            parts.append(embedded)
        }
        if let finder = finderComment(for: url), !finder.isEmpty {
            parts.append(finder)
        }

        return parts.joined(separator: " ")
    }

    // MARK: - Embedded containers

    private static func readEmbeddedText(url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let header = try? handle.read(upToCount: 12), header.count >= 12 else { return nil }
        let fourCC0 = fourCC(header, at: 0)
        let fourCC8 = fourCC(header, at: 8)
        let size = fileSize(of: url)

        if fourCC0 == "RIFF" && fourCC8 == "WAVE" {
            return readRiffWaveHints(handle: handle, fileSize: size)
        }
        if fourCC0 == "FORM" && (fourCC8 == "AIFF" || fourCC8 == "AIFC") {
            return readAiffHints(handle: handle, fileSize: size)
        }

        // MP3 / other formats — fall back to AVFoundation common metadata.
        return readAVMetadataHints(url: url)
    }

    private static func readRiffWaveHints(handle: FileHandle, fileSize: Int64) -> String? {
        var parts: [String] = []
        var offset: UInt64 = 12
        let limit = UInt64(max(0, fileSize))

        while offset + 8 <= limit {
            guard let chunk = try? readChunkHeader(handle: handle, at: offset, bigEndian: false) else { break }
            let dataStart = offset + 8
            let dataEnd = min(dataStart + UInt64(chunk.size), limit)

            if chunk.id == "LIST", chunk.size >= 4 {
                if let listTypeData = try? readBytes(handle: handle, at: dataStart, count: 4),
                   fourCC(listTypeData, at: 0) == "INFO" {
                    let info = readRiffInfoList(
                        handle: handle,
                        start: dataStart + 4,
                        end: dataEnd
                    )
                    parts.append(contentsOf: info)
                }
            } else if chunk.id == "bext", chunk.size >= 256 {
                let count = min(Int(chunk.size), 602)
                if let bext = try? readBytes(handle: handle, at: dataStart, count: count),
                   let desc = cStringField(bext, start: 0, length: min(256, bext.count)) {
                    parts.append(desc)
                }
            }

            // Chunks are word-aligned.
            let padded = UInt64(chunk.size + (chunk.size & 1))
            let next = dataStart + padded
            if next <= offset { break }
            offset = next
        }

        let joined = parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    private static func readRiffInfoList(handle: FileHandle, start: UInt64, end: UInt64) -> [String] {
        var parts: [String] = []
        var offset = start
        while offset + 8 <= end {
            guard let chunk = try? readChunkHeader(handle: handle, at: offset, bigEndian: false) else { break }
            let dataStart = offset + 8
            let dataEnd = min(dataStart + UInt64(chunk.size), end)
            if riffInfoKeys.contains(chunk.id), dataEnd > dataStart {
                let count = min(Int(dataEnd - dataStart), maxFieldBytes)
                if let raw = try? readBytes(handle: handle, at: dataStart, count: count),
                   let text = decodeTextField(raw) {
                    parts.append(text)
                }
            }
            let padded = UInt64(chunk.size + (chunk.size & 1))
            let next = dataStart + padded
            if next <= offset { break }
            offset = next
        }
        return parts
    }

    private static func readAiffHints(handle: FileHandle, fileSize: Int64) -> String? {
        var parts: [String] = []
        var offset: UInt64 = 12
        let limit = UInt64(max(0, fileSize))
        let interesting: Set<String> = ["NAME", "AUTH", "ANNO", "(c) "]

        while offset + 8 <= limit {
            guard let chunk = try? readChunkHeader(handle: handle, at: offset, bigEndian: true) else { break }
            let dataStart = offset + 8
            if interesting.contains(chunk.id), chunk.size > 0 {
                let count = min(Int(chunk.size), maxFieldBytes)
                if let raw = try? readBytes(handle: handle, at: dataStart, count: count),
                   let text = decodeAiffTextField(raw) {
                    parts.append(text)
                }
            }
            let padded = UInt64(chunk.size + (chunk.size & 1))
            let next = dataStart + padded
            if next <= offset { break }
            offset = next
        }

        let joined = parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    private static func readAVMetadataHints(url: URL) -> String? {
        let asset = AVURLAsset(url: url)
        var parts: [String] = []
        let wanted: Set<AVMetadataKey> = [
            .commonKeyTitle,
            .commonKeySubject,
            .commonKeyDescription,
            .commonKeyType,
            .commonKeyArtist,
            .commonKeyAlbumName,
        ]
        for item in asset.commonMetadata {
            guard let key = item.commonKey, wanted.contains(key) else { continue }
            if let s = item.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                parts.append(s)
            }
        }
        // ID3 comment / genre often live outside commonMetadata.
        for item in asset.metadata {
            let id = item.identifier?.rawValue.lowercased() ?? ""
            let keySpace = item.keySpace?.rawValue.lowercased() ?? ""
            let keyString = (item.key as? String)?.uppercased() ?? ""
            let looksLikeComment =
                id.contains("comment")
                || id.contains("description")
                || id.contains("genre")
                || (keySpace.contains("id3") && (keyString == "COMM" || keyString == "TCON"))
            guard looksLikeComment else { continue }
            if let s = item.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                parts.append(s)
            }
        }
        let joined = parts.joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }

    // MARK: - Finder comment

    private static func finderComment(for url: URL) -> String? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return nil }
        guard let value = MDItemCopyAttribute(item, kMDItemFinderComment) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Binary helpers

    private struct ChunkHeader {
        var id: String
        var size: UInt32
    }

    private static func readChunkHeader(
        handle: FileHandle,
        at offset: UInt64,
        bigEndian: Bool
    ) throws -> ChunkHeader? {
        guard let data = try readBytes(handle: handle, at: offset, count: 8), data.count == 8 else {
            return nil
        }
        let id = fourCC(data, at: 0)
        let size = data.withUnsafeBytes { buf -> UInt32 in
            let raw = buf.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
            return bigEndian ? UInt32(bigEndian: raw) : UInt32(littleEndian: raw)
        }
        return ChunkHeader(id: id, size: size)
    }

    private static func readBytes(handle: FileHandle, at offset: UInt64, count: Int) throws -> Data? {
        guard count > 0 else { return Data() }
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: count)
    }

    private static func fourCC(_ data: Data, at offset: Int) -> String {
        guard offset + 4 <= data.count else { return "" }
        return String(bytes: data[offset..<(offset + 4)], encoding: .isoLatin1) ?? ""
    }

    private static func decodeTextField(_ data: Data) -> String? {
        // INFO strings are typically null-terminated ASCII / Latin-1.
        let trimmedNulls = data.prefix { $0 != 0 }
        if let s = String(bytes: trimmedNulls, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            return s
        }
        if let s = String(bytes: trimmedNulls, encoding: .isoLatin1)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            return s
        }
        return nil
    }

    /// AIFF NAME/AUTH/(c) use Pascal strings; ANNO is raw text.
    private static func decodeAiffTextField(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        let pascalLen = Int(data[data.startIndex])
        if pascalLen > 0, pascalLen < data.count, pascalLen <= data.count - 1 {
            let slice = data[(data.startIndex + 1)..<(data.startIndex + 1 + pascalLen)]
            if let s = decodeTextField(Data(slice)) { return s }
        }
        return decodeTextField(data)
    }

    private static func cStringField(_ data: Data, start: Int, length: Int) -> String? {
        guard start + length <= data.count else { return nil }
        let slice = data[start..<(start + length)]
        return decodeTextField(Data(slice))
    }

    private static func fileSize(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }
}
