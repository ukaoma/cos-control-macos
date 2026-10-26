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
  print("PASS: V15 and 348 upgrades, custom timing/scale/art protection, missing-asset atomic failure, ambient native slicing/cadence, 13 unchanged casts and both rollback generations")
 }
}
