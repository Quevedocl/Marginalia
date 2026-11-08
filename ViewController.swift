import UIKit
import WebKit
import AVFoundation

final class ViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    private let webView: WKWebView
    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = true
        config.websiteDataStore = .default()
        // Le dice a la web que corre como app instalada: activa su ajuste de alto real de pantalla
        // (sin esto iOS le entrega un alto menor y la app se ve comprimida arriba y abajo).
        let js = "Object.defineProperty(navigator,'standalone',{get:function(){return true},configurable:true});"
        config.userContentController.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView = WKWebView(frame: .zero, configuration: config)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) no se usa") }

    override var preferredStatusBarStyle: UIStatusBarStyle { .darkContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white

        // Pantalla completa real: la web ocupa todo el alto, incluida el área bajo la cámara y la barra inferior.
        webView.frame = view.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.bounces = false
        webView.scrollView.isScrollEnabled = false   // la app web ya desplaza sus propias listas
        webView.isOpaque = false
        webView.backgroundColor = .white
        webView.scrollView.backgroundColor = .white
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        view.addSubview(webView)

        // Audio: mantener y reanudar la música al bloquear/desbloquear o tras una interrupción
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(appToBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(resumeAudio), name: UIApplication.willEnterForegroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(resumeAudio), name: UIApplication.didBecomeActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(audioInterruption(_:)), name: AVAudioSession.interruptionNotification, object: nil)

        if let url = URL(string: appURL) {
            webView.load(URLRequest(url: url))
        }
    }

    @objc private func appToBackground() {
        try? AVAudioSession.sharedInstance().setActive(true)
        endBg()
        bgTask = UIApplication.shared.beginBackgroundTask { [weak self] in self?.endBg() }
        resumeAudio()
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.endBg() }
    }

    private func endBg() {
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
    }

    @objc private func resumeAudio() {
        try? AVAudioSession.sharedInstance().setActive(true)
        for d in [0.0, 0.4, 1.2, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak self] in
                self?.webView.evaluateJavaScript("window.qmResume&&window.qmResume()", completionHandler: nil)
            }
        }
    }

    @objc private func audioInterruption(_ n: Notification) {
        guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
        resumeAudio()
    }

    // Enlaces que no son web (spotify:, mailto:, etc.) se abren fuera de la app
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(),
           !["http", "https", "about", "blob", "data"].contains(scheme) {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    // window.open / target=_blank (por ejemplo «Abrir en Spotify»)
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { UIApplication.shared.open(url) }
        return nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let html = "<meta name='viewport' content='width=device-width,initial-scale=1'><body style='font:17px -apple-system;text-align:center;padding:30vh 24px'>Sin conexión.<br>Revisa internet y vuelve a abrir Q-Music.</body>"
        webView.loadHTMLString(html, baseURL: nil)
    }
}
