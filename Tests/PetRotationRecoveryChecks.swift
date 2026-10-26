import AppKit
import Foundation
@MainActor enum PetRotationRecoveryChecks {
 static func run(root:URL) async throws {
  let fm=FileManager.default,dir=fm.temporaryDirectory.appendingPathComponent("pet-retry-\(UUID())")
  try fm.createDirectory(at:dir,withIntermediateDirectories:true);defer{try? fm.removeItem(at:dir)}
  let model=PetRotationControllerHarness(dir)
  // Real detached decode fails because the pack has not finished arriving.
  model.ensurePetRotation(for:.swarm)
  for _ in 0..<200 {if !model.pending {break};try await Task.sleep(for:.milliseconds(20))}
  precondition(!model.pending && model.petRotationPose == .swarm && model.petSpriteKit.rotations.isEmpty,"failed decode must finish and remain eligible for retry")
  // The source becomes complete without changing pose or restarting the app.
  let pack=root.appendingPathComponent("Resources/BundledCharacters/jedi-miles-windu")
  let data=try Data(contentsOf:pack.appendingPathComponent(PetSpriteStore.stateFileName))
  let json=try JSONSerialization.jsonObject(with:data) as! [String:Any]
  let row=(json["poses"] as! [String:[String:Any]])["swarm"]!
  let rotation=row["rotation"] as! [String:Any],variants=rotation["variants"] as! [[String:String]]
  for name in Set(variants.flatMap{[$0["file"]!,$0["bodyFile"]!,$0["entryFile"]!]}) {try fm.linkItem(at:pack.appendingPathComponent(name),to:dir.appendingPathComponent(name))}
  try JSONSerialization.data(withJSONObject:["poses":["swarm":row]]).write(to:dir.appendingPathComponent(PetSpriteStore.stateFileName))
  model.ensurePetRotation(for:.swarm)
  precondition(!model.pending && model.petSpriteKit.rotations.isEmpty,"repeated polls must respect retry backoff")
  try await Task.sleep(for:.milliseconds(5100))
  model.ensurePetRotation(for:.swarm)
  precondition(model.pending,"same-pose retry must start after recovery delay")
  for _ in 0..<1000 {if !model.pending {break};try await Task.sleep(for:.milliseconds(20))}
  let art=model.petSpriteKit.rotations[.swarm]!
  precondition(art.variants.count==3 && art.frames==256)
  let image=art.variants[1].full[128]
  model.ensurePetRotation(for:.swarm)
  precondition(!model.pending && model.petSpriteKit.rotations[.swarm]!.variants[1].full[128] === image,"healthy art must not redecode or restart shuffle")
  print("PASS: actual ControllerModel cast-load methods recover a failed asynchronous swarm decode, preserve backoff, load all3 casts, and retain healthy art")
 }
}
