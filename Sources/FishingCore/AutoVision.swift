import Foundation
import CoreGraphics

public struct WaterPoint {
    public let x:Double, y:Double, score:Double
}

/// Finds the fishing UI only when it exists. Initial setup needs only visible water.
public enum AutoVision {
    private struct Blob {
        var x0:Int, y0:Int, x1:Int, y1:Int, count:Int
        var width:Int { x1-x0+1 }; var height:Int { y1-y0+1 }
        var centerX:Double { Double(x0+x1)/2 }
        func joining(_ b:Blob)->Blob {
            Blob(x0:min(x0,b.x0),y0:min(y0,b.y0),x1:max(x1,b.x1),y1:max(y1,b.y1),count:count+b.count)
        }
    }
    private static func neutralDark(_ p:RGB)->Bool {
        max(p.r,p.g,p.b)<90 && max(p.r,p.g,p.b)-min(p.r,p.g,p.b)<35
    }
    private static func laneBlue(_ p:RGB)->Bool { p.isBlue && p.g>110 && p.r>25 && p.b>180 }
    private static func ocean(_ p:RGB)->Bool { p.b>75 && p.b>p.r*1.5 && p.b>p.g*1.10 && p.r<130 }

    private static func blobs(_ pixels:Pixels,within bounds:Region,matching predicate:(RGB)->Bool)->[Blob] {
        let step=max(1,pixels.height/650)
        let left=max(0,Int(bounds.x*Double(pixels.width))), top=max(0,Int(bounds.y*Double(pixels.height)))
        let width=max(1,Int(bounds.w*Double(pixels.width))/step), height=max(1,Int(bounds.h*Double(pixels.height))/step)
        var mask=[UInt8](repeating:0,count:width*height)
        for gy in 0..<height { for gx in 0..<width {
            if predicate(pixels.color(x:left+gx*step,y:top+gy*step)) { mask[gy*width+gx]=1 }
        } }
        var result:[Blob]=[], queue:[Int]=[]
        for seed in mask.indices where mask[seed]==1 {
            queue.removeAll(keepingCapacity:true); queue.append(seed); mask[seed]=0
            var head=0, b=Blob(x0:seed%width,y0:seed/width,x1:seed%width,y1:seed/width,count:0)
            while head<queue.count {
                let i=queue[head]; head += 1
                let x=i%width,y=i/width
                b.x0=min(b.x0,x); b.x1=max(b.x1,x); b.y0=min(b.y0,y); b.y1=max(b.y1,y); b.count += 1
                if x>0 && mask[i-1]==1 { mask[i-1]=0; queue.append(i-1) }
                if x+1<width && mask[i+1]==1 { mask[i+1]=0; queue.append(i+1) }
                if y>0 && mask[i-width]==1 { mask[i-width]=0; queue.append(i-width) }
                if y+1<height && mask[i+width]==1 { mask[i+width]=0; queue.append(i+width) }
            }
            if b.count>=3 {
                result.append(Blob(x0:left+b.x0*step,y0:top+b.y0*step,x1:left+b.x1*step+step-1,
                                   y1:top+b.y1*step+step-1,count:b.count*step*step))
            }
        }
        return result
    }
    public static func water(_ pixels:Pixels,within bounds:Region)->WaterPoint? {
        guard bounds.valid, pixels.width>0, pixels.height>0 else { return nil }
        let w=Double(pixels.width), h=Double(pixels.height)
        let radius=max(5,Int(min(bounds.w*w,bounds.h*h)*0.028))
        var best:WaterPoint?, bestRank = -Double.infinity
        // Stay away from window chrome, hotbars, and screen edges.
        for iy in 0..<12 { for ix in 0..<18 {
            let nx=bounds.x+bounds.w*(0.09+Double(ix)/17*0.82)
            let ny=bounds.y+bounds.h*(0.15+Double(iy)/11*0.55)
            let cx=Int(nx*w),cy=Int(ny*h)
            var count=0, matches=0, minB=255.0,maxB=0.0
            for sy in -4...4 { for sx in -4...4 {
                let p=pixels.color(x:cx+sx*radius/4,y:cy+sy*radius/4)
                count += 1; if ocean(p) { matches += 1 }; minB=min(minB,p.b); maxB=max(maxB,p.b)
            } }
            let score=Double(matches)/Double(count)
            guard score>=0.97, maxB-minB<125 else { continue }
            // Prefer water nearer the character instead of distant blue sky.
            let rank=score-abs((nx-bounds.x)/bounds.w-0.40)*0.06-abs((ny-bounds.y)/bounds.h-0.57)*0.25
            if rank>bestRank { bestRank=rank; best=WaterPoint(x:nx,y:ny,score:score) }
        } }
        return best
    }
    public static func fishingUI(_ pixels:Pixels,within bounds:Region)->Calibration? {
        guard bounds.valid, pixels.width>0, pixels.height>0 else { return nil }
        let pw=Double(pixels.width),ph=Double(pixels.height), bh=bounds.h*ph
        let blue=blobs(pixels,within:bounds,matching:laneBlue).filter {
            Double($0.height)>bh*0.035 && $0.width>=5 && Double($0.width)<bh*0.10
                && Double($0.height)>Double($0.width)*2 && Double($0.count)/Double($0.width*$0.height)>0.40
        }
        let green=blobs(pixels,within:bounds,matching:{$0.isGreen})
        var accepted:[Calibration]=[]
        for base in blue where Double(base.height)>bh*0.15 {
            var b=base
            for other in blue where abs(other.centerX-base.centerX)<Double(max(base.width,other.width))*0.45 {
                let gap=max(0,max(other.y0-b.y1,b.y0-other.y1))
                if Double(gap)<bh*0.22 { b=b.joining(other) }
            }
            let cx=Int(b.centerX), half=max(2,Int(Double(b.width)*0.16))
            // A fishing lane has dark rails. Open ocean streaks do not.
            var railRows=0
            for k in 1...10 {
                let y=b.y0+(b.height-1)*k/11
                if neutralDark(pixels.color(x:b.x0-3,y:y)) && neutralDark(pixels.color(x:b.x1+3,y:y)) { railRows += 1 }
            }
            guard railRows>=6 else { continue }
            var top=b.y0,bottom=b.y1
            let minY=max(0,Int(bounds.y*ph)),maxY=min(pixels.height-1,Int((bounds.y+bounds.h)*ph)-1)
            var lane=Region(x:Double(cx-half)/pw,y:Double(top)/ph,w:Double(half*2+1)/pw,h:Double(bottom-top+1)/ph)
            guard lane.valid, lane.h*ph>bh*0.25 else { continue }
            var c=Calibration(); c.lane=lane; c.marker=RGB(25,25,25)
            var first=Detector.detect(pixels,calibration:c)
            if !first.tracked {
                // The resting box sits just beyond the blue fill. Bound expansion
                // by track width so dark scenery beneath it cannot become a lane.
                let limit=Int(Double(b.width)*1.5)
                while top>minY && b.y0-top<limit && neutralDark(pixels.color(x:cx,y:top-1)) { top -= 1 }
                while bottom<maxY && bottom-b.y1<limit && neutralDark(pixels.color(x:cx,y:bottom+1)) { bottom += 1 }
                lane=Region(x:Double(cx-half)/pw,y:Double(top)/ph,w:Double(half*2+1)/pw,h:Double(bottom-top+1)/ph)
                c.lane=lane; first=Detector.detect(pixels,calibration:c)
            }
            guard first.tracked, let markerY=first.markerY else { continue }
            let markerCenter=top+Int(markerY*Double(bottom-top+1))
            let sampleOffset=max(1,Int((first.markerHeight ?? 0.04)*Double(bottom-top+1)/3))
            let samples=[markerCenter-sampleOffset,markerCenter,markerCenter+sampleOffset]
                .map { pixels.color(x:cx,y:$0) }.filter(neutralDark)
            c.marker=samples.min(by:{$0.r+$0.g+$0.b < $1.r+$1.g+$1.b}) ?? RGB(25,25,25)
            var gauges:[Region]=[]
            for g in green {
                guard g.centerX>Double(b.x1+b.width),g.centerX<Double(b.x1)+Double(bottom-top)*0.4,
                    g.y0>top,Double(g.y1)<Double(bottom)+Double(bottom-top)*0.25,
                    g.width>=4,Double(g.width)<Double(bottom-top)*0.12 else { continue }
                let gx=Int(g.centerX), gh=max(2,g.width/6)
                var gt=g.y0
                let gb=g.y1 // Green fill ends at the gauge's fixed interior bottom.
                func gaugePixel(_ y:Int)->Bool { let p=pixels.color(x:gx,y:y); return neutralDark(p) || p.isGreen }
                while gt>minY && gaugePixel(gt-1) { gt -= 1 }
                let length=gb-gt+1
                guard Double(length)>Double(bottom-top)*0.55,Double(length)<Double(bottom-top)*1.3,
                    length>g.width*5 else { continue }
                let padding=max(2,g.width/5)
                let gauge=Region(x:Double(gx-gh)/pw,y:Double(gt+padding)/ph,
                                 w:Double(gh*2+1)/pw,h:Double(length-padding)/ph)
                if gauge.valid { gauges.append(gauge) }
            }
            guard gauges.count==1 else { continue }
            c.progress=gauges[0]
            // Deduplicate upper/lower blue segments of the same lane.
            if !accepted.contains(where:{ abs(($0.lane?.x ?? 0)-lane.x)<lane.w*2 }) { accepted.append(c) }
        }
        return accepted.count==1 ? accepted.first:nil
    }
}
