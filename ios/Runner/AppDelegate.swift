import Flutter
import UIKit
import AVFoundation
import MediaPlayer
import UniformTypeIdentifiers
import Foundation // 添加此行
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, UIDocumentPickerDelegate {
  var flutterResult: FlutterResult?
  var directoryPath: URL!

  // 定义插件通道名称
  private var directoryPicker: DirectoryPicker?
  private var nowPlaying: NowPlayingBridge?
  private var backgroundDownloads: IosBackgroundDownloads?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    guard let controller = window?.rootViewController as? FlutterViewController else {
          fatalError("rootViewController is not of type FlutterViewController")
    }

    backgroundDownloads = IosBackgroundDownloads(messenger: controller.binaryMessenger)

    let methodChannel = FlutterMethodChannel(name: "venera/method_channel", binaryMessenger: controller.binaryMessenger)
    let thermalChannel = FlutterMethodChannel(name: "venera/thermal", binaryMessenger: controller.binaryMessenger)
    thermalChannel.setMethodCallHandler { call, result in
      guard call.method == "sample" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let status: Int
      switch ProcessInfo.processInfo.thermalState {
      case .nominal: status = 0
      case .fair: status = 1
      case .serious: status = 2
      case .critical: status = 3
      @unknown default: status = -1
      }
      result(["status": status])
    }
    nowPlaying = NowPlayingBridge(messenger: controller.binaryMessenger)
    methodChannel.setMethodCallHandler { (call, result) in
      if call.method == "getProxy" {
        if let proxySettings = CFNetworkCopySystemProxySettings()?.takeUnretainedValue() as NSDictionary?,
          let dict = proxySettings.object(forKey: kCFNetworkProxiesHTTPProxy) as? NSDictionary,
          let host = dict.object(forKey: kCFNetworkProxiesHTTPProxy) as? String,
          let port = dict.object(forKey: kCFNetworkProxiesHTTPPort) as? Int {
          let proxyConfig = "\(host):\(port)"
          result(proxyConfig)
        } else {
          result("")
        }
      } else if call.method == "getDirectoryPath" {
        self.flutterResult = result
        self.getDirectoryPath()
      } else if call.method == "stopAccessingSecurityScopedResource" {
        self.directoryPath?.stopAccessingSecurityScopedResource()
        self.directoryPath = nil
        result(nil)
      } else if call.method == "selectDirectory" {
        self.directoryPicker = DirectoryPicker()
        self.directoryPicker?.selectDirectory(result: result)
      } else if call.method == "exportFiles" {
        // Saves copies of the files where the user picks, with the system's
        // "Save to Files" picker: no access to the destination is needed.
        let paths = call.arguments as? [String] ?? []
        let urls = paths.map { URL(fileURLWithPath: $0) }
        let picker = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
        self.presentPicker(picker) { picked in result(picked != nil) }
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func application(_ application: UIApplication,
    handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void) {
    if identifier == IosBackgroundDownloads.identifier, let downloads = backgroundDownloads {
      downloads.handleEvents(completionHandler)
    } else {
      super.application(application, handleEventsForBackgroundURLSession: identifier,
        completionHandler: completionHandler)
    }
  }

  func getDirectoryPath() {
    let documentPicker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.folder], asCopy: false)
    documentPicker.delegate = self
    documentPicker.allowsMultipleSelection = false
    documentPicker.directoryURL = nil
    documentPicker.modalPresentationStyle = .formSheet

    if let rootViewController = window?.rootViewController {
      rootViewController.present(documentPicker, animated: true, completion: nil)
    }
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let url = urls.first else {
      flutterResult?(nil)
      return
    }
    // A folder of the app itself (On My iPhone > Venera-V) needs no security
    // scope, and starting one fails for it: it is still usable. Only a scope
    // that was started is stopped later.
    if url.startAccessingSecurityScopedResource() {
      self.directoryPath = url
    }
    flutterResult?(url.path)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    flutterResult?(nil)
  }

  /// The picker shown by [presentPicker], kept until it returns.
  private var pickerTask: DocumentPickerTask?

  /// Shows [picker] and calls [done] with the first picked url, or nil.
  func presentPicker(_ picker: UIDocumentPickerViewController, done: @escaping (URL?) -> Void) {
    guard var top = window?.rootViewController else {
      done(nil)
      return
    }
    while let presented = top.presentedViewController { top = presented }
    let task = DocumentPickerTask { [weak self] url in
      self?.pickerTask = nil
      done(url)
    }
    pickerTask = task
    picker.delegate = task
    picker.allowsMultipleSelection = false
    top.present(picker, animated: true)
  }
}

/// Metadata and remote commands for the media_kit player. Owns no player.
private final class NowPlayingBridge {
  private let channel: FlutterMethodChannel
  private var installedCommands = false
  private var active = false
  private var artworkPath: String?
  private var artwork: MPMediaItemArtwork?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "venera/now_playing", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(nil)
        return
      }
      switch call.method {
      case "update":
        guard let args = call.arguments as? [String: Any] else {
          result(FlutterError(code: "arguments", message: "Expected Now Playing metadata", details: nil))
          return
        }
        do {
          if !self.active {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
          }
          self.update(args)
          result(nil)
        } catch {
          result(FlutterError(code: "audio_session", message: error.localizedDescription, details: nil))
        }
      case "clear":
        self.active = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        self.setCommandsEnabled(false, previous: false, next: false)
        self.artworkPath = nil
        self.artwork = nil
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func update(_ args: [String: Any]) {
    installCommands()
    active = true
    setCommandsEnabled(true, previous: args["canPrevious"] as? Bool ?? false,
                       next: args["canNext"] as? Bool ?? false)
    var info: [String: Any] = [
      MPMediaItemPropertyTitle: args["title"] as? String ?? "",
      MPMediaItemPropertyArtist: args["artist"] as? String ?? "",
      MPMediaItemPropertyPlaybackDuration: (args["duration"] as? NSNumber)?.doubleValue ?? 0,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: (args["position"] as? NSNumber)?.doubleValue ?? 0,
      MPNowPlayingInfoPropertyPlaybackRate: (args["rate"] as? NSNumber)?.doubleValue ?? 0
    ]
    if let album = args["album"] as? String {
      info[MPMediaItemPropertyAlbumTitle] = album
    }
    let path = args["artworkPath"] as? String
    if path != artworkPath || artwork == nil {
      artworkPath = path
      artwork = nil
      if let path = path, let image = UIImage(contentsOfFile: path) {
        artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
      }
    }
    if let artwork = artwork {
      info[MPMediaItemPropertyArtwork] = artwork
    }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
  }

  private func setCommandsEnabled(_ enabled: Bool, previous: Bool, next: Bool) {
    let center = MPRemoteCommandCenter.shared()
    let commands: [MPRemoteCommand] = [
      center.playCommand, center.pauseCommand, center.togglePlayPauseCommand,
      center.changePlaybackPositionCommand, center.skipForwardCommand,
      center.skipBackwardCommand
    ]
    for command in commands {
      command.isEnabled = enabled
    }
    center.previousTrackCommand.isEnabled = enabled && previous
    center.nextTrackCommand.isEnabled = enabled && next
  }

  private func installCommands() {
    guard !installedCommands else { return }
    installedCommands = true
    let center = MPRemoteCommandCenter.shared()
    center.skipForwardCommand.preferredIntervals = [10]
    center.skipBackwardCommand.preferredIntervals = [10]
    let commands: [(MPRemoteCommand, String)] = [
      (center.playCommand, "play"), (center.pauseCommand, "pause"),
      (center.togglePlayPauseCommand, "toggle"), (center.changePlaybackPositionCommand, "seek"),
      (center.skipForwardCommand, "forward"), (center.skipBackwardCommand, "backward"),
      (center.nextTrackCommand, "next"), (center.previousTrackCommand, "previous")
    ]
    for (command, name) in commands {
      command.addTarget { [weak self] event in
        var args: [String: Any] = ["name": name]
        if let seek = event as? MPChangePlaybackPositionCommandEvent {
          args["position"] = seek.positionTime
        }
        DispatchQueue.main.async { [weak self] in
          guard let self = self, self.active else { return }
          self.channel.invokeMethod("command", arguments: args)
        }
        return .success
      }
    }
  }
}

/// Delegate of a picker shown by `AppDelegate.presentPicker`.
class DocumentPickerTask: NSObject, UIDocumentPickerDelegate {
  private var done: ((URL?) -> Void)?

  init(done: @escaping (URL?) -> Void) {
    self.done = done
  }

  private func finish(_ url: URL?) {
    done?(url)
    done = nil
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    finish(urls.first)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    finish(nil)
  }
}

/// Owns HTTP work while Flutter is suspended. Only four URLSession tasks are
/// submitted at once; the remaining requests live in our durable pending list.
/// All state and delegate calls are serialized on the main queue.
private final class IosBackgroundDownloads: NSObject, URLSessionDownloadDelegate {
  static let identifier = "venera.http.background.v1"

  private struct Job: Codable {
    var id: String
    var path: String
    var url: String
    var headers: [String: String]
    var method: String
    var body: String
    var state = "queued"
    var received: Int64 = 0
    var total: Int64 = -1
    var status = 0
    var responseHeaders = [String: [String]]()
    var error: String?
    var resumeData: Data?
  }

  private let channel: FlutterMethodChannel
  private let store: URL
  private var jobs = [String: Job]()
  private var order = [String]()
  private var active = [String: URLSessionDownloadTask]()
  private var ready = false
  private var lastEvent = Date.distantPast
  private var controlWaiters = [(Set<Int>, FlutterResult)]()
  private var pausing = Set<Int>()
  private var deliveryGeneration = 0
  private var eventsDelivered = false
  private var completionHandler: (() -> Void)?

  func handleEvents(_ completion: @escaping () -> Void) {
    eventsDelivered = false
    completionHandler = completion
  }

  private lazy var session: URLSession = {
    let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
    configuration.isDiscretionary = false
    configuration.sessionSendsLaunchEvents = true
    configuration.httpMaximumConnectionsPerHost = 4
    configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
    configuration.waitsForConnectivity = true
    return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
  }()

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "venera/ios_downloads", binaryMessenger: messenger)
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    store = support.appendingPathComponent("ios-http-jobs.json")
    super.init()
    do {
      try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
      if FileManager.default.fileExists(atPath: store.path) {
        let restored = try JSONDecoder().decode([Job].self, from: Data(contentsOf: store))
        for job in restored {
          jobs[job.id] = job
          order.append(job.id)
        }
      }
    } catch {
      NSLog("Cannot restore background downloads: %@", String(describing: error))
    }
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    session.getAllTasks { tasks in
      DispatchQueue.main.async {
        for task in tasks {
          guard let download = task as? URLSessionDownloadTask,
            let id = task.taskDescription, let job = self.jobs[id],
            job.state == "running" || job.state == "queued" else {
            task.cancel()
            continue
          }
          self.active[id] = download
          self.jobs[id]?.state = "running"
        }
        for id in self.order where self.jobs[id]?.state == "running" && self.active[id] == nil {
          self.jobs[id]?.state = "queued"
        }
        self.ready = true
        self.pump()
        self.changed()
      }
    }
  }

  private func persist() throws {
    let data = try JSONEncoder().encode(order.compactMap { jobs[$0] })
    try data.write(to: store, options: .atomic)
    // Destination files must remain writable with the screen locked after
    // the first unlock. Credentials and resume data stay in app-private storage.
    try FileManager.default.setAttributes([
      .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
    ], ofItemAtPath: store.path)
  }

  private func save() {
    do {
      try persist()
    } catch {
      NSLog("Cannot save background downloads: %@", String(describing: error))
    }
  }

  private func changed() {
    channel.invokeMethod("changed", arguments: nil)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "enqueue":
      guard let requests = call.arguments as? [[String: Any]] else {
        result(FlutterError(code: "arguments", message: "Invalid download list", details: nil))
        return
      }
      for request in requests {
        guard let id = request["id"] as? String, let path = request["path"] as? String,
          let url = request["url"] as? String, let parsed = URL(string: url),
          ["http", "https"].contains(parsed.scheme?.lowercased() ?? "") else {
          result(FlutterError(code: "arguments", message: "Invalid HTTP download", details: nil))
          return
        }
        if var old = jobs[id] {
          if old.state == "complete" && FileManager.default.fileExists(atPath: old.path) {
            continue
          }
          if old.state == "running" || old.state == "queued" {
            continue
          }
          old.state = "queued"
          old.error = nil
          let headers = request["headers"] as? [String: String] ?? [:]
          if old.headers != headers {
            old.headers = headers
            old.resumeData = nil
          }
          jobs[id] = old
        } else {
          jobs[id] = Job(id: id, path: path, url: url,
            headers: request["headers"] as? [String: String] ?? [:],
            method: request["method"] as? String ?? "GET",
            body: request["body"] as? String ?? "")
          order.append(id)
        }
      }
      do {
        try persist()
        pump()
        result(nil)
      } catch {
        result(FlutterError(code: "storage", message: String(describing: error), details: nil))
      }
    case "status":
      guard let id = call.arguments as? String, let job = jobs[id] else {
        result(nil)
        return
      }
      result(["state": job.state, "received": job.received, "total": job.total,
        "status": job.status, "headers": job.responseHeaders, "error": job.error as Any? ?? NSNull()])
    case "pause", "remove":
      guard let prefix = call.arguments as? String else { result(nil); return }
      var cancelling = Set<Int>()
      for id in order {
        guard var job = jobs[id], job.path == prefix || job.path.hasPrefix(prefix + "/") else { continue }
        if job.state == "complete" { continue }
        job.state = call.method == "remove" ? "cancelled" : "paused"
        jobs[id] = job
        if let task = active[id] {
          cancelling.insert(task.taskIdentifier)
          if !pausing.insert(task.taskIdentifier).inserted { continue }
          task.cancel { data in
            DispatchQueue.main.async {
              if self.jobs[id]?.state != "cancelled" {
                self.jobs[id]?.resumeData = data
              }
              self.pausing.remove(task.taskIdentifier)
              self.save()
              self.finishControl(task.taskIdentifier)
              self.pump()
            }
          }
        }
      }
      save()
      changed()
      if cancelling.isEmpty {
        result(nil)
      } else {
        controlWaiters.append((cancelling, result))
      }
    case "forget":
      if let id = call.arguments as? String, active[id] == nil {
        jobs.removeValue(forKey: id)
        order.removeAll { $0 == id }
        save()
      }
      result(nil)
    case "update":
      result(nil)
    case "forgetTree":
      if let prefix = call.arguments as? String {
        let forgotten = order.filter { id in
          guard let job = jobs[id] else { return false }
          return (active[id] == nil || job.state == "complete") &&
            (job.path == prefix || job.path.hasPrefix(prefix + "/"))
        }
        for id in forgotten { jobs.removeValue(forKey: id) }
        order.removeAll { jobs[$0] == nil }
        save()
      }
      result(nil)
    case "settled":
      finishDelivery()
      result(nil)
    case "requestPermission":
      // Persist the request, including denials, across process launches.
      if UserDefaults.standard.bool(forKey: "iosDownloadNotificationPermissionAsked") {
        result(nil)
        return
      }
      UserDefaults.standard.set(true, forKey: "iosDownloadNotificationPermissionAsked")
      UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, error in
        DispatchQueue.main.async {
          if let error = error {
            result(FlutterError(code: "notifications", message: String(describing: error), details: nil))
          } else {
            result(nil)
          }
        }
      }
    case "finish", "notifyFailure":
      if let values = call.arguments as? [String: Any], let title = values["title"] as? String {
        notify(title: title, text: values["text"] as? String ?? "",
          id: call.method == "finish" ? "venera.queue.complete" : "venera.queue.failed")
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func pump() {
    guard ready else { return }
    for id in order {
      if active.count >= 4 { break }
      guard var job = jobs[id], job.state == "queued", active[id] == nil,
        pausing.isEmpty,
        let url = URL(string: job.url) else { continue }
      var request = URLRequest(url: url)
      request.httpMethod = job.method
      request.allHTTPHeaderFields = job.headers
      let body = Data(base64Encoded: job.body) ?? Data()
      if !body.isEmpty { request.httpBody = body }
      // Request cookies are supplied by the app's source-aware cookie jar.
      request.httpShouldHandleCookies = false
      let task: URLSessionDownloadTask
      if let data = job.resumeData {
        task = session.downloadTask(withResumeData: data)
      } else {
        task = session.downloadTask(with: request)
        job.received = 0
      }
      task.taskDescription = id
      job.state = "running"
      jobs[id] = job
      active[id] = task
      save()
      task.resume()
    }
  }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
    guard let id = downloadTask.taskDescription else { return }
    jobs[id]?.received = totalBytesWritten
    jobs[id]?.total = totalBytesExpectedToWrite
    if UIApplication.shared.applicationState != .background &&
      Date().timeIntervalSince(lastEvent) >= 0.25 {
      lastEvent = Date()
      changed()
    }
  }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL) {
    if !ready, let id = downloadTask.taskDescription, jobs[id]?.state == "running" {
      active[id] = downloadTask
    }
    guard let id = downloadTask.taskDescription, var job = jobs[id],
      job.state == "running", active[id]?.taskIdentifier == downloadTask.taskIdentifier else { return }
    do {
      guard let response = downloadTask.response as? HTTPURLResponse else {
        throw NSError(domain: "venera.download", code: 0,
          userInfo: [NSLocalizedDescriptionKey: "Missing HTTP response"])
      }
      job.status = response.statusCode
      for (key, value) in response.allHeaderFields {
        job.responseHeaders[String(describing: key).lowercased()] = [String(describing: value)]
      }
      guard response.statusCode == 200 || response.statusCode == 206 else {
        throw NSError(domain: "venera.download", code: response.statusCode,
          userInfo: [NSLocalizedDescriptionKey: "HTTP \(response.statusCode)"])
      }
      if let range = job.headers.first(where: { $0.key.lowercased() == "range" })?.value {
        let requested = range.lowercased().replacingOccurrences(of: "bytes=", with: "")
        let returned = response.value(forHTTPHeaderField: "Content-Range")?
          .lowercased().components(separatedBy: "/").first ?? ""
        guard response.statusCode == 206,
          (requested.hasSuffix("-") ? returned.hasPrefix("bytes " + requested)
            : returned == "bytes " + requested) else {
          throw NSError(domain: "venera.download", code: 206,
            userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP byte range response"])
        }
      }
      let destination = URL(fileURLWithPath: job.path)
      let directory = destination.deletingLastPathComponent()
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try FileManager.default.setAttributes([
        .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
      ], ofItemAtPath: directory.path)
      // Never expose a partially written destination. URLSession's temporary
      // file must be moved before this delegate returns.
      let incoming = destination.appendingPathExtension("incoming")
      if FileManager.default.fileExists(atPath: incoming.path) {
        try FileManager.default.removeItem(at: incoming)
      }
      try FileManager.default.moveItem(at: location, to: incoming)
      try FileManager.default.setAttributes([
        .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
      ], ofItemAtPath: incoming.path)
      if FileManager.default.fileExists(atPath: destination.path) {
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: incoming)
      } else {
        try FileManager.default.moveItem(at: incoming, to: destination)
      }
      job.received = (try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
      job.total = job.received
      job.state = "complete"
      job.resumeData = nil
    } catch {
      job.state = "failed"
      job.error = String(describing: error)
      job.resumeData = nil
    }
    jobs[id] = job
    save()
    changed()
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if !ready, let id = task.taskDescription, jobs[id]?.state == "running",
      let download = task as? URLSessionDownloadTask {
      active[id] = download
    }
    guard let id = task.taskDescription,
      active[id]?.taskIdentifier == task.taskIdentifier else { return }
    active.removeValue(forKey: id)
    finishControl(task.taskIdentifier)
    if let error = error as NSError?, jobs[id]?.state == "running" {
      // Invalid resume data is retried once as a fresh request.
      if jobs[id]?.resumeData != nil {
        jobs[id]?.resumeData = nil
        jobs[id]?.state = "queued"
      } else {
        jobs[id]?.state = "failed"
        jobs[id]?.error = error.localizedDescription
        jobs[id]?.resumeData = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
      }
    } else if jobs[id]?.state == "running" {
      jobs[id]?.state = "failed"
      jobs[id]?.error = "The background session returned no downloaded file"
    }
    save()
    pump()
    changed()
  }

  private func finishControl(_ taskIdentifier: Int) {
    guard !pausing.contains(taskIdentifier),
      !active.values.contains(where: { $0.taskIdentifier == taskIdentifier }) else { return }
    for index in controlWaiters.indices.reversed() {
      controlWaiters[index].0.remove(taskIdentifier)
      if controlWaiters[index].0.isEmpty {
        let done = controlWaiters.remove(at: index).1
        done(nil)
      }
    }
  }

  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    // Refill and persist BEFORE releasing iOS's background wake assertion.
    pump()
    save()
    eventsDelivered = true
    changed()
    // Let Dart reconcile files and post queue/task notifications before
    // releasing the wake assertion. Flutter may still be starting after an OS
    // relaunch, so this acknowledgement has a bounded fallback.
    deliveryGeneration += 1
    let generation = deliveryGeneration
    DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
      if self.deliveryGeneration == generation { self.finishDelivery() }
    }
  }

  private func finishDelivery() {
    guard eventsDelivered, let completion = completionHandler else { return }
    completionHandler = nil
    eventsDelivered = false
    deliveryGeneration += 1
    completion()
  }

  private func notify(title: String, text: String, id: String) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = text
    content.sound = .default
    UNUserNotificationCenter.current().add(UNNotificationRequest(
      identifier: id, content: content, trigger: nil))
  }
}
