import Foundation
import SwiftUI

@MainActor func runControl2ActivityIntegrationChecks() {
    let normal = ActivitySection.visibleSections(environment: [:])
    precondition(normal.count == 7 && !normal.contains(.work))
    precondition(ActivitySection.visibleSections(environment: ["COS_CONTROL2_FOUNDATION": "0"]) == normal)
    let optedIn = ActivitySection.visibleSections(environment: ["COS_CONTROL2_FOUNDATION": "1"])
    precondition(optedIn == normal + [.work])
    precondition(ActivitySection.work.title == "Work" && ActivitySection.work.icon == "tray.full")
    precondition(!ActivityWindow.allowsLiveSectionLoads(isolatedWorkPreview: true, backgroundWorkEnabled: true))
    precondition(!ActivityWindow.allowsLiveSectionLoads(isolatedWorkPreview: true, backgroundWorkEnabled: false))
    precondition(!ActivityWindow.allowsLiveSectionLoads(isolatedWorkPreview: false, backgroundWorkEnabled: false))
    precondition(ActivityWindow.allowsLiveSectionLoads(isolatedWorkPreview: false, backgroundWorkEnabled: true))
    let model = ControllerModel(startBackgroundWork: false)
    let preview = ActivityWindow.workPreview(model: model)
    precondition(!model.backgroundWorkEnabled && preview.isolatedWorkPreview)
    precondition(!ActivityWindow(model: model).isolatedWorkPreview)
    print("PASS: shared Activity Work navigation, opt-in visibility, isolated preview/live-load policy")
}
