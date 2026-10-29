import Foundation
import CoreGraphics
import FishingCore

final class CycleTests {
    let tracked=Observation(markerY:0.8,targetY:0.4,markerHeight:0.05,progress:0.3,blueVisible:true)
    func waitingCycle()->FishingCycle {
        var c=FishingCycle(); c.start(now:0)
        XCTAssertEqual(c.advance(now:3),[.button(true)])
        XCTAssertEqual(c.advance(now:3.13),[.button(false)])
        return c
    }
    func testCastWithoutAnyMinigame() {
        var c=FishingCycle(); c.start(now:0)
        XCTAssertEqual(c.advance(now:2.9),[])
        XCTAssertEqual(c.advance(now:3),[.button(true)])
        XCTAssertEqual(c.phase,.casting)
        XCTAssertEqual(c.advance(now:3.13),[.button(false)])
        XCTAssertEqual(c.phase,.waiting)
    }
    func testStopReleasesAndCancelsFutureCasts() {
        var c=FishingCycle(); c.start(now:0); _=c.advance(now:3)
        XCTAssertEqual(c.stop(now:3.01),[.button(false)])
        XCTAssertFalse(c.running)
        XCTAssertEqual(c.advance(now:999999),[])
    }
    func testNoTimeLimitAndRetryAfterNoBite() {
        var c=waitingCycle()
        XCTAssertEqual(c.advance(now:49),[.button(true)])
        _=c.advance(now:49.13)
        XCTAssertEqual(c.advance(now:86400),[.button(true)])
        XCTAssertTrue(c.running)
    }
    func testManualClickDoesNotStopReeling() {
        var c=waitingCycle()
        _=c.advance(now:3.2,observation:tracked)
        XCTAssertEqual(c.advance(now:3.3,observation:tracked),[.button(true)])
        c.externalRelease()
        XCTAssertTrue(c.running)
        XCTAssertEqual(c.advance(now:3.4,observation:tracked),[.button(true)])
        XCTAssertEqual(c.phase,.reeling)
    }
    func testFocusPauseReleasesAndResumes() {
        var c=waitingCycle()
        _=c.advance(now:3.2,observation:tracked); _=c.advance(now:3.3,observation:tracked)
        XCTAssertEqual(c.pause(now:3.4),[.button(false)])
        XCTAssertTrue(c.running)
        XCTAssertEqual(c.advance(now:900),[])
        c.resume(now:901)
        _=c.advance(now:901.1,observation:tracked)
        XCTAssertEqual(c.advance(now:901.2,observation:tracked),[.button(true)])
    }
    func testWindowMovementReacquiresInsteadOfStopping() {
        var c=waitingCycle()
        _=c.advance(now:3.2,observation:tracked); _=c.advance(now:3.3,observation:tracked)
        XCTAssertEqual(c.invalidateTracking(now:3.4),[.button(false)])
        XCTAssertEqual(c.phase,.recovering)
        _=c.advance(now:3.5,observation:tracked)
        XCTAssertEqual(c.advance(now:3.6,observation:tracked),[.button(true)])
        let anchor=CastAnchor(x:0.4,y:0.6)
        let old=anchor.point(in:CGRect(x:100,y:100,width:1000,height:600))
        let moved=anchor.point(in:CGRect(x:120,y:110,width:1000,height:600))
        XCTAssertEqual(moved.x-old.x,20)
        XCTAssertEqual(moved.y-old.y,10)
    }
    func testMissingBarsReleaseAndRetry() {
        var c=waitingCycle()
        _=c.advance(now:3.2,observation:tracked); _=c.advance(now:3.3,observation:tracked)
        XCTAssertEqual(c.advance(now:3.4,observation:Observation()),[.button(false)])
        _=c.advance(now:4.2)
        XCTAssertEqual(c.phase,.recovering)
        XCTAssertEqual(c.advance(now:6.3,observation:Observation()),[.button(true)])
        XCTAssertTrue(c.running)
    }
    func testMoreThanTenCatchesKeepsRunning() {
        var c=waitingCycle(),t=3.2
        let full=Observation(markerY:0.5,targetY:0.5,markerHeight:0.05,progress:1,blueVisible:true)
        for _ in 0..<12 {
            for _ in 0..<5 { _=c.advance(now:t,observation:full); t += 0.1 }
            _=c.advance(now:t,observation:Observation()); t += 0.45
            _=c.advance(now:t,observation:Observation())
            XCTAssertEqual(c.phase,.settling)
            t += 1.6; XCTAssertEqual(c.advance(now:t),[.button(true)])
            t += 0.13; _=c.advance(now:t); t += 0.1
        }
        XCTAssertEqual(c.catches,12)
        XCTAssertTrue(c.running)
    }
    func testMouseOutputMovesThenPressesAndReleasesThroughSystemStream() {
        var recorded:[CGEvent]=[],taps:[CGEventTapLocation]=[]
        let output=MouseOutput { event,tap in recorded.append(event); taps.append(tap) }
        let point=CGPoint(x:420,y:530)
        XCTAssertTrue(output.button(true,at:point)); XCTAssertTrue(output.button(false,at:point))
        XCTAssertEqual(recorded.map(\.type),[.mouseMoved,.leftMouseDown,.leftMouseUp])
        XCTAssertTrue(taps.allSatisfy{$0 == .cghidEventTap})
        XCTAssertTrue(recorded.allSatisfy{$0.location==point})
        XCTAssertEqual(recorded[1].getIntegerValueField(.mouseEventClickState),1)
        XCTAssertEqual(recorded[1].getIntegerValueField(.eventSourceUserData),0x47504F46)
    }
}
