import Foundation
import SwiftUI

@MainActor func runControl2ActivityIntegrationChecks() {
    let normal = ActivitySection.visibleSections(environment: [:])
    precondition(normal.count == 7 && !normal.contains(.work))
    precondition(ActivitySection.visibleSections(environment: ["COS_CONTROL2_FOUNDATION": "0"]) == normal)
    let optedIn = ActivitySection.visibleSections(environment: ["COS_CONTROL2_FOUNDATION": "1"])
    precondition(optedIn.count == 7 && optedIn == normal.map { $0 == .tasks ? .work : $0 })
    precondition(!optedIn.contains(.tasks) && optedIn.contains(.work))
    precondition(ActivitySection.resolvedLaunch(.tasks, environment: ["COS_CONTROL2_FOUNDATION": "1"]) == .work)
    precondition(ActivitySection.resolvedLaunch(.tasks, environment: [:]) == .tasks)
    precondition(ActivitySection.resolvedLaunch(.sessions, environment: ["COS_CONTROL2_FOUNDATION": "1"]) == .sessions)
    precondition(ActivityWindow.workSubviewForLaunch(.tasks, current: .meetingFollowUp) == .tasks)
    precondition(ActivityWindow.workSubviewForLaunch(.work, current: .meetingFollowUp) == .meetingFollowUp)
    precondition(ActivityWindow.usesExistingTaskList(isolatedWorkPreview: false, subview: .tasks))
    precondition(!ActivityWindow.usesExistingTaskList(isolatedWorkPreview: false, subview: .meetingFollowUp))
    precondition(!ActivityWindow.usesExistingTaskList(isolatedWorkPreview: true, subview: .tasks))
    precondition(!ActivityWindow.usesExistingTaskList(isolatedWorkPreview: true, subview: .meetingFollowUp))
    precondition(ActivitySection.work.title == "Work" && ActivitySection.work.icon == "tray.full")
    precondition(!ActivityWindow.allowsLiveSectionLoads(isolatedWorkPreview: true, backgroundWorkEnabled: true))
    precondition(!ActivityWindow.allowsLiveSectionLoads(isolatedWorkPreview: true, backgroundWorkEnabled: false))
    precondition(!ActivityWindow.allowsLiveSectionLoads(isolatedWorkPreview: false, backgroundWorkEnabled: false))
    precondition(ActivityWindow.allowsLiveSectionLoads(isolatedWorkPreview: false, backgroundWorkEnabled: true))
    let model = ControllerModel(startBackgroundWork: false)
    model.activitySignals = ActivitySignals([
        "tasks": .object(["needsYou": .number(7), "newest": .string("2099-01-01T00:00:00Z"),
                          "inboxIDs": .array([.string("preview-test-" + UUID().uuidString)]), "source": .string("tasks")])
    ])
    precondition(model.activityNumber(.tasks) == 8)
    precondition(model.activityNumber(.work) == 8, "Work must retain Tasks needs-you/inbox badge")
    precondition(model.activityDot(.tasks) && model.activityDot(.work), "Work must retain Tasks unread dot")
    precondition(model.activityCursor(.work) == model.activityCursor(.tasks), "Work reads the same existing Tasks cursor")
    precondition(model.activityNumber(.meetings) == nil && !model.activityDot(.meetings))
    let preview = ActivityWindow.workPreview(model: model)
    precondition(!model.backgroundWorkEnabled && preview.isolatedWorkPreview)
    precondition(!ActivityWindow(model: model).isolatedWorkPreview)
    print("PASS: seven shared Activity peers, legacy Tasks maps to Work/Tasks, existing Tasks reuse and notification marks, isolated preview/live-load policy")
}
