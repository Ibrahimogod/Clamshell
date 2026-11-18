import Testing
@testable import ClamshellWire

@Suite("Sources and frame rate (1.8)")
struct SourcesTests {
    @Test func effectiveFrameRate() {
        #expect(FrameRateRequest.effective(modeHz: 120, cap: 0) == 120)
        #expect(FrameRateRequest.effective(modeHz: 120, cap: 60) == 60)
        #expect(FrameRateRequest.effective(modeHz: 60, cap: 90) == 60)
        #expect(FrameRateRequest.effective(modeHz: 120, cap: 5) == 15)
    }

    @Test func frameRateRoundTrip() throws {
        #expect(try FrameRateRequest(FrameRateRequest(maxFps: 30).message).maxFps == 30)
        #expect(try FrameRateRequest(FrameRateRequest(maxFps: 0).message).maxFps == 0)
    }

    @Test func windowListCapsAndRoundTrips() throws {
        let many = (1...100).map { StreamableWindow(id: UInt32($0), app: "App", title: "W\($0)", width: 100, height: 100) }
        let list = WindowList(windows: many)
        #expect(list.windows.count == WindowList.maxWindows)
        let back = try WindowList(list.message)
        #expect(back.windows == list.windows)
        #expect(try WindowList(WindowList(windows: []).message).windows.isEmpty)
    }

    @Test func windowIdZeroIsRejected() {
        var t = TLVWriter()
        t.bytes(1, StreamableWindow(id: 0, app: "", title: "", width: 0, height: 0).encode())
        #expect(throws: (any Error).self) { try WindowList(body: t.bytes) }
    }

    @Test func sourceRequestRoundTrip() throws {
        let r = try SourceRequest(SourceRequest(windowId: 9, fit: false).message)
        #expect(r.windowId == 9 && !r.fit)
        let whole = try SourceRequest(SourceRequest.wholeScreen.message)
        #expect(whole.windowId == 0 && !whole.fit)
    }

    @Test func windowSpaceMaps() {
        let s = WindowSpace(originX: 100, originY: 50, width: 800, height: 600)
        let g = s.global(unitX: 0.5, unitY: 0.5)
        #expect(g.x == 500 && g.y == 350)
        let u = s.unit(globalX: 900, globalY: 650)
        #expect(u.x == 1 && u.y == 1)
        #expect(s.contains(globalX: 100, globalY: 50))
        #expect(!s.contains(globalX: 900, globalY: 650))
        #expect(WindowSpace(originX: 0, originY: 0, width: 0, height: 0).unit(globalX: 5, globalY: 5) == (0, 0))
    }

    @Test func fittedWindowSize() {
        let fit = WindowSpace.fitted(pictureWidth: 1000, pictureHeight: 700, screenWidth: 1512, screenHeight: 944)
        #expect(fit.width == 1000 && fit.height == 700)
        let shrunk = WindowSpace.fitted(pictureWidth: 3000, pictureHeight: 1000, screenWidth: 1500, screenHeight: 900)
        #expect(shrunk.width == 1500 && shrunk.height == 500)
        let floor = WindowSpace.fitted(pictureWidth: 100, pictureHeight: 50, screenWidth: 1500, screenHeight: 900)
        #expect(floor.width == 320 && floor.height == 240)
    }

    @Test func helloCarriesExpiry() throws {
        let h = Hello(appVersion: "1.1.0", build: 7, capabilities: [.frameRateCap], deviceName: "iPhone", appExpires: 1_795_500_000)
        #expect(try Hello(h.message).appExpires == 1_795_500_000)
        let old = Hello(appVersion: "1.0.0", build: 1, capabilities: [], deviceName: "iPhone")
        #expect(try Hello(old.message).appExpires == nil)
    }

    @Test func hostStateNewFields() throws {
        let s = HostState(screen: .active, keepsAwake: false, targetBitrateKbps: 1, micReady: false, window: "Notes", fps: 30)
        let back = try HostState(s.message)
        #expect(back.micReady == false && back.window == "Notes" && back.fps == 30)
        let plain = try HostState(HostState(screen: .active, keepsAwake: false, targetBitrateKbps: 1).message)
        #expect(plain.micReady == nil && plain.window == nil && plain.fps == 0)
    }
}
