import AppKit
import Combine
import SwiftUI

@MainActor
final class TalkingUIWindowPresenter: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var isVisible = false

    var visibilityDidChange: ((Bool) -> Void)?

    private var window: NSWindow?
    private var hostingController: NSHostingController<TalkingUIView>?
    private var suppressNextVisibilityNotification = false
    private var rememberedUnexpandedContentWidth: CGFloat?
    private var isApplyingAutomaticResize = false
    private var automaticColumnCount = 1

    private let defaultContentSize = NSSize(width: 320, height: 260)
    private let maximumAutomaticColumnCount = 4

    func show(snapshot: TalkingUISnapshot) {
        let shouldBringForward = window == nil

        if window == nil {
            createWindow(snapshot: snapshot)
        } else {
            render(snapshot)
        }

        if shouldBringForward {
            render(snapshot)
            window?.orderFrontRegardless()
        }

        setVisible(true)
    }

    func update(snapshot: TalkingUISnapshot) {
        render(snapshot)
    }

    func close(notify: Bool = true) {
        guard let window else {
            setVisible(false, notify: notify)
            return
        }

        suppressNextVisibilityNotification = !notify
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        hostingController = nil
        rememberedUnexpandedContentWidth = nil
        setVisible(false, notify: !suppressNextVisibilityNotification)
        suppressNextVisibilityNotification = false
    }

    func windowDidResize(_ notification: Notification) {
        guard !isApplyingAutomaticResize, automaticColumnCount <= 1, let window else {
            return
        }

        rememberedUnexpandedContentWidth = window.contentLayoutRect.width
    }

    private func createWindow(snapshot: TalkingUISnapshot) {
        let hostingController = NSHostingController(rootView: TalkingUIView(snapshot: snapshot.withColumnCount(1)))
        let window = NSPanel(contentViewController: hostingController)
        window.title = "Talking UI"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .nonactivatingPanel]
        window.level = .floating
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = true
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.setContentSize(defaultContentSize)
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.delegate = self
        rememberedUnexpandedContentWidth = defaultContentSize.width

        self.hostingController = hostingController
        self.window = window
    }

    private func render(_ snapshot: TalkingUISnapshot) {
        let columnCount = preferredColumnCount(for: snapshot)
        hostingController?.rootView = TalkingUIView(snapshot: snapshot.withColumnCount(columnCount))
        applyAutomaticWidthIfNeeded(preferredColumnCount: columnCount)
    }

    private func preferredColumnCount(for snapshot: TalkingUISnapshot) -> Int {
        guard let window else {
            return 1
        }

        return min(
            maximumAutomaticColumnCount,
            snapshot.preferredAutoExpandedColumnCount(forContentHeight: window.contentLayoutRect.height)
        )
    }

    private func applyAutomaticWidthIfNeeded(preferredColumnCount: Int) {
        guard let window else {
            return
        }

        let baseContentWidth = rememberedUnexpandedContentWidth ?? window.contentLayoutRect.width

        if preferredColumnCount <= 1 {
            automaticColumnCount = 1
            resizeContentWidthIfNeeded(baseContentWidth)
            rememberedUnexpandedContentWidth = baseContentWidth
            return
        }

        if rememberedUnexpandedContentWidth == nil {
            rememberedUnexpandedContentWidth = window.contentLayoutRect.width
        }

        automaticColumnCount = preferredColumnCount
        resizeContentWidthIfNeeded(baseContentWidth * CGFloat(preferredColumnCount))
    }

    private func resizeContentWidthIfNeeded(_ targetWidth: CGFloat) {
        guard let window else {
            return
        }

        let currentContentSize = window.contentLayoutRect.size
        guard abs(currentContentSize.width - targetWidth) > 1 else {
            return
        }

        isApplyingAutomaticResize = true
        window.setContentSize(NSSize(width: targetWidth, height: currentContentSize.height))
        isApplyingAutomaticResize = false
    }

    private func setVisible(_ isVisible: Bool, notify: Bool = true) {
        guard self.isVisible != isVisible else {
            return
        }

        self.isVisible = isVisible

        if notify {
            visibilityDidChange?(isVisible)
        }
    }
}
