import UIKit

@MainActor
final class ShareViewController: UIViewController {
    private var didStartOpening = false
    private var didAppear = false
    private var pendingAlert: (title: String, message: String)?

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        guard !didStartOpening else { return }
        didStartOpening = true

        Task {
            await saveDraftAndOpenHermes()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        didAppear = true
        if let pendingAlert {
            self.pendingAlert = nil
            presentAlert(title: pendingAlert.title, message: pendingAlert.message)
        }
    }

    private func configureView() {
        view.backgroundColor = .clear
        view.isOpaque = false
    }

    private func saveDraftAndOpenHermes() async {
        let input = await ShareInputReader.input(from: extensionContext)
        let draft = HermesShareDraft.draftText(textSnippets: input.textSnippets, urls: input.urls)

        guard !draft.isEmpty || !input.attachments.isEmpty else {
            showAlert(title: "Nothing to share", message: "Atlas accepts text, URLs, images, PDFs, and files up to 20 MB.")
            return
        }

        guard let directory = HermesShareDraft.containerURL() else {
            showAlert(title: "Couldn't share to Atlas", message: "Atlas's storage isn't available. Open Atlas once, then share again.")
            return
        }

        do {
            try HermesShareDraft.savePendingImport(draft: draft, attachments: input.attachments, in: directory)
        } catch {
            showAlert(title: "Couldn't share to Atlas", message: "The shared content couldn't be saved. Try sharing it again.")
            return
        }

        openHermes()
    }

    /// Errors stay on screen on an opaque alert until OK, which ends the share.
    private func showAlert(title: String, message: String) {
        guard didAppear else {
            pendingAlert = (title, message)
            return
        }
        presentAlert(title: title, message: message)
    }

    private func presentAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        })
        present(alert, animated: true)
    }

    private func openHermes() {
        let url = HermesShareDraft.openURL

        extensionContext?.open(url, completionHandler: { [weak self] success in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if success {
                    self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
                } else {
                    self.openHermesViaWorkaround(url)
                }
            }
        })
    }

    private func openHermesViaWorkaround(_ url: URL) {
        let application = containingApplicationResponder()
        if let application, open(url, using: application) {
            extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
            return
        }

        if openViaResponderChain(url) || openViaContainingApplication(url) {
            extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
            return
        }

        // Fallback if everything fails: the import is saved, so say how to reach it.
        showAlert(title: "Saved for Atlas", message: "Open Atlas to finish sharing.")
    }

    private func openViaContainingApplication(_ url: URL) -> Bool {
        // Owner-accepted App Review risk: share extensions have no guaranteed
        // containing-app launcher, but this preserves the current fast return UX.
        let sharedApplicationSelector = NSSelectorFromString("sharedApplication")
        let openURLModernSelector = NSSelectorFromString("openURL:options:completionHandler:")

        guard
            let applicationClass = NSClassFromString("UIApplication") as? NSObject.Type,
            applicationClass.responds(to: sharedApplicationSelector),
            let application = applicationClass.perform(sharedApplicationSelector)?.takeUnretainedValue() as? NSObject
        else {
            return false
        }

        if application.responds(to: openURLModernSelector),
           let implementation = application.method(for: openURLModernSelector) {
            typealias OpenURLModernFunction = @convention(c) (NSObject, Selector, NSURL, NSDictionary, Any?) -> Void
            let openURL = unsafeBitCast(implementation, to: OpenURLModernFunction.self)
            openURL(application, openURLModernSelector, url as NSURL, [:] as NSDictionary, nil)
            return true
        }

        return false
    }

    private func containingApplicationResponder() -> UIResponder? {
        guard let applicationClass = NSClassFromString("UIApplication") else {
            return nil
        }

        var responder: UIResponder? = self
        while let currentResponder = responder {
            if currentResponder.isKind(of: applicationClass) {
                return currentResponder
            }

            responder = currentResponder.next
        }

        return nil
    }

    private func openViaResponderChain(_ url: URL) -> Bool {
        var responder: UIResponder? = self

        while let currentResponder = responder {
            if open(url, using: currentResponder) {
                return true
            }

            responder = currentResponder.next
        }

        return false
    }

    private func open(_ url: URL, using responder: UIResponder) -> Bool {
        // Owner-accepted App Review risk; this is a fallback for hosts where
        // NSExtensionContext.open does not route to the containing app.
        if let application = responder as? UIApplication {
            application.open(url, options: [:], completionHandler: nil)
            return true
        }

        let openURLModernSelector = NSSelectorFromString("openURL:options:completionHandler:")
        if responder.responds(to: openURLModernSelector),
           let implementation = responder.method(for: openURLModernSelector) {
            typealias OpenURLModernFunction = @convention(c) (UIResponder, Selector, NSURL, NSDictionary, Any?) -> Void
            let openURL = unsafeBitCast(implementation, to: OpenURLModernFunction.self)
            openURL(responder, openURLModernSelector, url as NSURL, [:] as NSDictionary, nil)
            return true
        }

        return false
    }

}
