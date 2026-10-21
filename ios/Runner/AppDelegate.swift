import Flutter
import UIKit
import UniformTypeIdentifiers
import Foundation // 添加此行

@main
@objc class AppDelegate: FlutterAppDelegate, UIDocumentPickerDelegate {
  var flutterResult: FlutterResult?
  var directoryPath: URL!

  // 定义插件通道名称
  private var directoryPicker: DirectoryPicker?

  private var nativeVideoPlayer: NativeVideoPlayer?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    guard let controller = window?.rootViewController as? FlutterViewController else {
          fatalError("rootViewController is not of type FlutterViewController")
    }

    let videoPlayer = NativeVideoPlayer(host: controller)
    nativeVideoPlayer = videoPlayer
    registrar(forPlugin: "NativeVideoPlayer")?.register(
      NativePlayerViewFactory(owner: videoPlayer), withId: "venera/native_player_view")

    let methodChannel = FlutterMethodChannel(name: "venera/method_channel", binaryMessenger: controller.binaryMessenger)
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
      } else if call.method == "setScreenOn" {
        if let arguments = call.arguments as? Bool {
          let screenOn = arguments
          UIApplication.shared.isIdleTimerDisabled = screenOn
        }
        result(nil)
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
      } else if call.method == "pickFolderCopy" {
        // A copy of a folder: opening one in place fails outside the app's
        // own folders on some installs, while copies always work.
        let picker = UIDocumentPickerViewController(
          forOpeningContentTypes: [UTType.folder], asCopy: true)
        self.presentPicker(picker) { picked in result(picked?.path) }
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
