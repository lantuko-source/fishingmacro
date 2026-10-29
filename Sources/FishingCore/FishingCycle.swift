import Foundation
import CoreGraphics

public enum FishingPhase:String {
    case stopped="Stopped", countdown="Starting", casting="Casting", waiting="Waiting for bite"
    case reeling="Reeling", recovering="Finding fishing bars", settling="Next cast", paused="Paused — return to Roblox"
}
public enum FishingAction:Equatable { case button(Bool) }

/// Owns one continuous fishing run. Frame observations and clock ticks are
/// separate so a cast is emitted even when the minigame does not exist yet.
public struct FishingCycle {
    public private(set) var phase:FishingPhase = .stopped
    public private(set) var catches=0
    public private(set) var holding=false
    public var running:Bool { phase != .stopped }
    private var stateTime=0.0,lastGood=0.0,heldSince=0.0,releasedUntil=0.0
    private var stableFrames=0,pauseTime=0.0
    private var resumePhase:FishingPhase = .waiting
    private var controller=BalanceController()
    private var evidence=CatchEvidence()
    public init() {}
    public mutating func start(now:Double) {
        self=FishingCycle(); phase = .countdown; stateTime=now; lastGood=now
    }
    private mutating func button(_ down:Bool,now:Double)->[FishingAction] {
        guard holding != down else { return [] }
        holding=down
        if down { heldSince=now }
        return [.button(down)]
    }
    public mutating func stop(now:Double)->[FishingAction] {
        let actions=button(false,now:now); phase = .stopped; controller.reset(); evidence.reset()
        return actions
    }
    public mutating func externalRelease() { holding=false }
    public mutating func pause(now:Double)->[FishingAction] {
        guard running,phase != .paused else { return [] }
        resumePhase=phase == .casting || phase == .reeling ? .waiting:phase
        pauseTime=now; phase = .paused
        return button(false,now:now)
    }
    public mutating func resume(now:Double) {
        guard phase == .paused else { return }
        stateTime += now-pauseTime; lastGood=now; phase=resumePhase; stableFrames=0
        if phase == .waiting { stateTime=now }
        controller.reset(); evidence.reset()
    }
    public mutating func invalidateTracking(now:Double)->[FishingAction] {
        guard running else { return [] }
        controller.reset(); evidence.reset(); stableFrames=0
        if phase == .reeling { phase = .recovering; stateTime=now }
        return button(false,now:now)
    }
    public mutating func advance(now:Double,observation:Observation? = nil)->[FishingAction] {
        guard running,phase != .paused else { return [] }
        var actions:[FishingAction]=[]
        if holding && phase == .reeling && now-heldSince>=1.5 {
            actions += button(false,now:now); releasedUntil=now+0.08
        }
        switch phase {
        case .countdown:
            if now-stateTime>=3 {
                phase = .casting; stateTime=now; actions += button(true,now:now)
            }
        case .casting:
            if now-stateTime>=0.12 {
                actions += button(false,now:now); phase = .waiting; stateTime=now; stableFrames=0
            }
        case .waiting,.recovering:
            if let o=observation {
                stableFrames=o.tracked ? stableFrames+1:0
                if stableFrames>=2 {
                    phase = .reeling; lastGood=now; controller.reset(); evidence.reset()
                    actions += button(controller.update(o,now:now),now:now)
                } else if phase == .recovering && !o.blueVisible && now-stateTime>=2 {
                    phase = .casting; stateTime=now; actions += button(true,now:now)
                }
            }
            if phase == .waiting && now-stateTime>=45 {
                phase = .casting; stateTime=now; stableFrames=0; actions += button(true,now:now)
            }
        case .reeling:
            if let o=observation {
                if evidence.update(o,now:now) {
                    actions += button(false,now:now); catches += 1; phase = .settling; stateTime=now
                } else if o.tracked {
                    lastGood=now
                    actions += button(controller.update(o,now:now) && now>=releasedUntil,now:now)
                } else { actions += button(false,now:now); controller.reset() }
            }
            if phase == .reeling && now-lastGood>=0.8 {
                actions += button(false,now:now); phase = .recovering; stateTime=now; stableFrames=0
            }
        case .settling:
            if now-stateTime>=1.5 {
                phase = .casting; stateTime=now; stableFrames=0; evidence.reset()
                actions += button(true,now:now)
            }
        case .paused,.stopped: break
        }
        return actions
    }
}

/// A cached water point follows window movement/resizing without a new selection.
public struct CastAnchor {
    public let x:Double,y:Double
    public init(x:Double,y:Double) { self.x=max(0.03,min(0.97,x)); self.y=max(0.08,min(0.92,y)) }
    public func point(in frame:CGRect)->CGPoint { CGPoint(x:frame.minX+x*frame.width,y:frame.minY+y*frame.height) }
}

/// Public macOS input, with an injectable sink so checks never send real clicks.
public struct MouseOutput {
    private let sink:(CGEvent,CGEventTapLocation)->Void
    public init(sink:@escaping(CGEvent,CGEventTapLocation)->Void = { $0.post(tap:$1) }) { self.sink=sink }
    @discardableResult public func button(_ down:Bool,at point:CGPoint)->Bool {
        if down {
            guard let move=CGEvent(mouseEventSource:nil,mouseType:.mouseMoved,mouseCursorPosition:point,mouseButton:.left) else { return false }
            move.flags=[]; move.setIntegerValueField(.eventSourceUserData,value:0x47504F46)
            sink(move,.cghidEventTap)
        }
        guard let event=CGEvent(mouseEventSource:CGEventSource(stateID:.hidSystemState),
            mouseType:down ? .leftMouseDown:.leftMouseUp,mouseCursorPosition:point,mouseButton:.left) else { return false }
        event.flags=[]
        event.setIntegerValueField(.mouseEventClickState,value:1)
        event.setIntegerValueField(.eventSourceUserData,value:0x47504F46)
        sink(event,.cghidEventTap)
        return true
    }
}
