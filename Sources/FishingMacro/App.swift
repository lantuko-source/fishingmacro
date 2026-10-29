import SwiftUI
import AppKit
import FishingCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var model:MacroModel?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification:Notification) { MainActor.assumeIsolated { Self.model?.shutdown() } }
}

@main struct FishingMacroApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model=MacroModel()
    var body: some Scene {
        WindowGroup("Fishing Macro") {
            ContentView(model:model)
                .frame(minWidth:1040,minHeight:740)
                .onAppear {
                    AppDelegate.model=model
                    if let i=CommandLine.arguments.firstIndex(of:"--image"), CommandLine.arguments.count>i+1 {
                        model.loadImage(URL(fileURLWithPath:CommandLine.arguments[i+1]))
                    }
                }
        }.defaultSize(width:1180,height:820)
        .commands {
            CommandGroup(replacing:.newItem) {}
            CommandMenu("Fishing") {
                Button("Stop") { model.stop("Stopped by you") }.keyboardShortcut("p",modifiers:[])
                Button("Open test image…") { model.importImage() }
            }
        }
        MenuBarExtra("Fishing Macro",systemImage:"fish.fill") {
            Text(model.phase)
            Button("Stop · P") { model.stop("Stopped from menu bar") }
            Divider()
            Button("Show Fishing Macro") { NSApp.activate(ignoringOtherApps:true); NSApp.windows.first?.makeKeyAndOrderFront(nil) }
            Button("Quit") { model.shutdown(); NSApp.terminate(nil) }
        }
    }
}

struct ContentView: View {
    @ObservedObject var model:MacroModel
    let ink=Color(red:0.07,green:0.15,blue:0.20)
    let teal=Color(red:0.02,green:0.43,blue:0.43)
    var body: some View {
        HStack(spacing:0) {
            VStack(alignment:.leading,spacing:23) {
                HStack(spacing:10) {
                    Image(systemName:"fish.fill").font(.system(size:28)).foregroundStyle(teal)
                    VStack(alignment:.leading,spacing:3) {
                        Text("FISHING MACRO").font(.system(size:10,weight:.bold,design:.monospaced)).tracking(2).foregroundStyle(teal)
                        Text("Ready when they bite.").font(.system(size:20,weight:.semibold,design:.rounded)).foregroundStyle(ink)
                    }
                }
                VStack(alignment:.leading,spacing:12) {
                    eyebrow("MAC PERMISSIONS")
                    permission("Screen Recording",on:model.recording,action:{model.requestRecording()},settings:{model.openPrivacy("Privacy_ScreenCapture")})
                    permission("Accessibility",on:model.accessibility,action:{model.requestAccessibility()},settings:{model.openPrivacy("Privacy_Accessibility")})
                    Button("Refresh permission status") { model.refreshPermissions() }.font(.caption).buttonStyle(.link)
                }
                Divider()
                VStack(alignment:.leading,spacing:12) {
                    eyebrow("START AND FISH")
                    Text("Face open water with your rod equipped. Start captures your screen and casts automatically.")
                        .font(.system(size:13)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    Text(model.screenLabel).font(.system(size:10,design:.monospaced)).foregroundStyle(.secondary)
                }
                Divider()
                VStack(alignment:.leading,spacing:14) {
                    Button { model.start() } label: {
                        Label(model.running ? "Stop fishing":"Start fishing",systemImage:model.running ? "stop.fill":"play.fill")
                            .font(.system(size:15,weight:.semibold)).frame(maxWidth:.infinity).padding(.vertical,7)
                    }.buttonStyle(.borderedProminent).tint(model.running ? .red:teal).controlSize(.large)
                    Text("Press P to stop").font(.system(size:13,weight:.semibold,design:.monospaced)).frame(maxWidth:.infinity).foregroundStyle(teal)
                    Text("Runs until you stop it. No session or catch limit.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                }
                Spacer(minLength:0)
                Label { Text("Mouse clicks and window movement keep the run active. Switching away pauses input; return to Roblox to continue.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                } icon: { Image(systemName:"hand.raised").foregroundStyle(teal) }
            }.padding(26).frame(width:300).background(Color(red:0.95,green:0.96,blue:0.94))
            VStack(alignment:.leading,spacing:18) {
                HStack(alignment:.top) {
                    VStack(alignment:.leading,spacing:6) {
                        Text(model.running ? model.phase : "Start. Fish. Press P to stop.").font(.system(size:25,weight:.semibold,design:.rounded)).foregroundStyle(ink)
                        Text("Automatic capture, casting, and balancing. Runs until stopped.").font(.system(size:12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(model.imported ? "OFFLINE":model.running ? "RUNNING":"READY")
                        .font(.system(size:10,weight:.bold,design:.monospaced)).tracking(1).padding(.horizontal,12).padding(.vertical,7)
                        .background(teal.opacity(0.1),in:Capsule())
                }
                HStack(spacing:14) {
                    status("Water",value:model.water == nil ? "Waiting for view":"Clear water found",symbol:"water.waves",active:model.water != nil)
                    status("Fishing bars",value:model.observation.tracked ? "Tracking":"Appear after a bite",symbol:"slider.vertical.3",active:model.observation.tracked)
                    status("Casts / catches",value:"\(model.casts) sent · \(model.catches) confirmed",symbol:"fish",active:model.casts>0)
                }
                ZStack {
                    RoundedRectangle(cornerRadius:16).fill(Color(red:0.075,green:0.13,blue:0.17))
                    if let image=model.image {
                        ScreenPreview(image:image,calibration:model.calibration,water:model.water,showRegions:!model.running).padding(12)
                    } else {
                        VStack(spacing:16) {
                            Image(systemName:"display").font(.system(size:48,weight:.ultraLight)).foregroundStyle(.white.opacity(0.5))
                            Text("Start with the ocean.").font(.system(size:22,weight:.medium,design:.rounded)).foregroundStyle(.white)
                            Text("Face the water in GPO and press Start fishing.\nThe screen is captured automatically.")
                                .font(.system(size:13)).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.6))
                        }
                    }
                }.frame(maxWidth:.infinity,maxHeight:.infinity).layoutPriority(1)
                if model.running,let live=model.liveImage {
                    HStack(spacing:14) {
                        Image(decorative:live,scale:1).resizable().scaledToFit().frame(width:85,height:80).background(.black.opacity(0.1)).clipShape(RoundedRectangle(cornerRadius:6))
                        VStack(alignment:.leading,spacing:7) {
                            eyebrow("LIVE VIEW")
                            Text(model.observation.reason).font(.caption)
                            Text(model.lastAction).font(.system(size:16,weight:.semibold,design:.rounded)).foregroundStyle(teal)
                        }
                        Spacer()
                        if let progress=model.observation.progress { Text("\(Int(progress*100))%\ngauge").font(.caption).monospacedDigit().multilineTextAlignment(.trailing) }
                        Text("\(Int(model.elapsed))s").font(.caption).monospacedDigit()
                    }
                } else {
                    HStack(spacing:16) {
                        Label("Automatic water selection",systemImage:"scope")
                        Label("Hold ↑  Release ↓",systemImage:"arrow.up.arrow.down")
                        Label("Stop anytime",systemImage:"stop.circle")
                    }.font(.system(size:11)).foregroundStyle(.secondary)
                }
                HStack(alignment:.top,spacing:9) {
                    Circle().fill(model.observation.tracked || model.water != nil ? teal:Color.orange).frame(width:7,height:7).padding(.top,4)
                    Text(model.message).font(.system(size:12)).foregroundStyle(ink).fixedSize(horizontal:false,vertical:true)
                    Spacer()
                    if model.busy { ProgressView().controlSize(.small) }
                }.padding(13).frame(maxWidth:.infinity,alignment:.leading).background(teal.opacity(0.06),in:RoundedRectangle(cornerRadius:10))
            }.padding(26).background(Color(red:0.99,green:0.985,blue:0.97))
        }.preferredColorScheme(.light)
            .onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)) { _ in model.refreshPermissions() }
    }
    private func eyebrow(_ s:String)->some View { Text(s).font(.system(size:10,weight:.bold)).tracking(1.5).foregroundStyle(.secondary) }
    private func status(_ title:String,value:String,symbol:String,active:Bool)->some View {
        HStack(spacing:9) {
            Image(systemName:symbol).font(.system(size:17)).foregroundStyle(active ? teal:.secondary)
            VStack(alignment:.leading,spacing:3) {
                Text(title.uppercased()).font(.system(size:9,weight:.bold)).tracking(1).foregroundStyle(.secondary)
                Text(value).font(.system(size:11,weight:.medium)).foregroundStyle(ink)
            }
            Spacer(minLength:0)
        }.padding(12).frame(maxWidth:.infinity).background(.white.opacity(0.7),in:RoundedRectangle(cornerRadius:10))
    }
    private func permission(_ title:String,on:Bool,action:@escaping()->Void,settings:@escaping()->Void)->some View {
        HStack {
            Image(systemName:on ? "checkmark.circle.fill":"circle").foregroundStyle(on ? teal:Color.secondary)
            Text(title).font(.system(size:12)); Spacer()
            if !on { Button("Allow",action:action).font(.caption).buttonStyle(.borderless) }
            Button("Settings",action:settings).font(.caption).buttonStyle(.borderless)
        }
    }
}

struct ScreenPreview:View {
    let image:CGImage,calibration:Calibration,water:WaterPoint?,showRegions:Bool
    var body:some View {
        GeometryReader { geo in
            let ratio=min(geo.size.width/Double(image.width),geo.size.height/Double(image.height))
            let size=CGSize(width:Double(image.width)*ratio,height:Double(image.height)*ratio)
            ZStack(alignment:.topLeading) {
                Image(decorative:image,scale:1).resizable().frame(width:size.width,height:size.height)
                if showRegions {
                    if let lane=calibration.lane { region(lane,size:size,color:.cyan) }
                    if let progress=calibration.progress { region(progress,size:size,color:.orange) }
                    if let point=water { Image(systemName:"plus.circle.fill").foregroundStyle(.mint).position(x:point.x*size.width,y:point.y*size.height) }
                }
            }.frame(width:size.width,height:size.height)
                .offset(x:(geo.size.width-size.width)/2,y:(geo.size.height-size.height)/2)
        }
    }
    private func region(_ r:Region,size:CGSize,color:Color)->some View {
        Rectangle().stroke(color,lineWidth:1.5).frame(width:r.w*size.width,height:r.h*size.height).offset(x:r.x*size.width,y:r.y*size.height)
    }
}
