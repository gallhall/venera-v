import Flutter
import UIKit
import AVFoundation
import MediaPlayer
import UniformTypeIdentifiers
import Foundation // 添加此行

@main
@objc class AppDelegate: FlutterAppDelegate, UIDocumentPickerDelegate {
  var flutterResult: FlutterResult?
  var directoryPath: URL!

  // 定义插件通道名称
  private var directoryPicker: DirectoryPicker?
  private var nowPlaying: NowPlayingBridge?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    guard let controller = window?.rootViewController as? FlutterViewController else {
          fatalError("rootViewController is not of type FlutterViewController")
    }

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
