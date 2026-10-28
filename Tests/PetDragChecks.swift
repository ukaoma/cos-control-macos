import CoreGraphics
import Foundation

/// 0.5.352: the pet drags itself (PetDragTracker). Behaviour only; Tests/pet-drag-source-contract.py pins that
/// PetPanel actually routes the left button through it.
@main enum PetDragChecks {
    static func main() {
        var passed = 0
        func check(_ ok: Bool, _ why: String) { precondition(ok, why); passed += 1 }
        let origin = CGPoint(x: 2389, y: 300)
        let press = CGPoint(x: 2500, y: 400)
        let below = PetDragTracker.threshold - 0.5

        // A click that wobbles under the threshold stays a click: nothing moves and the tap runs.
        var click = PetDragTracker()
        click.mouseDown(mouse: press, origin: origin, mayDrag: true)
        check(click.mouseDragged(mouse: CGPoint(x: press.x + below, y: press.y)) == .forward,
              "a press moved under the threshold must not move the pet")
        check(!click.dragging, "a press under the threshold must not count as a drag")
        check(click.mouseUp() == false, "releasing a click must not end a drag")
        check(click.consumeTap(), "a click under the threshold must still run the tap")

        // A drag past the threshold moves the panel with the pointer, from where it was pressed.
        var drag = PetDragTracker()
        drag.mouseDown(mouse: press, origin: origin, mayDrag: true)
        check(drag.mouseDragged(mouse: CGPoint(x: press.x + 1, y: press.y)) == .forward, "1pt is still a click")
        check(drag.mouseDragged(mouse: CGPoint(x: press.x + 453, y: press.y - 305))
              == .move(CGPoint(x: origin.x + 453, y: origin.y - 305)),
              "a drag past the threshold must put the panel where the pointer took it")
        check(drag.dragging, "a press past the threshold is a drag")
        // Once dragging, coming back near the start keeps moving: it never falls back to a click.
        check(drag.mouseDragged(mouse: CGPoint(x: press.x + 1, y: press.y)) == .move(CGPoint(x: origin.x + 1, y: origin.y)),
              "a drag that comes back near its start must keep following the pointer")
        check(drag.mouseUp(), "releasing a drag must end it")
        check(!drag.consumeTap(), "the tap SwiftUI reports for a drag's release must be swallowed")
        check(drag.consumeTap(), "only ONE tap is swallowed after a drag")

        // A stale swallow never eats the next real click.
        var stale = PetDragTracker()
        stale.mouseDown(mouse: press, origin: origin, mayDrag: true)
        _ = stale.mouseDragged(mouse: CGPoint(x: press.x + 40, y: press.y))
        _ = stale.mouseUp()
        stale.mouseDown(mouse: press, origin: origin, mayDrag: true)
        _ = stale.mouseUp()
        check(stale.consumeTap(), "a new press must clear the swallow left by the last drag")

        // Pills, lists, cards, buttons and control-click never drag, however far the pointer goes.
        var pill = PetDragTracker()
        pill.mouseDown(mouse: press, origin: origin, mayDrag: false)
        check(pill.mouseDragged(mouse: CGPoint(x: press.x + 200, y: press.y + 200)) == .forward,
              "a press on a pill or button must never move the pet")
        check(pill.mouseUp() == false && pill.consumeTap(), "a press on a pill must still reach the pill")

        // Exactly at the threshold it is a drag (the boundary the panel uses).
        var edge = PetDragTracker()
        edge.mouseDown(mouse: press, origin: origin, mayDrag: true)
        check(edge.mouseDragged(mouse: CGPoint(x: press.x, y: press.y + PetDragTracker.threshold))
              == .move(CGPoint(x: origin.x, y: origin.y + PetDragTracker.threshold)), "at the threshold the pet drags")

        // A drop lands inside the visible frame of the screen it was dropped on (0.5.352 QA: a syncPanel mid-drag
        // could leave the pet half off-screen until the next resize).
        let screen = CGRect(x: 0, y: 25, width: 1920, height: 1055)
        let size = CGSize(width: 490, height: 257)
        check(PetDragTracker.dropOrigin(frame: CGRect(origin: CGPoint(x: 1700, y: 300), size: size), screen: screen)
              == CGPoint(x: 1920 - 490, y: 300), "a pet dropped half off the right edge must come back on screen")
        check(PetDragTracker.dropOrigin(frame: CGRect(origin: CGPoint(x: -120, y: -80), size: size), screen: screen)
              == CGPoint(x: 0, y: 25), "a pet dropped off the bottom-left must rest inside the visible frame")
        check(PetDragTracker.dropOrigin(frame: CGRect(origin: CGPoint(x: 600, y: 950), size: size), screen: screen)
              == CGPoint(x: 600, y: 25 + 1055 - 257), "a pet dropped under the menu bar must come down inside it")
        check(PetDragTracker.dropOrigin(frame: CGRect(origin: CGPoint(x: 600, y: 300), size: size), screen: screen)
              == CGPoint(x: 600, y: 300), "a pet dropped fully on screen must stay exactly where it was dropped")
        check(PetDragTracker.dropOrigin(frame: CGRect(origin: CGPoint(x: 5000, y: 300), size: size), screen: nil)
              == CGPoint(x: 5000, y: 300), "with no screen to clamp to, the drop is left alone")

        print("COS Control: pet drag tracker, \(passed) checks passed (click under \(PetDragTracker.threshold)pt taps, a drag moves the panel and swallows one tap, pills never drag)")
    }
}
