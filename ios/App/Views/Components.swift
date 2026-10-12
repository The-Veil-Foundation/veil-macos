import SwiftUI

/// Lays chips out left to right and wraps them onto as many lines as needed.
struct ChipFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += lineHeight + spacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: proposal.width ?? widest, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += lineHeight + spacing
                x = bounds.minX
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// One selectable chip.
struct Chip: View {
    let title: String
    var isOn: Bool = false
    var systemImage: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title).lineLimit(1)
            }
            .font(.caption)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .foregroundStyle(isOn ? Color.white : Color.primary)
            .background(Capsule().fill(isOn ? Color.accentColor : Color.secondary.opacity(0.15)))
        }
        .buttonStyle(.plain)
    }
}

/// A list of matcher strings — domains, addresses, ports — edited as chips
/// with a field to add more. Pasting a comma- or newline-separated list adds
/// every entry in it.
struct TokenListEditor: View {
    @Environment(Loc.self) private var loc
    @Binding var values: [String]
    var placeholder: String
    var monospaced = true
    var onChange: () -> Void = {}

    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !values.isEmpty {
                ChipFlow(spacing: 6) {
                    ForEach(values, id: \.self) { value in
                        Button {
                            let removed = value
                            values.removeAll { $0 == removed }
                            onChange()
                        } label: {
                            HStack(spacing: 4) {
                                Text(value)
                                    .font(monospaced ? .caption.monospaced() : .caption)
                                    .lineLimit(1)
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack {
                TextField(placeholder, text: $draft)
                    .font(monospaced ? .callout.monospaced() : .callout)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.asciiCapable)
                    .onSubmit(commit)
                Button(loc("Add"), action: commit)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func commit() {
        let entries = draft
            .split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !values.contains($0) }
        guard !entries.isEmpty else { return }
        values.append(contentsOf: entries)
        draft = ""
        onChange()
    }
}

/// A row title with an "i" that explains it, for settings whose effect is not
/// obvious from the name alone.
struct HintLabel: View {
    let title: String
    let hint: String
    @State private var showing = false

    init(_ title: String, _ hint: String) {
        self.title = title
        self.hint = hint
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Button {
                showing = true
            } label: {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .popover(isPresented: $showing) {
                Text(hint)
                    .font(.callout)
                    .padding()
                    .frame(idealWidth: 300)
                    .fixedSize(horizontal: false, vertical: true)
                    .presentationCompactAdaptation(.popover)
            }
        }
    }
}
