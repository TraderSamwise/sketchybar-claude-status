import Cocoa
import WebKit

class StatusRenderer: NSObject, WKNavigationDelegate, WKUIDelegate {
    private let webView: WKWebView
    private let outputPath: String
    private let isLogin: Bool
    private var window: NSWindow?
    private var hasFinishedInitialLoad = false
    private var popupWebView: WKWebView?
    private var captureTimer: Timer?

    init(output: String, login: Bool) {
        self.outputPath = output
        self.isLogin = login

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        self.webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800), configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    func run() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: isLogin ? 500 : 1200, height: isLogin ? 700 : 800),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window?.title = "Claude Status — Login"
        window?.contentView = webView

        if isLogin {
            window?.center()
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            window?.setFrameOrigin(NSPoint(x: 0, y: 0))
            window?.orderBack(nil)
        }

        webView.load(URLRequest(url: URL(string: "https://claude.ai/code")!))
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let popup = WKWebView(frame: webView.bounds, configuration: configuration)
        popup.autoresizingMask = [.width, .height]
        popup.uiDelegate = self
        popup.navigationDelegate = self
        webView.addSubview(popup)
        popupWebView = popup
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        if webView == popupWebView {
            popupWebView?.removeFromSuperview()
            popupWebView = nil
        }
    }

    // MARK: - Initial load polling

    private func pollForSessions(attempts: Int = 0) {
        let checkJS = "document.body && document.body.innerText.includes('Recents')"
        webView.evaluateJavaScript(checkJS) { result, _ in
            let found = result as? Bool ?? false
            if found {
                self.startCaptureLoop()
            } else if attempts > 30 {
                fputs("Timed out waiting for page\n", stderr)
                exit(1)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.pollForSessions(attempts: attempts + 1)
                }
            }
        }
    }

    // MARK: - Capture loop

    private var captureCount = 0

    private func startCaptureLoop() {
        capture()
        captureTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.captureCount += 1
            // Safety reload every ~10 minutes (400 captures at 1.5s)
            if self.captureCount % 400 == 0 {
                self.reload()
            } else {
                self.capture()
            }
        }
    }

    private func reload() {
        hasFinishedInitialLoad = false
        webView.load(URLRequest(url: URL(string: "https://claude.ai/code")!))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !isLogin else { return }
        guard !hasFinishedInitialLoad else { return }
        hasFinishedInitialLoad = true
        if captureCount == 0 {
            pollForSessions()
        } else {
            pollUntilReady()
        }
    }

    private func pollUntilReady(attempts: Int = 0) {
        let checkJS = "document.body && document.body.innerText.includes('Recents')"
        webView.evaluateJavaScript(checkJS) { result, _ in
            let found = result as? Bool ?? false
            if found {
                self.capture()
            } else if attempts > 15 {
                return
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.pollUntilReady(attempts: attempts + 1)
                }
            }
        }
    }

    private let captureJS = """
        (function() {
            // Find Code sidebar via "Routines" anchor
            const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
            let codeNode = null;
            while (walker.nextNode()) {
                if (walker.currentNode.textContent.trim() === 'Routines') {
                    codeNode = walker.currentNode;
                    break;
                }
            }
            if (!codeNode) return JSON.stringify({error: 'no sidebar'});

            let sidebar = codeNode.parentElement;
            for (let i = 0; i < 10; i++) {
                if (!sidebar.parentElement) break;
                if (sidebar.innerText.includes('Recents')) break;
                sidebar = sidebar.parentElement;
            }

            // Parse session names from sidebar text
            const lines = sidebar.innerText.split('\\n').map(l => l.trim()).filter(l => l.length > 0);
            const recentsIdx = lines.indexOf('Recents');
            if (recentsIdx === -1) return JSON.stringify({error: 'no Recents'});

            const skip = new Set(['Recents', 'View all', 'New session', 'Routines', 'Customize', 'More']);
            const sessionNames = [];
            for (let i = recentsIdx + 1; i < lines.length && sessionNames.length < 4; i++) {
                const line = lines[i];
                if (skip.has(line) || line.length > 100 || line.length < 2 || line.startsWith('⇧')) continue;
                if (line.includes('Try the') || line.includes('Install')) break;
                sessionNames.push(line);
            }
            if (sessionNames.length === 0) return JSON.stringify({error: 'no sessions'});

            // Find actual DOM elements for each session by matching text
            const rowElements = [];
            sessionNames.forEach(name => {
                const tw = document.createTreeWalker(sidebar, NodeFilter.SHOW_TEXT);
                while (tw.nextNode()) {
                    const t = tw.currentNode.textContent.trim();
                    if (t === name || (name.endsWith('…') && t.startsWith(name.replace('…', '')))) {
                        let el = tw.currentNode.parentElement;
                        while (el && el !== sidebar) {
                            if (el.querySelector('.df-leading-slot')) {
                                rowElements.push(el);
                                break;
                            }
                            el = el.parentElement;
                        }
                        break;
                    }
                }
            });

            // Build overlay inside .cds-root to inherit CSS vars and fonts
            let overlay = document.getElementById('sb-overlay');
            if (overlay) overlay.remove();

            overlay = document.createElement('div');
            overlay.id = 'sb-overlay';
            overlay.style.cssText = 'display:flex;flex-direction:row;align-items:center;gap:4px;padding:4px 6px 8px 6px;background:#1a1a1a;position:fixed;top:0;left:0;z-index:999999;white-space:nowrap;';

            rowElements.forEach(row => {
                const clone = row.cloneNode(true);
                // Strip width classes but keep the rest for icon rendering
                clone.className = clone.className.replace(/\\bw-full\\b/g, '').replace(/\\bshrink-0\\b/g, '');
                clone.style.cssText = `
                    height: auto !important;
                    width: fit-content !important;
                    min-width: 0 !important;
                    display: inline-flex !important;
                    padding: 1px 6px !important;
                    background: #2a2a2a !important;
                    border-radius: 4px !important;
                    border: 1px solid #444 !important;
                    flex-shrink: 0 !important;
                    max-width: 200px !important;
                    overflow: hidden !important;
                    font-size: 12px !important;
                `;
                overlay.appendChild(clone);
            });

            const root = document.querySelector('.cds-root') || document.body;
            root.appendChild(overlay);
            const rect = overlay.getBoundingClientRect();
            return JSON.stringify({width: Math.ceil(rect.width), height: Math.ceil(rect.height), count: rowElements.length});
        })()
    """

    private var isCapturing = false

    private func capture() {
        guard !isCapturing else { return }
        isCapturing = true

        webView.evaluateJavaScript(captureJS) { [weak self] result, _ in
            guard let self = self else { return }

            guard let jsonStr = result as? String,
                  let data = jsonStr.data(using: .utf8),
                  let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let width = info["width"] as? Int,
                  let height = info["height"] as? Int,
                  width > 0, height > 0 else {
                self.isCapturing = false
                return
            }

            let snapshotConfig = WKSnapshotConfiguration()
            snapshotConfig.rect = CGRect(x: 0, y: 0, width: width, height: height)

            self.webView.takeSnapshot(with: snapshotConfig) { image, _ in
                self.isCapturing = false
                guard let image = image,
                      let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else {
                    return
                }
                try? png.write(to: URL(fileURLWithPath: self.outputPath))
            }
        }
    }
}

let args = CommandLine.arguments
let login = args.contains("--login")

let outputIndex = args.firstIndex(of: "--output").map { $0 + 1 }
let outputPath = outputIndex.flatMap { $0 < args.count ? args[$0] : nil } ?? "/tmp/claude-status.png"

let app = NSApplication.shared
app.setActivationPolicy(login ? .regular : .accessory)

let renderer = StatusRenderer(output: outputPath, login: login)
renderer.run()
app.run()
