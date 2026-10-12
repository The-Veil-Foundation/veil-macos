import SwiftUI

/// Shows a server as a QR code so it can be moved to another device, plus the
/// raw share link for copy/paste.
struct QRDisplayView: View {
    @Environment(Loc.self) private var loc
    @Environment(\.dismiss) private var dismiss

    let server: ProxyConfig

    @State private var modules: [[Bool]]?
    @State private var failed = false
    @State private var copied = false

    private var link: String { LinkBuilder.link(for: server) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    card
                    actions
                    Text(link)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
                .padding(20)
            }
            .navigationTitle(server.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(loc("Done")) { dismiss() }
                }
            }
            // Built off the main thread, once: a long link is a few thousand
            // modules, and the sheet should be up before they are.
            .task(id: link) {
                let text = link
                let result = await Task.detached(priority: .userInitiated) {
                    QRCode.matrix(from: text)
                }.value
                if let result { modules = result } else { failed = true }
            }
        }
        .presentationDetents([.large])
    }

    // MARK: Pieces

    /// The code on a white card in either theme: scanners want dark on light.
    private var card: some View {
        VStack(spacing: 14) {
            ZStack {
                if let modules {
                    QRModulesView(modules: modules)
                        .transition(.opacity)
                } else if failed {
                    Text(loc("Could not render a QR code for this server."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    ProgressView()
                }
            }
            .frame(width: 248, height: 248)
            .animation(.easeOut(duration: 0.2), value: modules == nil)

            Text(verbatim: server.proto.rawValue.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.black.opacity(0.45))
                .tracking(1)
        }
        .padding(22)
        .background(.white, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 20, y: 8)
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button {
                UIPasteboard.general.string = link
                withAnimation(.snappy) { copied = true }
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    withAnimation(.snappy) { copied = false }
                }
            } label: {
                Label(copied ? loc("Copied") : loc("Copy"),
                      systemImage: copied ? "checkmark" : "doc.on.doc")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .sensoryFeedback(.success, trigger: copied) { _, now in now }

            ShareLink(item: link) {
                Label(loc("Share"), systemImage: "square.and.arrow.up")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .controlSize(.large)
        .buttonBorderShape(.capsule)
    }
}

/// A QR code drawn as rounded dots, with the three finder patterns as rounded
/// squares and the app's mark in the middle. The error correction the matrix
/// was built with covers what the mark hides.
private struct QRModulesView: View {
    let modules: [[Bool]]

    var body: some View {
        GeometryReader { geometry in
            let count = modules.count
            let side = min(geometry.size.width, geometry.size.height)
            let cell = side / CGFloat(count)
            let logo = Int((Double(count) * 0.22).rounded(.up)) | 1
            let logoStart = (count - logo) / 2

            ZStack {
                Canvas { context, _ in
                    for (y, row) in modules.enumerated() {
                        for (x, dark) in row.enumerated() where dark {
                            if Self.inFinder(x, y, count) { continue }
                            if (logoStart..<logoStart + logo).contains(x),
                               (logoStart..<logoStart + logo).contains(y) { continue }
                            let rect = CGRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell,
                                              width: cell, height: cell)
                                .insetBy(dx: cell * 0.08, dy: cell * 0.08)
                            context.fill(Path(roundedRect: rect, cornerRadius: rect.width * 0.38),
                                         with: .color(.black))
                        }
                    }
                    for origin in [(0, 0), (count - 7, 0), (0, count - 7)] {
                        Self.drawFinder(in: &context, x: origin.0, y: origin.1, cell: cell)
                    }
                }

                RoundedRectangle(cornerRadius: cell * CGFloat(logo) * 0.26, style: .continuous)
                    .fill(.white)
                    .frame(width: cell * CGFloat(logo), height: cell * CGFloat(logo))
                    .overlay {
                        Image(systemName: "shield.lefthalf.filled")
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(Color.accentColor)
                            .padding(cell * CGFloat(logo) * 0.2)
                    }
            }
            .frame(width: side, height: side)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private static func inFinder(_ x: Int, _ y: Int, _ count: Int) -> Bool {
        (x < 7 && y < 7) || (x >= count - 7 && y < 7) || (x < 7 && y >= count - 7)
    }

    /// The 7×7 eye: a rounded ring with a rounded 3×3 pupil.
    private static func drawFinder(in context: inout GraphicsContext, x: Int, y: Int, cell: CGFloat) {
        let outer = CGRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell,
                           width: cell * 7, height: cell * 7)
        var ring = Path(roundedRect: outer, cornerRadius: cell * 2.2, style: .continuous)
        ring.addPath(Path(roundedRect: outer.insetBy(dx: cell, dy: cell),
                          cornerRadius: cell * 1.5, style: .continuous))
        context.fill(ring, with: .color(.black), style: FillStyle(eoFill: true))
        let pupil = outer.insetBy(dx: cell * 2, dy: cell * 2)
        context.fill(Path(roundedRect: pupil, cornerRadius: cell * 1.0, style: .continuous),
                     with: .color(.black))
    }
}
