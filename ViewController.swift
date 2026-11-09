import UIKit
import WebKit
import AVFoundation
import MediaPlayer

final class ViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    private let webView: WKWebView
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    // Volumen real del iPhone: una web no puede cambiarlo, así que se maneja con un MPVolumeView oculto
    private let volumeView = MPVolumeView(frame: CGRect(x: -400, y: -400, width: 120, height: 40))
    private var volObserver: NSKeyValueObservation?

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
        // Puente JS → nativo para el control de volumen (window.webkit.messageHandlers.qmVol)
        webView.configuration.userContentController.add(WeakHandler { [weak self] body in self?.handleVolume(body) }, name: "qmVol")
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

        // Control de volumen del sistema (oculto, fuera de pantalla)
        volumeView.alpha = 0.01
        volumeView.isUserInteractionEnabled = false
        view.addSubview(volumeView)

        // Sesión de audio de reproducción: sigue sonando con la pantalla bloqueada
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)
        // Si cambias el volumen con los botones del iPhone, la barra de la app lo refleja
        volObserver = session.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            if let v = change.newValue { self?.pushVolume(v) }
        }

        // Audio: mantener y reanudar la música al bloquear/desbloquear o tras una interrupción
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(appToBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(resumeAudio), name: UIApplication.willEnterForegroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(resumeAudio), name: UIApplication.didBecomeActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(audioInterruption(_:)), name: AVAudioSession.interruptionNotification, object: nil)
        // Bloqueo de pantalla: iOS pausa el video de YouTube un instante; se reanuda lo antes posible
        nc.addObserver(self, selector: #selector(resumeAudio), name: UIApplication.willResignActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(resumeAudio), name: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil)
        nc.addObserver(self, selector: #selector(resumeAudio), name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)

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
        pushVolume()
        for d in [0.0, 0.12, 0.35, 0.8, 1.5, 3.0, 5.0] {
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

    // MARK: - Volumen

    private func handleVolume(_ body: Any) {
        var value: Float?
        if let dict = body as? [String: Any], let n = dict["v"] as? NSNumber { value = n.floatValue }
        else if let n = body as? NSNumber { value = n.floatValue }
        guard let v = value else { return }
        let clamped = min(1, max(0, v))
        DispatchQueue.main.async { [weak self] in
            guard let slider = self?.volumeView.subviews.compactMap({ $0 as? UISlider }).first else { return }
            slider.value = clamped
            slider.sendActions(for: .valueChanged)
        }
    }

    /// Envía a la web el volumen actual del sistema para que la barra coincida.
    private func pushVolume(_ v: Float? = nil) {
        let vol = v ?? AVAudioSession.sharedInstance().outputVolume
        DispatchQueue.main.async { [weak self] in
            self?.webView.evaluateJavaScript("window.qmSysVol&&window.qmSysVol(\(vol))", completionHandler: nil)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pushVolume()
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

/// Evita que WKUserContentController retenga al ViewController.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    private let onMessage: (Any) -> Void
    init(_ onMessage: @escaping (Any) -> Void) { self.onMessage = onMessage }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        onMessage(message.body)
    }
}
