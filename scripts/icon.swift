import AppKit
let output=CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath:output,withIntermediateDirectories:true)
for size in [16,32,128,256,512] {
    for scale in [1,2] {
        let n=size*scale
        let image=NSImage(size:NSSize(width:n,height:n))
        image.lockFocus()
        let rect=NSRect(x:0,y:0,width:n,height:n)
        NSColor(calibratedRed:0.03,green:0.25,blue:0.29,alpha:1).setFill()
        NSBezierPath(roundedRect:rect.insetBy(dx:Double(n)*0.04,dy:Double(n)*0.04),xRadius:Double(n)*0.23,yRadius:Double(n)*0.23).fill()
        NSColor(calibratedRed:0.18,green:0.75,blue:0.65,alpha:1).setFill()
        NSBezierPath(ovalIn:NSRect(x:Double(n)*0.15,y:Double(n)*0.15,width:Double(n)*0.7,height:Double(n)*0.7)).fill()
        if let fish=NSImage(systemSymbolName:"fish.fill",accessibilityDescription:nil) {
            let tinted=NSImage(size:fish.size)
            tinted.lockFocus(); fish.draw(at:.zero,from:.zero,operation:.sourceOver,fraction:1)
            NSColor.white.setFill(); NSRect(origin:.zero,size:fish.size).fill(using:.sourceAtop); tinted.unlockFocus()
            tinted.draw(in:NSRect(x:Double(n)*0.23,y:Double(n)*0.31,width:Double(n)*0.54,height:Double(n)*0.38))
        }
        image.unlockFocus()
        let bitmap=NSBitmapImageRep(data:image.tiffRepresentation!)!
        let suffix=scale==2 ? "@2x":""
        try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:output+"/icon_\(size)x\(size)\(suffix).png"))
    }
}
