import SwiftUI

/// Shared header for every stage in the sidebar:
/// - Clicking anywhere on the title/chevron area expands or collapses immediately
/// - Displays an optional accent dot when values differ from clean defaults
/// - Shows a compact summary when collapsed
/// - Keeps all stage switches consistently right-aligned
struct StageHeader: View {
    let stepNumber: Int?
    let title: String
    @Binding var expanded: Bool
    var summary: String? = nil
    var isModified: Bool = false
    var toggleBinding: Binding<Bool>? = nil
    var toggleHelp: String = ""

    var body: some View {
        HStack(spacing: 6) {
            Button {
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 22)

                    if let stepNumber {
                        Text("\(stepNumber)")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                            .background(Color.primary.opacity(0.08), in: Circle())
                    }

                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if isModified {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                            .help("Modified from clean default")
                    }

                    Spacer(minLength: 4)

                    if !expanded, let summary, !summary.isEmpty {
                        Text(summary)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let toggleBinding {
                Toggle("", isOn: toggleBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .help(toggleHelp)
            }
        }
    }
}
