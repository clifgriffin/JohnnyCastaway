// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation
import Testing
import JohnnyEngine
@testable import JohnnyScreenSaver

struct SharedStoryFramesTests {
    @Test("Displays share frames and permit one writer at a time")
    func sharedFrames() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var writer: SharedStoryFrames? = try SharedStoryFrames(folder: folder)
        let first = try SharedStoryFrames(folder: folder)
        let second = try SharedStoryFrames(folder: folder)
        #expect(writer?.isProducer == true)
        #expect(!first.isProducer && !second.isProducer)
        #expect(first.readLatest() == nil)
        #expect(!first.claimProducer())

        var framebuffer = Framebuffer(filledWith: 3)
        framebuffer.pixels[10] = 255
        var color = EnginePalette.RGBA(r: 11, g: 22, b: 33)
        color.a = 44
        let palette = EnginePalette(colors: Array(repeating: color, count: 16))
        try writer?.publish(framebuffer: framebuffer, palette: palette)

        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        probe.arguments = ["-module-cache-path", folder.appendingPathComponent("module-cache").path,
                           "-e", """
            import Darwin
            import Foundation
            let fd = open(CommandLine.arguments[1], O_RDWR)
            guard fd >= 0 else { exit(2) }
            guard flock(fd, LOCK_EX | LOCK_NB) == -1, errno == EWOULDBLOCK else { exit(1) }
            let bytes = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
            var pixels = [UInt8](repeating: 3, count: 640 * 480)
            pixels[10] = 255
            let colors = Data(Array(repeating: [UInt8](arrayLiteral: 11, 22, 33, 44), count: 16).flatMap { $0 })
            guard bytes.count == 32 + pixels.count + 64,
                  bytes.subdata(in: 32..<(32 + pixels.count)) == Data(pixels),
                  bytes.suffix(64) == colors else { exit(3) }
            """, folder.appendingPathComponent(".johnny-story.lock").path,
                           folder.appendingPathComponent(".johnny-story.frame").path]
        try probe.run()
        probe.waitUntilExit()
        #expect(probe.terminationStatus == 0)

        for reader in [first, second] {
            let frame = try #require(reader.readLatest())
            #expect(frame.framebuffer.pixels == framebuffer.pixels)
            #expect(frame.palette.colors.allSatisfy { $0.r == 11 && $0.g == 22 && $0.b == 33 && $0.a == 44 })
            #expect(reader.readLatest() == nil)
        }

        writer?.releaseProducer()
        #expect(first.claimProducer())
        #expect(!second.claimProducer())
        framebuffer.pixels[0] = 9
        try first.publish(framebuffer: framebuffer, palette: palette)
        #expect(second.readLatest()?.framebuffer.pixels == framebuffer.pixels)
        first.releaseProducer()
        #expect(writer?.claimProducer() == true)
        writer = nil
        #expect(second.claimProducer())
    }

    @Test("Busy, malformed, and truncated frames are not read")
    func invalidFrames() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = try SharedStoryFrames(folder: folder)
        let reader = try SharedStoryFrames(folder: folder)
        let frameURL = folder.appendingPathComponent(".johnny-story.frame")
        let handle = try FileHandle(forUpdating: frameURL)
        defer { try? handle.close() }

        #expect(flock(handle.fileDescriptor, LOCK_EX | LOCK_NB) == 0)
        #expect(reader.readLatest() == nil)
        try writer.publish(framebuffer: Framebuffer(filledWith: 2), palette: .black)
        #expect(flock(handle.fileDescriptor, LOCK_UN) == 0)
        #expect(reader.readLatest() == nil)

        try writer.publish(framebuffer: Framebuffer(filledWith: 2), palette: .black)
        try handle.seek(toOffset: 32)
        try handle.write(contentsOf: Data([16]))
        #expect(reader.readLatest() == nil)
        try writer.publish(framebuffer: Framebuffer(filledWith: 4), palette: .black)
        #expect(reader.readLatest()?.framebuffer.pixels[0] == 4)

        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data(repeating: 0, count: 8))
        #expect(reader.readLatest() == nil)
        try handle.truncate(atOffset: 1)
        #expect(reader.readLatest() == nil)
        do {
            _ = try SharedStoryFrames(folder: folder)
            Issue.record("A truncated frame file was accepted.")
        } catch { }
        do {
            try writer.publish(framebuffer: Framebuffer(), palette: .black)
            Issue.record("A frame was written to a truncated file.")
        } catch { }
    }
}
