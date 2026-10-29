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
    @Published var message="Face the water in GPO, then capture your screen. No fishing bars are needed yet."
    @Published var phase="Stopped"
    @Published var screenLabel="No screen captured"
    @Published var preview=true
    @Published var duration=120.0
    @Published var catches=0
    @Published var running=false
    @Published var busy=false
    @Published var accessibility=false
    @Published var recording=false
    @Published var hasCapture=false
    @Published var imported=false
    @Published var elapsed=0.0
    @Published var lastAction="Released"
    private var filter:SCContentFilter?
    private var displayFrame=CGRect.zero, referenceFrame=CGRect.zero
    private var gameBounds=Region(x:0,y:0,w:1,h:1)
    private var targetPID:pid_t=0
    private var selectedID:CGWindowID=0
    private var timer:Timer?
    private var keyMonitor:Any?, clickMonitor:Any?, localMonitor:Any?
    private var hotKey:EventHotKeyRef?
    private var eventHandler:EventHandlerRef?
    private var runID=UUID()
    private var captureBusy=false
    private var startTime=0.0, stateTime=0.0, lastFrameTime=0.0, lastCaptureRequest=0.0
    private var lastGood=0.0, heldSince=0.0, forcedReleaseUntil=0.0, nextCastAt=0.0
    private var buttonDown=false, pointerArmed=false, stableFrames=0
    private var oceanPoint=CGPoint.zero
    private var controller=BalanceController()
    private var evidence=CatchEvidence()
    private let tag:Int64=0x47504F46
    private var sessionPreview=true
    private var crop:Region?
    private var safetyCounter=0
    private var cachedWindowOK=true
    private var capturePermissionConfirmed=false
    private var clock:Double { ProcessInfo.processInfo.systemUptime }

    init() {
        refreshPermissions(); installStopControls()
        timer=Timer.scheduledTimer(withTimeInterval:0.02,repeats:true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.screensDidSleepNotification,
            object:nil,queue:.main) { [weak self] _ in Task { @MainActor in self?.stop("Display went to sleep") } }
    }
    func refreshPermissions() {
        accessibility=AXIsProcessTrusted()
        // A real successful ScreenCaptureKit image is stronger evidence than a
        // legacy preflight result, which can remain false in the current process.
        recording=CGPreflightScreenCaptureAccess() || capturePermissionConfirmed
    }
    func requestAccessibility() {
        _=AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String:true] as CFDictionary)
        refreshPermissions()
    }
    func requestRecording() {
        _=CGRequestScreenCaptureAccess(); refreshPermissions()
        if !recording {
            message="If Fishing Macro is already enabled in Settings, remove its old entry and add the app from Applications again. Then quit and reopen this installed copy."
        }
    }
    func openPrivacy(_ pane:String) {
        if let url=URL(string:"x-apple.systempreferences:com.apple.preference.security?"+pane) { NSWorkspace.shared.open(url) }
    }
    private func configuration(region:Region? = nil)->SCStreamConfiguration {
        let cfg=SCStreamConfiguration(), r=region ?? Region(x:0,y:0,w:1,h:1)
        let scale=min(2,max(1,Double(filter?.pointPixelScale ?? 1)))
        cfg.sourceRect=CGRect(x:r.x*displayFrame.width,y:r.y*displayFrame.height,
                              width:r.w*displayFrame.width,height:r.h*displayFrame.height)
        cfg.width=max(2,Int(r.w*displayFrame.width*scale)); cfg.height=max(2,Int(r.h*displayFrame.height*scale))
        cfg.showsCursor=false; cfg.capturesAudio=false; cfg.shouldBeOpaque=true
        return cfg
    }
    func captureScreen() async {
        stop(nil); busy=true; hasCapture=false; defer { busy=false }
        do {
            let content=try await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly:true)
            let foreground=NSWorkspace.shared.frontmostApplication?.processIdentifier
            let candidates=content.windows.filter { $0.owningApplication?.bundleIdentifier=="com.roblox.RobloxPlayer"
                && $0.windowLayer==0 && $0.frame.width>300 && $0.frame.height>200 }
                .sorted { a,b in
                    if a.owningApplication?.processID==foreground && b.owningApplication?.processID != foreground { return true }
                    if b.owningApplication?.processID==foreground && a.owningApplication?.processID != foreground { return false }
                    return a.frame.width*a.frame.height > b.frame.width*b.frame.height
                }
            guard let win=candidates.first, let app=win.owningApplication else {
                message="Open Roblox, join GPO, and face the water. Then capture your screen."; return
            }
            guard let display=content.displays.first(where:{$0.frame.contains(win.frame)}) else {
                message="Move the Roblox window fully onto one screen, then capture again."; return
            }
            displayFrame=display.frame; referenceFrame=win.frame; targetPID=app.processID; selectedID=win.windowID
            gameBounds=Region(x:(win.frame.minX-display.frame.minX)/display.frame.width,
                              y:(win.frame.minY-display.frame.minY)/display.frame.height,
                              w:win.frame.width/display.frame.width,h:win.frame.height/display.frame.height)
            let excluded=content.applications.filter { $0.processID==ProcessInfo.processInfo.processIdentifier }
            filter=SCContentFilter(display:display,excludingApplications:excluded,exceptingWindows:[])
            NSRunningApplication(processIdentifier:targetPID)?.activate(options:[])
            try await Task.sleep(nanoseconds:400_000_000)
            let shot=try await SCScreenshotManager.captureImage(contentFilter:filter!,configuration:configuration())
            capturePermissionConfirmed=true
            image=shot; liveImage=nil; imported=false; hasCapture=true
            screenLabel="Entire screen · \(Int(display.frame.width)) × \(Int(display.frame.height))"
            analyzeSetup(shot)
            refreshPermissions()
            NSApp.activate(ignoringOtherApps:true)
            NSApp.windows.first(where:{$0.isVisible && $0.canBecomeKey})?.makeKeyAndOrderFront(nil)
        } catch {
            capturePermissionConfirmed=false; refreshPermissions()
            message="Screen capture unavailable: \(error.localizedDescription). If already enabled, remove its old Settings entry and add Fishing Macro from Applications again."
        }
    }
    private func analyzeSetup(_ shot:CGImage) {
        calibration=Calibration(); observation=Observation()
        guard let pixels=Pixels(image:shot) else { message="Could not read screen pixels"; return }
        water=AutoVision.water(pixels,within:gameBounds)
        if let c=AutoVision.fishingUI(pixels,within:gameBounds) {
            calibration=c; observation=Detector.detect(pixels,calibration:c)
        }
        message=water == nil ? "No clear blue water found inside Roblox. Face open water and capture again."
            : "Clear water found. Start when ready; the fishing bars will be detected automatically after a bite."
    }
    func importImage() {
        stop(nil)
        let panel=NSOpenPanel(); panel.allowedContentTypes=[.png,.jpeg]; panel.canChooseDirectories=false
        if panel.runModal() == .OK, let url=panel.url { loadImage(url) }
    }
    func loadImage(_ url:URL) {
        stop(nil)
        guard let source=CGImageSourceCreateWithURL(url as CFURL,nil),let img=CGImageSourceCreateImageAtIndex(source,0,nil) else { message="Could not read image"; return }
        image=img; imported=true; hasCapture=false; gameBounds=Region(x:0,y:0,w:1,h:1)
        screenLabel="Offline image · no input"
        analyzeSetup(img)
        message="Offline image: \(observation.reason). Capture your actual screen to fish."
    }
    func start() {
        guard !running else { stop("Stopped by you"); return }
        refreshPermissions()
        guard hasCapture,!imported,filter != nil else { message="Capture your screen first."; return }
        // hasCapture proves a real image was obtained. Every run captures again
        // before its first mouse press, so revoked access still stops input.
        guard preview || accessibility else { message="Allow Accessibility before enabling real clicks."; return }
        guard hotKey != nil else { message="Emergency shortcut is unavailable. Close the app using Control–Option–X, then relaunch."; return }
        guard !CGEventSource.buttonState(.combinedSessionState,button:.left) else { message="Release the mouse button before starting."; return }
        sessionPreview=preview; runID=UUID(); running=true; phase="Starting in 3…"
        startTime=clock; stateTime=clock; lastFrameTime=clock; lastCaptureRequest=0; lastGood=clock
        stableFrames=0; catches=0; elapsed=0; crop=nil; pointerArmed=false
        cachedWindowOK=true; safetyCounter=0; forcedReleaseUntil=0
        calibration=Calibration(); observation=Observation(); controller.reset(); evidence.reset()
        message=sessionPreview ? "Preview watches the screen without clicking. Cast manually to check tracking."
            : "Keep the pointer still. Control–Option–X stops immediately."
        NSRunningApplication(processIdentifier:targetPID)?.activate(options:[])
    }
    func stop(_ reason:String?) {
        runID=UUID(); running=false; phase="Stopped"; setButton(false)
        pointerArmed=false; controller.reset(); evidence.reset(); stableFrames=0
        if let reason=reason { message=reason }
    }
    private func setButton(_ wanted:Bool) {
        guard wanted != buttonDown else { return }
        if wanted && !sessionPreview {
            guard running,NSWorkspace.shared.frontmostApplication?.processIdentifier==targetPID,
                AXIsProcessTrusted(),currentWindowIsSafe(),pointerArmed else { stop("Mouse input safety check failed"); return }
        }
        if !sessionPreview {
            guard let event=CGEvent(mouseEventSource:nil,mouseType:wanted ? .leftMouseDown:.leftMouseUp,
                mouseCursorPosition:oceanPoint,mouseButton:.left) else {
                if wanted { stop("Could not create mouse event") }; return
            }
            event.setIntegerValueField(.eventSourceUserData,value:tag)
            event.setIntegerValueField(.mouseEventClickState,value:1); event.flags=[]; event.postToPid(targetPID)
        }
        buttonDown=wanted; lastAction=wanted ? "Holding ↑":"Released ↓"
        if wanted { heldSince=clock }
    }
    private func currentWindowIsSafe()->Bool {
        guard let list=CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]],
            let top=list.first(where:{($0[kCGWindowOwnerPID as String] as? Int)==Int(targetPID) && ($0[kCGWindowLayer as String] as? Int)==0}),
            (top[kCGWindowNumber as String] as? UInt32)==selectedID,
            let bounds=top[kCGWindowBounds as String] as? NSDictionary,let rect=CGRect(dictionaryRepresentation:bounds) else { return false }
        return abs(rect.minX-referenceFrame.minX)<1 && abs(rect.minY-referenceFrame.minY)<1
            && abs(rect.width-referenceFrame.width)<1 && abs(rect.height-referenceFrame.height)<1
    }
    private func tick() {
        guard running else { return }
        let now=clock; elapsed=now-startTime
        guard elapsed<duration else { stop("Session limit reached. Start again when ready."); return }
        if !sessionPreview && !AXIsProcessTrusted() { stop("Accessibility permission was removed"); return }
        if IsSecureEventInputEnabled() { stop("macOS Secure Input became active"); return }
        if now-startTime>0.5 {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier==targetPID else { stop("Roblox lost focus"); return }
            safetyCounter += 1
            if safetyCounter%5==0 { cachedWindowOK=currentWindowIsSafe() }
            guard cachedWindowOK else { stop("Roblox window changed. Capture your screen again."); return }
        }
        if phase.hasPrefix("Starting") {
            if now-stateTime<3 { phase="Starting in \(max(1,Int(ceil(3-(now-stateTime)))))…"; return }
            phase=sessionPreview ? "Preview":"Finding water"; lastFrameTime=now; stateTime=now
        }
        if !sessionPreview && pointerArmed,let p=CGEvent(source:nil)?.location,
            hypot(p.x-oceanPoint.x,p.y-oceanPoint.y)>24 { stop("Pointer moved — stopped"); return }
        if now-lastFrameTime>0.6 { stop("Screen capture stalled — released mouse"); return }
        if buttonDown && now-heldSince>1.5 { setButton(false); forcedReleaseUntil=now+0.08 }
        if phase=="Casting",now-stateTime>=0.08 { setButton(false); phase="Waiting for bite"; stateTime=now }
        if phase=="Waiting for bite",now-stateTime>35 { stop("No bite in 35 seconds. Check rod, bait, and view of the water."); return }
        if phase=="Reeling",now-lastGood>0.8 { stop("Lost reliable tracking — stopped and released. Capture again if the layout changed."); return }
        if phase=="Catch confirmed",now>=nextCastAt {
            if catches>=10 { stop("10-catch limit reached"); return }
            phase="Finding water"; crop=nil; pointerArmed=false; stateTime=now
        }
        let interval=crop == nil ? 0.08:0.04
        if phase != "Casting" && now-lastCaptureRequest>=interval && !captureBusy { requestFrame() }
    }
    private func preparePointer(_ water:WaterPoint) {
        self.water=water
        oceanPoint=CGPoint(x:displayFrame.minX+water.x*displayFrame.width,y:displayFrame.minY+water.y*displayFrame.height)
        CGWarpMouseCursorPosition(oceanPoint); pointerArmed=true
    }
    private func requestFrame() {
        guard let filter=filter else { stop("Screen capture is not configured"); return }
        captureBusy=true; lastCaptureRequest=clock
        let id=runID,region=crop,cfg=configuration(region:crop),requested=clock
        Task { @MainActor [weak self] in
            guard let self=self else { return }
            do {
                let img=try await SCScreenshotManager.captureImage(contentFilter:filter,configuration:cfg)
                self.captureBusy=false
                guard self.running,self.runID==id else { return }
                guard self.clock-requested<0.5 else { self.stop("Capture took too long — stopped"); return }
                guard let pixels=Pixels(image:img) else { self.stop("Could not read captured pixels"); return }
                self.lastFrameTime=self.clock; self.liveImage=img
                self.handleFrame(pixels,region:region,now:self.clock)
            } catch {
                self.captureBusy=false
                guard self.running,self.runID==id else { return }
                self.capturePermissionConfirmed=false; self.refreshPermissions()
                self.stop("Screen capture failed: \(error.localizedDescription)")
            }
        }
    }
    private func handleFrame(_ pixels:Pixels,region:Region?,now:Double) {
        if region==nil {
            if let found=AutoVision.fishingUI(pixels,within:gameBounds) {
                calibration=found; observation=Detector.detect(pixels,calibration:found)
            } else { observation=Observation(reason:"Waiting for the fishing bars to appear") }
        } else { observation=Detector.detect(pixels,calibration:calibration,crop:region) }
        guard clock-now<0.35 else { stop("Visual analysis took too long — stopped"); return }
        let o=observation
        if sessionPreview {
            if o.tracked { crop=calibration.crop }
            else if !o.blueVisible { crop=nil }
            let wanted=controller.update(o,now:now)
            lastAction=o.tracked ? (wanted ? "Would hold ↑":"Would release ↓") : "Waiting for a bite"
            return
        }
        if phase=="Finding water" {
            guard let point=AutoVision.water(pixels,within:gameBounds) else {
                stop("No clear blue water found inside Roblox. Face open water and capture again."); return
            }
            preparePointer(point)
            if o.tracked { phase="Waiting for bite"; stateTime=now; stableFrames=1 }
            else { phase="Casting"; stateTime=now; stableFrames=0; evidence.reset(); setButton(true) }
            return
        }
        if phase=="Waiting for bite" {
            stableFrames=o.tracked ? stableFrames+1:0
            if stableFrames>=3 {
                phase="Reeling"; crop=calibration.crop; lastGood=now; controller.reset(); evidence.reset()
                message="Fishing bars found. Balancing the black box on the white line."
            }
        }
        guard phase=="Reeling" else { return }
        if evidence.update(o,now:now) {
            setButton(false); catches += 1; phase="Catch confirmed"; nextCastAt=now+1.5; crop=nil
            message="Full green gauge and closed minigame observed. Next cast in 1.5 seconds."; return
        }
        guard o.tracked else { setButton(false); controller.reset(); return }
        lastGood=now
        let wanted=controller.update(o,now:now)
        setButton(wanted && now>=forcedReleaseUntil)
    }
    private func installStopControls() {
        var ref:EventHotKeyRef?
        let hotID=EventHotKeyID(signature:0x47504F46,id:1)
        if RegisterEventHotKey(UInt32(kVK_ANSI_X),UInt32(controlKey|optionKey),hotID,GetApplicationEventTarget(),0,&ref)==noErr { hotKey=ref }
        var spec=EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(),{ _,event,context in
            guard let context=context, let event=event else { return OSStatus(eventNotHandledErr) }
            var id=EventHotKeyID()
            GetEventParameter(event,EventParamName(kEventParamDirectObject),EventParamType(typeEventHotKeyID),nil,
                MemoryLayout<EventHotKeyID>.size,nil,&id)
            guard id.signature==0x47504F46 else { return OSStatus(eventNotHandledErr) }
            let model=Unmanaged<MacroModel>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in model.stop("Stopped with Control–Option–X") }
            return noErr
        },1,&spec,Unmanaged.passUnretained(self).toOpaque(),&eventHandler)
        keyMonitor=NSEvent.addGlobalMonitorForEvents(matching:.keyDown) { [weak self] event in
            let key=event.keyCode
            if [53,36,44,48].contains(key) { Task { @MainActor in self?.stop("Keyboard stop") } }
        }
        clickMonitor=NSEvent.addGlobalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown]) { [weak self] event in
            if event.cgEvent?.getIntegerValueField(.eventSourceUserData) != 0x47504F46 {
                Task { @MainActor in
                    if self?.running == true && self?.sessionPreview == false { self?.stop("Manual mouse click — stopped") }
                }
            }
        }
        localMonitor=NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in
            if event.keyCode==53 { Task { @MainActor in self?.stop("Stopped with Escape") } }
            return event
        }
    }
    func shutdown() {
        stop(nil); timer?.invalidate()
        if let m=keyMonitor { NSEvent.removeMonitor(m) }
        if let m=clickMonitor { NSEvent.removeMonitor(m) }
        if let m=localMonitor { NSEvent.removeMonitor(m) }
        if let key=hotKey { UnregisterEventHotKey(key) }
        if let handler=eventHandler { RemoveEventHandler(handler) }
    }
}
