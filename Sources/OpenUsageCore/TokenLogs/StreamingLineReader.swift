import CoreFoundation
import CryptoKit
import Darwin
import Foundation

/// Lightweight POSIX file metadata obtained via `lstat` or `fstat` without materializing iCloud-evicted files.
public struct FileMetadata: Sendable, Equatable, Codable {
    public let size: UInt64
    public let mtimeNanos: Int64
    public let inode: UInt64
    public let device: UInt64
    public let isRegularFile: Bool
    public let isDataless: Bool

    public init(
        size: UInt64,
        mtimeNanos: Int64,
        inode: UInt64,
        device: UInt64 = 0,
        isRegularFile: Bool,
        isDataless: Bool
    ) {
        self.size = size
        self.mtimeNanos = mtimeNanos
        self.inode = inode
        self.device = device
        self.isRegularFile = isRegularFile
        self.isDataless = isDataless
    }

    public func sameIdentity(as other: FileMetadata) -> Bool {
        device == other.device && inode == other.inode
    }

    /// Reads file metadata using `lstat`. Never follows symlinks and never triggers iCloud downloads.
    public static func read(at url: URL) -> FileMetadata? {
        try? readOrThrow(at: url)
    }

    /// Reads file metadata using `lstat`, returning `nil` only when the path does not exist (`ENOENT` / `ENOTDIR`)
    /// and throwing `POSIXError` for filesystem errors such as permission denial (`EACCES`).
    public static func readOrThrow(at url: URL) throws -> FileMetadata? {
        var st = stat()
        var statErrno: Int32 = 0
        let result = url.withUnsafeFileSystemRepresentation { ptr -> Int32 in
            guard let ptr else {
                statErrno = EINVAL
                return -1
            }
            let rc = lstat(ptr, &st)
            if rc != 0 {
                statErrno = errno
            }
            return rc
        }
        if result == 0 {
            return from(stat: st)
        }
        if statErrno == ENOENT || statErrno == ENOTDIR {
            return nil
        }
        throw POSIXError(POSIXErrorCode(rawValue: statErrno) ?? .EIO)
    }

    /// Reads file metadata using `fstat` on an already-open descriptor.
    public static func read(fd: Int32) -> FileMetadata? {
        var st = stat()
        guard Darwin.fstat(fd, &st) == 0 else { return nil }
        return from(stat: st)
    }

    private static func from(stat st: stat) -> FileMetadata {
        let mode = st.st_mode & S_IFMT
        let isRegular = (mode == S_IFREG)
        let isDataless = (st.st_flags & UInt32(SF_DATALESS)) != 0
        let sec = Int64(st.st_mtimespec.tv_sec)
        let nsec = Int64(st.st_mtimespec.tv_nsec)
        let mtimeNanos = sec &* 1_000_000_000 &+ nsec

        return FileMetadata(
            size: UInt64(max(0, st.st_size)),
            mtimeNanos: mtimeNanos,
            inode: UInt64(st.st_ino),
            device: UInt64(UInt32(bitPattern: st.st_dev)),
            isRegularFile: isRegular,
            isDataless: isDataless
        )
    }
}

/// Decision returned by a line consumer in `StreamingLineReader`.
public enum LineConsumeAction: Sendable {
    /// Advance the consumed byte offset past this line.
    case advance
    /// Keep the consumed byte offset before this line (e.g. incomplete trailing JSON line mid-write).
    case keepUnconsumed
}

/// Result of streaming lines from an open file descriptor, tying consumed offset and SHA-256 fingerprint
/// directly to the exact bytes read from that descriptor.
public struct LineReadResult: Sendable, Equatable {
    public let consumedOffset: UInt64
    public let eofOffset: UInt64
    public let consumedFingerprint: String

    public init(consumedOffset: UInt64, eofOffset: UInt64, consumedFingerprint: String) {
        self.consumedOffset = consumedOffset
        self.eofOffset = eofOffset
        self.consumedFingerprint = consumedFingerprint
    }
}

/// Low-memory buffered POSIX line reader that streams arbitrarily large files from a given byte offset.
public enum StreamingLineReader {
    public static let defaultChunkSize = 64 * 1024
    /// Cap single-line accumulation to protect against corrupt multi-hundred-MB single lines without newlines.
    private static let maxLineBytes = 64 * 1024 * 1024
    /// Maximum whole-file read size for legacy JSON files.
    public static let maxWholeFileBytes = 128 * 1024 * 1024

    /// Opens a regular file read-only without following a trailing symlink.
    public static func openReadOnly(at url: URL) -> Int32 {
        url.withUnsafeFileSystemRepresentation { ptr -> Int32 in
            guard let ptr else {
                errno = EINVAL
                return -1
            }
            return Darwin.open(ptr, O_RDONLY | O_NOFOLLOW)
        }
    }

    /// Verifies that the path still resolves to the exact same regular file (`st_dev`, `st_ino`)
    /// and that neither the open descriptor nor the path changed size or mtime since `openMeta`.
    public static func verifyUnchanged(at url: URL, fd: Int32, since openMeta: FileMetadata) -> Bool {
        guard let fdMetaAfter = FileMetadata.read(fd: fd),
              let pathMetaAfter = FileMetadata.read(at: url) else {
            return false
        }
        guard fdMetaAfter.isRegularFile, !fdMetaAfter.isDataless,
              pathMetaAfter.isRegularFile, !pathMetaAfter.isDataless else {
            return false
        }
        guard pathMetaAfter.sameIdentity(as: openMeta),
              fdMetaAfter.sameIdentity(as: openMeta) else {
            return false
        }
        guard fdMetaAfter.size == openMeta.size,
              fdMetaAfter.mtimeNanos == openMeta.mtimeNanos,
              pathMetaAfter.size == openMeta.size,
              pathMetaAfter.mtimeNanos == openMeta.mtimeNanos else {
            return false
        }
        return true
    }

    /// Formats a `SHA256` hasher's digest as lowercase hex without mutating the caller's hasher.
    public static func hexDigest(of hasher: SHA256) -> String {
        hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Streams `0..<offset` from an already-open descriptor `fd` (seeking to byte 0 first) into a `SHA256`
    /// hasher, leaving `fd` positioned at `offset`. Returns `nil` if the file ends before `offset` or I/O fails.
    public static func prefixHasher(fd: Int32, upToOffset offset: UInt64) -> SHA256? {
        guard Darwin.lseek(fd, 0, SEEK_SET) == 0 else { return nil }
        var hasher = SHA256()
        guard offset > 0 else { return hasher }

        let chunkSize = defaultChunkSize
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { buffer.deallocate() }

        var remaining = offset
        while remaining > 0 {
            let toRead = Int(min(UInt64(chunkSize), remaining))
            let bytesRead = Darwin.read(fd, buffer, toRead)
            if bytesRead < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if bytesRead == 0 {
                return nil
            }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: bytesRead))
            remaining -= UInt64(bytesRead)
        }
        return hasher
    }

    /// Streams lines from an already-open descriptor `fd` starting at `startOffset` (in bytes),
    /// simultaneously updating `initialHasher` over the exact consumed bytes `0..<consumedOffset`.
    public static func readLines(
        fd: Int32,
        fromOffset startOffset: UInt64 = 0,
        initialHasher: SHA256? = nil,
        chunkSize: Int = defaultChunkSize,
        handler: (_ lineData: Data, _ endedWithNewline: Bool) -> LineConsumeAction
    ) throws -> LineReadResult {
        let sought = Darwin.lseek(fd, off_t(startOffset), SEEK_SET)
        guard sought >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let effectiveChunkSize = max(1024, chunkSize)
        let readBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: effectiveChunkSize)
        defer { readBuffer.deallocate() }

        var committedHasher = initialHasher ?? SHA256()
        var runningHasher = committedHasher
        var pendingLine = Data()
        pendingLine.reserveCapacity(4096)
        var lineOverflowed = false
        var lineStartOffset = startOffset
        var consumedOffset = startOffset
        var currentFileOffset = startOffset

        while true {
            let bytesRead = Darwin.read(fd, readBuffer, effectiveChunkSize)
            if bytesRead < 0 {
                if errno == EINTR {
                    continue
                }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if bytesRead == 0 {
                break
            }

            let sliceStart = readBuffer
            var cursor = 0
            while cursor < bytesRead {
                // Scan for 0x0A ('\n')
                var newlinePos = -1
                if let found = memchr(sliceStart.advanced(by: cursor), 0x0A, bytesRead - cursor) {
                    newlinePos = found.assumingMemoryBound(to: UInt8.self) - sliceStart
                }

                if newlinePos >= 0 {
                    let rawSegmentLength = (newlinePos + 1) - cursor
                    runningHasher.update(
                        bufferPointer: UnsafeRawBufferPointer(
                            start: sliceStart.advanced(by: cursor),
                            count: rawSegmentLength
                        )
                    )

                    let segmentLength = newlinePos - cursor
                    if !lineOverflowed {
                        if pendingLine.count + segmentLength <= maxLineBytes {
                            if segmentLength > 0 {
                                pendingLine.append(sliceStart.advanced(by: cursor), count: segmentLength)
                            }
                        } else {
                            lineOverflowed = true
                            pendingLine.removeAll(keepingCapacity: true)
                        }
                    }

                    let lineEndOffset = currentFileOffset + UInt64(newlinePos + 1)
                    if !lineOverflowed {
                        // Strip trailing '\r' if CRLF
                        if pendingLine.last == 0x0D {
                            pendingLine.removeLast()
                        }
                        if !pendingLine.isEmpty {
                            _ = handler(pendingLine, true)
                        }
                    }
                    consumedOffset = lineEndOffset
                    committedHasher = runningHasher
                    lineStartOffset = lineEndOffset
                    pendingLine.removeAll(keepingCapacity: true)
                    lineOverflowed = false
                    cursor = newlinePos + 1
                } else {
                    let remaining = bytesRead - cursor
                    runningHasher.update(
                        bufferPointer: UnsafeRawBufferPointer(
                            start: sliceStart.advanced(by: cursor),
                            count: remaining
                        )
                    )
                    if !lineOverflowed {
                        if pendingLine.count + remaining <= maxLineBytes {
                            pendingLine.append(sliceStart.advanced(by: cursor), count: remaining)
                        } else {
                            lineOverflowed = true
                            pendingLine.removeAll(keepingCapacity: true)
                        }
                    }
                    cursor = bytesRead
                }
            }

            currentFileOffset += UInt64(bytesRead)
        }

        // Handle any trailing bytes after the final newline.
        if !lineOverflowed, !pendingLine.isEmpty {
            if pendingLine.last == 0x0D {
                pendingLine.removeLast()
            }
            if pendingLine.isEmpty {
                consumedOffset = currentFileOffset
                committedHasher = runningHasher
            } else {
                let action = handler(pendingLine, false)
                switch action {
                case .advance:
                    consumedOffset = currentFileOffset
                    committedHasher = runningHasher
                case .keepUnconsumed:
                    consumedOffset = lineStartOffset
                }
            }
        } else if lineOverflowed {
            consumedOffset = currentFileOffset
            committedHasher = runningHasher
        }

        return LineReadResult(
            consumedOffset: consumedOffset,
            eofOffset: currentFileOffset,
            consumedFingerprint: hexDigest(of: committedHasher)
        )
    }

    /// Reads an entire already-open descriptor `fd` from byte 0 to EOF, returning both the exact bytes
    /// and their SHA-256 hex digest in a single pass.
    public static func readAllBytes(
        fd: Int32,
        maxBytes: Int = maxWholeFileBytes
    ) throws -> (data: Data, fingerprint: String) {
        guard Darwin.lseek(fd, 0, SEEK_SET) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let chunkSize = defaultChunkSize
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { buffer.deallocate() }

        var data = Data()
        var hasher = SHA256()
        while true {
            let bytesRead = Darwin.read(fd, buffer, chunkSize)
            if bytesRead < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if bytesRead == 0 {
                break
            }
            if data.count + bytesRead > maxBytes {
                throw POSIXError(.EFBIG)
            }
            data.append(buffer, count: bytesRead)
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: bytesRead))
        }
        return (data: data, fingerprint: hexDigest(of: hasher))
    }

    /// Streams lines from `url` starting at `startOffset` (in bytes).
    /// Returns the byte offset immediately after the last consumed line.
    @discardableResult
    public static func readLines(
        at url: URL,
        fromOffset startOffset: UInt64 = 0,
        chunkSize: Int = defaultChunkSize,
        handler: (_ lineData: Data, _ endedWithNewline: Bool) -> LineConsumeAction
    ) throws -> UInt64 {
        let fd = openReadOnly(at: url)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = Darwin.close(fd) }

        let result = try readLines(
            fd: fd,
            fromOffset: startOffset,
            initialHasher: nil,
            chunkSize: chunkSize,
            handler: handler
        )
        return result.consumedOffset
    }

    /// Computes a full streaming SHA-256 fingerprint of the consumed prefix `0..<offset` of `url`
    /// using a bounded 64 KB buffer without retaining raw log bytes. Returns `nil` if the file
    /// cannot be read or ends before `offset`.
    public static func prefixFingerprint(at url: URL, upToOffset offset: UInt64) -> String? {
        let fd = openReadOnly(at: url)
        guard fd >= 0 else { return nil }
        defer { _ = Darwin.close(fd) }

        guard let hasher = prefixHasher(fd: fd, upToOffset: offset) else {
            return nil
        }
        return hexDigest(of: hasher)
    }

    /// Fast byte-subsequence check used to skip irrelevant JSONL lines before JSON decoding.
    public static func dataContainsASCII(_ data: Data, needle: [UInt8]) -> Bool {
        let needleCount = needle.count
        guard needleCount > 0, data.count >= needleCount else { return false }
        return data.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) -> Bool in
            guard let rawBase = rawBuffer.baseAddress else {
                return false
            }
            let base = rawBase.assumingMemoryBound(to: UInt8.self)
            let total = rawBuffer.count
            let firstByte = Int32(needle[0])
            let limit = total - needleCount
            var i = 0
            while i <= limit {
                guard let found = memchr(base.advanced(by: i), firstByte, limit - i + 1) else {
                    return false
                }
                let pos = UnsafePointer(found.assumingMemoryBound(to: UInt8.self)) - base
                if needleCount == 1 || memcmp(base.advanced(by: pos), needle, needleCount) == 0 {
                    return true
                }
                i = pos + 1
            }
            return false
        }
    }
}

/// Fast, thread-safe timestamp parser for ISO 8601 strings and Unix epoch numbers (seconds or milliseconds).
public enum LogTimestampParser {
    /// Parses an ISO 8601 string such as `2026-11-26T12:34:56.789Z` or `2026-11-26T07:34:56-05:00`.
    public static func parseISO8601(_ string: String) -> Date? {
        let bytes = Array(string.utf8)
        // Minimum valid length: "YYYY-MM-DDTHH:MM:SSZ" (20 bytes)
        guard bytes.count >= 19 else { return nil }

        func digit(_ index: Int) -> Int? {
            guard index < bytes.count else { return nil }
            let b = bytes[index]
            guard b >= 48 && b <= 57 else { return nil }
            return Int(b - 48)
        }

        func twoDigits(_ start: Int) -> Int? {
            guard let a = digit(start), let b = digit(start + 1) else { return nil }
            return a * 10 + b
        }

        func fourDigits(_ start: Int) -> Int? {
            guard let a = digit(start),
                  let b = digit(start + 1),
                  let c = digit(start + 2),
                  let d = digit(start + 3) else { return nil }
            return a * 1000 + b * 100 + c * 10 + d
        }

        guard let year = fourDigits(0), (1...9999).contains(year),
              bytes[4] == 45, // '-'
              let month = twoDigits(5), (1...12).contains(month),
              bytes[7] == 45, // '-'
              let day = twoDigits(8), (1...daysInMonth(year: year, month: month)).contains(day),
              (bytes[10] == 84 || bytes[10] == 116 || bytes[10] == 32), // 'T' | 't' | ' '
              let hour = twoDigits(11), (0...23).contains(hour),
              bytes[13] == 58, // ':'
              let minute = twoDigits(14), (0...59).contains(minute),
              bytes[16] == 58, // ':'
              let second = twoDigits(17), (0...60).contains(second) else {
            return nil
        }

        var idx = 19
        var fractionalSeconds = 0.0
        if idx < bytes.count && (bytes[idx] == 46 || bytes[idx] == 44) { // '.' or ','
            idx += 1
            var scale = 0.1
            var digitsRead = 0
            while idx < bytes.count, let d = digit(idx) {
                if digitsRead < 9 {
                    fractionalSeconds += Double(d) * scale
                    scale *= 0.1
                }
                digitsRead += 1
                idx += 1
            }
            guard digitsRead > 0 else { return nil }
        }

        var tzOffsetSeconds = 0
        if idx < bytes.count {
            let marker = bytes[idx]
            if marker == 90 || marker == 122 { // 'Z' or 'z'
                idx += 1
            } else if marker == 43 || marker == 45 { // '+' or '-'
                let sign = (marker == 43) ? 1 : -1
                idx += 1
                guard let tzHour = twoDigits(idx), (0...23).contains(tzHour) else { return nil }
                idx += 2
                var tzMinute = 0
                if idx < bytes.count {
                    if bytes[idx] == 58 { // ':'
                        idx += 1
                    }
                    guard let parsedMin = twoDigits(idx), (0...59).contains(parsedMin) else { return nil }
                    tzMinute = parsedMin
                    idx += 2
                }
                tzOffsetSeconds = sign * (tzHour * 3600 + tzMinute * 60)
            } else {
                return nil
            }
        }

        guard idx == bytes.count else { return nil }

        let expectedYear = Int32(year - 1900)
        let expectedMonth = Int32(month - 1)
        let expectedDay = Int32(day)
        let expectedHour = Int32(hour)
        let expectedMinute = Int32(minute)
        let clampedSecond = Int32(min(59, second))

        var tmValue = tm()
        tmValue.tm_year = expectedYear
        tmValue.tm_mon = expectedMonth
        tmValue.tm_mday = expectedDay
        tmValue.tm_hour = expectedHour
        tmValue.tm_min = expectedMinute
        tmValue.tm_sec = clampedSecond

        let epochSeconds = timegm(&tmValue)
        guard epochSeconds != -1 || (year == 1969 && month == 12 && day == 31 && hour == 23 && minute == 59 && second == 59) else {
            return nil
        }
        // Reject any silent calendar normalization performed by timegm.
        guard tmValue.tm_year == expectedYear,
              tmValue.tm_mon == expectedMonth,
              tmValue.tm_mday == expectedDay,
              tmValue.tm_hour == expectedHour,
              tmValue.tm_min == expectedMinute,
              tmValue.tm_sec == clampedSecond else {
            return nil
        }

        let timestamp = Double(epochSeconds - tzOffsetSeconds) + fractionalSeconds
        return Date(timeIntervalSince1970: timestamp)
    }

    private static func isLeapYear(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0)
    }

    private static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        case 2: return isLeapYear(year) ? 29 : 28
        default: return 0
        }
    }

    /// Parses a numeric Unix timestamp (auto-detecting milliseconds vs seconds).
    public static func parseEpoch(_ value: Double) -> Date? {
        guard value.isFinite, value > 0 else { return nil }
        // Values >= 1e11 are treated as milliseconds (post-1973 ms timestamps are >= 1e11; seconds won't reach 1e11 until year 5138).
        let seconds = value >= 100_000_000_000 ? (value / 1_000.0) : value
        // Bound to year 9999-12-31T23:59:59Z so malformed huge numbers never produce out-of-range dates.
        guard seconds.isFinite, seconds > 0, seconds <= 253_402_300_800.0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    public static func parseEpoch(_ value: Int64) -> Date? {
        guard value > 0 else { return nil }
        return parseEpoch(Double(value))
    }

    /// Parses a JSON timestamp field (either an ISO 8601 string or a Unix epoch number), rejecting booleans.
    public static func parseJSONTimestamp(_ raw: Any?) -> Date? {
        guard let raw, !(raw is NSNull) else { return nil }
        if type(of: raw) == Bool.self {
            return nil
        }
        if CFGetTypeID(raw as AnyObject) == CFBooleanGetTypeID() {
            return nil
        }
        if let str = raw as? String {
            return parseISO8601(str)
        }
        if let num = raw as? NSNumber {
            if CFGetTypeID(num) == CFBooleanGetTypeID() {
                return nil
            }
            return parseEpoch(num.doubleValue)
        }
        return nil
    }
}

/// Safe recursive directory enumerator that skips internal symlinks and reports `FileMetadata` (including `isDataless`).
public enum SafeDirectoryScanner {
    /// Returns sorted regular files under `root` matching `predicate`.
    /// Resolves symlinks on `root` itself (e.g. a symlinked `~/.claude/projects`), while skipping symlinks inside the tree.
    public static func discoverFiles(
        under root: URL,
        matching predicate: (URL) -> Bool
    ) -> [(url: URL, relativePath: String, metadata: FileMetadata)] {
        let fm = FileManager.default
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: resolvedRoot.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        let rootPrefix = resolvedRoot.path.hasSuffix("/")
            ? resolvedRoot.path
            : resolvedRoot.path + "/"

        guard let enumerator = fm.enumerator(
            at: resolvedRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants]
        ) else {
            return []
        }

        var results: [(url: URL, relativePath: String, metadata: FileMetadata)] = []
        while let element = enumerator.nextObject() as? URL {
            // Never follow symlinks to avoid cycles or escaping the log directory.
            if let values = try? element.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]) {
                if values.isSymbolicLink == true {
                    if values.isDirectory == true {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                if values.isDirectory == true {
                    continue
                }
            }

            guard predicate(element) else { continue }
            guard let metadata = FileMetadata.read(at: element),
                  metadata.isRegularFile else {
                continue
            }

            let fullPath = element.standardizedFileURL.path
            let relativePath = fullPath.hasPrefix(rootPrefix)
                ? String(fullPath.dropFirst(rootPrefix.count))
                : element.lastPathComponent
            results.append((url: element, relativePath: relativePath, metadata: metadata))
        }

        results.sort { $0.relativePath < $1.relativePath }
        return results
    }
}
