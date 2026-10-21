import AVFoundation
import AVKit
import Flutter
import UIKit

/// Plays videos with AVPlayer. In the Flutter page, the platform view
/// `venera/native_player_view` shows only the video, under the app's own
/// controls; `enterFullscreen` presents the system player
/// (AVPlayerViewController) with its controls over the page. Driven by
/// `NativeVideoPlayer` in lib/foundation/video/native_player.dart.
///
/// Methods on `venera/native_player`:
///   open {url, headers, startMs?, title, rate, actions}
///   update {title, actions}   actions: [{id, title, icon}]
///   play, pause, seek {ms}, setRate {rate}, enterFullscreen, close
/// Events on `venera/native_player/events`, as {event, ...}:
///   position {ms, bufferMs}, duration {ms}, playing {value},
///   buffering {value}, rate {value} (only for a speed picked in the system
///   player), fullscreen {value}, completed, error {message}, action {id}
class NativeVideoPlayer: NSObject, FlutterStreamHandler, AVPlayerViewControllerDelegate {
  private weak var host: FlutterViewController?

  private var events: FlutterEventSink?

  private let player = AVPlayer()

  /// The video in the page.
  private var controller: AVPlayerViewController?

  /// The system player while it is presented fullscreen.
  private var fullscreenController: PlayerViewController?

  /// Set while the speed is changed from Flutter, which knows it already.
  private var settingRate = false

  private var itemObservers: [NSKeyValueObservation] = []

  private var playerObservers: [NSKeyValueObservation] = []

  private var notificationObservers: [NSObjectProtocol] = []

  private var timeObserver: Any?

  private var rate: Float = 1

  private var title = ""

  private var actions: [[String: String]] = []

  /// Seeked to once the item is ready.
  private var pendingStart: CMTime?

  init(host: FlutterViewController) {
    self.host = host
    super.init()
    let methods = FlutterMethodChannel(
      name: "venera/native_player", binaryMessenger: host.binaryMessenger)
    methods.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    FlutterEventChannel(
      name: "venera/native_player/events", binaryMessenger: host.binaryMessenger
    ).setStreamHandler(self)

    playerObservers.append(
      player.observe(\.rate, options: [.new]) { [weak self] player, _ in
        self?.send("playing", ["value": player.rate != 0])
      })
    if #available(iOS 16.0, *) {
      // The speed picked in the player's own menu.
      playerObservers.append(
        player.observe(\.defaultRate, options: [.new]) { [weak self] player, _ in
          guard let self, !self.settingRate else { return }
          self.rate = player.defaultRate
          self.send("rate", ["value": Double(player.defaultRate)])
        })
    }
    playerObservers.append(
      player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
        self?.send(
          "buffering", ["value": player.timeControlStatus == .waitingToPlayAtSpecifiedRate])
      })
    timeObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(value: 1, timescale: 2), queue: .main
    ) { [weak self] time in
      guard let self, self.player.currentItem != nil else { return }
      self.send(
        "position", ["ms": Self.milliseconds(time), "bufferMs": self.bufferedMilliseconds()])
    }
  }

  deinit {
    if let timeObserver { player.removeTimeObserver(timeObserver) }
  }

  // MARK: FlutterStreamHandler

  func onListen(withArguments arguments: Any?, eventSink: @escaping FlutterEventSink)
    -> FlutterError?
  {
    events = eventSink
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    events = nil
    return nil
  }

  private func send(_ event: String, _ data: [String: Any] = [:]) {
    var map = data
    map["event"] = event
    // Key-value observations may come from other threads.
    if Thread.isMainThread {
      events?(map)
    } else {
      DispatchQueue.main.async { [weak self] in self?.events?(map) }
    }
  }

  private static func milliseconds(_ time: CMTime) -> Int {
    let seconds = CMTimeGetSeconds(time)
    return seconds.isFinite ? Int(seconds * 1000) : 0
  }

  /// End of the loaded range at the current position.
  private func bufferedMilliseconds() -> Int {
    guard let item = player.currentItem else { return 0 }
    let now = player.currentTime()
    for value in item.loadedTimeRanges {
      let range = value.timeRangeValue
      if range.containsTime(now) || CMTimeCompare(range.start, now) > 0 {
        return Self.milliseconds(CMTimeRangeGetEnd(range))
      }
    }
    return 0
  }

  // MARK: Methods

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "open":
      guard let url = args["url"] as? String, let parsed = Self.parseUrl(url) else {
        result(FlutterError(code: "url", message: "Invalid url", details: nil))
        return
      }
      update(args)
      if let r = args["rate"] as? Double { rate = Float(r) }
      var start: CMTime?
      if let ms = args["startMs"] as? Int, ms > 0 {
        start = CMTime(value: CMTimeValue(ms), timescale: 1000)
      }
      open(parsed, headers: args["headers"] as? [String: String] ?? [:], start: start)
      result(nil)
    case "update":
      update(args)
      result(nil)
    case "play":
      play()
      result(nil)
    case "pause":
      player.pause()
      result(nil)
    case "seek":
      let ms = args["ms"] as? Int ?? 0
      player.seek(
        to: CMTime(value: CMTimeValue(ms), timescale: 1000),
        toleranceBefore: .zero, toleranceAfter: .zero)
      result(nil)
    case "setRate":
      rate = Float(args["rate"] as? Double ?? 1)
      settingRate = true
      if #available(iOS 16.0, *) { player.defaultRate = rate }
      if player.rate != 0 { player.rate = rate }
      settingRate = false
      result(nil)
    case "enterFullscreen":
      enterFullscreen()
      result(nil)
    case "close":
      close()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func parseUrl(_ url: String) -> URL? {
    if url.hasPrefix("/") { return URL(fileURLWithPath: url) }
    return URL(string: url)
      ?? url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed).flatMap {
        URL(string: $0)
      }
  }

  private func update(_ args: [String: Any]) {
    if let t = args["title"] as? String { title = t }
    if let a = args["actions"] as? [[String: String]] { actions = a }
    if let item = player.currentItem { item.externalMetadata = metadata() }
    applyActions()
  }

  private func play() {
    if #available(iOS 16.0, *) {
      player.defaultRate = rate
      player.play()
    } else {
      player.playImmediately(atRate: rate)
    }
  }

  private func open(_ url: URL, headers: [String: String], start: CMTime?) {
    var options: [String: Any] = [:]
    if !headers.isEmpty { options["AVURLAssetHTTPHeaderFieldsKey"] = headers }
    let item = AVPlayerItem(asset: AVURLAsset(url: url, options: options))
    item.externalMetadata = metadata()
    pendingStart = start
    observe(item)
    player.replaceCurrentItem(with: item)
    activateAudioSession()
    play()
  }

  private func metadata() -> [AVMetadataItem] {
    let item = AVMutableMetadataItem()
    item.identifier = .commonIdentifierTitle
    item.value = title as NSString
    item.extendedLanguageTag = "und"
    return [item]
  }

  private func observe(_ item: AVPlayerItem) {
    itemObservers.removeAll()
    for o in notificationObservers { NotificationCenter.default.removeObserver(o) }
    notificationObservers.removeAll()

    itemObservers.append(
      item.observe(\.status, options: [.new]) { [weak self] item, _ in
        DispatchQueue.main.async { self?.statusChanged(item) }
      })
    itemObservers.append(
      item.observe(\.duration, options: [.new]) { [weak self] item, _ in
        DispatchQueue.main.async {
          guard let self, item === self.player.currentItem else { return }
          let ms = Self.milliseconds(item.duration)
          if ms > 0 { self.send("duration", ["ms": ms]) }
        }
      })
    notificationObservers.append(
      NotificationCenter.default.addObserver(
        forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
      ) { [weak self] _ in
        self?.send("completed")
      })
    notificationObservers.append(
      NotificationCenter.default.addObserver(
        forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
      ) { [weak self] note in
        let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
        self?.send("error", ["message": error?.localizedDescription ?? "Playback failed"])
      })
  }

  private func statusChanged(_ item: AVPlayerItem) {
    guard item === player.currentItem else { return }
    switch item.status {
    case .readyToPlay:
      if let start = pendingStart {
        pendingStart = nil
        player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero)
      }
      let ms = Self.milliseconds(item.duration)
      if ms > 0 { send("duration", ["ms": ms]) }
    case .failed:
      send("error", ["message": Self.describe(item.error)])
    default:
      break
    }
  }

  private static func describe(_ error: Error?) -> String {
    guard let error = error as NSError? else { return "Playback failed" }
    var parts = [error.localizedDescription]
    if let reason = error.localizedFailureReason { parts.append(reason) }
    if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
      parts.append("\(underlying.domain) \(underlying.code)")
    }
    return parts.joined(separator: " · ")
  }

  private func activateAudioSession() {
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playback, mode: .moviePlayback)
    try? session.setActive(true)
  }

  // MARK: Views

  /// Embeds the video in [container], a platform view of the Flutter page.
  /// The page draws its own controls over it.
  fileprivate func attach(to container: UIView) -> AVPlayerViewController? {
    guard let host else { return nil }
    let vc = AVPlayerViewController()
    // Also while fullscreen, so the page shows the video when the
    // fullscreen player shrinks back into it.
    vc.player = player
    vc.showsPlaybackControls = false
    // Its Live Text button would sit under the page's controls, which take
    // all touches. The fullscreen player keeps it.
    if #available(iOS 16.0, *) { vc.allowsVideoFrameAnalysis = false }
    vc.view.isUserInteractionEnabled = false
    vc.view.backgroundColor = .black
    host.addChild(vc)
    vc.view.frame = container.bounds
    vc.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    container.addSubview(vc.view)
    vc.didMove(toParent: host)
    controller = vc
    return vc
  }

  /// Presents the system player with its controls over the page; the
  /// `fullscreen` event says when it is closed.
  private func enterFullscreen() {
    guard let host, fullscreenController == nil, player.currentItem != nil else { return }
    let vc = PlayerViewController()
    vc.player = player
    vc.delegate = self
    vc.allowsPictureInPicturePlayback = true
    vc.modalPresentationStyle = .fullScreen
    // Grows out of the video in the page and shrinks back into it, with
    // the system zoom transition (iOS 18), like fullscreen in Safari.
    // Only the close button leaves fullscreen: the transition's swipe and
    // pinch to dismiss would catch touches meant for the player.
    if #available(iOS 18.0, *) {
      let options = UIViewController.Transition.ZoomOptions()
      options.interactiveDismissShouldBegin = { _ in false }
      vc.preferredTransition = .zoom(options: options) { [weak self] _ in
        self?.controller?.view
      }
    } else {
      vc.modalTransitionStyle = .crossDissolve
    }
    vc.onDismiss = { [weak self] in self?.fullscreenClosed() }
    var presenter: UIViewController = host
    while let presented = presenter.presentedViewController { presenter = presented }
    fullscreenController = vc
    applyActions()
    presenter.present(vc, animated: true)
    send("fullscreen", ["value": true])
  }

  private func fullscreenClosed() {
    fullscreenController = nil
    send("fullscreen", ["value": false])
  }

  fileprivate func detach(_ vc: AVPlayerViewController) {
    vc.willMove(toParent: nil)
    vc.view.removeFromSuperview()
    vc.removeFromParent()
    if controller === vc { controller = nil }
  }

  /// Stops playback, e.g. when the page closes or another engine takes over.
  private func close() {
    fullscreenController?.dismiss(animated: true)
    player.pause()
    itemObservers.removeAll()
    for o in notificationObservers { NotificationCenter.default.removeObserver(o) }
    notificationObservers.removeAll()
    player.replaceCurrentItem(with: nil)
    pendingStart = nil
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  private func applyActions() {
    fullscreenController?.setActions(actions) { [weak self] id in
      self?.send("action", ["id": id])
    }
  }

  // MARK: AVPlayerViewControllerDelegate

  func playerViewController(
    _ playerViewController: AVPlayerViewController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler:
      @escaping (Bool) -> Void
  ) {
    // The page with the player is still there.
    completionHandler(true)
  }
}

/// The platform view `venera/native_player_view`.
class NativePlayerViewFactory: NSObject, FlutterPlatformViewFactory {
  private let owner: NativeVideoPlayer

  init(owner: NativeVideoPlayer) {
    self.owner = owner
    super.init()
  }

  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?)
    -> FlutterPlatformView
  {
    NativePlayerPlatformView(owner: owner, frame: frame)
  }
}

private class NativePlayerPlatformView: NSObject, FlutterPlatformView {
  private let container: UIView

  private weak var owner: NativeVideoPlayer?

  private var controller: AVPlayerViewController?

  init(owner: NativeVideoPlayer, frame: CGRect) {
    self.owner = owner
    container = UIView(frame: frame)
    container.backgroundColor = .black
    super.init()
    controller = owner.attach(to: container)
  }

  deinit {
    if let controller {
      let owner = owner
      DispatchQueue.main.async { owner?.detach(controller) }
    }
  }

  func view() -> UIView { container }
}

/// The fullscreen system player. Shows the buttons from Flutter (a skip
/// button) over the video: AVPlayerViewController has no API for them on iOS.
private class PlayerViewController: AVPlayerViewController {
  private let actionBar = UIStackView()

  private var onPressed: ((String) -> Void)?

  /// Called once the player is closed, with its close button or a swipe.
  var onDismiss: (() -> Void)?

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if isBeingDismissed || presentingViewController == nil {
      onDismiss?()
      onDismiss = nil
    }
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    actionBar.axis = .horizontal
    actionBar.spacing = 12
    actionBar.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(actionBar)
    NSLayoutConstraint.activate([
      actionBar.trailingAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
      actionBar.bottomAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -56),
    ])
  }

  @objc private func buttonPressed(_ button: UIButton) {
    if let id = button.accessibilityIdentifier { onPressed?(id) }
  }

  func setActions(_ actions: [[String: String]], onPressed: @escaping (String) -> Void) {
    self.onPressed = onPressed
    loadViewIfNeeded()
    for v in actionBar.arrangedSubviews { v.removeFromSuperview() }
    for action in actions {
      let id = action["id"] ?? ""
      let button = UIButton(type: .system)
      button.setTitle(" " + (action["title"] ?? id), for: .normal)
      button.setImage(action["icon"].flatMap { UIImage(systemName: $0) }, for: .normal)
      button.tintColor = .white
      button.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
      button.backgroundColor = UIColor.black.withAlphaComponent(0.55)
      button.layer.cornerRadius = 18
      button.heightAnchor.constraint(equalToConstant: 36).isActive = true
      button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
      button.accessibilityIdentifier = id
      button.addTarget(self, action: #selector(buttonPressed(_:)), for: .touchUpInside)
      actionBar.addArrangedSubview(button)
    }
  }
}
