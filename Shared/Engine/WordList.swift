// A language's built-in word list, read straight from a memory-mapped file made by
// tools/build_lexicon.py. Mapped pages are clean, so they don't count against the keyboard's
// memory limit the way loaded strings would. Same behaviour as WordList in core.js.

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A read-only file mapped into memory.
final class MappedFile {
    let base: UnsafeRawPointer
    let count: Int

    init?(path: String) {
        let fd = open(path, O_RDONLY)
        if fd < 0 { return nil }
        defer { close(fd) }
        var st = stat()
        if fstat(fd, &st) != 0 || st.st_size <= 0 { return nil }
        let size = Int(st.st_size)
        guard let p = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0), p != MAP_FAILED else { return nil }
        base = UnsafeRawPointer(p)
        count = size
    }

    deinit {
        munmap(UnsafeMutableRawPointer(mutating: base), count)
    }
}

public enum WordListError: Error, CustomStringConvertible {
    case unreadable(String)
    case badFormat(String)

    public var description: String {
        switch self {
        case .unreadable(let p): return "can't read word list \(p)"
        case .badFormat(let p): return "word list \(p) is damaged"
        }
    }
}

private let uidLock = NSLock()
private var nextUid = 1

public final class WordList {
    /// Unique per loaded list (for caches keyed by list).
    public let uid: Int
    public let size: Int
    /// Language code ("en"), used to find the shared-word maps next to it.
    public let lang: String
    private let file: MappedFile
    private let scores: UnsafePointer<Int16>
    private let dispOff: UnsafePointer<UInt32>
    private let keyOff: UnsafePointer<UInt32>
    private let sortedIds: UnsafePointer<Int32>
    private let flStart: UnsafePointer<UInt32>
    private let flIds: UnsafePointer<Int32>
    private let fStart: UnsafePointer<UInt32>
    private let fIds: UnsafePointer<Int32>
    private let disp: UnsafePointer<UInt8>
    private let keys: UnsafePointer<UInt8>
    /// Which of this list's words another list has too, by the other list's language.
    private var sharedMaps = [String: SharedMap]()
    private let sharedLock = NSLock()
    /// Directory the list came from (for the shared-word maps).
    private let directory: String

    /// Loads `<directory>/<lang>.lex`.
    public convenience init(directory: String, lang: String) throws {
        try self.init(path: (directory as NSString).appendingPathComponent("\(lang).lex"), lang: lang)
    }

    public init(path: String, lang: String) throws {
        guard let f = MappedFile(path: path) else { throw WordListError.unreadable(path) }
        uidLock.lock()
        uid = nextUid
        nextUid += 1
        uidLock.unlock()
        file = f
        self.lang = lang
        directory = (path as NSString).deletingLastPathComponent
        let b = f.base
        func u32(_ off: Int) -> UInt32 { b.loadUnaligned(fromByteOffset: off, as: UInt32.self).littleEndian }
        guard f.count >= 32,
              b.load(fromByteOffset: 0, as: UInt8.self) == 0x54, // T
              b.load(fromByteOffset: 1, as: UInt8.self) == 0x52, // R
              b.load(fromByteOffset: 2, as: UInt8.self) == 0x4C, // L
              b.load(fromByteOffset: 3, as: UInt8.self) == 0x58, // X
              u32(4) == 1 else { throw WordListError.badFormat(path) }
        let n = Int(u32(8))
        let dispBytes = Int(u32(12))
        let keyBytes = Int(u32(16))
        func pad4(_ x: Int) -> Int { (x + 3) & ~3 }
        var off = 32
        let scoreAt = off; off += pad4(2 * n)
        let dispOffAt = off; off += 4 * (n + 1)
        let keyOffAt = off; off += 4 * (n + 1)
        let sortedAt = off; off += 4 * n
        let flStartAt = off; off += 4 * 677
        let flIdsAt = off; off += 4 * n
        let fStartAt = off; off += 4 * 27
        let fIdsAt = off; off += 4 * n
        let dispAt = off; off += pad4(dispBytes)
        let keysAt = off; off += pad4(keyBytes)
        guard off == f.count else { throw WordListError.badFormat(path) }
        size = n
        scores = (b + scoreAt).assumingMemoryBound(to: Int16.self)
        dispOff = (b + dispOffAt).assumingMemoryBound(to: UInt32.self)
        keyOff = (b + keyOffAt).assumingMemoryBound(to: UInt32.self)
        sortedIds = (b + sortedAt).assumingMemoryBound(to: Int32.self)
        flStart = (b + flStartAt).assumingMemoryBound(to: UInt32.self)
        flIds = (b + flIdsAt).assumingMemoryBound(to: Int32.self)
        fStart = (b + fStartAt).assumingMemoryBound(to: UInt32.self)
        fIds = (b + fIdsAt).assumingMemoryBound(to: Int32.self)
        disp = (b + dispAt).assumingMemoryBound(to: UInt8.self)
        keys = (b + keysAt).assumingMemoryBound(to: UInt8.self)
        // Spot checks, so a damaged file fails here rather than mid-swipe.
        guard dispOff[n] == UInt32(dispBytes), keyOff[n] == UInt32(keyBytes),
              flStart[676] == UInt32(n), fStart[26] == UInt32(n) else { throw WordListError.badFormat(path) }
    }

    // ---- one word ----

    /// zipf frequency * 100.
    @inline(__always) public func score(_ id: Int) -> Int16 { scores[id] }

    @inline(__always) public func keyLength(_ id: Int) -> Int { Int(keyOff[id + 1] &- keyOff[id]) }

    @inline(__always) public func keyBytes(_ id: Int) -> UnsafeBufferPointer<UInt8> {
        let a = Int(keyOff[id])
        return UnsafeBufferPointer(start: keys + a, count: Int(keyOff[id + 1]) - a)
    }

    @inline(__always) func displayBytes(_ id: Int) -> UnsafeBufferPointer<UInt8> {
        let a = Int(dispOff[id])
        return UnsafeBufferPointer(start: disp + a, count: Int(dispOff[id + 1]) - a)
    }

    public func key(_ id: Int) -> String { String(decoding: keyBytes(id), as: UTF8.self) }

    public func display(_ id: Int) -> String { String(decoding: displayBytes(id), as: UTF8.self) }

    // ---- groups ----

    /// Ids of words that start with letter `first` and end with `last` (0-25), in id order.
    @inline(__always) public func withFirstLast(_ first: Int, _ last: Int) -> UnsafeBufferPointer<Int32> {
        let b = first * 26 + last
        let a = Int(flStart[b])
        return UnsafeBufferPointer(start: flIds + a, count: Int(flStart[b + 1]) - a)
    }

    /// Ids of words that start with letter `first` (0-25), in id order.
    @inline(__always) public func withFirst(_ first: Int) -> UnsafeBufferPointer<Int32> {
        let a = Int(fStart[first])
        return UnsafeBufferPointer(start: fIds + a, count: Int(fStart[first + 1]) - a)
    }

    /// Id of the word spelled like this ignoring case (accents count), or -1.
    public func find(_ word: String) -> Int {
        let lower = word.lowercased()
        let key = keyOf(lower)
        if key.isEmpty { return -1 }
        let r = keyRange(Array(key.utf8))
        var pos = r.lowerBound
        while pos < r.upperBound {
            let id = Int(sortedIds[pos])
            if display(id).lowercased() == lower { return id }
            pos += 1
        }
        return -1
    }

    /// Ids of words with exactly this key ("its" gives its and it's), in id order.
    public func withKey(_ key: String) -> [Int] {
        if key.isEmpty { return [] }
        let r = keyRange(Array(key.utf8))
        var out = [Int]()
        out.reserveCapacity(r.count)
        for pos in r { out.append(Int(sortedIds[pos])) }
        return out
    }

    /// [start, end) positions, in key order, of words whose key starts with prefix.
    public func prefixRange(_ prefix: String) -> Range<Int> {
        // In key order: keys before the prefix, the prefix itself, keys starting with it, the rest.
        let p = Array(prefix.utf8)
        let a = lowerBound(p)
        var lo = a
        var hi = size
        while lo < hi {
            let mid = (lo + hi) >> 1
            if compareKey(Int(sortedIds[mid]), p) != .greater { lo = mid + 1 } else { hi = mid }
        }
        return a..<lo
    }

    @inline(__always) public func sortedId(_ position: Int) -> Int { Int(sortedIds[position]) }

    // ---- shared words ----

    /// One byte per word of this list: 1 when `other` has the word spelled exactly the same.
    public func shared(with other: WordList) -> SharedMap {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        if let m = sharedMaps[other.lang] { return m }
        let path = (directory as NSString).appendingPathComponent("shared-\(lang)-\(other.lang).bin")
        let m: SharedMap
        if let f = MappedFile(path: path), f.count == size {
            m = SharedMap(file: f)
        } else {
            // Not shipped for this pair: work it out (costs memory, so the build makes them).
            var set = Set<String>()
            set.reserveCapacity(other.size)
            for i in 0..<other.size { set.insert(other.display(i)) }
            var bytes = [UInt8](repeating: 0, count: size)
            for i in 0..<size where set.contains(display(i)) { bytes[i] = 1 }
            m = SharedMap(bytes: bytes)
        }
        sharedMaps[other.lang] = m
        return m
    }

    // ---- key search ----

    private enum KeyOrder { case less, prefixed, equal, greater }

    /// Where word `id`'s key sits against `p`: before it, starting with it (longer), equal, or after.
    @inline(__always) private func compareKey(_ id: Int, _ p: [UInt8]) -> KeyOrder {
        let k = keyBytes(id)
        let n = min(k.count, p.count)
        var i = 0
        while i < n {
            let a = k[i]
            let b = p[i]
            if a != b { return a < b ? .less : .greater }
            i += 1
        }
        if k.count == p.count { return .equal }
        return k.count < p.count ? .less : .prefixed
    }

    /// First position whose key is not less than p.
    private func lowerBound(_ p: [UInt8]) -> Int {
        var lo = 0
        var hi = size
        while lo < hi {
            let mid = (lo + hi) >> 1
            if compareKey(Int(sortedIds[mid]), p) == .less { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private func keyRange(_ p: [UInt8]) -> Range<Int> {
        let a = lowerBound(p)
        var b = a
        while b < size && compareKey(Int(sortedIds[b]), p) == .equal { b += 1 }
        return a..<b
    }
}

/// Which words of one list another list also has (see WordList.shared(with:)).
public final class SharedMap {
    private let file: MappedFile?
    private let bytes: [UInt8]
    private let ptr: UnsafePointer<UInt8>?

    init(file: MappedFile) {
        self.file = file
        bytes = []
        ptr = file.base.assumingMemoryBound(to: UInt8.self)
    }

    init(bytes: [UInt8]) {
        file = nil
        self.bytes = bytes
        ptr = nil
    }

    @inline(__always) public subscript(_ id: Int) -> Bool {
        if let p = ptr { return p[id] == 1 }
        return bytes[id] == 1
    }
}
