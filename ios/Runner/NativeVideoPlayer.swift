import AVFoundation
import AVKit
import Flutter
import MediaPlayer
import UIKit

/// Plays videos in the system player (AVPlayerViewController), presented
/// fullscreen over the Flutter view. Driven by `NativeVideoPlayer` in
/// lib/foundation/video/native_player.dart.
///
/// Methods on `venera/native_player`:
///   open {url, headers, startMs?, title, rate, actions}
///   update {title, actions}   actions: [{id, title, icon}]
///   play, pause, seek {ms}, setRate {rate}, close
/// Events on `venera/native_player/events`, as {event, ...}:
///   position {ms}, duration {ms}, playing {value}, rate {value},
///   completed, error {message}, closed {ms}, action {id}
class NativeVideoPlayer: NSObject, FlutterStreamHandler, AVPlayerViewControllerDelegate {
  private weak var host: FlutterViewController?

  private var events: FlutterEventSink?

  private let player = AVPlayer()

  private var controller: PlayerViewController?

  private var itemObservers: [NSKeyValueObservation] = []

  private var playerObservers: [NSKeyValueObservation] = []

  private var notificationObservers: [NSObjectProtocol] = []

  private var timeObserver: Any?

  private var remoteCommandTargets: [(MPRemoteCommand, Any)] = []

  private var isPictureInPicture = false

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
          self?.rate = player.defaultRate
          self?.send("rate", ["value": Double(player.defaultRate)])
        })
    }
    timeObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(value: 1, timescale: 2), queue: .main
    ) { [weak self] time in
      guard let self, self.player.currentItem != nil else { return }
      self.send("position", ["ms": Self.milliseconds(time)])
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
      if #available(iOS 16.0, *) {
        player.defaultRate = rate
      } else {
        send("rate", ["value": Double(rate)])
      }
      if player.rate != 0 { player.rate = rate }
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
    present()
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

  // MARK: Presentation

  private func present() {
    // The picture-in-picture window keeps playing the new item.
    if controller != nil || isPictureInPicture { return }
    guard let host else { return }
    let vc = PlayerViewController()
    vc.player = player
    vc.delegate = self
    vc.allowsPictureInPicturePlayback = true
    vc.modalPresentationStyle = .fullScreen
    vc.onDismiss = { [weak self, weak vc] in
      guard let self, let vc, self.controller === vc else { return }
      self.controller = nil
      if !self.isPictureInPicture { self.finish(notify: true) }
    }
    controller = vc
    applyActions()
    var top: UIViewController = host
    while let presented = top.presentedViewController { top = presented }
    top.present(vc, animated: true)
  }

  /// Closes the player from Flutter, e.g. to fall back to the other engine.
  private func close() {
    if let vc = controller {
      controller = nil
      vc.dismiss(animated: true)
    }
    finish(notify: false)
  }

  /// Playback has ended: the player and picture in picture are closed.
  /// Tells Flutter with `notify`, when the user closed it.
  private func finish(notify: Bool) {
    player.pause()
    let ms = Self.milliseconds(player.currentTime())
    let hadItem = player.currentItem != nil
    itemObservers.removeAll()
    for o in notificationObservers { NotificationCenter.default.removeObserver(o) }
    notificationObservers.removeAll()
    player.replaceCurrentItem(with: nil)
    pendingStart = nil
    applyRemoteCommands(enabled: false)
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    if notify && hadItem { send("closed", ["ms": ms]) }
  }

  private func applyActions() {
    applyRemoteCommands(enabled: controller != nil || isPictureInPicture)
    controller?.setActions(actions) { [weak self] id in
      self?.send("action", ["id": id])
    }
  }

  /// Back and forward 15 seconds from the lock screen, Control Center and
  /// headphones.
  private func applyRemoteCommands(enabled: Bool) {
    for (command, target) in remoteCommandTargets { command.removeTarget(target) }
    remoteCommandTargets.removeAll()
    let center = MPRemoteCommandCenter.shared()
    center.previousTrackCommand.isEnabled = false
    center.nextTrackCommand.isEnabled = false
    for (command, seconds) in [
      (center.skipBackwardCommand, -15.0), (center.skipForwardCommand, 15.0),
    ] {
      command.preferredIntervals = [NSNumber(value: abs(seconds))]
      command.isEnabled = enabled
      if !enabled { continue }
      let target = command.addTarget { [weak self] _ in
        guard let self, self.player.currentItem != nil else { return .noActionableNowPlayingItem }
        var time = CMTimeGetSeconds(self.player.currentTime()) + seconds
        let duration = CMTimeGetSeconds(self.player.currentItem!.duration)
        if duration.isFinite { time = min(time, duration) }
        self.player.seek(to: CMTime(seconds: max(time, 0), preferredTimescale: 1000))
        return .success
      }
      remoteCommandTargets.append((command, target))
    }
  }

  // MARK: AVPlayerViewControllerDelegate

  func playerViewControllerWillStartPictureInPicture(
    _ playerViewController: AVPlayerViewController
  ) {
    isPictureInPicture = true
  }

  func playerViewControllerDidStopPictureInPicture(
    _ playerViewController: AVPlayerViewController
  ) {
    isPictureInPicture = false
    // Closed from the picture-in-picture window, not restored.
    if controller == nil { finish(notify: true) }
  }

  func playerViewController(
    _ playerViewController: AVPlayerViewController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler:
      @escaping (Bool) -> Void
  ) {
    guard let host, let vc = playerViewController as? PlayerViewController,
      vc.presentingViewController == nil
    else {
      completionHandler(true)
      return
    }
    controller = vc
    applyActions()
    var top: UIViewController = host
    while let presented = top.presentedViewController { top = presented }
    top.present(vc, animated: true) { completionHandler(true) }
  }
}

/// Tells when the user closes the player, and shows the buttons from
/// Flutter over the video (AVPlayerViewController has no API for them on
/// iOS). A skip button stays visible; the others show on a tap, like the
/// player's own controls.
private class PlayerViewController: AVPlayerViewController, UIGestureRecognizerDelegate {
  var onDismiss: (() -> Void)?

  private let actionBar = UIStackView()

  private var hideTimer: Timer?

  private var isPinned = false

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
        equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -96),
    ])
    // Sees taps without taking them from the player's controls.
    let tap = UITapGestureRecognizer(target: self, action: #selector(onTap))
    tap.cancelsTouchesInView = false
    tap.delegate = self
    view.addGestureRecognizer(tap)
  }

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
  ) -> Bool {
    true
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch)
    -> Bool
  {
    // A tap on one of the buttons is not a tap on the video.
    !(touch.view?.isDescendant(of: actionBar) ?? false)
  }

  @objc private func onTap() {
    if isPinned { return }
    setBarVisible(actionBar.alpha == 0)
  }

  private func setBarVisible(_ visible: Bool) {
    hideTimer?.invalidate()
    UIView.animate(withDuration: 0.2) { self.actionBar.alpha = visible ? 1 : 0 }
    if visible && !isPinned {
      hideTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
        self?.setBarVisible(false)
      }
    }
  }

  private var onPressed: ((String) -> Void)?

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
    isPinned = actions.contains { $0["id"] == "skip" }
    setBarVisible(isPinned || actionBar.alpha > 0)
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if isBeingDismissed || presentingViewController == nil {
      onDismiss?()
    }
  }
}
