import Foundation
import Testing

@Suite struct AreaGeometryTests {
    private let area = CGRect(x: 100, y: 100, width: 400, height: 300)
    private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)

    @Test(arguments: [
        (CGPoint(x: 300, y: 250), AreaGeometry.Handle.move),
        (CGPoint(x: 103, y: 250), .left),
        (CGPoint(x: 496, y: 250), .right),
        (CGPoint(x: 300, y: 405), .top),
        (CGPoint(x: 300, y: 95), .bottom),
        (CGPoint(x: 98, y: 402), .topLeft),
        (CGPoint(x: 504, y: 96), .bottomRight),
    ])
    func handles(point: CGPoint, handle: AreaGeometry.Handle) {
        #expect(AreaGeometry.handle(at: point, in: area) == handle)
    }

    @Test func outsideIsNothing() {
        #expect(AreaGeometry.handle(at: CGPoint(x: 600, y: 250), in: area) == nil)
        #expect(AreaGeometry.handle(at: CGPoint(x: 80, y: 80), in: area) == nil)
    }

    @Test func movingKeepsTheSize() {
        let moved = AreaGeometry.adjusted(area, by: CGSize(width: 50, height: -30), handle: .move, within: screen)
        #expect(moved == CGRect(x: 150, y: 70, width: 400, height: 300))
    }

    @Test func movingStopsAtTheScreenEdge() {
        let moved = AreaGeometry.adjusted(area, by: CGSize(width: 900, height: -500), handle: .move, within: screen)
        #expect(moved == CGRect(x: 600, y: 0, width: 400, height: 300))
    }

    @Test func resizingMovesOnlyThatEdge() {
        let wider = AreaGeometry.adjusted(area, by: CGSize(width: 60, height: 0), handle: .right, within: screen)
        #expect(wider == CGRect(x: 100, y: 100, width: 460, height: 300))
        let corner = AreaGeometry.adjusted(area, by: CGSize(width: -20, height: 40), handle: .topLeft, within: screen)
        #expect(corner == CGRect(x: 80, y: 100, width: 420, height: 340))
    }

    @Test func resizingStopsAtTheMinimumAndTheScreen() {
        let squeezed = AreaGeometry.adjusted(area, by: CGSize(width: 1000, height: 0), handle: .left, within: screen)
        #expect(squeezed.width == AreaGeometry.minimumSize && squeezed.maxX == area.maxX)
        let stretched = AreaGeometry.adjusted(area, by: CGSize(width: 0, height: 900), handle: .top, within: screen)
        #expect(stretched.maxY == screen.maxY && stretched.minY == area.minY)
    }
}

@Suite struct TargetPillPlacementTests {
    private let pill = CGSize(width: 100, height: 34)
    private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)

    private func origin(below target: CGRect, insideIfNeeded: Bool = false) -> CGPoint? {
        TargetPill.origin(for: pill, below: target, gap: 16, within: screen, insideIfNeeded: insideIfNeeded)
    }

    @Test func goesCenteredBelow() {
        #expect(origin(below: CGRect(x: 200, y: 300, width: 400, height: 300)) == CGPoint(x: 350, y: 250))
    }

    // A window that fills the screen gets no pill; an area gets it just inside its bottom edge.
    @Test func noRoomBelow() {
        let full = CGRect(x: 0, y: 20, width: 1000, height: 780)
        #expect(origin(below: full) == nil)
        #expect(origin(below: full, insideIfNeeded: true) == CGPoint(x: 450, y: 36))
    }

    @Test func staysOnScreenSideways() {
        #expect(origin(below: CGRect(x: -150, y: 300, width: 200, height: 200))?.x == 4)
        #expect(origin(below: CGRect(x: 950, y: 300, width: 200, height: 200))?.x == 896)
    }
}
