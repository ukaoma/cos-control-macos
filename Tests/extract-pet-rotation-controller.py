#!/usr/bin/env python3
"""Compile the production loader lifecycle without starting Control or touching user art."""
import pathlib,sys
root=pathlib.Path(sys.argv[1]);out=pathlib.Path(sys.argv[2]);s=(root/'Sources/ControllerModel.swift').read_text()
a=s.index('    private var petCastPoses:');b=s.index('    let petEncounterPlayback =',a)
body=s[a:b]
assert body.count('let directory = PetSpriteStore.supportDirectory()')==1
body=body.replace('let directory = PetSpriteStore.supportDirectory()','let directory = testDirectory')
out.write_text('''import AppKit
import Combine
import Foundation
@MainActor final class PetRotationControllerHarness {
 let testDirectory: URL
 var petSpriteKit = PetSpriteKit()
 let petArtScale: CGFloat = 1
 let petSpritePose = PetSpritePose.swarm
 init(_ directory:URL) {testDirectory=directory;petCastPoses=[.swarm]}
 var pending:Bool {petRotationLoad != nil}
'''+body+'}\n')
