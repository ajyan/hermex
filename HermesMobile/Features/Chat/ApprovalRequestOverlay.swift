import SwiftUI
import UIKit

struct ApprovalRequestOverlay: View {
    let prompt: ApprovalPromptState
    let isResponding: Bool
    let errorMessage: String?
    let onChoice: (ApprovalChoice) -> Void
    let onSkipAll: () -> Void

    @AppStorage(Self.alwaysAllowExplainedKey) private var hasConfirmedAlwaysAllow = false
    @State private var isConfirmingSkipAll = false
    @State private var isConfirmingAlwaysAllow = false

    static let alwaysAllowExplainedKey = "approvals.alwaysAllowExplained"

    var body: some View {
        ZStack {
            Color.black.opacity(0.38)
                .ignoresSafeArea()

            // Scrolls only when the card is taller than the screen (large text,
            // landscape), so every button stays reachable.
            ViewThatFits(in: .vertical) {
                card
                ScrollView {
                    card.padding(.vertical, 18)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .alert("Skip approvals for this session?", isPresented: $isConfirmingSkipAll) {
            Button("Skip approvals", role: .destructive) { onSkipAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every command in this session runs without asking you first, including this one. Turn it off from the Approval bypass pill above the composer.")
        }
        .alert("Always allow this command?", isPresented: $isConfirmingAlwaysAllow) {
            Button("Always allow") {
                hasConfirmedAlwaysAllow = true
                onChoice(.always)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This is saved on your server and applies to every session, not just this one. To revoke it, remove the entry from command_allowlist in the Hermes config.yaml on your server.")
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            details
            actions
        }
        .padding(16)
        .frame(maxWidth: 520, alignment: .leading)
        .glowSurface(.request, cornerRadius: HXRadius.lg, opaque: true)
        .hxShadow(.modal)
        .padding(.horizontal, 18)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(HermexPaper.request.glow)

            Text("Approval required")
                .font(.headline)
                .foregroundStyle(HermexPaper.request.glow)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let description = nonEmpty(prompt.pending.description) {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let command = nonEmpty(prompt.pending.command) {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(command)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: HXRadius.sm, style: .continuous))
            }

            if let scope = prompt.scopeLine {
                Text(scope)
                    .font(.caption)
                    .foregroundStyle(HermexPaper.request.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if prompt.pendingCount > 1 {
                Text("1 of \(prompt.pendingCount) pending")
                    .font(.caption)
                    .foregroundStyle(HermexPaper.request.secondaryInk)
            }

            if let errorMessage = nonEmpty(errorMessage) {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.hxDanger)
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                approvalButton("Allow once", systemImage: "checkmark.circle.fill", choice: .once, prominent: true)
                approvalButton("Allow session", systemImage: "lock.open", choice: .session, prominent: false)
            }

            HStack(spacing: 8) {
                approvalButton("Always allow", systemImage: "star.fill", choice: .always, prominent: false)
                approvalButton("Deny", systemImage: "xmark.circle.fill", choice: .deny, prominent: false, role: .destructive)
            }

            Button {
                isConfirmingSkipAll = true
            } label: {
                Label("Skip all this session", systemImage: "bolt.slash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.chatDecision(.secondary))
            .disabled(isResponding)
        }
    }

    @ViewBuilder
    private func approvalButton(
        _ title: LocalizedStringKey,
        systemImage: String,
        choice: ApprovalChoice,
        prominent: Bool,
        role: ButtonRole? = nil
    ) -> some View {
        if prominent {
            Button(role: role) {
                choose(choice)
            } label: {
                Label(title, systemImage: systemImage)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.chatDecision(.primary))
            .disabled(isResponding)
        } else {
            Button(role: role) {
                choose(choice)
            } label: {
                Label(title, systemImage: systemImage)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.chatDecision(role == .destructive ? .destructive : .secondary))
            .disabled(isResponding)
        }
    }

    /// "Always allow" writes a permanent server rule, so the first one asks.
    private func choose(_ choice: ApprovalChoice) {
        if choice == .always, !hasConfirmedAlwaysAllow {
            isConfirmingAlwaysAllow = true
        } else {
            onChoice(choice)
        }
    }

    private func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

/// Shown above the composer while the session skips approvals. Tapping it turns
/// the bypass off; the pill stays until the server confirms.
struct ApprovalBypassStatusPill: View {
    let isTurningOff: Bool
    let onTurnOff: () -> Void

    var body: some View {
        Button(action: onTurnOff) {
            HStack(spacing: 8) {
                Label("Approval bypass active", systemImage: "bolt.slash.fill")
                    .foregroundStyle(Color.hxTextPrimary)
                if isTurningOff {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Text("Turn off")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(.primary.opacity(0.10), lineWidth: 1)
            )
            .hxShadow(.float)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isTurningOff)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Approval bypass active"))
        .accessibilityHint(Text("Turns approval bypass off, so commands in this session ask again"))
        .accessibilityAddTraits(.isButton)
    }
}
