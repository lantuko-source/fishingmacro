import Foundation
import ImageIO
import FishingCore


// Dependency-free checks also run with Apple's Command Line Tools (no full Xcode).
var failures=0
func fail(_ message:String) { failures += 1; print("  FAIL: \(message)") }
func XCTAssertTrue(_ b:Bool,_ message:String="",file:StaticString=#filePath,line:UInt=#line) { if !b { fail("\(file):\(line) expected true \(message)") } }
func XCTAssertFalse(_ b:Bool,_ message:String="",file:StaticString=#filePath,line:UInt=#line) { XCTAssertTrue(!b,message,file:file,line:line) }
func XCTAssertNil<T>(_ v:T?,file:StaticString=#filePath,line:UInt=#line) { XCTAssertTrue(v == nil,"expected nil",file:file,line:line) }
func XCTAssertEqual<T:Equatable>(_ a:T,_ b:T,file:StaticString=#filePath,line:UInt=#line) { XCTAssertTrue(a==b,"\(a) != \(b)",file:file,line:line) }
func XCTAssertEqual(_ a:Double,_ b:Double,accuracy:Double,file:StaticString=#filePath,line:UInt=#line) { XCTAssertTrue(abs(a-b)<=accuracy,"\(a) != \(b) ± \(accuracy)",file:file,line:line) }
func XCTAssertGreaterThan(_ a:Double,_ b:Double,file:StaticString=#filePath,line:UInt=#line) { XCTAssertTrue(a>b,"\(a) <= \(b)",file:file,line:line) }
func XCTAssertLessThan(_ a:Double,_ b:Double,file:StaticString=#filePath,line:UInt=#line) { XCTAssertTrue(a<b,"\(a) >= \(b)",file:file,line:line) }
enum CheckError:Error { case skip(String), missingValue }
func XCTSkip(_ message:String)->CheckError { .skip(message) }
func XCTUnwrap<T>(_ v:T?) throws -> T { guard let v=v else { throw CheckError.missingValue }; return v }

final class TrackingTests {
    func calibration() -> Calibration {
        var c=Calibration()
        c.lane=Region(x:0.1,y:0.1,w:0.05,h:0.8)
        c.progress=Region(x:0.3,y:0.1,w:0.05,h:0.8)
        c.marker=RGB(20,20,20)
        return c
    }
    func fixture(marker:Range<Int>? = 160..<180, extra:Range<Int>? = nil, white:Bool=true,
                 fill:Range<Int>? = 120..<180) -> Pixels {
        var p=Pixels(width:200,height:200,rgba:[UInt8](repeating:0,count:200*200*4))
        func rect(_ xs:Range<Int>,_ ys:Range<Int>,_ color:RGB) {
            for y in ys { for x in xs {
                let i=(y*200+x)*4
                p.rgba[i]=UInt8(color.r); p.rgba[i+1]=UInt8(color.g); p.rgba[i+2]=UInt8(color.b); p.rgba[i+3]=255
            } }
        }
        rect(20..<30,20..<180,RGB(50,170,250))
        if let m=marker { rect(20..<30,m,RGB(20,20,20)) }
        if let m=extra { rect(20..<30,m,RGB(20,20,20)) }
        if white { rect(20..<30,95..<98,RGB(250,250,250)) }
        rect(60..<70,20..<180,RGB(25,25,25))
        if let f=fill { rect(60..<70,f,RGB(150,250,60)) }
        return p
    }
    func testDetectsBottomBoxAndWhiteLine() {
        let o=Detector.detect(fixture(),calibration:calibration())
        XCTAssertTrue(o.tracked,o.reason)
        XCTAssertEqual(o.markerY!,0.9375,accuracy:0.001)
        XCTAssertEqual(o.targetY!,0.478125,accuracy:0.001)
        XCTAssertEqual(o.progress!,0.375,accuracy:0.001)
    }
    func testRejectsMultipleBlackBoxes() { XCTAssertFalse(Detector.detect(fixture(extra:50..<65),calibration:calibration()).tracked) }
    func testRejectsMissingWhiteLine() { XCTAssertFalse(Detector.detect(fixture(white:false),calibration:calibration()).tracked) }
    func testRejectsMissingBox() { XCTAssertFalse(Detector.detect(fixture(marker:nil),calibration:calibration()).tracked) }
    func testGreenSceneryAboveEmptyBottomIsNotProgress() { XCTAssertNil(Detector.detect(fixture(fill:70..<100),calibration:calibration()).progress) }
    func testCompleteProgress() { XCTAssertEqual(Detector.detect(fixture(fill:20..<180),calibration:calibration()).progress,1) }
    func testHoldToRiseReleaseToFall() {
        var controller=BalanceController()
        XCTAssertTrue(controller.update(Observation(markerY:0.8,targetY:0.4,markerHeight:0.05,blueVisible:true),now:0))
        controller.reset()
        XCTAssertFalse(controller.update(Observation(markerY:0.2,targetY:0.4,markerHeight:0.05,blueVisible:true),now:1))
    }
    func testAmbiguousFrameReleases() {
        var controller=BalanceController()
        _=controller.update(Observation(markerY:0.8,targetY:0.4,blueVisible:true),now:0)
        XCTAssertFalse(controller.update(Observation(),now:0.1))
    }
    func testControllerBalancesSimulatedMomentum() {
        var controller=BalanceController(), y=0.9, velocity=0.0
        var errors:[Double]=[]
        let dt=0.04
        for i in 0..<500 {
            let t=Double(i)*dt, target=0.5+sin(t*0.5)*0.15
            let hold=controller.update(Observation(markerY:y,targetY:target,markerHeight:0.06,blueVisible:true),now:t)
            velocity=(velocity+(hold ? -1.8:1.8)*dt)*0.92
            y=max(0.02,min(0.98,y+velocity*dt))
            if i>100 { errors.append(abs(y-target)) }
        }
        XCTAssertLessThan(errors.reduce(0,+)/Double(errors.count),0.045)
    }
    func testDisappearanceAloneNeverConfirmsCatch() {
        var evidence=CatchEvidence()
        for i in 0..<100 { XCTAssertFalse(evidence.update(Observation(),now:Double(i)*0.05)) }
    }
    func testFullGaugeThenClosedMinigameConfirms() {
        var e=CatchEvidence()
        let full=Observation(markerY:0.5,targetY:0.5,progress:0.99,blueVisible:true)
        XCTAssertFalse(e.update(full,now:0)); XCTAssertFalse(e.update(full,now:0.05)); XCTAssertFalse(e.update(full,now:0.1))
        XCTAssertFalse(e.update(Observation(),now:0.15))
        XCTAssertTrue(e.update(Observation(),now:0.6))
    }
    func testOneFullFrameIsNotEnough() {
        var e=CatchEvidence()
        _=e.update(Observation(markerY:0.5,targetY:0.5,progress:1,blueVisible:true),now:0)
        _=e.update(Observation(),now:0.1)
        XCTAssertFalse(e.update(Observation(),now:0.6))
    }
    func testOldFullGaugeDoesNotConfirmLaterLoss() {
        var e=CatchEvidence()
        for i in 0..<3 { _=e.update(Observation(markerY:0.5,targetY:0.5,progress:1,blueVisible:true),now:Double(i)*0.1) }
        _=e.update(Observation(),now:3)
        XCTAssertFalse(e.update(Observation(),now:3.5))
    }
    func testRegionsMustStayInsideTheCapture() {
        XCTAssertFalse(Region(x:0.9,y:0,w:0.2,h:0.8).valid)
        XCTAssertFalse(Region(x:0,y:0,w:0,h:0.8).valid)
        XCTAssertTrue(calibration().crop!.valid)
    }
    func testWhiteLineOverBlackBoxStillTracks() {
        let o=Detector.detect(fixture(marker:85..<110),calibration:calibration())
        XCTAssertTrue(o.tracked,o.reason)
        XCTAssertEqual(o.markerY!,(97.5-20)/160,accuracy:0.01)
    }
    func testCropCoordinatesMatchFullFrame() {
        let c=calibration(), crop=c.crop!
        let pixels=fixture()
        let x=Int(crop.x*200), y=Int(crop.y*200), w=Int(crop.w*200), h=Int(crop.h*200)
        var data:[UInt8]=[]
        for row in y..<y+h { data.append(contentsOf:pixels.rgba[(row*200+x)*4..<(row*200+x+w)*4]) }
        let o=Detector.detect(Pixels(width:w,height:h,rgba:data),calibration:c,crop:crop)
        XCTAssertTrue(o.tracked,o.reason)
        XCTAssertEqual(o.markerY!,0.9375,accuracy:0.01)
    }
    func testProvidedScreenshotWhenAvailable() throws {
        guard let path=ProcessInfo.processInfo.environment["FISHING_SAMPLE"] else { throw XCTSkip("Set FISHING_SAMPLE to check a local screenshot without committing it") }
        let source=try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath:path) as CFURL,nil))
        let image=try XCTUnwrap(CGImageSourceCreateImageAtIndex(source,0,nil))
        let pixels=try XCTUnwrap(Pixels(image:image))
        var c=Calibration()
        c.lane=Region(x:269.0/650,y:140.0/864,w:10.0/650,h:582.0/864)
        c.progress=Region(x:375.0/650,y:225.0/864,w:12.0/650,h:550.0/864)
        c.marker=pixels.color(x:273,y:704)
        let o=Detector.detect(pixels,calibration:c)
        print("Provided screenshot: marker=\(String(describing:o.markerY)), target=\(String(describing:o.targetY)), progress=\(String(describing:o.progress)); \(o.reason)")
        XCTAssertTrue(o.tracked,o.reason)
        XCTAssertGreaterThan(o.markerY!,0.93)
        XCTAssertEqual(o.targetY!,(576.0-140)/582,accuracy:0.015)
        XCTAssertEqual(o.progress!,0.22,accuracy:0.04)
        let auto=AutoVision.fishingUI(pixels,within:Region(x:0,y:0,w:1,h:1))
        print("Auto UI: \(String(describing:auto?.lane)), gauge=\(String(describing:auto?.progress))")
        XCTAssertTrue(auto != nil,"Automatically discover the lane and gauge without marking")
        if let auto=auto {
            let detected=Detector.detect(pixels,calibration:auto)
            print("Auto progress: \(String(describing:detected.progress))")
            XCTAssertTrue(detected.tracked)
            XCTAssertEqual(try XCTUnwrap(detected.progress),0.22,accuracy:0.04)
        }
        XCTAssertTrue(AutoVision.water(pixels,within:Region(x:0,y:0,w:1,h:1)) != nil)
        // The live app receives a full display with a window somewhere inside it.
        var display=Pixels(width:1200,height:1000,rgba:[UInt8](repeating:40,count:1200*1000*4))
        for row in 0..<pixels.height {
            let source=row*pixels.width*4
            let destination=((row+60)*display.width+420)*4
            display.rgba.replaceSubrange(destination..<destination+pixels.width*4,
                with:pixels.rgba[source..<source+pixels.width*4])
        }
        let window=Region(x:420.0/1200,y:60.0/1000,w:650.0/1200,h:864.0/1000)
        let embedded=try XCTUnwrap(AutoVision.fishingUI(display,within:window))
        let embeddedObservation=Detector.detect(display,calibration:embedded)
        XCTAssertTrue(embeddedObservation.tracked)
        XCTAssertEqual(try XCTUnwrap(embeddedObservation.progress),0.22,accuracy:0.04)
        let water=try XCTUnwrap(AutoVision.water(display,within:window))
        XCTAssertTrue(window.rect.contains(CGPoint(x:water.x,y:water.y)))
    }
    func testOceanNeedsNoFishingUI() {
        var data=[UInt8](repeating:255,count:200*200*4)
        for i in stride(from:0,to:data.count,by:4) { data[i]=15; data[i+1]=65; data[i+2]=160 }
        let p=Pixels(width:200,height:200,rgba:data), bounds=Region(x:0,y:0,w:1,h:1)
        XCTAssertTrue(AutoVision.water(p,within:bounds) != nil)
        XCTAssertNil(AutoVision.fishingUI(p,within:bounds))
    }
    func testNoBlueWaterMeansNoClickCandidate() {
        let p=Pixels(width:200,height:200,rgba:[UInt8](repeating:50,count:200*200*4))
        XCTAssertNil(AutoVision.water(p,within:Region(x:0,y:0,w:1,h:1)))
    }
}

@main struct CheckRunner {
    static func main() {
        let suite=TrackingTests()
        let tests:[(String,() throws -> Void)] = [
            ("testDetectsBottomBoxAndWhiteLine",suite.testDetectsBottomBoxAndWhiteLine),
            ("testRejectsMultipleBlackBoxes",suite.testRejectsMultipleBlackBoxes),
            ("testRejectsMissingWhiteLine",suite.testRejectsMissingWhiteLine),
            ("testRejectsMissingBox",suite.testRejectsMissingBox),
            ("testGreenSceneryAboveEmptyBottomIsNotProgress",suite.testGreenSceneryAboveEmptyBottomIsNotProgress),
            ("testCompleteProgress",suite.testCompleteProgress),
            ("testHoldToRiseReleaseToFall",suite.testHoldToRiseReleaseToFall),
            ("testAmbiguousFrameReleases",suite.testAmbiguousFrameReleases),
            ("testControllerBalancesSimulatedMomentum",suite.testControllerBalancesSimulatedMomentum),
            ("testDisappearanceAloneNeverConfirmsCatch",suite.testDisappearanceAloneNeverConfirmsCatch),
            ("testFullGaugeThenClosedMinigameConfirms",suite.testFullGaugeThenClosedMinigameConfirms),
            ("testOneFullFrameIsNotEnough",suite.testOneFullFrameIsNotEnough),
            ("testOldFullGaugeDoesNotConfirmLaterLoss",suite.testOldFullGaugeDoesNotConfirmLaterLoss),
            ("testRegionsMustStayInsideTheCapture",suite.testRegionsMustStayInsideTheCapture),
            ("testWhiteLineOverBlackBoxStillTracks",suite.testWhiteLineOverBlackBoxStillTracks),
            ("testCropCoordinatesMatchFullFrame",suite.testCropCoordinatesMatchFullFrame),
            ("testProvidedScreenshotWhenAvailable",suite.testProvidedScreenshotWhenAvailable),
            ("testOceanNeedsNoFishingUI",suite.testOceanNeedsNoFishingUI),
            ("testNoBlueWaterMeansNoClickCandidate",suite.testNoBlueWaterMeansNoClickCandidate)
        ]
        var passed=0, skipped=0
        for (name,run) in tests {
            let before=failures
            do {
                try run()
                if before==failures { print("PASS \(name)"); passed += 1 }
            } catch CheckError.skip(let reason) { print("SKIP \(name): \(reason)"); skipped += 1 }
            catch { fail("\(name): \(error)") }
        }
        print("\(passed) passed, \(skipped) skipped, \(failures) failures")
        if failures>0 { exit(1) }
    }
}
