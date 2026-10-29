import Foundation
import CoreGraphics

public struct RGB: Codable, Equatable {
    public var r: Double, g: Double, b: Double
    public init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
    public func distance(_ p: RGB) -> Double {
        sqrt(pow(r-p.r, 2) + pow(g-p.g, 2) + pow(b-p.b, 2))
    }
    public var isBlue: Bool { b > 120 && b > r + 35 && g > r + 15 }
    public var isWhite: Bool { min(r, g, b) > 180 && max(r, g, b)-min(r, g, b) < 60 }
    public var isGreen: Bool { g > 150 && g > r * 1.2 && g > b * 1.3 }
}

/// All image and calibration coordinates are top-left, normalized to [0, 1].
public struct Region: Codable, Equatable {
    public var x: Double, y: Double, w: Double, h: Double
    public init(x: Double, y: Double, w: Double, h: Double) { self.x=x; self.y=y; self.w=w; self.h=h }
    public var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
    public var valid: Bool { x >= 0 && y >= 0 && w > 0 && h > 0 && x+w <= 1.00001 && y+h <= 1.00001 }
    public func relative(to crop: Region) -> Region {
        Region(x:(x-crop.x)/crop.w, y:(y-crop.y)/crop.h, w:w/crop.w, h:h/crop.h)
    }
    public func union(_ other: Region) -> Region {
        let r = rect.union(other.rect)
        return Region(x:r.minX, y:r.minY, w:r.width, h:r.height)
    }
}

public struct Calibration: Codable {
    public var lane: Region?
    public var progress: Region?
    public var marker: RGB?
    public init() {}
    public var crop: Region? { guard let l=lane, let p=progress else { return nil }; return l.union(p) }
}

public struct Pixels {
    public let width: Int, height: Int
    public var rgba: [UInt8]
    public init(width: Int, height: Int, rgba: [UInt8]) {
        self.width=width; self.height=height; self.rgba=rgba
    }
    public init?(image: CGImage) {
        width=image.width; height=image.height
        rgba = [UInt8](repeating:0, count:width*height*4)
        let ok = rgba.withUnsafeMutableBytes { ptr -> Bool in
            guard let ctx=CGContext(data:ptr.baseAddress, width:width, height:height,
                bitsPerComponent:8, bytesPerRow:width*4, space:CGColorSpace(name:CGColorSpace.sRGB)!,
                bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            ctx.draw(image, in:CGRect(x:0,y:0,width:width,height:height))
            return true
        }
        if !ok { return nil }
    }
    public func color(x: Int, y: Int) -> RGB {
        let i = (min(height-1,max(0,y))*width + min(width-1,max(0,x)))*4
        return RGB(Double(rgba[i]), Double(rgba[i+1]), Double(rgba[i+2]))
    }
    public func color(nx: Double, ny: Double) -> RGB { color(x:Int(nx*Double(width)), y:Int(ny*Double(height))) }
}

public struct Observation {
    public var markerY: Double?, targetY: Double?, markerHeight: Double?
    public var progress: Double?
    public var blueVisible: Bool
    public var reason: String
    public var tracked: Bool { markerY != nil && targetY != nil && blueVisible }
    public init(markerY: Double? = nil, targetY: Double? = nil, markerHeight: Double? = nil,
                progress: Double? = nil, blueVisible: Bool = false, reason: String = "No frame") {
        self.markerY=markerY; self.targetY=targetY; self.markerHeight=markerHeight
        self.progress=progress; self.blueVisible=blueVisible; self.reason=reason
    }
}

public enum Detector {
    private static func runs(_ flags: [Bool]) -> [Range<Int>] {
        var result:[Range<Int>] = [], start:Int?
        for i in 0...flags.count {
            if i < flags.count && flags[i] { if start == nil { start=i } }
            else if let s=start { result.append(s..<i); start=nil }
        }
        return result
    }
    /// Fail closed on multiple dark blocks or target lines. Never choose a random candidate.
    public static func detect(_ pixels: Pixels, calibration c: Calibration, crop: Region? = nil) -> Observation {
        guard let lane=c.lane, let marker=c.marker, lane.valid, pixels.width>0, pixels.height>0,
            pixels.rgba.count == pixels.width*pixels.height*4 else { return Observation(reason:"Select lane and black box") }
        let l = crop.map { lane.relative(to:$0) } ?? lane
        guard l.valid else { return Observation(reason:"Lane outside captured region") }
        let x0=max(0,Int(l.x*Double(pixels.width))), x1=min(pixels.width,Int((l.x+l.w)*Double(pixels.width)))
        let y0=max(0,Int(l.y*Double(pixels.height))), y1=min(pixels.height,Int((l.y+l.h)*Double(pixels.height)))
        guard x1-x0>=3, y1-y0>=40 else { return Observation(reason:"Lane selection is too small") }
        var white=[Bool](), black=[Bool](), blueRows=0
        for y in y0..<y1 {
            var wh=0, bl=0, blue=0
            for x in x0..<x1 {
                let p=pixels.color(x:x,y:y)
                if p.isWhite { wh += 1 }
                if p.distance(marker) < 48 && max(p.r,p.g,p.b) < 140 { bl += 1 }
                if p.isBlue { blue += 1 }
            }
            let count=Double(x1-x0)
            white.append(Double(wh)/count >= 0.65)
            black.append(Double(bl)/count >= 0.70)
            if Double(blue)/count >= 0.50 { blueRows += 1 }
        }
        let n=Double(y1-y0)
        let targets=runs(white).filter { $0.count >= 1 && Double($0.count)/n < 0.05 }
        // The white target can be drawn over the black box when centered.
        // Join only that known white gap, preserving one complete dark marker.
        for line in targets where line.lowerBound>0 && line.upperBound<black.count {
            if black[line.lowerBound-1] && black[line.upperBound] {
                for i in line { black[i]=true }
            }
        }
        let markers=runs(black).filter { Double($0.count)/n >= 0.025 && Double($0.count)/n <= 0.20 }
        let visible=Double(blueRows)/n > 0.45
        var o=Observation(blueVisible:visible, reason: !visible ? "Blue lane not visible" : "Ambiguous marker or target")
        if targets.count == 1 { o.targetY=Double(targets[0].lowerBound+targets[0].upperBound)/2/n }
        if markers.count == 1 {
            o.markerY=Double(markers[0].lowerBound+markers[0].upperBound)/2/n
            o.markerHeight=Double(markers[0].count)/n
        }
        if let p=c.progress {
            let r=crop.map { p.relative(to:$0) } ?? p
            if r.valid {
                let a=max(0,Int(r.x*Double(pixels.width))), b=min(pixels.width,Int((r.x+r.w)*Double(pixels.width)))
                let top=max(0,Int(r.y*Double(pixels.height))), bottom=min(pixels.height,Int((r.y+r.h)*Double(pixels.height)))
                if b-a>=3 && bottom-top>=40 {
                    var green=[Bool]()
                    for y in top..<bottom {
                        var matches=0
                        for x in a..<b { if pixels.color(x:x,y:y).isGreen { matches += 1 } }
                        green.append(Double(matches)/Double(b-a) > 0.65)
                    }
                    // Fill must be continuous from the bottom; reject isolated green scenery.
                    let blocks=runs(green)
                    if let block=blocks.last, block.upperBound >= green.count-3,
                       blocks.count == 1 {
                        o.progress=Double(block.count)/Double(green.count)
                    }
                }
            }
        }
        if o.tracked { o.reason="Tracking black box and white target" }
        return o
    }
}

public struct BalanceController {
    private var previousError: Double?, previousTime: Double?
    private var velocity=0.0
    public private(set) var holding=false
    public init() {}
    public mutating func reset() { self=BalanceController() }
    /// Positive screen-space error means the box is below the target: hold to rise.
    public mutating func update(_ o: Observation, now: Double) -> Bool {
        guard o.tracked, let box=o.markerY, let target=o.targetY else { reset(); return false }
        let error=box-target
        if let t=previousTime, let e=previousError, now-t >= 0.01, now-t < 0.3 {
            let derivative=max(-3,min(3,(error-e)/(now-t)))
            velocity=velocity*0.6 + derivative*0.4
        } else { velocity=0 }
        previousTime=now; previousError=error
        let predicted=error+velocity*0.08
        let tolerance=max(0.004,(o.markerHeight ?? 0.04)*0.15)
        if predicted > tolerance { holding=true }
        else if predicted < -tolerance { holding=false }
        return holding
    }
}

/// Catch confirmation requires several high-fill frames followed by a disappearing lane.
public struct CatchEvidence {
    private var fullFrames=0, lastFull:Double?, absentSince:Double?
    public init() {}
    public mutating func reset() { self=CatchEvidence() }
    public mutating func update(_ o: Observation, now: Double) -> Bool {
        if o.tracked && (o.progress ?? 0) >= 0.97 {
            fullFrames += 1
            if fullFrames >= 3 { lastFull=now }
        } else { fullFrames=0 }
        if o.blueVisible { absentSince=nil }
        else if absentSince == nil { absentSince=now }
        guard let full=lastFull, let absent=absentSince else { return false }
        return now-full <= 2 && now-absent >= 0.4
    }
}
