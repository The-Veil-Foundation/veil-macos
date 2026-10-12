import SwiftUI
import UIKit

// Long-press and ⋯ menus for list rows, drawn by the system but driven from
// UIKit. SwiftUI's own context menu cannot change while it is open, and the
// Advanced level has to replace the menu's contents in place — Back to return
// — instead of stacking a submenu over a dimmed parent. UIKit can, through
// `updateVisibleMenu`, so these menus go through it.

/// One row of a row menu.
struct RowMenuItem {
    enum Kind {
        case action(@MainActor () -> Void)
        /// Swaps the open menu's contents for these sections, with Back.
        case level([[RowMenuItem]])
    }

    var title: String
    var systemImage: String?
    var isDestructive = false
    var isDisabled = false
    /// Non-nil for an on/off item, drawn with a checkmark when on.
    var isChecked: Bool?
    var kind: Kind

    static func button(_ title: String, systemImage: String? = nil,
                       destructive: Bool = false, disabled: Bool = false,
                       checked: Bool? = nil,
                       action: @escaping @MainActor () -> Void) -> RowMenuItem {
        RowMenuItem(title: title, systemImage: systemImage, isDestructive: destructive,
                    isDisabled: disabled, isChecked: checked, kind: .action(action))
    }

    static func level(_ title: String, systemImage: String? = nil,
                      _ sections: [[RowMenuItem]]) -> RowMenuItem {
        RowMenuItem(title: title, systemImage: systemImage, kind: .level(sections))
    }
}

/// Sections of items; the system draws a separator between sections.
typealias RowMenu = [[RowMenuItem]]

@MainActor
enum RowMenuBuilder {
    /// - Parameter swap: replaces the contents of the menu on screen.
    static func menu(_ sections: RowMenu, backTitle: String,
                     swap: @escaping @MainActor (UIMenu) -> Void) -> UIMenu {
        build(sections, backTo: nil, backTitle: backTitle, swap: swap)
    }

    private static func build(_ sections: RowMenu, backTo parent: (@MainActor () -> UIMenu)?,
                              backTitle: String,
                              swap: @escaping @MainActor (UIMenu) -> Void) -> UIMenu {
        var groups: [UIMenuElement] = []
        if let parent {
            let back = UIAction(title: backTitle, image: UIImage(systemName: "chevron.backward"),
                                attributes: .keepsMenuPresented) { _ in swap(parent()) }
            groups.append(UIMenu(options: .displayInline, children: [back]))
        }
        let rebuildThis: @MainActor () -> UIMenu = {
            build(sections, backTo: parent, backTitle: backTitle, swap: swap)
        }
        for section in sections where !section.isEmpty {
            let children = section.map { item -> UIMenuElement in
                let image = item.systemImage.flatMap { UIImage(systemName: $0) }
                switch item.kind {
                case .action(let run):
                    var attributes: UIMenuElement.Attributes = []
                    if item.isDestructive { attributes.insert(.destructive) }
                    if item.isDisabled { attributes.insert(.disabled) }
                    return UIAction(title: item.title, image: image, attributes: attributes,
                                    state: item.isChecked == true ? .on : .off) { _ in run() }
                case .level(let inner):
                    // Stays open: the contents change, the menu does not go.
                    return UIAction(title: item.title, image: image,
                                    attributes: .keepsMenuPresented) { _ in
                        swap(build(inner, backTo: rebuildThis, backTitle: backTitle, swap: swap))
                    }
                }
            }
            groups.append(UIMenu(options: .displayInline, children: children))
        }
        return UIMenu(children: groups)
    }
}

// MARK: - Row surface

/// Laid over a row: answers a tap with `onTap` and a long press with the
/// menu, lifting the row's own list cell as the preview.
///
/// It takes the tap as well because a UIKit view over SwiftUI content keeps
/// SwiftUI's gestures underneath from firing. The list's swipe and scroll are
/// the cell's and the collection view's, so they still reach them.
struct RowMenuSurface: UIViewRepresentable {
    var isEnabled: Bool
    var backdrop: MenuBackdrop
    var backTitle: String
    var onTap: (() -> Void)?
    var sections: () -> RowMenu

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let interaction = UIContextMenuInteraction(delegate: context.coordinator)
        view.addInteraction(interaction)
        context.coordinator.interaction = interaction
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.tapped))
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    @MainActor
    final class Coordinator: NSObject, UIContextMenuInteractionDelegate {
        var parent: RowMenuSurface
        weak var interaction: UIContextMenuInteraction?

        init(_ parent: RowMenuSurface) { self.parent = parent }

        @objc func tapped() {
            guard parent.isEnabled else { return }
            parent.onTap?()
        }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
            guard parent.isEnabled else { return nil }
            let sections = parent.sections()
            let backTitle = parent.backTitle
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak interaction] _ in
                RowMenuBuilder.menu(sections, backTitle: backTitle) { menu in
                    interaction?.updateVisibleMenu { _ in menu }
                }
            }
        }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    configuration: UIContextMenuConfiguration,
                                    highlightPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
            preview(for: interaction)
        }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    configuration: UIContextMenuConfiguration,
                                    dismissalPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
            preview(for: interaction)
        }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    willDisplayMenuFor configuration: UIContextMenuConfiguration,
                                    animator: (any UIContextMenuInteractionAnimating)?) {
            parent.backdrop.open()
        }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    willEndFor configuration: UIContextMenuConfiguration,
                                    animator: (any UIContextMenuInteractionAnimating)?) {
            parent.backdrop.close()
        }

        /// The whole list cell lifts, not the bare content this view covers,
        /// and as one rounded card whether it sits first, last or between.
        private func preview(for interaction: UIContextMenuInteraction) -> UITargetedPreview? {
            guard let view = interaction.view, view.window != nil else { return nil }
            let cell = sequence(first: view, next: \.superview)
                .first { $0 is UICollectionViewCell || $0 is UITableViewCell } ?? view
            let parameters = UIPreviewParameters()
            parameters.backgroundColor = .secondarySystemGroupedBackground
            parameters.visiblePath = UIBezierPath(roundedRect: cell.bounds, cornerRadius: 22)
            return UITargetedPreview(view: cell, parameters: parameters)
        }
    }
}

// MARK: - ⋯ button

/// A ⋯ button opening the same kind of menu, so Advanced swaps in place there
/// too.
struct RowMenuButton: UIViewRepresentable {
    var backdrop: MenuBackdrop
    var backTitle: String
    var accessibilityLabel: String
    var sections: () -> RowMenu

    func makeUIView(context: Context) -> BackdropButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "ellipsis.circle")
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 0)
        let button = BackdropButton(configuration: configuration)
        button.showsMenuAsPrimaryAction = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    func updateUIView(_ button: BackdropButton, context: Context) {
        button.backdrop = backdrop
        button.accessibilityLabel = accessibilityLabel
        let sections = sections
        let backTitle = backTitle
        // Built when it opens, so it shows the source as it is then and
        // always starts on the everyday level.
        button.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak button] completion in
                let menu = RowMenuBuilder.menu(sections(), backTitle: backTitle) { menu in
                    button?.contextMenuInteraction?.updateVisibleMenu { _ in menu }
                }
                completion(menu.children)
            }
        ])
    }

    final class BackdropButton: UIButton {
        weak var backdrop: MenuBackdrop?

        override func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                             willDisplayMenuFor configuration: UIContextMenuConfiguration,
                                             animator: (any UIContextMenuInteractionAnimating)?) {
            super.contextMenuInteraction(interaction, willDisplayMenuFor: configuration, animator: animator)
            backdrop?.open()
        }

        override func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                             willEndFor configuration: UIContextMenuConfiguration,
                                             animator: (any UIContextMenuInteractionAnimating)?) {
            super.contextMenuInteraction(interaction, willEndFor: configuration, animator: animator)
            backdrop?.close()
        }
    }
}
