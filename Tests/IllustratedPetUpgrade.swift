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
  print("PASS: illustrated migration, custom timing/body protection, all 204 assets, 96 retained V15 assets, repeat no-op, 13 native casts")
 }
}
