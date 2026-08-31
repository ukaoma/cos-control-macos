import AppKit
import SwiftUI
import Foundation

struct IdleCanaryCell: Identifiable {
    let id: String
    let name: String
    let scenario: String
    let pose: PetSpritePose
    let frames: [NSImage]
    let interval: Double
    let scale: CGFloat
    let rests: [PetSpriteClip]
}

@main
@MainActor
struct JediIdleContract {
    static func main() throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        var cells: [IdleCanaryCell] = []
        let scenarios: [(String, Int, Int, PetSpritePose)] = [
            ("No sessions", 0, 0, .idle),
            ("Quiet open session", 1, 0, .patrol),
            ("Waiting session", 1, 1, .waiting)
        ]
        for (label, count, waiting, expectedPose) in scenarios {
            for character in PetSpriteStore.bundledCharacters {
                let source = resources.appendingPathComponent(character.folderName)
                let map = PetSpriteStore.loadStateMap(in: source)
                let intervals = PetSpriteStore.loadFrameIntervals(in: source)
                let scales = PetSpriteStore.loadRenderScales(in: source)
                var poses: [PetSpritePose: [NSImage]] = [:]
                for (pose, row) in map {
                    let data = try Data(contentsOf: source.appendingPathComponent(row.file))
                    poses[pose] = PetSpriteStrip.slice(NSImage(data: data)!, frames: row.frames)
                }
                let kit = PetSpriteKit(poses: poses)
                let pose = PetSpritePose.resolve(sessionCount: count, workingCount: 0,
                    waitingCount: waiting, focusState: nil, completing: false)
                precondition(pose == expectedPose)
                let frames = kit.frames(for: pose)
                precondition(frames.count == 8, "\(character.id)/\(label) still resolves to a static pose")
                let interval = intervals[pose] ?? pose.frameInterval(forFrames: frames.count)
                let restPoses = PetSpriteStore.restPoses(for: pose, stateMap: map)
                if character.id != PetSpriteStore.defaultCharacterID {
                    precondition(interval == 0.24 && scales[pose] == 1)
                    precondition(restPoses.isEmpty, "shared calm strip must not restart as a playlist rest")
                } else if pose == .patrol {
                    precondition(restPoses == [.idle, .waiting], "Miles retains distinct ambient clips")
                }
                var sprite = SessionPetSprite(working: pose.animates, reduceMotion: false,
                    frames: frames, pose: pose, frameInterval: interval)
                var pixels: Set<Data> = []
                for speed in [0.25, 0.8, 1.0, 2.0] {
                    for i in 0..<frames.count {
                        let wallTime = (Double(i) + 0.25) * interval / speed
                        let sampled = sprite.playbackFrame(elapsed: wallTime * speed)!
                        precondition(sampled === frames[i], "playback selector skipped an authored frame")
                        pixels.insert(NSBitmapImageRep(cgImage: PetSpriteStrip.raster(sampled)!)
                            .representation(using: .png, properties: [:])!)
                    }
                }
                precondition(pixels.count >= 4, "\(character.id) has no visible idle motion")
                precondition(sprite.playbackFrame(elapsed: 8.25 * interval) === frames[0])
                sprite.reduceMotion = true
                let held = sprite.playbackFrame(elapsed: 0)
                precondition(held != nil && sprite.playbackFrame(elapsed: 3.25 * interval) === held)
                precondition(sprite.playbackFrame(elapsed: 9.25 * interval) === held)
                let rests = restPoses.map { secondary in
                    PetSpriteClip(frames: kit.exactFrames(for: secondary),
                        frameInterval: intervals[secondary] ?? secondary.frameInterval(forFrames: kit.exactFrames(for: secondary).count))
                }
                cells.append(IdleCanaryCell(id: "\(character.id)-\(pose.rawValue)",
                    name: character.displayName.replacingOccurrences(of: "Jedi ", with: ""),
                    scenario: label, pose: pose, frames: frames, interval: interval,
                    scale: scales[pose] ?? 1, rests: rests))
                print("PASS \(character.id): \(label) = \(pose.rawValue), \(frames.count) frames, \(interval)s, \(pixels.count) distinct frames")
            }
        }
        let shared: [PetSpritePose: (file: String, frames: Int)] = [
            .patrol: ("walk.png", 8), .idle: ("rest.png", 8), .waiting: ("rest.png", 8)]
        precondition(PetSpriteStore.restPoses(for: .patrol, stateMap: shared) == [.idle])
        precondition(PetSpriteStore.restPoses(for: .working, stateMap: shared).isEmpty)
        print("Jedi idle contracts PASS: 12 real resolver paths, all 8 playback frames at four speeds, reduced motion, seams and rest deduplication")

        // Optional on-device canary uses the shipping SwiftUI TimelineView.
        // It never constructs ControllerModel, polls live work or writes preferences.
        if CommandLine.arguments.count > 2 {
            let output = URL(fileURLWithPath: CommandLine.arguments[2])
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let view = IdleCanaryView(cells: cells)
            let hosting = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 950),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Jedi idle runtime canary • source renderer • 80% speed"
            window.contentView = hosting
            window.center()
            window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
            for sample in 0..<32 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1 + Double(sample) * 0.2) {
                    hosting.layoutSubtreeIfNeeded()
                    if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                        try! bitmap.representation(using: .png, properties: [:])!.write(
                            to: output.appendingPathComponent(String(format: "native-%02d.png", sample)))
                    }
                    if sample == 31 { app.terminate(nil) }
                }
            }
            app.run()
        }
    }
}

struct IdleCanaryView: View {
    let cells: [IdleCanaryCell]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Idle in every calm state").font(.system(size: 27, weight: .semibold))
            Text("Native app renderer • 80 pt pet • 250% character • 80% speed • no live settings changed")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(293)), count: 4), spacing: 12) {
                ForEach(cells) { cell in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(cell.name + " · " + cell.scenario).font(.system(size: 12, weight: .medium))
                        SessionPetSprite(working: cell.pose.animates, reduceMotion: false,
                            frames: cell.frames, pose: cell.pose, frameInterval: cell.interval,
                            size: 80, characterScale: 2.5 * cell.scale,
                            animationSpeed: 0.8, restClips: cell.rests)
                            .frame(width: 277, height: 215, alignment: .bottom)
                        Text("\(cell.pose.rawValue) · \(cell.frames.count) frames")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }.padding(8).background(Color.black.opacity(0.035)).cornerRadius(8)
                }
            }
        }.padding(16).frame(width: 1240, height: 950).background(Color.white)
            .environment(\.colorScheme, .light)
    }
}
