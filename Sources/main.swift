import Cocoa
import WebKit

struct AppConfig {
    var autoFocusOnAsk: Bool = true

    static func load() -> AppConfig {
        let path = NSString(string: "~/.config/claude-status/config.json").expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return AppConfig()
        }
        var config = AppConfig()
        if let v = json["autoFocusOnAsk"] as? Bool { config.autoFocusOnAsk = v }
        return config
    }
}

class NonThrottledWindow: NSWindow {
    override var occlusionState: NSWindow.OcclusionState { [.visible] }
}

class StatusRenderer: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    private let webView: WKWebView
    private let outputPath: String
    private let statePath: String
    private var window: NSWindow?
    private var hasFinishedInitialLoad = false
    private var popupWebView: WKWebView?
    private var captureTimer: Timer?
    private var windowShown = false
    private var signalSource: DispatchSourceSignal?
    private var signedIn = false
    private var consecutiveFailures = 0
    private let config: AppConfig
    private var alertedSessions: Set<String> = []
    private var savedFrame: NSRect?
    private var previousApp: NSRunningApplication?

    init(output: String, config: AppConfig) {
        self.outputPath = output
        self.statePath = output.replacingOccurrences(of: ".png", with: ".state")
        self.config = config

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
        window = NonThrottledWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window?.title = "Claude Code"
        window?.contentView = webView
        window?.delegate = self
        window?.setFrameAutosaveName("ClaudeStatusWindow")
        if let saved = window?.frame { savedFrame = saved }
        window?.setFrameOrigin(NSPoint(x: 0, y: 0))
        window?.orderBack(nil)

        writeState("loading")
        setupSignalHandler()
        webView.load(URLRequest(url: URL(string: "https://claude.ai/code")!))
    }

    // MARK: - State

    private func writeState(_ state: String) {
        try? state.write(toFile: statePath, atomically: true, encoding: .utf8)
    }

    private func enterSignedOut() {
        signedIn = false
        captureTimer?.invalidate()
        captureTimer = nil
        try? FileManager.default.removeItem(atPath: outputPath)
        writeState("signed-out")
    }

    private func enterSignedIn() {
        signedIn = true
        consecutiveFailures = 0
        writeState("ok")
        if windowShown {
            hideWindow()
        }
        startCaptureLoop()
    }

    // MARK: - Window toggle

    func toggleWindow() {
        guard let window = window else { return }
        if windowShown {
            hideWindow()
        } else {
            previousApp = NSWorkspace.shared.frontmostApplication
            windowShown = true
            let frame = savedFrame ?? NSRect(x: 100, y: 200, width: 1200, height: 800)
            window.setFrame(frame, display: true)
            window.level = .floating
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func showWindow() {
        guard let window = window, !windowShown else { return }
        previousApp = NSWorkspace.shared.frontmostApplication
        windowShown = true
        let frame = savedFrame ?? NSRect(x: 100, y: 200, width: 1200, height: 800)
        window.setFrame(frame, display: true)
        window.level = .floating
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(webView)
    }

    private func hideWindow() {
        guard let window = window else { return }
        savedFrame = window.frame
        windowShown = false
        NSApp.setActivationPolicy(.accessory)
        window.level = .normal
        window.setFrameOrigin(NSPoint(x: 0, y: 0))
        window.orderBack(nil)
        previousApp?.activate()
        previousApp = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hideWindow()
        return false
    }

    private func setupSignalHandler() {
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler { [weak self] in
            self?.toggleWindow()
        }
        source.resume()
        signal(SIGUSR1, SIG_IGN)
        self.signalSource = source
    }

    // MARK: - OAuth popup support

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

    // MARK: - Navigation

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView == self.webView else { return }
        guard !hasFinishedInitialLoad else { return }
        hasFinishedInitialLoad = true
        pollForSessions()
    }

    // MARK: - Session polling

    private func pollForSessions(attempts: Int = 0) {
        let checkJS = "document.body && document.body.innerText.includes('Recents')"
        webView.evaluateJavaScript(checkJS) { result, _ in
            let found = result as? Bool ?? false
            if found {
                self.enterSignedIn()
            } else if attempts > 30 {
                self.enterSignedOut()
                self.pollWhileSignedOut()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.pollForSessions(attempts: attempts + 1)
                }
            }
        }
    }

    private func pollWhileSignedOut() {
        guard !signedIn else { return }
        let checkJS = "document.body && document.body.innerText.includes('Recents')"
        webView.evaluateJavaScript(checkJS) { result, _ in
            let found = result as? Bool ?? false
            if found {
                self.enterSignedIn()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.pollWhileSignedOut()
                }
            }
        }
    }

    // MARK: - Capture loop

    private var captureCount = 0
    private var warmIndex = 0

    private func startCaptureLoop() {
        captureTimer?.invalidate()
        capture()
        captureTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.captureCount += 1
            // Safety reload every ~10 minutes (400 captures at 1.5s)
            if self.captureCount % 400 == 0 {
                self.reload()
            } else {
                self.capture()
                self.checkForAwaitingSession()
                if self.captureCount % 13 == 0 && !self.windowShown {
                    self.warmNextSession()
                }
            }
        }
    }

    private func warmNextSession() {
        let js = "\(warmJS)(\(warmIndex))"
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self = self, let count = result as? Int, count > 0 else { return }
            self.warmIndex = (self.warmIndex + 1) % count
        }
    }

    private func reload() {
        hasFinishedInitialLoad = false
        webView.load(URLRequest(url: URL(string: "https://claude.ai/code")!))
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
            for (let i = recentsIdx + 1; i < lines.length && sessionNames.length < 6; i++) {
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
                clone.className = clone.className.replace(/\\bw-full\\b/g, '').replace(/\\bshrink-0\\b/g, '');
                const isIdle = row.querySelector('[aria-label="Idle"]') !== null;
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
                    opacity: ${isIdle ? '0.4' : '1'} !important;
                `;
                overlay.appendChild(clone);
            });

            const root = document.querySelector('.cds-root') || document.body;
            root.appendChild(overlay);
            const rect = overlay.getBoundingClientRect();
            return JSON.stringify({width: Math.ceil(rect.width), height: Math.ceil(rect.height), count: rowElements.length});
        })()
    """

    private let warmJS = """
        (function(targetIndex) {
            const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
            let codeNode = null;
            while (walker.nextNode()) {
                if (walker.currentNode.textContent.trim() === 'Routines') {
                    codeNode = walker.currentNode;
                    break;
                }
            }
            if (!codeNode) return -1;

            let sidebar = codeNode.parentElement;
            for (let i = 0; i < 10; i++) {
                if (!sidebar.parentElement) break;
                if (sidebar.innerText.includes('Recents')) break;
                sidebar = sidebar.parentElement;
            }

            const lines = sidebar.innerText.split('\\n').map(l => l.trim()).filter(l => l.length > 0);
            const recentsIdx = lines.indexOf('Recents');
            if (recentsIdx === -1) return -1;

            const skip = new Set(['Recents', 'View all', 'New session', 'Routines', 'Customize', 'More']);
            const sessionNames = [];
            for (let i = recentsIdx + 1; i < lines.length && sessionNames.length < 6; i++) {
                const line = lines[i];
                if (skip.has(line) || line.length > 100 || line.length < 2 || line.startsWith('⇧')) continue;
                if (line.includes('Try the') || line.includes('Install')) break;
                sessionNames.push(line);
            }

            const count = sessionNames.length;
            if (count === 0) return -1;
            const name = sessionNames[targetIndex % count];

            const tw = document.createTreeWalker(sidebar, NodeFilter.SHOW_TEXT);
            while (tw.nextNode()) {
                const t = tw.currentNode.textContent.trim();
                if (t === name || (name.endsWith('…') && t.startsWith(name.replace('…', '')))) {
                    let el = tw.currentNode.parentElement;
                    while (el && el !== sidebar) {
                        if (el.tagName === 'BUTTON') {
                            el.click();
                            return count;
                        }
                        el = el.parentElement;
                    }
                }
            }
            return -1;
        })
    """

    private let detectJS = """
        (function() {
            var dots = document.querySelectorAll('span.status-dot[data-kind="awaiting"]');
            var sessions = [];
            dots.forEach(function(dot) {
                var row = dot;
                for (var i = 0; i < 10; i++) {
                    row = row.parentElement;
                    if (!row) break;
                    if (row.tagName === 'BUTTON') break;
                }
                if (row && row.tagName === 'BUTTON') {
                    sessions.push(row.textContent.trim());
                }
            });
            return JSON.stringify(sessions);
        })()
    """

    private var isCapturing = false

    private func checkForAwaitingSession() {
        guard config.autoFocusOnAsk, signedIn, !windowShown else { return }
        webView.evaluateJavaScript(detectJS) { [weak self] result, _ in
            guard let self = self,
                  let jsonStr = result as? String,
                  let data = jsonStr.data(using: .utf8),
                  let sessions = try? JSONSerialization.jsonObject(with: data) as? [String] else {
                return
            }

            if sessions.isEmpty {
                self.alertedSessions.removeAll()
                return
            }

            self.alertedSessions = self.alertedSessions.intersection(Set(sessions))

            guard let target = sessions.first(where: { !self.alertedSessions.contains($0) }) else { return }
            self.alertedSessions.insert(target)

            let escaped = target.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
            let clickJS = """
                (function() {
                    var dots = document.querySelectorAll('span.status-dot[data-kind="awaiting"]');
                    for (var i = 0; i < dots.length; i++) {
                        var row = dots[i];
                        for (var j = 0; j < 10; j++) {
                            row = row.parentElement;
                            if (!row) break;
                            if (row.tagName === 'BUTTON') break;
                        }
                        if (row && row.tagName === 'BUTTON' && row.textContent.trim() === '\(escaped)') {
                            row.click();
                            return true;
                        }
                    }
                    return false;
                })()
            """
            self.webView.evaluateJavaScript(clickJS) { _, _ in
                self.showWindow()
            }
        }
    }

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
                self.consecutiveFailures += 1
                if self.consecutiveFailures > 20 {
                    self.enterSignedOut()
                    self.reload()
                    self.pollWhileSignedOut()
                }
                return
            }

            self.consecutiveFailures = 0
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
let outputIndex = args.firstIndex(of: "--output").map { $0 + 1 }
let outputPath = outputIndex.flatMap { $0 < args.count ? args[$0] : nil } ?? "/tmp/claude-status.png"

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let config = AppConfig.load()
let renderer = StatusRenderer(output: outputPath, config: config)
renderer.run()
app.run()
