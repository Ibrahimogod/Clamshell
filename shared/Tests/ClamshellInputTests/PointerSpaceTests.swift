import Testing
import ClamshellWire
@testable import ClamshellInput

@Suite("Pointer space")
struct PointerSpaceTests {
    /// Away: a 1335×867-point Mac screen mirrored into a 1600-pixel (800-point) picture.
    let away = PointerSpace(pictureWidth: 800, pictureHeight: 519, displayWidth: 1335, displayHeight: 867)

    @Test func fullSizePictureChangesNothing() {
        let home = PointerSpace(pictureWidth: 1335, pictureHeight: 867, displayWidth: 1335, displayHeight: 867)
        #expect(home.isIdentity)
        #expect(home.displayDelta(dx: 7, dy: -3) == (7, -3))
        let s = CursorShape(shapeId: 1, png: [1, 2], hotX: 64, hotY: 80, width: 384, height: 384)
        #expect(home.pictureShape(s) == s)
    }

    /// Crossing the picture on the phone crosses the whole display on the Mac, so the phone's predicted
    /// cursor and the Mac's reported one stay together.
    @Test func moveAcrossThePictureCrossesTheDisplay() {
        let d = away.displayDelta(dx: 800, dy: 519)
        #expect(abs(d.dx - 1335) < 0.01)
        #expect(abs(d.dy - 867) < 0.01)
    }

    /// The cursor keeps the same size relative to the screen: smaller in a smaller picture.
    @Test func shapesShrinkWithThePicture() {
        let s = CursorShape(shapeId: 9, png: [1, 2, 3], hotX: 4 * 16, hotY: 5 * 16, width: 24 * 16, height: 24 * 16)
        let p = away.pictureShape(s)
        #expect(p.shapeId == 9 && p.png == s.png)
        #expect(abs(Double(p.width) / 16 - 24 * 800 / 1335) < 0.1)
        #expect(abs(Double(p.hotX) / 16 - 4 * 800 / 1335) < 0.1)
    }

    @Test func emptySizesFallBackToIdentity() {
        #expect(PointerSpace(pictureWidth: 0, pictureHeight: 0, displayWidth: 1335, displayHeight: 867).isIdentity)
    }
}
