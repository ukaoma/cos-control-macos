import AppKit
import Foundation
import CryptoKit

/// Real packaged-art checks, in addition to the synthetic shuffle state machine.
@MainActor enum WinduMotionChecks {
 static func run(root: URL) throws {
  // Reproduce the same-pose failed-load latch: fallback loops cast A until the
  // next request is allowed. Healthy/pending decodes must never be restarted.
  precondition(PetRotationLoadPolicy.shouldRequest(wanted:.swarm,requested:nil,hasArt:false,loading:false,retryAfter:0,now:0))
  precondition(!PetRotationLoadPolicy.shouldRequest(wanted:.swarm,requested:.swarm,hasArt:false,loading:true,retryAfter:0,now:10))
  precondition(!PetRotationLoadPolicy.shouldRequest(wanted:.swarm,requested:.swarm,hasArt:false,loading:false,retryAfter:15,now:14))
  precondition(PetRotationLoadPolicy.shouldRequest(wanted:.swarm,requested:.swarm,hasArt:false,loading:false,retryAfter:15,now:15),"failed swarm load must retry rather than latch fallback cast forever")
  precondition(!PetRotationLoadPolicy.shouldRequest(wanted:.swarm,requested:.swarm,hasArt:true,loading:false,retryAfter:15,now:100),"successful art keeps its existing shuffle clock")
  precondition(PetRotationLoadPolicy.shouldRequest(wanted:.duel,requested:.swarm,hasArt:false,loading:true,retryAfter:15,now:10),"pose changes supersede an in-flight decode")
  precondition(!PetRotationLoadPolicy.shouldRequest(wanted:nil,requested:nil,hasArt:false,loading:false,retryAfter:0,now:100))
  let pack=root.appendingPathComponent("Resources/BundledCharacters/jedi-miles-windu")
  let evidence=try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("Tests/windu-motion-retime.json"))) as! [String:Any]
  let remap=evidence["sourceFrames"] as! [Int]
  precondition(remap.count==184 && Array(remap[84...])==Array(84..<184))
  let expected=[(0,28,24),(28,20,20),(48,16,24),(64,12,12),(76,8,4),(84,100,100)].flatMap { start, old, count in (0..<count).map { start + $0*old/count } }
  precondition(remap==expected,"both run bursts must take .48 seconds; impact remains frame85")
  let prior=try JSONSerialization.jsonObject(with:Data(contentsOf:pack.appendingPathComponent("ambient-v2-state-map.json"))) as! [String:Any]
  let priorRow=(prior["poses"] as! [String:[String:Any]])["working"]!
  let variants=(priorRow["rotation"] as! [String:Any])["variants"] as! [[String:String]]
  func digest(_ image:NSImage)->String {
   let cg=PetSpriteStrip.raster(image)!
   let context=CGContext(data:nil,width:cg.width,height:cg.height,bitsPerComponent:8,bytesPerRow:cg.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
   context.draw(cg,in:CGRect(x:0,y:0,width:cg.width,height:cg.height))
   return SHA256.hash(data:Data(bytes:context.data!,count:cg.width*cg.height*4)).map{String(format:"%02x",$0)}.joined()
  }
  autoreleasepool {
   let actual=PetSpriteStore.loadRotations(in:pack,only:[.working])[.working]!
   precondition(actual.variants.count==4 && actual.frames==184 && actual.manifest.handoffFrame==145)
   for (i,variant) in variants.enumerated() { autoreleasepool {
    let source=PetSpriteStrip.slice(NSImage(contentsOf:pack.appendingPathComponent(variant["file"]!))!,frames:184)
    let sourceHashes=source.map(digest)
    for f in 0..<184 {precondition(digest(actual.variants[i].full[f])==sourceHashes[remap[f]],"retime changed pixels or mismatched enemy/contact at \(i)/\(f)")}
   }}
  }
  autoreleasepool {
   let actual=PetSpriteStore.loadRotations(in:pack,only:[.swarm])[.swarm]!
   precondition(actual.variants.count==3 && actual.frames==256 && actual.manifest.handoffFrame==217)
   let identities=actual.variants.map { digest($0.full[128]) }
   precondition(Set(identities).count==3,"three files must produce visually distinct native casts")
   for seed in UInt64(0)..<4 {
    let bank=PetEncounterPlayback(seed:seed);var starts:[Int]=[];var incoming:Int?;var entryDigest:String?
    for tick in 0..<(256*12) {
     let s=bank.sample(pose:.swarm,rotation:actual,now:Double(tick)*0.02,speed:1,interval:0.02,paused:false)!
     precondition(s.frame==tick%256)
     if s.frame==0 {
      if let incoming {precondition(s.current==incoming,"next loop must use reserved incoming cast")}
      if let previous=starts.last {precondition(previous != s.current,"same cast repeated")}
      starts.append(s.current);incoming=s.incoming;entryDigest=nil
     }
     let layers=actual.layers(for:s)
     if s.inTail {
      precondition(layers.count==2 && layers[0]===actual.variants[s.incoming].entry[s.frame] && layers[1]===actual.variants[s.current].body[s.frame],"tail must compose incoming enemies with outgoing hero")
      entryDigest=digest(layers[0])
     } else {precondition(layers.count==1 && layers[0]===actual.variants[s.current].full[s.frame])}
     if s.frame==255 {precondition(entryDigest != nil)}
     // A SwiftUI re-evaluation at the same timestamp cannot consume a reservation.
     precondition(bank.sample(pose:.swarm,rotation:actual,now:Double(tick)*0.02,speed:1,interval:0.02,paused:false)==s)
    }
    for i in stride(from:0,to:starts.count,by:3){precondition(Set(starts[i..<i+3]).count==3)}
   }
  }
  print("PASS: actual Windu 4-cast retime pixels, original impact/tail, 3 distinct swarm casts, 48 loop handoffs and no immediate repeats")
 }
}
