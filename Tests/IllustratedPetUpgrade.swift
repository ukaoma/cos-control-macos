import Foundation
import AppKit
import CryptoKit
@main struct IllustratedPetUpgrade {
 static func main() throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1]), fm=FileManager.default
  let old=root.appendingPathComponent("Resources/DefaultPet"), sources=root.appendingPathComponent("Resources/BundledCharacters"), candidate=sources.appendingPathComponent("jedi-miles-windu")
  let temp=fm.temporaryDirectory.appendingPathComponent("illustrated-upgrade-\(UUID())")
  try fm.createDirectory(at:temp,withIntermediateDirectories:true);defer{try? fm.removeItem(at:temp)}
  func refs(_ value:Any)->Set<String>{if let d=value as? [String:Any]{return d.values.reduce(into:[]){$0.formUnion(refs($1))}};if let a=value as? [Any]{return a.reduce(into:[]){$0.formUnion(refs($1))}};if let s=value as? String,s.hasSuffix(".png"){return [s]};return []}
  let oldData=try Data(contentsOf:old.appendingPathComponent(PetSpriteStore.stateFileName)), oldJSON=try JSONSerialization.jsonObject(with:oldData), oldFiles=refs(oldJSON)
  for f in oldFiles {try fm.copyItem(at:old.appendingPathComponent(f),to:temp.appendingPathComponent(f))}
  let state=temp.appendingPathComponent(PetSpriteStore.stateFileName);try oldData.write(to:state)
  func refresh()->PetSpriteStore.BundledCharacterRefreshResult {autoreleasepool {PetSpriteStore.refreshRecognizedBundledCharacter(into:temp,sourceRootOverride:sources,retainedMilesOverride:old)}}
  var tuned=oldJSON as! [String:Any];var poses=tuned["poses"] as! [String:[String:Any]];poses["trio"]!["interval"]=0.081;tuned["poses"]=poses
  let tunedData=try JSONSerialization.data(withJSONObject:tuned);try tunedData.write(to:state)
  precondition(refresh() == .notApplicable && (try! Data(contentsOf:state)) == tunedData,"custom timing must survive")
  try oldData.write(to:state)
  let custom=temp.appendingPathComponent("windu-pack15-trio-b-body-1x.png"),original=try Data(contentsOf:custom)
  try (original+Data([1])).write(to:custom)
  precondition(refresh() == .notApplicable && (try! Data(contentsOf:state)) == oldData,"custom body layer must survive")
  try original.write(to:custom)
  let partialRoot=temp.appendingPathComponent("partial"),partial=partialRoot.appendingPathComponent("jedi-miles-windu")
  try fm.createDirectory(at:partial,withIntermediateDirectories:true)
  let missing="windu-illustrated-v1-1-swarm-c-entry-1x.png"
  for file in try fm.contentsOfDirectory(at:candidate,includingPropertiesForKeys:nil) where file.lastPathComponent != missing {
   try fm.linkItem(at:file,to:partial.appendingPathComponent(file.lastPathComponent))
  }
  precondition(PetSpriteStore.refreshRecognizedBundledCharacter(into:temp,sourceRootOverride:partialRoot,retainedMilesOverride:old) == .failed,
    "missing incoming cast must reject entire upgrade")
  precondition((try! Data(contentsOf:state))==oldData,"failed upgrade must retain old map")
  precondition(!fm.fileExists(atPath:temp.appendingPathComponent("windu-illustrated-v1-working-a-full-1x.png").path),"validation must complete before first write")
  try fm.removeItem(at:partialRoot)
  precondition(refresh() == .refreshed("jedi-miles-windu"),"exact stock V15 must upgrade")
  let next=try Data(contentsOf:candidate.appendingPathComponent(PetSpriteStore.stateFileName));precondition((try! Data(contentsOf:state))==next)
  for f in refs(try JSONSerialization.jsonObject(with:next)){precondition((try! Data(contentsOf:temp.appendingPathComponent(f))) == (try! Data(contentsOf:candidate.appendingPathComponent(f))),"new asset mismatch \(f)")}
  for f in oldFiles{precondition((try! Data(contentsOf:temp.appendingPathComponent(f))) == (try! Data(contentsOf:old.appendingPathComponent(f))),"rollback asset changed \(f)")}
  let stamp=try fm.attributesOfItem(atPath:state.path)[.modificationDate] as! Date
  precondition(refresh() == .notApplicable && (try! fm.attributesOfItem(atPath:state.path)[.modificationDate] as! Date)==stamp,"repeat launch must not rewrite")
  for pose in [PetSpritePose.working,.duel,.trio,.swarm]{autoreleasepool{
   let r=PetSpriteStore.loadRotations(in:temp,only:[pose])[pose]!
   precondition(r.variants.count == (pose == .working ? 4 : 3))
   precondition(r.frames == (pose == .working ? 184 : pose == .duel ? 148 : pose == .trio ? 172 : 256))
  }}
  // Existing 0.5.348 users must receive the ambient pass, while a custom
  // interval, render scale, image, or missing incoming row refuses mutation.
  let previousData=try Data(contentsOf:candidate.appendingPathComponent("illustrated-v1-1-state-map.json"))
  let previousJSON=try JSONSerialization.jsonObject(with:previousData)
  let previousFiles=refs(previousJSON)
  let installed348=temp.appendingPathComponent("stock348")
  try fm.createDirectory(at:installed348,withIntermediateDirectories:true)
  for f in previousFiles {try fm.copyItem(at:candidate.appendingPathComponent(f),to:installed348.appendingPathComponent(f))}
  let state348=installed348.appendingPathComponent(PetSpriteStore.stateFileName)
  try previousData.write(to:state348)
  func refresh348(_ from:URL?=nil)->PetSpriteStore.BundledCharacterRefreshResult {autoreleasepool {PetSpriteStore.refreshRecognizedBundledCharacter(into:installed348,sourceRootOverride:from ?? sources,retainedMilesOverride:old)}}
  for (key,value) in [("interval",0.21),("renderScale",1.1)] {
   var customState=previousJSON as! [String:Any];var customRows=customState["poses"] as! [String:[String:Any]]
   customRows["idle"]![key]=value;customState["poses"]=customRows
   let bytes=try JSONSerialization.data(withJSONObject:customState);try bytes.write(to:state348)
   precondition(refresh348() == .notApplicable && (try! Data(contentsOf:state348))==bytes,"custom 348 idle setting must survive")
  }
  try previousData.write(to:state348)
  let oldIdle=installed348.appendingPathComponent("session-pet-idle-cutouts-v2.png"),oldIdleData=try Data(contentsOf:oldIdle)
  try (oldIdleData+Data([1])).write(to:oldIdle)
  precondition(refresh348() == .notApplicable,"custom 348 idle art must survive")
  try oldIdleData.write(to:oldIdle)
  try fm.createDirectory(at:partial,withIntermediateDirectories:true)
  let missingIdle="windu-ambient-illustrated-v2-idle-1x.png"
  for file in try fm.contentsOfDirectory(at:candidate,includingPropertiesForKeys:nil) where file.lastPathComponent != missingIdle {
   try fm.linkItem(at:file,to:partial.appendingPathComponent(file.lastPathComponent))
  }
  precondition(refresh348(partialRoot) == .failed && (try! Data(contentsOf:state348))==previousData,"incomplete ambient pack must refuse whole upgrade")
  precondition(!fm.fileExists(atPath:installed348.appendingPathComponent("windu-ambient-illustrated-v2-waiting-1x.png").path),"no partial ambient files before validation")
  try fm.removeItem(at:partialRoot)
  precondition(refresh348() == .refreshed("jedi-miles-windu"),"exact stock 348 must upgrade to ambient generation")
  precondition((try! Data(contentsOf:state348))==next)
  for f in previousFiles {precondition((try! Data(contentsOf:installed348.appendingPathComponent(f))) == (try! Data(contentsOf:candidate.appendingPathComponent(f))),"348 rollback changed")}
  let currentMap=PetSpriteStore.loadStateMap(in:installed348),cadence=PetSpriteStore.loadFrameIntervals(in:installed348)
  for (pose,frames,interval) in [(PetSpritePose.idle,82,0.04),(.waiting,76,0.04),(.patrol,8,0.14)] {
   precondition(currentMap[pose]?.frames==frames && cadence[pose]==interval)
   let image=NSImage(contentsOf:installed348.appendingPathComponent(currentMap[pose]!.file))!
   precondition(PetSpriteStrip.slice(image,frames:frames).count==frames,"native ambient cells must all decode")
  }
  let stamp348=try fm.attributesOfItem(atPath:state348.path)[.modificationDate] as! Date
  precondition(refresh348() == .notApplicable && (try! fm.attributesOfItem(atPath:state348.path)[.modificationDate] as! Date)==stamp348)
  // A 349 installation receives only the new full-strip timing; custom casts or intervals remain untouched.
  let data349=try Data(contentsOf:candidate.appendingPathComponent("ambient-v2-state-map.json"))
  let json349=try JSONSerialization.jsonObject(with:data349)
  let stock349=temp.appendingPathComponent("stock349")
  try fm.createDirectory(at:stock349,withIntermediateDirectories:true)
  let files349=refs(json349)
  for f in files349 {try fm.copyItem(at:candidate.appendingPathComponent(f),to:stock349.appendingPathComponent(f))}
  let map349=stock349.appendingPathComponent(PetSpriteStore.stateFileName)
  try data349.write(to:map349)
  func refresh349()->PetSpriteStore.BundledCharacterRefreshResult {autoreleasepool{PetSpriteStore.refreshRecognizedBundledCharacter(into:stock349,sourceRootOverride:sources,retainedMilesOverride:old)}}
  var custom349=json349 as! [String:Any];var customRows349=custom349["poses"] as! [String:[String:Any]]
  customRows349["working"]!["interval"]=0.021;custom349["poses"]=customRows349
  let customBytes349=try JSONSerialization.data(withJSONObject:custom349);try customBytes349.write(to:map349)
  precondition(refresh349() == .notApplicable && (try! Data(contentsOf:map349))==customBytes349,"custom 349 cadence must survive")
  try data349.write(to:map349)
  let customized349=stock349.appendingPathComponent("windu-illustrated-v1-working-b-full-1x.png"),original349=try Data(contentsOf:customized349)
  try (original349+Data([1])).write(to:customized349)
  precondition(refresh349() == .notApplicable,"custom second cast must survive")
  try original349.write(to:customized349)
  precondition(refresh349() == .refreshed("jedi-miles-windu"),"349 stock must receive timing polish")
  precondition((try! Data(contentsOf:map349))==next)
  for f in files349 {precondition((try! Data(contentsOf:stock349.appendingPathComponent(f))) == (try! Data(contentsOf:candidate.appendingPathComponent(f))),"349 rollback asset changed")}
  let stamp349=try fm.attributesOfItem(atPath:map349.path)[.modificationDate] as! Date
  precondition(refresh349() == .notApplicable && (try! fm.attributesOfItem(atPath:map349.path)[.modificationDate] as! Date)==stamp349,"349 upgrade must be idempotent")
  // Motion V2 (Miles 2026-10-31): a Windu Motion V1 installation (0.5.350 to 0.5.359) receives the fragment-free working
  // strips under new names; its motion-v1 files stay as they were for rollback, and a customized cast is left alone.
  let historyV1=try JSONSerialization.jsonObject(with:Data(contentsOf:candidate.appendingPathComponent("stock-state-history.json"))) as! [String:Any]
  let motionV1=(historyV1["maps"] as! [[String:Any]]).first{($0["name"] as? String)?.hasPrefix("Windu Motion V1") == true}!["state"]!
  let stockV1=temp.appendingPathComponent("stockMotionV1")
  try fm.createDirectory(at:stockV1,withIntermediateDirectories:true)
  let filesV1=refs(motionV1)
  for f in filesV1 {try fm.copyItem(at:candidate.appendingPathComponent(f),to:stockV1.appendingPathComponent(f))}
  let mapV1=stockV1.appendingPathComponent(PetSpriteStore.stateFileName)
  try JSONSerialization.data(withJSONObject:motionV1).write(to:mapV1)
  func refreshV1()->PetSpriteStore.BundledCharacterRefreshResult {autoreleasepool{PetSpriteStore.refreshRecognizedBundledCharacter(into:stockV1,sourceRootOverride:sources,retainedMilesOverride:old)}}
  let customizedV1=stockV1.appendingPathComponent("windu-motion-v1-working-c-full-1x.png"),originalV1=try Data(contentsOf:customizedV1)
  try (originalV1+Data([1])).write(to:customizedV1)
  precondition(refreshV1() == .notApplicable,"custom motion-v1 cast must survive")
  try originalV1.write(to:customizedV1)
  precondition(refreshV1() == .refreshed("jedi-miles-windu"),"motion-v1 stock must receive the fragment fix")
  precondition((try! Data(contentsOf:mapV1))==next)
  for f in refs(try JSONSerialization.jsonObject(with:next)){precondition((try! Data(contentsOf:stockV1.appendingPathComponent(f))) == (try! Data(contentsOf:candidate.appendingPathComponent(f))),"motion-v2 asset mismatch \(f)")}
  for f in filesV1 {precondition((try! Data(contentsOf:stockV1.appendingPathComponent(f))) == (try! Data(contentsOf:candidate.appendingPathComponent(f))),"motion-v1 rollback asset changed")}
  let stampV1=try fm.attributesOfItem(atPath:mapV1.path)[.modificationDate] as! Date
  precondition(refreshV1() == .notApplicable && (try! fm.attributesOfItem(atPath:mapV1.path)[.modificationDate] as! Date)==stampV1,"motion-v1 upgrade must be idempotent")
  // Generation 28 re-runs this refresh for everyone already at 27. What it must leave alone: a Motion V1 install with
  // its own timing, every bundled character whose pack is already current, and a chosen still image.
  let customV1=stockV1.appendingPathComponent("customMotionV1")
  try fm.createDirectory(at:customV1,withIntermediateDirectories:true)
  for f in filesV1 {try fm.copyItem(at:candidate.appendingPathComponent(f),to:customV1.appendingPathComponent(f))}
  var tunedV1=motionV1 as! [String:Any];var tunedRowsV1=tunedV1["poses"] as! [String:[String:Any]]
  tunedRowsV1["working"]!["interval"]=0.0215;tunedV1["poses"]=tunedRowsV1
  let tunedBytesV1=try JSONSerialization.data(withJSONObject:tunedV1);let customMapV1=customV1.appendingPathComponent(PetSpriteStore.stateFileName)
  try tunedBytesV1.write(to:customMapV1)
  precondition(autoreleasepool{PetSpriteStore.refreshRecognizedBundledCharacter(into:customV1,sourceRootOverride:sources,retainedMilesOverride:old)} == .notApplicable
    && (try! Data(contentsOf:customMapV1))==tunedBytesV1,"a motion-v1 install with its own cadence must survive")
  for id in ["jedi-nia-solari","jedi-elara-vale","jedi-rowan-vale"] {
   let pack=sources.appendingPathComponent(id),installed=temp.appendingPathComponent("current-\(id)")
   try fm.createDirectory(at:installed,withIntermediateDirectories:true)
   let packMap=try Data(contentsOf:pack.appendingPathComponent(PetSpriteStore.stateFileName))
   for f in refs(try JSONSerialization.jsonObject(with:packMap)) {try fm.copyItem(at:pack.appendingPathComponent(f),to:installed.appendingPathComponent(f))}
   try packMap.write(to:installed.appendingPathComponent(PetSpriteStore.stateFileName))
   precondition(autoreleasepool{PetSpriteStore.refreshRecognizedBundledCharacter(into:installed,sourceRootOverride:sources,retainedMilesOverride:old)} == .notApplicable
     && (try! Data(contentsOf:installed.appendingPathComponent(PetSpriteStore.stateFileName)))==packMap,"\(id) already current must not be rewritten")
  }
  // A complete stock V15 install with a still image beside it: without the still-image rule this directory would upgrade.
  let chosenStill=temp.appendingPathComponent("chosenStill")
  try fm.createDirectory(at:chosenStill,withIntermediateDirectories:true)
  for f in oldFiles {try fm.copyItem(at:old.appendingPathComponent(f),to:chosenStill.appendingPathComponent(f))}
  try oldData.write(to:chosenStill.appendingPathComponent(PetSpriteStore.stateFileName))
  func refreshStill()->PetSpriteStore.BundledCharacterRefreshResult {autoreleasepool{PetSpriteStore.refreshRecognizedBundledCharacter(into:chosenStill,sourceRootOverride:sources,retainedMilesOverride:old)}}
  try Data(contentsOf:candidate.appendingPathComponent("session-pet-idle-cutouts-v2.png")).write(to:chosenStill.appendingPathComponent("\(PetSpriteStore.fileStem).png"))
  precondition(refreshStill() == .notApplicable && (try! Data(contentsOf:chosenStill.appendingPathComponent(PetSpriteStore.stateFileName)))==oldData,
    "a chosen still image must survive even beside a complete stock map")
  try fm.removeItem(at:chosenStill.appendingPathComponent("\(PetSpriteStore.fileStem).png"))
  precondition(refreshStill() == .refreshed("jedi-miles-windu"),"the same install with no still image does upgrade, so the check above is about the still")
  print("PASS: V15, 348, 349 and motion-v1 upgrades, custom timing/scale/art protection, a rerun on current packs and a chosen still, missing-asset atomic failure, ambient native slicing/cadence, 13 unchanged casts and both rollback generations")
 }
}
