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
  // 0.5.368: the bundled working row is Motion V13. Motion V2 (0.5.360 to 0.5.367) stays in the pack, for rollback and as the
  // stock map those installs are recognized by, so its retime and fragment rules still run, on the V2 row from the history.
  let fm=FileManager.default
  let motionV2=fm.temporaryDirectory.appendingPathComponent("windu-motion-v2-\(UUID())")
  try fm.createDirectory(at:motionV2,withIntermediateDirectories:true);defer{try? fm.removeItem(at:motionV2)}
  let history=try JSONSerialization.jsonObject(with:Data(contentsOf:pack.appendingPathComponent("stock-state-history.json"))) as! [String:Any]
  let v2Maps=(history["maps"] as! [[String:Any]]).filter{($0["name"] as? String)=="Windu Motion V2 \u{00b7} Control 0.5.360"}
  precondition(v2Maps.count==1,"the Motion V2 map must stay in the stock history")
  let v2Row=((v2Maps[0]["state"] as! [String:Any])["poses"] as! [String:[String:Any]])["working"]!
  func pngs(_ value:Any)->Set<String>{if let d=value as? [String:Any]{return d.values.reduce(into:[]){$0.formUnion(pngs($1))}};if let a=value as? [Any]{return a.reduce(into:[]){$0.formUnion(pngs($1))}};if let s=value as? String,s.hasSuffix(".png"){return [s]};return []}
  for f in pngs(v2Row) {try fm.linkItem(at:pack.appendingPathComponent(f),to:motionV2.appendingPathComponent(f))}
  try JSONSerialization.data(withJSONObject:["poses":["working":v2Row]]).write(to:motionV2.appendingPathComponent(PetSpriteStore.stateFileName))
  let prior=try JSONSerialization.jsonObject(with:Data(contentsOf:pack.appendingPathComponent("ambient-v2-state-map.json"))) as! [String:Any]
  let priorRow=(prior["poses"] as! [String:[String:Any]])["working"]!
  let variants=(priorRow["rotation"] as! [String:Any])["variants"] as! [[String:String]]
  func alphaMax(_ cg:CGImage)->UInt8 {
   let context=CGContext(data:nil,width:cg.width,height:cg.height,bitsPerComponent:8,bytesPerRow:cg.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
   context.draw(cg,in:CGRect(x:0,y:0,width:cg.width,height:cg.height))
   let bytes=UnsafeBufferPointer(start:context.data!.assumingMemoryBound(to:UInt8.self),count:cg.width*cg.height*4)
   return stride(from:3,to:bytes.count,by:4).reduce(UInt8(0)){max($0,bytes[$1])}
  }
  func digest(_ image:NSImage)->String {
   let cg=PetSpriteStrip.raster(image)!
   let context=CGContext(data:nil,width:cg.width,height:cg.height,bitsPerComponent:8,bytesPerRow:cg.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
   context.draw(cg,in:CGRect(x:0,y:0,width:cg.width,height:cg.height))
   return SHA256.hash(data:Data(bytes:context.data!,count:cg.width*cg.height*4)).map{String(format:"%02x",$0)}.joined()
  }
  autoreleasepool {
   let actual=PetSpriteStore.loadRotations(in:motionV2,only:[.working])[.working]!
   precondition(actual.variants.count==4 && actual.frames==184 && actual.manifest.handoffFrame==145)
   for (i,variant) in variants.enumerated() { autoreleasepool {
    let source=PetSpriteStrip.slice(NSImage(contentsOf:pack.appendingPathComponent(variant["file"]!))!,frames:184)
    let sourceHashes=source.map(digest)
    // Motion V2 (Miles 2026-10-31): frames 160-167 drop the stray wreck fragment that crossed the hero's feet after the
    // enemy left; they show the clean run cell of frame 7. Every other frame is still the exact retime of the source.
    for f in 0..<184 {let cell=(160...167).contains(f) ? remap[7] : remap[f];precondition(digest(actual.variants[i].full[f])==sourceHashes[cell],"retime changed pixels or mismatched enemy/contact at \(i)/\(f)")}
    // The tail of a loop draws the body strip, so the same eight cells must be clean there too: the hero standing, as in the
    // last eight frames of the loop (measured on the shipped art: all sixteen cells are one image per cast).
    let cleanBody=digest(actual.variants[i].body[176])
    for f in 160...167 {precondition(digest(actual.variants[i].body[f])==cleanBody,"the body strip still carries the fragment at \(i)/\(f)")}
   }}
  }
  // Motion V13 (Miles 2026-11-04): the strike cuts through the droid and each half flies off its own way. The bundled row, at
  // 1x and through the Retina strips at 2x: four casts sharing the run-in and then distinct, 184 frames, handoff 145.
  // From the handoff on, the body strip the tail draws IS the full frame (nothing of the droid is left to cross the hero),
  // and before it the body strip is empty, so the tail can only ever show the hero who finished the strike.
  for scale in [CGFloat(1),2] { autoreleasepool {
   let actual=PetSpriteStore.loadRotations(in:pack,displayScale:scale,only:[.working])[.working]!
   precondition(actual.variants.count==4 && actual.frames==184 && actual.manifest.handoffFrame==145 && actual.manifest.variants.allSatisfy{$0.file.hasPrefix("windu-motion-v13a-working-")},"the bundled working row is Motion V13")
   let width=PetSpriteStrip.raster(actual.variants[0].full[0])!.width
   precondition(width==Int(scale)*PetSpriteStrip.raster(PetSpriteStore.loadRotations(in:pack,only:[.working])[.working]!.variants[0].full[0])!.width,"\(scale)x must decode the \(scale)x strips")
   let castA=actual.variants[0].full.map(digest)
   for (i,variant) in actual.variants.enumerated() { autoreleasepool {
    let full=variant.full.map(digest)
    precondition(full.count==184 && variant.body.count==184 && variant.entry.count==184)
    if i>0 {precondition(full[0..<56]==castA[0..<56] && (56..<184).allSatisfy{full[$0] != castA[$0]},"cast \(i) shares the run-in and is its own strike after it at \(scale)x")}
    for f in 0..<184 {
     precondition((PetSpriteStrip.raster(variant.full[f]).map(alphaMax) ?? 0)>0,"Motion V13 frame \(i)/\(f) is blank at \(scale)x")
     let body=digest(variant.body[f])
     if f+1>=145 {precondition(body==full[f],"the tail body is not the full frame at \(i)/\(f), \(scale)x")}
     else {precondition(PetSpriteStrip.raster(variant.body[f]).map{alphaMax($0)==0} ?? false,"the body strip draws before the handoff at \(i)/\(f), \(scale)x")}
    }
   }}
  }}
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
  print("PASS: actual Windu Motion V2 rollback retime pixels and fragment-free tail, Motion V13 at 1x and 2x (4 casts, distinct strikes, tail body is the full frame, no body before the handoff), 3 distinct swarm casts, 48 loop handoffs and no immediate repeats")
 }
}
