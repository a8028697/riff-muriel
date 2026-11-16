import UIKit
import AVFoundation
import MediaPlayer
import WebKit
import Capacitor

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Music app: keep playing with the screen locked or the app in the background,
        // and ignore the silent switch. The session is not activated here: that would stop other
        // apps' audio the moment Muriel opens; WebKit activates it when a song starts.
        // "Play over games" (Settings → Tracks → Playback): mix with other apps' audio instead of stopping it.
        let mix = UserDefaults.standard.bool(forKey: "murielMixWithOthers")
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: mix ? [.mixWithOthers] : [])
        return true
    }

    func applicationWillResignActive(_ application: UIApplication) {
        // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
        // Use this method to pause ongoing tasks, disable timers, and invalidate graphics rendering callbacks. Games should use this method to pause the game.
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
        // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        // Called as part of the transition from the background to the active state; here you can undo many of the changes made on entering the background.
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // the lyrics Live Activity can't follow the song once the app is gone
        #if canImport(ActivityKit)
        if #available(iOS 16.2, *) { LyricsActivity.shared.endAllBeforeExit() }
        #endif
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default Configuration",
                                          sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}


// Muriel's web view. WebKit has a (private) preference that mutes a page's audio while the page
// is hidden: playback keeps "running" and shows on the lock screen, but nothing is audible once the
// app is backgrounded or the phone is locked. Turn it off, if this iOS version has it.
class MurielBridgeViewController: CAPBridgeViewController {
    override open func webViewConfiguration(for instanceConfiguration: InstanceConfiguration) -> WKWebViewConfiguration {
        let config = super.webViewConfiguration(for: instanceConfiguration)
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        if config.preferences.responds(to: NSSelectorFromString("_setRequiresPageVisibilityToPlayAudio:")) {
            config.preferences.setValue(false, forKey: "requiresPageVisibilityToPlayAudio")
        }
        return config
    }

    // plugins that live in the app itself (not in an npm package) are registered by hand
    override open func capacitorDidLoad() {
        bridge?.registerPluginInstance(MurielLiveActivityPlugin())
        bridge?.registerPluginInstance(MurielAudioSessionPlugin())
        bridge?.registerPluginInstance(MurielNativePlayerPlugin())
    }
}

// Another app's sound (a call, Siri, a video) interrupting Muriel: the page (mobile/audio-interruption.js) is
// told when it starts and when it ends, and whether iOS says to play again, so a song that was playing starts
// again like it does in Spotify (#26). Paused in the background the app is suspended soon after; iOS wakes it
// for the end of the interruption, and a short background task keeps it awake until the page has asked the
// song to play again (or a lock screen play has arrived).
@objc(MurielAudioSessionPlugin)
public class MurielAudioSessionPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "MurielAudioSessionPlugin"
    public let jsName = "MurielAudioSession"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "setMix", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getMix", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getState", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "reactivate", returnType: CAPPluginReturnPromise)
    ]
    private var awake: UIBackgroundTaskIdentifier = .invalid
    private var awakeEnd: DispatchWorkItem?

    // "Play over games": mix with other apps' audio (on) or take over the audio like a normal music app (off)
    @objc func setMix(_ call: CAPPluginCall) {
        let on = call.getBool("enabled") ?? false
        UserDefaults.standard.set(on, forKey: "murielMixWithOthers")
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: on ? [.mixWithOthers] : [])
            call.resolve(["enabled": on])
        } catch {
            call.reject("setCategory failed")
        }
    }

    @objc func getMix(_ call: CAPPluginCall) {
        call.resolve(["enabled": UserDefaults.standard.bool(forKey: "murielMixWithOthers")])
    }

    // what the system really has right now (for the status line under "Play over games")
    @objc func getState(_ call: CAPPluginCall) {
        let s = AVAudioSession.sharedInstance()
        call.resolve([
            "category": s.category.rawValue,
            "mix": s.categoryOptions.contains(.mixWithOthers),
            "otherAudio": s.isOtherAudioPlaying
        ])
    }

    // after another app (a game) cut Muriel off: take the audio session back, mixing with it, so playback can start again
    @objc func reactivate(_ call: CAPPluginCall) {
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try s.setActive(true)
            call.resolve(["ok": true])
        } catch {
            call.resolve(["ok": false, "error": error.localizedDescription])
        }
    }

    override public func load() {
        // WebKit may reset the audio session when a song starts: while "Play over games" is on, put the mix option back
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            guard UserDefaults.standard.bool(forKey: "murielMixWithOthers") else { return }
            let s = AVAudioSession.sharedInstance()
            if !s.categoryOptions.contains(.mixWithOthers) {
                try? s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            }
            // experiment: keep the Control Center / Dynamic Island card at 0:01 and "playing" (like an old MixerBox bug
            // that games could not silence); whoever sets the info (WebKit or the native player) gets overwritten each second
            let center = MPNowPlayingInfoCenter.default()
            if var info = center.nowPlayingInfo {
                info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = 1.0
                info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
                center.nowPlayingInfo = info
            }
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let self = self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            switch type {
            case .began:
                if UserDefaults.standard.bool(forKey: "murielMixWithOthers") { self.stayAwake(seconds: 20) }
                self.notifyListeners("interruption", data: ["type": "began"])
            case .ended:
                let opts = AVAudioSession.InterruptionOptions(rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
                self.stayAwake(seconds: 20)
                self.notifyListeners("interruption", data: ["type": "ended", "shouldResume": opts.contains(.shouldResume)])
            @unknown default:
                break
            }
        }
    }

    // once the song plays again iOS keeps the app running by itself; this only bridges the moment until then
    private func stayAwake(seconds: Double) {
        if awake == .invalid {
            awake = UIApplication.shared.beginBackgroundTask(withName: "MurielInterruptionEnd") { [weak self] in self?.endAwake() }
        }
        awakeEnd?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.endAwake() }
        awakeEnd = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func endAwake() {
        awakeEnd?.cancel()
        awakeEnd = nil
        guard awake != .invalid else { return }
        UIApplication.shared.endBackgroundTask(awake)
        awake = .invalid
    }
}


// Native player (Settings → Tracks → Playback → "Native player"). The song is played by AVPlayer inside the app
// instead of the web view's <audio>, so iOS treats Muriel like any other music app (and our audio session settings,
// like "Play over games", apply to it exactly). The page keeps its player object and forwards to this plugin
// (mobile-ui.js), so the rest of the app does not change. There is no Web Audio chain in this mode: no equalizer or effects.
@objc(MurielNativePlayerPlugin)
public class MurielNativePlayerPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "MurielNativePlayerPlugin"
    public let jsName = "MurielNativePlayer"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "load", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "play", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "pause", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "seek", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stop", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setVolume", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setRate", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setNowPlaying", returnType: CAPPluginReturnPromise)
    ]

    private var player: AVPlayer?
    private var item: AVPlayerItem?
    private var loadId = 0
    private var timeObserver: Any?
    private var observers: [NSKeyValueObservation] = []
    private var endObserver: NSObjectProtocol?
    private var stallObserver: NSObjectProtocol?
    private var volume: Float = 1
    private var rate: Float = 1
    private var preservePitch = true
    private var remoteReady = false

    // every event goes to the page on one channel; "id" lets the page ignore events of a song it already left
    private func emit(_ name: String, _ extra: [String: Any] = [:]) {
        var data: [String: Any] = ["name": name, "id": loadId]
        for (k, v) in extra { data[k] = v }
        if Thread.isMainThread {
            notifyListeners("evt", data: data)
        } else {
            DispatchQueue.main.async { [weak self] in self?.notifyListeners("evt", data: data) }
        }
    }

    private func finite(_ v: Double) -> Double { v.isFinite ? v : 0 }

    private func teardown() {
        if let o = timeObserver { player?.removeTimeObserver(o) }
        timeObserver = nil
        observers.forEach { $0.invalidate() }
        observers.removeAll()
        if let e = endObserver { NotificationCenter.default.removeObserver(e) }
        if let s = stallObserver { NotificationCenter.default.removeObserver(s) }
        endObserver = nil
        stallObserver = nil
        player?.pause()
        player = nil
        item = nil
    }

    @objc func load(_ call: CAPPluginCall) {
        guard let s = call.getString("url"), !s.isEmpty else { call.reject("no url"); return }
        let id = call.getInt("id") ?? 0
        let headers = call.options["headers"] as? [String: String]
        DispatchQueue.main.async {
            self.teardown()
            self.loadId = id
            let url: URL
            if s.hasPrefix("/") {
                url = URL(fileURLWithPath: s)
            } else if let u = URL(string: s) {
                url = u
            } else {
                call.reject("bad url")
                return
            }
            var options: [String: Any]? = nil
            if let h = headers, !h.isEmpty { options = ["AVURLAssetHTTPHeaderFieldsKey": h] }
            let asset = AVURLAsset(url: url, options: options)
            let item = AVPlayerItem(asset: asset)
            item.audioTimePitchAlgorithm = self.preservePitch ? .spectral : .varispeed
            let player = AVPlayer(playerItem: item)
            player.automaticallyWaitsToMinimizeStalling = true
            player.volume = self.volume
            player.defaultRate = self.rate
            self.player = player
            self.item = item
            self.observe(player, item)
            self.setupRemote()
            call.resolve()
        }
    }

    private func observe(_ player: AVPlayer, _ item: AVPlayerItem) {
        observers.append(item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self = self else { return }
            switch item.status {
            case .readyToPlay:
                let d = item.duration.seconds
                self.emit("meta", ["d": d.isFinite ? d : -1])
            case .failed:
                self.emit("error", ["message": item.error?.localizedDescription ?? "failed"])
            default:
                break
            }
        })
        observers.append(item.observe(\.duration, options: [.new]) { [weak self] item, _ in
            let d = item.duration.seconds
            if d.isFinite && d > 0 { self?.emit("duration", ["d": d]) }
        })
        observers.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            switch p.timeControlStatus {
            case .playing: self?.emit("playing")
            case .waitingToPlayAtSpecifiedRate: self?.emit("waiting")
            case .paused: self?.emit("paused")
            @unknown default: break
            }
        })
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
            guard let self = self, let it = self.item else { return }
            let d = it.duration.seconds
            self.emit("time", ["t": self.finite(t.seconds), "d": d.isFinite ? d : -1, "rate": Double(self.player?.rate ?? 0)])
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            self?.emit("ended")
        }
        stallObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main) { [weak self] _ in
            self?.emit("stalled")
        }
    }

    @objc func play(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            try? AVAudioSession.sharedInstance().setActive(true)
            self.player?.play()
            call.resolve()
        }
    }

    @objc func pause(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.player?.pause()
            call.resolve()
        }
    }

    @objc func seek(_ call: CAPPluginCall) {
        let t = call.getDouble("time") ?? 0
        DispatchQueue.main.async {
            guard let p = self.player else { call.resolve(); return }
            p.seek(to: CMTime(seconds: max(0, t), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                call.resolve()
            }
        }
    }

    @objc func stop(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.teardown()
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            call.resolve()
        }
    }

    @objc func setVolume(_ call: CAPPluginCall) {
        let v = Float(min(1, max(0, call.getDouble("volume") ?? 1)))
        DispatchQueue.main.async {
            self.volume = v
            self.player?.volume = v
            call.resolve()
        }
    }

    @objc func setRate(_ call: CAPPluginCall) {
        let r = Float(min(4, max(0.1, call.getDouble("rate") ?? 1)))
        let keepPitch = call.getBool("preservePitch") ?? true
        DispatchQueue.main.async {
            self.rate = r
            self.preservePitch = keepPitch
            self.item?.audioTimePitchAlgorithm = keepPitch ? .spectral : .varispeed
            self.player?.defaultRate = r
            if let p = self.player, p.timeControlStatus != .paused { p.rate = r }
            call.resolve()
        }
    }

    // title / artist / position for the lock screen and Control Center (the page sends them; no artwork yet)
    @objc func setNowPlaying(_ call: CAPPluginCall) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: call.getString("title") ?? "",
            MPMediaItemPropertyArtist: call.getString("artist") ?? "",
            MPMediaItemPropertyAlbumTitle: call.getString("album") ?? "",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: call.getDouble("position") ?? 0,
            MPNowPlayingInfoPropertyPlaybackRate: call.getDouble("rate") ?? 0
        ]
        if let d = call.getDouble("duration"), d > 0 { info[MPMediaItemPropertyPlaybackDuration] = d }
        DispatchQueue.main.async {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            call.resolve()
        }
    }

    // lock screen / Control Center / headphone buttons: forwarded to the page, which runs its own play / next / previous
    private func remote(_ data: [String: Any]) {
        DispatchQueue.main.async { [weak self] in self?.notifyListeners("remote", data: data) }
    }

    private func setupRemote() {
        if remoteReady { return }
        remoteReady = true
        let rc = MPRemoteCommandCenter.shared()
        let map: [(MPRemoteCommand, String)] = [
            (rc.playCommand, "play"),
            (rc.pauseCommand, "pause"),
            (rc.togglePlayPauseCommand, "toggle"),
            (rc.nextTrackCommand, "next"),
            (rc.previousTrackCommand, "prev")
        ]
        for (cmd, name) in map {
            cmd.isEnabled = true
            cmd.addTarget { [weak self] _ in
                self?.remote(["action": name])
                return .success
            }
        }
        rc.changePlaybackPositionCommand.isEnabled = true
        rc.changePlaybackPositionCommand.addTarget { [weak self] event in
            if let e = event as? MPChangePlaybackPositionCommandEvent {
                self?.remote(["action": "seek", "time": e.positionTime])
            }
            return .success
        }
    }
}