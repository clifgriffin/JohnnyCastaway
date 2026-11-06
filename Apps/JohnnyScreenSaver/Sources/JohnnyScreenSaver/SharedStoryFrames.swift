// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation
import JohnnyEngine

/// One writer supplies indexed frames to all display views and host processes.
/// Use each connection on one thread. Keep the files in the resource folder.
final class SharedStoryFrames {
    private static let magic: UInt64 = 0x4A4F484E4E594631
    private static let headerSize = 32
    private static let pixelCount = Framebuffer.width * Framebuffer.height
    private static let payloadSize = pixelCount + 64
    private static let fileSize = headerSize + payloadSize

    private let producerFD: Int32
    private let frameFD: Int32
    private let memory: UnsafeMutableRawPointer
    private var producerToken: UInt64 = 0
    private var revision: UInt64 = 0
    private var lastReadToken: UInt64 = 0
    private var lastReadRevision: UInt64 = 0
    private(set) var isProducer = false

    private enum Failure: LocalizedError {
        case systemCall(String, Int32)
        case invalidFrame
        case notProducer

        var errorDescription: String? {
            switch self {
            case let .systemCall(operation, code):
                return "Shared story \(operation): \(String(cString: strerror(code)))"
            case .invalidFrame: return "The shared story frame is invalid."
            case .notProducer: return "This display does not own the shared story."
            }
        }
    }

    init(folder: URL) throws {
        let producerFD = Darwin.open(folder.appendingPathComponent(".johnny-story.lock").path,
                                     O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard producerFD >= 0 else { throw Failure.systemCall("open lock", errno) }
        let frameFD = Darwin.open(folder.appendingPathComponent(".johnny-story.frame").path,
                                  O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard frameFD >= 0 else {
            let code = errno
            Darwin.close(producerFD)
            throw Failure.systemCall("open frame", code)
        }
        do {
            var lockInfo = stat()
            guard fstat(producerFD, &lockInfo) == 0,
                  lockInfo.st_mode & S_IFMT == S_IFREG else { throw Failure.invalidFrame }
            // Only file setup can wait. Frame reads and writes never wait.
            guard flock(frameFD, LOCK_EX) == 0 else {
                throw Failure.systemCall("lock frame", errno)
            }
            defer { flock(frameFD, LOCK_UN) }
            var info = stat()
            guard fstat(frameFD, &info) == 0 else {
                throw Failure.systemCall("inspect frame", errno)
            }
            guard info.st_mode & S_IFMT == S_IFREG else { throw Failure.invalidFrame }
            if info.st_size == 0 {
                guard ftruncate(frameFD, off_t(Self.fileSize)) == 0 else {
                    throw Failure.systemCall("create frame", errno)
                }
            } else if info.st_size != Self.fileSize {
                throw Failure.invalidFrame
            }
            guard let memory = mmap(nil, Self.fileSize, PROT_READ | PROT_WRITE,
                                    MAP_SHARED, frameFD, 0), memory != MAP_FAILED else {
                throw Failure.systemCall("map frame", errno)
            }
            self.producerFD = producerFD
            self.frameFD = frameFD
            self.memory = memory
        } catch {
            Darwin.close(frameFD)
            Darwin.close(producerFD)
            throw error
        }
        _ = claimProducer()
    }

    deinit {
        munmap(memory, Self.fileSize)
        // Closing the descriptor also releases writer ownership after a crash.
        Darwin.close(frameFD)
        Darwin.close(producerFD)
    }

    @discardableResult
    func claimProducer() -> Bool {
        if isProducer { return true }
        guard flock(producerFD, LOCK_EX | LOCK_NB) == 0 else { return false }
        producerToken = UInt64.random(in: 1...UInt64.max)
        revision = 0
        isProducer = true
        return true
    }

    func releaseProducer() {
        guard isProducer else { return }
        flock(producerFD, LOCK_UN)
        isProducer = false
    }

    func publish(framebuffer: Framebuffer, palette: EnginePalette) throws {
        guard isProducer else { throw Failure.notProducer }
        guard framebuffer.pixels.count == Self.pixelCount,
              framebuffer.pixels.allSatisfy({ $0 < 16 || $0 == 255 }),
              palette.colors.count == 16 else { throw Failure.invalidFrame }
        if flock(frameFD, LOCK_EX | LOCK_NB) != 0 {
            if errno == EWOULDBLOCK { return }
            throw Failure.systemCall("lock frame", errno)
        }
        defer { flock(frameFD, LOCK_UN) }
        guard hasFullFile() else { throw Failure.invalidFrame }

        // A failed writer must not leave a partly written frame marked valid.
        memory.storeBytes(of: UInt64(0), as: UInt64.self)
        framebuffer.pixels.withUnsafeBytes { bytes in
            memory.advanced(by: Self.headerSize).copyMemory(from: bytes.baseAddress!,
                                                           byteCount: Self.pixelCount)
        }
        let paletteBytes = memory.advanced(by: Self.headerSize + Self.pixelCount)
            .assumingMemoryBound(to: UInt8.self)
        for (index, color) in palette.colors.enumerated() {
            paletteBytes[index * 4] = color.r
            paletteBytes[index * 4 + 1] = color.g
            paletteBytes[index * 4 + 2] = color.b
            paletteBytes[index * 4 + 3] = color.a
        }
        revision &+= 1
        if revision == 0 {
            producerToken = UInt64.random(in: 1...UInt64.max)
            revision = 1
        }
        memory.storeBytes(of: producerToken, toByteOffset: 8, as: UInt64.self)
        memory.storeBytes(of: revision, toByteOffset: 16, as: UInt64.self)
        memory.storeBytes(of: UInt64(Self.payloadSize), toByteOffset: 24, as: UInt64.self)
        memory.storeBytes(of: Self.magic, as: UInt64.self)
    }

    func readLatest() -> (framebuffer: Framebuffer, palette: EnginePalette)? {
        guard flock(frameFD, LOCK_SH | LOCK_NB) == 0 else { return nil }
        defer { flock(frameFD, LOCK_UN) }
        guard hasFullFile(),
              memory.load(as: UInt64.self) == Self.magic,
              memory.load(fromByteOffset: 24, as: UInt64.self) == Self.payloadSize else {
            return nil
        }
        let token = memory.load(fromByteOffset: 8, as: UInt64.self)
        let revision = memory.load(fromByteOffset: 16, as: UInt64.self)
        guard token != 0, revision != 0,
              token != lastReadToken || revision != lastReadRevision else { return nil }
        let pixels = memory.advanced(by: Self.headerSize).assumingMemoryBound(to: UInt8.self)
        var framebuffer = Framebuffer()
        framebuffer.pixels = Array(UnsafeBufferPointer(start: pixels, count: Self.pixelCount))
        guard framebuffer.pixels.allSatisfy({ $0 < 16 || $0 == 255 }) else { return nil }
        let bytes = pixels.advanced(by: Self.pixelCount)
        let colors = (0..<16).map { index in
            var color = EnginePalette.RGBA(r: bytes[index * 4], g: bytes[index * 4 + 1],
                                           b: bytes[index * 4 + 2])
            color.a = bytes[index * 4 + 3]
            return color
        }
        lastReadToken = token
        lastReadRevision = revision
        return (framebuffer, EnginePalette(colors: colors))
    }

    private func hasFullFile() -> Bool {
        var info = stat()
        return fstat(frameFD, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
            && info.st_size == Self.fileSize
    }
}
