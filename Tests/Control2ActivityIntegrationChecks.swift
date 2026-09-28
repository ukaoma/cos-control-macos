import Foundation
import SwiftUI

@MainActor func runControl2ActivityIntegrationChecks() {
    let normal = ActivitySection.visibleSections(environment: [:])
    precondition(normal.count == 7 && normal.contains(.work) && !normal.contains(.tasks))
    precondition(ActivitySection.visibleSections(environment: ["COS_CONTROL2_FOUNDATION": "0"]) == normal)
    precondition(ActivitySection.visibleSections(environment: ["COS_CONTROL2_FOUNDATION": "1"]) == normal)
    let rollback = ActivitySection.visibleSections(environment: ["COS_CONTROL_WORK_DISABLED": "1"])
    precondition(rollback == normal.map { $0 == .work ? .tasks : $0 })
    precondition(ActivitySection.resolvedLaunch(.tasks, environment: [:]) == .work)
    precondition(ActivitySection.resolvedLaunch(.tasks, environment: ["COS_CONTROL_WORK_DISABLED": "1"]) == .tasks)
    precondition(ActivitySection.resolvedLaunch(.sessions, environment: [:]) == .sessions)
    precondition(ActivityWindow.workSubviewForLaunch(.tasks, current: .meetingFollowUp) == .tasks)
    precondition(ActivityWindow.workSubviewForLaunch(.work, current: .meetingFollowUp) == .meetingFollowUp)
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
    let connectedModel = ControllerModel(startBackgroundWork: false, allowActivityLoads: true)
    precondition(!connectedModel.backgroundWorkEnabled && connectedModel.activityLoadsEnabled)
    precondition(!ActivityWindow.workConnectedTest(model: connectedModel).isolatedWorkPreview)
    precondition(!model.activityLoadsEnabled, "The isolated preview cannot load foreground production sections")
    let sampleRows = WorkWorkspaceProjection.previewRows(Control2PreviewTask.samples)
    precondition(sampleRows.count == 6 && sampleRows.filter(\.checked).count == 1)
    let sampleReviews = WorkWorkspaceProjection.previewReviewStore()
    precondition(sampleReviews.reviews.count == 1 && sampleReviews.reviews[0].canPrepare)
    precondition(!sampleReviews.available, "Sample review transport cannot admit a live review")
    // Handoffs must carry the full task and finish line, not the lens's capped title.
    let task = TaskRow(.object([
        "id": .string("legacy-row"), "domain": .string("demo"), "title": .string("Short lens title"),
        "text": .string("The complete task description for the chosen destination"),
        "doneWhen": .string("Check desktop and phone widths"), "source": .string("Meeting evidence")
    ]))!
    let source = WorkSource.taskSnapshot(task)
    precondition(source.id == "task:demo:legacy-row" && source.project == "demo")
    precondition(source.context.contains(task.text) && source.context.contains(task.doneWhen) && source.context.contains(task.source))
    precondition(source.suggestedPrompt.contains("Ask before publishing or sending externally."))
    let otherDomain = TaskRow(.object([
        "id": .string("legacy-row"), "domain": .string("another-domain"), "title": .string(task.title),
        "text": .string(task.text), "doneWhen": .string(task.doneWhen), "source": .string(task.source)
    ]))!
    precondition(WorkSource.taskSnapshot(otherDomain).id != source.id, "Matching row IDs across domains must never share a handoff history or backlink")
    let changed = TaskRow(.object([
        "id": .string("legacy-row"), "domain": .string("demo"), "title": .string("Short lens title"),
        "text": .string(task.text), "doneWhen": .string("A revised finish line"), "source": .string(task.source)
    ]))!
    precondition(WorkSource.taskSnapshot(changed).revision != source.revision, "A changed goal must not reuse the previewed context revision")
    print("PASS: seven shared Activity peers, legacy Tasks maps to Work/Tasks, shared workspace routing and notification marks, isolated preview/live-load policy")
    print("PASS: handoff context retains the full task/finish line/source and changes snapshot revision with the goal")
}
