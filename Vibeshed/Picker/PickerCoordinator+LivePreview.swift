import Foundation

/// A live preview in progress: the parameter being browsed.
struct LivePreviewSession {
    let actionID: ActionID
    let parameterID: String
}

/// Live parameter preview: while the picker collects a parameter declared with
/// `livePreview: true`, the highlighted option is reported to the owning module once
/// the highlight and the typing settle (`LivePreviewScheduler`), and the module applies
/// it for real. Return commits it; Escape, backing out of the parameter, or dismissing
/// the picker ends the preview uncommitted so the module can revert.
extension PickerCoordinator {
    /// Re-evaluates the preview after a mode, selection, or visibility change.
    func syncLivePreview() {
        let target = livePreviewTarget()
        // The picker's overlay would blur the very desktop being previewed.
        panelController.setOverlaySuspended(target != nil)
        if let session = livePreview,
           target?.actionID != session.actionID || target?.parameter.id != session.parameterID
        {
            _ = endLivePreview(committed: false)
        }
        guard let target else { return }

        if livePreview == nil {
            livePreview = LivePreviewSession(actionID: target.actionID, parameterID: target.parameter.id)
        }
        guard let optionID = pickerState.selectedParameterOptionID else { return }
        let module = moduleRegistry.module(id: target.actionID.moduleID)
        let parameterID = target.parameter.id
        let actionID = target.actionID
        livePreviewScheduler.schedule(optionID) {
            await module?.previewParameterOption(optionID, parameterID: parameterID, actionID: actionID)
        }
    }

    /// Ends the current preview, if any. Returns the task delivering the end to the
    /// module so a commit can be ordered before the action runs.
    func endLivePreview(committed: Bool) -> Task<Void, Never>? {
        guard let session = livePreview else { return nil }
        livePreview = nil
        livePreviewScheduler.reset()
        let module = moduleRegistry.module(id: session.actionID.moduleID)
        return Task {
            await module?.endParameterPreview(
                parameterID: session.parameterID,
                actionID: session.actionID,
                committed: committed
            )
        }
    }

    private func livePreviewTarget() -> (actionID: ActionID, parameter: ActionParameter)? {
        guard panelController.isVisible,
              case let .parameterInput(actionID, _) = pickerState.mode,
              let parameter = pickerState.currentParameter,
              parameter.livePreview
        else { return nil }
        return (actionID, parameter)
    }
}
