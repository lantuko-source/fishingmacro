import AppKit
import SwiftUI
import ScreenCaptureKit
import ApplicationServices
import Carbon
import ImageIO
import FishingCore

@MainActor final class MacroModel: ObservableObject {
    @Published var image:CGImage?
    @Published var liveImage:CGImage?
    @Published var calibration=Calibration()
    @Published var water:WaterPoint?
    @Published var observation=Observation()
    @Published var message="Face the water with your rod equipped, then press Start fishing."
    @Published var phase="Stopped"
    @Published var screenLabel="Screen capture starts automatically"
    @Published var catches=0
    @Published var casts=0
    @Published var running=false
    @Published var busy=false
    @Published var accessibility=false
    @Published var recording=false
    @Published var imported=false
    @Published var elapsed=0.0
    @Published var lastAction="Released"
    private var filter:SCContentFilter?
    private var displayFrame=CGRect.zero,windowFrame=CGRect.zero
    private var gameBounds=Region(x:0,y:0,w:1,h:1)
    private var displays:[SCDisplay]=[], excludedApps:[SCRunningApplication]=[]
    private var displayID:CGDirectDisplayID=0,targetPID:pid_t=0
    private var selectedID:CGWindowID=0
    private var timer:Timer?,mouseMonitor:Any?
    private var awakeActivity:NSObjectProtocol?
    private var hotKey:EventHotKeyRef?,eventHandler:EventHandlerRef?
    private var runID=UUID(),geometryRevision=0
    private var captureBusy=false,buttonDown=false,capturePermissionConfirmed=false,windowVisible=false
    private var startTime=0.0,lastFrameTime=0.0,lastCaptureRequest=0.0,lastGeometryCheck=0.0
    private var anchor:CastAnchor?,crop:Region?
    private var cycle=FishingCycle()
    private let output=MouseOutput()
    private var clock:Double { ProcessInfo.processInfo.systemUptime }

    init() {
        refreshPermissions(); installStopHandler()
        timer=Timer.scheduledTimer(withTimeInterval:0.02,repeats:true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        mouseMonitor=NSEvent.addGlobalMonitorForEvents(matching:.leftMouseUp) { [weak self] event in
            guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != 0x47504F46 else { return }
            Task { @MainActor in
                // A physical click never ends a run. Reconcile its mouse-up so
                // the next controller frame can hold again if needed.
                self?.buttonDown=false; self?.cycle.externalRelease()
            }
        }
    }
    func refreshPermissions() {
        accessibility=AXIsProcessTrusted()
        recording=CGPreflightScreenCaptureAccess() || capturePermissionConfirmed
    }
    func requestAccessibility() {
        _=AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String:true] as CFDictionary)
        refreshPermissions()
    }
    func requestRecording() {
        _=CGRequestScreenCaptureAccess(); refreshPermissions()
        if !recording { message="Allow Fishing Macro in Screen Recording settings, then return here." }
    }
    func openPrivacy(_ pane:String) {
        if let url=URL(string:"x-apple.systempreferences:com.apple.preference.security?"+pane) { NSWorkspace.shared.open(url) }
    }
    private func configuration(region:Region? = nil)->SCStreamConfiguration {
        let cfg=SCStreamConfiguration(),r=region ?? Region(x:0,y:0,w:1,h:1)
        let scale=min(2,max(1,Double(filter?.pointPixelScale ?? 1)))
        cfg.sourceRect=CGRect(x:r.x*displayFrame.width,y:r.y*displayFrame.height,
                              width:r.w*displayFrame.width,height:r.h*displayFrame.height)
        cfg.width=max(2,Int(r.w*displayFrame.width*scale)); cfg.height=max(2,Int(r.h*displayFrame.height*scale))
        cfg.showsCursor=false; cfg.capturesAudio=false; cfg.shouldBeOpaque=true
        return cfg
    }
    private func useDisplay(for frame:CGRect)->Bool {
        guard let display=displays.max(by: { a,b in
            a.frame.intersection(frame).width*a.frame.intersection(frame).height < b.frame.intersection(frame).width*b.frame.intersection(frame).height
        }),display.frame.intersects(frame) else { return false }
        if displayID != display.displayID {
            displayID=display.displayID; displayFrame=display.frame
            filter=SCContentFilter(display:display,excludingApplications:excludedApps,exceptingWindows:[])
            crop=nil; geometryRevision += 1
        }
        return true
    }
    private func updateBounds(_ rect:CGRect) {
        windowFrame=rect
        let visible=rect.intersection(displayFrame)
        gameBounds=Region(x:(visible.minX-displayFrame.minX)/displayFrame.width,
                          y:(visible.minY-displayFrame.minY)/displayFrame.height,
                          w:visible.width/displayFrame.width,h:visible.height/displayFrame.height)
    }
    func start() {
        guard !running else { stop("Stopped by you"); return }
        refreshPermissions()
        guard accessibility else { message="Allow Accessibility to send the fishing clicks."; return }
        var ref:EventHotKeyRef?
        let hotID=EventHotKeyID(signature:0x47504F46,id:1)
        guard RegisterEventHotKey(UInt32(kVK_ANSI_P),0,hotID,GetApplicationEventTarget(),0,&ref)==noErr else {
            message="P is unavailable as a stop key. Close the other app using that shortcut, then retry."; return
        }
        hotKey=ref; running=true; busy=true; phase="Preparing screen capture"
        awakeActivity=ProcessInfo.processInfo.beginActivity(options:[.userInitiated,.idleSystemSleepDisabled,.idleDisplaySleepDisabled],reason:"Fishing macro runs until stopped")
        imported=false; casts=0; catches=0; elapsed=0; anchor=nil; water=nil; crop=nil
        calibration=Calibration(); observation=Observation(); displayID=0
        runID=UUID(); let id=runID
        Task { @MainActor [weak self] in
            guard let self=self else { return }
            defer { if self.runID==id { self.busy=false } }
            do {
                let content=try await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly:true)
                guard self.running,self.runID==id else { return }
                let foreground=NSWorkspace.shared.frontmostApplication?.processIdentifier
                let candidates=content.windows.filter { $0.owningApplication?.bundleIdentifier=="com.roblox.RobloxPlayer"
                    && $0.windowLayer==0 && $0.frame.width>300 && $0.frame.height>200 }.sorted { a,b in
                    if a.owningApplication?.processID==foreground && b.owningApplication?.processID != foreground { return true }
                    if b.owningApplication?.processID==foreground && a.owningApplication?.processID != foreground { return false }
                    return a.frame.width*a.frame.height > b.frame.width*b.frame.height
                }
                guard let win=candidates.first,let owner=win.owningApplication else {
                    self.stop("Open Roblox and join GPO, then press Start fishing."); return
                }
                self.displays=content.displays
                self.excludedApps=content.applications.filter { $0.processID==ProcessInfo.processInfo.processIdentifier }
                self.targetPID=owner.processID; self.selectedID=win.windowID
                guard self.useDisplay(for:win.frame) else { self.stop("Roblox has no visible screen."); return }
                self.updateBounds(win.frame)
                self.windowVisible=true
                if let app=NSRunningApplication(processIdentifier:self.targetPID) {
                    NSApp.yieldActivation(to:app); _=app.activate(options:[])
                }
                try await Task.sleep(nanoseconds:350_000_000)
                guard self.running,self.runID==id else { return }
                let shot=try await SCScreenshotManager.captureImage(contentFilter:self.filter!,configuration:self.configuration())
                guard self.running,self.runID==id else { return }
                guard let pixels=Pixels(image:shot),let point=AutoVision.water(pixels,within:self.gameBounds) else {
                    self.stop("No clear blue water found. Face open water and press Start fishing again."); return
                }
                self.water=point
                let global=CGPoint(x:self.displayFrame.minX+point.x*self.displayFrame.width,y:self.displayFrame.minY+point.y*self.displayFrame.height)
                self.anchor=CastAnchor(x:(global.x-self.windowFrame.minX)/self.windowFrame.width,
                                       y:(global.y-self.windowFrame.minY)/self.windowFrame.height)
                self.image=shot; self.liveImage=nil; self.capturePermissionConfirmed=true; self.refreshPermissions()
                self.screenLabel="Capturing automatically · \(Int(self.displayFrame.width)) × \(Int(self.displayFrame.height))"
                self.startTime=self.clock; self.lastFrameTime=self.clock; self.lastGeometryCheck=0
                self.cycle.start(now:self.clock); self.phase="Starting in 3 seconds"
                self.message="Casting starts automatically. P stops. Ordinary clicks and window movement keep the run active."
            } catch {
                guard self.runID==id else { return }
                self.capturePermissionConfirmed=false; self.refreshPermissions()
                self.stop("Capture unavailable: \(error.localizedDescription)")
            }
        }
    }
    func stop(_ reason:String?) {
        runID=UUID(); running=false; busy=false
        _=cycle.stop(now:clock); releaseButton()
        phase="Stopped"; crop=nil
        if let key=hotKey { UnregisterEventHotKey(key); hotKey=nil }
        if let activity=awakeActivity { ProcessInfo.processInfo.endActivity(activity); awakeActivity=nil }
        if let reason=reason { message=reason }
    }
    private func releaseButton() {
        guard buttonDown else { return }
        _=output.button(false,at:CGEvent(source:nil)?.location ?? .zero)
        buttonDown=false; lastAction="Released ↓"
    }
    private func apply(_ actions:[FishingAction]) {
        for action in actions {
            guard case .button(let down)=action else { continue }
            if !down { releaseButton(); continue }
            guard running,AXIsProcessTrusted() else { stop("Accessibility permission is unavailable."); return }
            guard windowVisible,NSWorkspace.shared.frontmostApplication?.processIdentifier==targetPID,let anchor=anchor else {
                _=cycle.pause(now:clock); releaseButton(); return
            }
            let point=anchor.point(in:windowFrame)
            guard windowFrame.intersection(displayFrame).insetBy(dx:4,dy:4).contains(point) else {
                _=cycle.pause(now:clock); releaseButton(); message="Waiting for the water point to be visible inside Roblox."; return
            }
            guard output.button(true,at:point) else { stop("macOS could not create a mouse event."); return }
            buttonDown=true; lastAction=cycle.phase == .casting ? "Cast click sent":"Holding ↑"
            if cycle.phase == .casting { casts += 1 }
        }
    }
    private func refreshGeometry()->Bool {
        guard let list=CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] else { return false }
        let windows=list.filter { ($0[kCGWindowOwnerPID as String] as? Int)==Int(targetPID) && ($0[kCGWindowLayer as String] as? Int)==0 }
        guard let info=windows.first(where:{($0[kCGWindowNumber as String] as? UInt32)==selectedID}) ?? windows.first,
            let bounds=info[kCGWindowBounds as String] as? NSDictionary,let rect=CGRect(dictionaryRepresentation:bounds),
            rect.width>300,rect.height>200,useDisplay(for:rect) else { return false }
        selectedID=info[kCGWindowNumber as String] as? UInt32 ?? selectedID
        if rect != windowFrame {
            updateBounds(rect); crop=nil; geometryRevision += 1
            apply(cycle.invalidateTracking(now:clock))
            message="Window changed; water point adjusted and fishing bars will be found again."
        }
        return true
    }
    private func tick() {
        guard running,!busy else { return }
        let now=clock; elapsed=now-startTime
        if !AXIsProcessTrusted() { stop("Accessibility permission was removed."); return }
        let foreground=NSWorkspace.shared.frontmostApplication
        if foreground?.bundleIdentifier=="com.roblox.RobloxPlayer",foreground?.processIdentifier != targetPID {
            targetPID=foreground!.processIdentifier; selectedID=0
        }
        if now-lastGeometryCheck>=0.25 { lastGeometryCheck=now; windowVisible=refreshGeometry() }
        if foreground?.processIdentifier != targetPID || !windowVisible || IsSecureEventInputEnabled() {
            apply(cycle.pause(now:now)); phase=FishingPhase.paused.rawValue
            message="Run stays active while paused. Return to Roblox to continue, or press P to stop."
            return
        }
        if now-lastFrameTime>1.5 && cycle.phase != .countdown {
            apply(cycle.pause(now:now)); phase="Waiting for screen capture"
            if !captureBusy { requestFrame() }; return
        }
        cycle.resume(now:now)
        let previous=cycle.phase
        apply(cycle.advance(now:now)); publish(previous:previous)
        if cycle.phase == .countdown { lastFrameTime=now; return }
        let interval=crop == nil ? 0.10:0.04
        if cycle.phase != .casting && now-lastCaptureRequest>=interval && !captureBusy { requestFrame() }
    }
    private func publish(previous:FishingPhase) {
        guard running else { return }
        phase=cycle.phase.rawValue; catches=cycle.catches
        if cycle.phase == .recovering || cycle.phase == .settling || cycle.phase == .waiting { crop=nil }
        if previous != cycle.phase {
            if cycle.phase == .casting { message="Cast click sent to the water. Waiting for the fishing UI." }
            if cycle.phase == .reeling { message="Holding to rise and releasing to fall, following the white target." }
            if cycle.phase == .recovering { message="Reacquiring fishing bars; the run continues automatically." }
        }
    }
    private func requestFrame() {
        guard let filter=filter else { stop("Screen capture is not configured."); return }
        captureBusy=true; lastCaptureRequest=clock
        let id=runID,region=crop,revision=geometryRevision,cfg=configuration(region:crop)
        Task { @MainActor [weak self] in
            guard let self=self else { return }
            defer { self.captureBusy=false }
            do {
                let img=try await SCScreenshotManager.captureImage(contentFilter:filter,configuration:cfg)
                guard self.running,self.runID==id,self.geometryRevision==revision else { return }
                guard let pixels=Pixels(image:img) else { return }
                self.lastFrameTime=self.clock; self.liveImage=img
                if self.cycle.phase == .paused { return }
                if region==nil {
                    if let found=AutoVision.fishingUI(pixels,within:self.gameBounds) {
                        self.calibration=found; self.observation=Detector.detect(pixels,calibration:found)
                    } else { self.observation=Observation(reason:"Waiting for the fishing bars to appear") }
                } else { self.observation=Detector.detect(pixels,calibration:self.calibration,crop:region) }
                let previous=self.cycle.phase
                self.apply(self.cycle.advance(now:self.clock,observation:self.observation))
                if self.cycle.phase == .reeling { self.crop=self.calibration.crop }
                self.publish(previous:previous)
            } catch {
                guard self.running,self.runID==id else { return }
                self.capturePermissionConfirmed=false; self.refreshPermissions()
                self.stop("Screen capture failed: \(error.localizedDescription)")
            }
        }
    }
    private func installStopHandler() {
        var spec=EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(),{ _,event,context in
            guard let event=event,let context=context else { return OSStatus(eventNotHandledErr) }
            var id=EventHotKeyID()
            GetEventParameter(event,EventParamName(kEventParamDirectObject),EventParamType(typeEventHotKeyID),nil,
                MemoryLayout<EventHotKeyID>.size,nil,&id)
            guard id.signature==0x47504F46 else { return OSStatus(eventNotHandledErr) }
            let model=Unmanaged<MacroModel>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in model.stop("Stopped with P") }
            return noErr
        },1,&spec,Unmanaged.passUnretained(self).toOpaque(),&eventHandler)
    }
    func importImage() {
        stop(nil)
        let panel=NSOpenPanel(); panel.allowedContentTypes=[.png,.jpeg]
        if panel.runModal() == .OK,let url=panel.url { loadImage(url) }
    }
    func loadImage(_ url:URL) {
        stop(nil)
        guard let source=CGImageSourceCreateWithURL(url as CFURL,nil),let shot=CGImageSourceCreateImageAtIndex(source,0,nil),let pixels=Pixels(image:shot) else { return }
        imported=true; image=shot; liveImage=nil
        let bounds=Region(x:0,y:0,w:1,h:1)
        water=AutoVision.water(pixels,within:bounds)
        if let found=AutoVision.fishingUI(pixels,within:bounds) { calibration=found; observation=Detector.detect(pixels,calibration:found) }
        message="Offline image only. Start fishing captures your actual screen automatically."
    }
    func shutdown() {
        stop(nil); timer?.invalidate()
        if let monitor=mouseMonitor { NSEvent.removeMonitor(monitor) }
        if let handler=eventHandler { RemoveEventHandler(handler) }
    }
}
