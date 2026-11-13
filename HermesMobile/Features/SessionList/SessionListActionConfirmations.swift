import SwiftUI

struct SessionActionConfirmations: ViewModifier {
    @Bindable var viewModel: SessionListViewModel
    @Binding var sessionPendingDeletion: SessionSummary?
    @Binding var projectPendingDeletion: ProjectSummary?

    let deleteSession: (SessionSummary) -> Void
    let deleteProject: (ProjectSummary) -> Void

    func body(content: Content) -> some View {
        content
            .alert(
                "Session action failed",
                isPresented: Binding(
                    get: { viewModel.actionErrorMessage != nil },
                    set: { isPresented in
                        if !isPresented {
                            viewModel.clearActionError()
                        }
                    }
                )
            ) {
                Button("OK") {
                    viewModel.clearActionError()
                }
            } message: {
                Text(viewModel.actionErrorMessage ?? "")
            }
            .alert(
                Self.deleteTitle(for: sessionPendingDeletion),
                isPresented: Binding(
                    get: { sessionPendingDeletion != nil },
                    set: { isPresented in
                        if !isPresented {
                            sessionPendingDeletion = nil
                        }
                    }
                )
            ) {
                Button("Cancel", role: .cancel) {
                    sessionPendingDeletion = nil
                }

                Button("Delete", role: .destructive) {
                    let session = sessionPendingDeletion
                    sessionPendingDeletion = nil

                    if let session {
                        deleteSession(session)
                    }
                }
            } message: {
                Text("This removes the chat from the Hermes server for good. It can't be restored from Archived.")
            }
            .alert(
                projectPendingDeletion.map { String(localized: "Delete \"\($0.displayName)\"?") } ?? String(localized: "Delete project?"),
                isPresented: Binding(
                    get: { projectPendingDeletion != nil },
                    set: { isPresented in
                        if !isPresented {
                            projectPendingDeletion = nil
                        }
                    }
                )
            ) {
                Button("Cancel", role: .cancel) {
                    projectPendingDeletion = nil
                }

                Button("Delete", role: .destructive) {
                    let project = projectPendingDeletion
                    projectPendingDeletion = nil

                    if let project {
                        deleteProject(project)
                    }
                }
            } message: {
                Text("Sessions in this project will be moved to No project. The sessions themselves will not be deleted.")
            }
    }

    /// Names the chat so a delete from a menu can't hit the wrong one.
    static func deleteTitle(for session: SessionSummary?) -> String {
        guard let session else { return String(localized: "Delete chat?") }
        return String(localized: "Delete \"\(SessionRowView.displayTitle(for: session))\"?")
    }
}
