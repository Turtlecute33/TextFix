// SPDX-License-Identifier: GPL-3.0-only
import AppKit

/// Small factory helpers for the hand-built AppKit UI. They exist so the settings window reads as
/// a description of the form rather than as three hundred lines of `translatesAutoresizing...`.
enum Controls {
    static func label(_ text: String, font: NSFont = .systemFont(ofSize: 13)) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    /// The right-aligned caption in front of a control. macOS forms align labels to the trailing
    /// edge of their column so the controls line up on a single left edge.
    static func fieldLabel(_ text: String) -> NSTextField {
        let field = label(text)
        field.alignment = .right
        field.textColor = .labelColor
        field.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        return field
    }

    /// The explanatory line under a control. Small, secondary, and the reason the window needs no
    /// help button.
    static func hint(_ text: String) -> NSTextField {
        let field = label(text, font: .systemFont(ofSize: 11))
        field.textColor = .secondaryLabelColor
        return field
    }

    static func sectionHeader(_ text: String) -> NSTextField {
        let field = label(text, font: .systemFont(ofSize: 11, weight: .semibold))
        field.textColor = .secondaryLabelColor
        return field
    }

    static func checkbox(_ title: String, target: AnyObject? = nil, action: Selector? = nil) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: target, action: action)
        button.font = .systemFont(ofSize: 13)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    static func popUp(_ titles: [String], target: AnyObject? = nil, action: Selector? = nil) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.addItems(withTitles: titles)
        button.target = target
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    static func textField(placeholder: String = "") -> NSTextField {
        let field = NSTextField()
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 13)
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    static func secureField(placeholder: String = "") -> NSSecureTextField {
        let field = NSSecureTextField()
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 13)
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    static func button(_ title: String, target: AnyObject?, action: Selector, isDefault: Bool = false) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        if isDefault { button.keyEquivalent = "\r" }
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    /// A text button that looks like a link, used for "Get a key" rather than making the user go
    /// and find the provider's console themselves.
    static func link(_ title: String, target: AnyObject?, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.isBordered = false
        button.bezelStyle = .inline
        button.contentTintColor = .linkColor
        button.font = .systemFont(ofSize: 11)
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.linkColor,
            .font: NSFont.systemFont(ofSize: 11),
        ])
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        return box
    }

    /// A multi-line editor inside a scroll view, for the prompts. NSTextView is the only AppKit
    /// control that gives a usable editing experience for a paragraph of text.
    static func promptEditor() -> (scroll: NSScrollView, text: NSTextView) {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let text = NSTextView()
        text.isEditable = true
        text.isRichText = false
        text.allowsUndo = true
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.textContainerInset = NSSize(width: 4, height: 6)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        // A prompt is prose, not code being pasted into a shell: the substitutions AppKit turns on
        // by default would quietly replace the quotes and dashes the model is being told to use.
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        scroll.documentView = text
        return (scroll, text)
    }

    /// A row of `label: control`, with the label in a fixed-width trailing-aligned column so every
    /// row in the form shares one control edge.
    ///
    /// The caption is centred against the control rather than baseline-aligned: a row's control is
    /// often a stack of two things, and a container view's "first baseline" is its top edge, which
    /// would put the caption a few points too high in exactly the rows that need it most.
    /// `top` pins the caption to the top instead, for a row whose control is a tall editor.
    static func row(
        _ caption: String, _ control: NSView, labelWidth: CGFloat, alignTop: Bool = false
    ) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let captionLabel = fieldLabel(caption)
        container.addSubview(captionLabel)
        container.addSubview(control)

        var constraints: [NSLayoutConstraint] = [
            captionLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            captionLabel.widthAnchor.constraint(equalToConstant: labelWidth),
            captionLabel.topAnchor.constraint(greaterThanOrEqualTo: container.topAnchor),
            captionLabel.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),

            control.leadingAnchor.constraint(equalTo: captionLabel.trailingAnchor, constant: 10),
            control.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            control.topAnchor.constraint(equalTo: container.topAnchor),
            control.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ]
        constraints.append(alignTop
            ? captionLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 3)
            : captionLabel.centerYAnchor.constraint(equalTo: control.centerYAnchor))
        NSLayoutConstraint.activate(constraints)
        return container
    }
}
