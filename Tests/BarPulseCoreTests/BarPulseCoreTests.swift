@testable import BarPulseCore
import XCTest

final class FormattingTests: XCTestCase {
    func testPercent() {
        XCTAssertEqual(Format.percent(0), "0%")
        XCTAssertEqual(Format.percent(0.234), "23%")
        XCTAssertEqual(Format.percent(1.4), "100%")
        XCTAssertEqual(Format.percent(-1), "0%")
        XCTAssertEqual(Format.precisePercent(0.1234), "12.3%")
    }

    func testRateKeepsThreeSignificantDigits() {
        XCTAssertEqual(Format.rate(0), "0.0 KB/s")
        XCTAssertEqual(Format.rate(512), "0.5 KB/s")
        XCTAssertEqual(Format.rate(12.6 * 1024), "12.6 KB/s")
        XCTAssertEqual(Format.rate(812 * 1024), "812 KB/s")
        // 999.5 KB/s would print as "1000", so it rolls over to MB/s.
        XCTAssertEqual(Format.rate(999.6 * 1024), "1.0 MB/s")
        XCTAssertEqual(Format.rate(3.26 * 1024 * 1024), "3.3 MB/s")
        XCTAssertEqual(Format.rate(250 * 1024 * 1024), "250 MB/s")
        XCTAssertEqual(Format.rate(2 * 1024 * 1024 * 1024), "2.0 GB/s")
    }

    func testBytes() {
        XCTAssertEqual(Format.bytes(512), "512 B")
        XCTAssertEqual(Format.bytes(64 * 1024 * 1024 * 1024), "64.0 GB")
        XCTAssertEqual(Format.bytes(1_288_490_189), "1.2 GB")
        XCTAssertEqual(Format.bytes(500 * 1024 * 1024), "500 MB")
    }

    func testTemperature() {
        XCTAssertEqual(Format.temperature(56.4), "56°")
        XCTAssertEqual(Format.temperature(nil), "--")
        XCTAssertEqual(Format.temperature(100, unit: .fahrenheit), "212°")
    }

    func testDuration() {
        XCTAssertEqual(Format.duration(8 * 60), "8 分钟")
        XCTAssertEqual(Format.duration(5 * 3600 + 12 * 60), "5 小时 12 分")
        XCTAssertEqual(Format.duration(3 * 86400 + 4 * 3600), "3 天 4 小时")
    }

    func testHistoryKeepsNewestSamples() {
        var history = History(capacity: 3)
        [1, 2, 3, 4, .nan].forEach { history.append($0) }
        XCTAssertEqual(history.values, [3, 4, 0])
        XCTAssertEqual(history.peak, 4)
    }
}

final class ThermalSamplerTests: XCTestCase {
    func testSpreadPicksEvenlyAcrossTheGroup() {
        XCTAssertEqual(ThermalSampler.spread(Array(0..<12), limit: 4), [0, 3, 6, 9])
        XCTAssertEqual(ThermalSampler.spread([1, 2, 3], limit: 6), [1, 2, 3])
        XCTAssertEqual(ThermalSampler.spread(Array(0..<42), limit: 6).count, 6)
    }
}

final class SMCDecodingTests: XCTestCase {
    func testDecodesCommonEncodings() {
        // 2320.0 as little-endian IEEE float, as published by Apple silicon fan keys.
        XCTAssertEqual(SMC.decode(type: "flt ", bytes: [0, 0, 17, 69]), 2320)
        XCTAssertEqual(SMC.decode(type: "sp78", bytes: [0x2D, 0x80]), 45.5)
        XCTAssertEqual(SMC.decode(type: "fpe2", bytes: [0x1F, 0x40]), 2000)
        XCTAssertEqual(SMC.decode(type: "ui8 ", bytes: [2]), 2)
        XCTAssertEqual(SMC.decode(type: "ui16", bytes: [0x01, 0x00]), 256)
        XCTAssertNil(SMC.decode(type: "hex_", bytes: [7]))
        XCTAssertEqual(SMC.string(SMC.code("TB0T")), "TB0T")
    }
}

/// Live checks against this Mac's kernel interfaces.
final class LiveSamplerTests: XCTestCase {
    func testCPUUsageIsAFraction() throws {
        let sampler = CPUSampler()
        Thread.sleep(forTimeInterval: 0.3)
        let snapshot = sampler.sample()
        XCTAssertEqual(snapshot.cores.count, sampler.coreCount)
        XCTAssert((0...1).contains(snapshot.usage))
        XCTAssertEqual(snapshot.usage, snapshot.user + snapshot.system, accuracy: 1e-9)
        XCTAssertEqual(sampler.clusters.map(\.count).reduce(0, +), sampler.coreCount)
    }

    func testCPUSamplerDetectsLoad() throws {
        let sampler = CPUSampler()
        let deadline = Date().addingTimeInterval(0.6)
        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            var x = 0.0
            while Date() < deadline { x += sin(x) }
            _ = x
        }
        XCTAssertGreaterThan(sampler.sample().usage, 4.0 / Double(sampler.coreCount) * 0.5)
    }

    func testMemoryBreakdownIsConsistent() {
        let snapshot = MemorySampler().sample()
        XCTAssertGreaterThan(snapshot.total, 0)
        XCTAssertGreaterThan(snapshot.used, 0)
        XCTAssertLessThanOrEqual(snapshot.used, snapshot.total)
        XCTAssert((0...1).contains(snapshot.usage))
    }

    func testNetworkCountersAreMonotonic() {
        let sampler = NetworkSampler()
        let first = sampler.sample()
        Thread.sleep(forTimeInterval: 0.2)
        let second = sampler.sample()
        XCTAssertGreaterThanOrEqual(second.totalDownloaded, first.totalDownloaded)
        XCTAssertGreaterThanOrEqual(second.downloadRate, 0)
        XCTAssertGreaterThanOrEqual(second.uploadRate, 0)
    }

    func testNetworkCountsPhysicalInterfacesOnly() {
        XCTAssertTrue(NetworkSampler.isCounted("en0", primary: "en0"))
        XCTAssertTrue(NetworkSampler.isCounted("ppp0", primary: "ppp0"))
        XCTAssertFalse(NetworkSampler.isCounted("utun3", primary: "utun3"))
        XCTAssertFalse(NetworkSampler.isCounted("bridge100", primary: "en0"))
        XCTAssertFalse(NetworkSampler.isCounted("lo0", primary: "en0"))
    }

    func testGPUReportsUtilisation() throws {
        let sampler = GPUSampler()
        let snapshot = sampler.sample()
        try XCTSkipUnless(snapshot.available, "No IOAccelerator statistics on this machine")
        XCTAssert((0...1).contains(snapshot.usage))
    }

    func testThermalSensorsArePlausible() throws {
        let snapshot = ThermalSampler().sample()
        let readings = [snapshot.cpu, snapshot.gpu, snapshot.soc].compactMap { $0 }
        try XCTSkipIf(readings.isEmpty, "No temperature sensors readable")
        for value in readings {
            XCTAssert((10...120).contains(value), "implausible temperature \(value)")
        }
    }

    func testFansAreReportedWhenPresent() throws {
        guard let smc = SMC() else { throw XCTSkip("SMC unavailable") }
        let count = Int(smc.readNumber("FNum") ?? 0)
        try XCTSkipIf(count == 0, "Fanless Mac")
        let snapshot = ThermalSampler().sample()
        XCTAssertEqual(snapshot.fans.count, count)
        for fan in snapshot.fans {
            XCTAssertGreaterThanOrEqual(fan.rpm, 0)
            XCTAssertGreaterThan(fan.maximum, fan.minimum)
        }
    }
}
