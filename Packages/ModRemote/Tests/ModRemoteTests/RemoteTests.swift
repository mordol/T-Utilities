import Foundation
import Testing
@testable import ModRemote

struct RemoteProtocolTests {
    static let samples: [RemoteMessage] = [
        .hello(version: RemoteMessage.version, maxWidth: 1920),
        .videoConfig(width: 1920, height: 1200, parameterSets: [Data([0x67, 1, 2]), Data([0x68, 3])]),
        .videoFrame(isKeyFrame: true, data: Data(repeating: 7, count: 5000)),
        .videoFrame(isKeyFrame: false, data: Data()),
        .input(.mouseMove(x: 0.25, y: 1)),
        .input(.mouseDown(button: .right, x: 0.5, y: 0.5, clickCount: 2)),
        .input(.mouseUp(button: .other, x: 0, y: 0.75, clickCount: 1)),
        .input(.scroll(dx: -3, dy: 120, isPrecise: true)),
        .input(.key(code: 0x37, isDown: true, isRepeat: false, flags: 1 << 20)),
        .input(.key(code: 0, isDown: false, isRepeat: true, flags: 0)),
        .setMaxWidth(1280),
        .requestKeyFrame,
        .ping,
        .pong,
        .bye(reason: "다른 기기가 이미 연결되어 있습니다"),
    ]

    @Test func everyMessageRoundTrips() throws {
        var deframer = MessageDeframer()
        let stream = Self.samples.reduce(Data()) { $0 + $1.encoded() }
        #expect(try deframer.append(stream) == Self.samples)
    }

    @Test func partialMessagesWaitForTheRest() throws {
        var deframer = MessageDeframer()
        let stream = Self.samples.reduce(Data()) { $0 + $1.encoded() }
        var received: [RemoteMessage] = []
        var offset = 0
        // Odd chunk size so boundaries fall inside headers and bodies.
        while offset < stream.count {
            let end = min(offset + 7, stream.count)
            received += try deframer.append(stream.subdata(in: offset ..< end))
            offset = end
        }
        #expect(received == Self.samples)
    }

    @Test func rejectsBrokenStreams() {
        var deframer = MessageDeframer()
        #expect(throws: RemoteProtocolError.self) { try deframer.append(Data([0xFF, 0xFF, 0xFF, 0xFF, 1])) }
        var unknown = MessageDeframer()
        #expect(throws: RemoteProtocolError.self) { try unknown.append(Data([0, 0, 0, 1, 99])) }
        var truncated = MessageDeframer()
        #expect(throws: RemoteProtocolError.self) { try truncated.append(Data([0, 0, 0, 2, 1, 0])) }
    }
}

struct TailnetTests {
    @Test func onlyCGNATRangeIsTailnet() {
        #expect(Tailnet.isTailnetIPv4("100.86.45.115"))
        #expect(Tailnet.isTailnetIPv4("100.64.0.1"))
        #expect(Tailnet.isTailnetIPv4("100.127.255.255"))
        #expect(!Tailnet.isTailnetIPv4("100.128.0.1"))
        #expect(!Tailnet.isTailnetIPv4("100.63.0.1"))
        #expect(!Tailnet.isTailnetIPv4("192.168.0.10"))
        #expect(!Tailnet.isTailnetIPv4("fd7a:115c:a1e0::e2c:2d74"))
        #expect(!Tailnet.isTailnetIPv4("100.86.45"))
    }

    @Test func statusListsOtherMacsOnlineFirst() throws {
        let json = #"""
        {"BackendState":"Running",
         "Self":{"HostName":"me","OS":"macOS","Online":true,"TailscaleIPs":["100.86.45.115","fd7a::1"]},
         "Peer":{
          "a":{"HostName":"Taegyu’s Mac mini","DNSName":"taegyus-mac-mini.tail.ts.net.","OS":"macOS","Online":false,"TailscaleIPs":["100.82.127.50"]},
          "b":{"HostName":"Tab","OS":"android","Online":true,"TailscaleIPs":["100.123.3.56"]},
          "c":{"HostName":"","DNSName":"taegyu-cgqm.tail.ts.net.","OS":"macOS","Online":true,"TailscaleIPs":["fd7a::2","100.102.215.24"]}
         }}
        """#
        let status = try #require(Tailnet.parseStatus(Data(json.utf8)))
        #expect(status.isRunning)
        #expect(status.selfAddress == "100.86.45.115")
        #expect(status.peers.map(\.name) == ["taegyu-cgqm", "Taegyu’s Mac mini"])
        #expect(status.peers.map(\.address) == ["100.102.215.24", "100.82.127.50"])
        #expect(status.peers.map(\.isOnline) == [true, false])
    }

    @Test func garbageIsNoStatus() {
        #expect(Tailnet.parseStatus(Data("not json".utf8)) == nil)
    }
}

struct StreamSizeTests {
    @Test func scalesDownToMaxWidthKeepingAspect() {
        #expect(ScreenStreamer.streamSize(display: (3024, 1964), maxWidth: 1920) == (1920, 1246))
        #expect(ScreenStreamer.streamSize(display: (3840, 2160), maxWidth: 1280) == (1280, 720))
    }

    @Test func neverUpscalesAndStaysEven() {
        #expect(ScreenStreamer.streamSize(display: (1366, 767), maxWidth: 1920) == (1366, 766))
    }
}
