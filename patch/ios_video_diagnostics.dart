import 'dart:convert';
import 'dart:io';

// The pinned media_kit plugin's mpv video output is named libmpv in both
// modes. Expose the actual selected texture for diagnostic iOS builds.
void main(List<String> args) {
  final config = File('.dart_tool/package_config.json').absolute;
  final packages = jsonDecode(config.readAsStringSync())['packages'] as List;
  final package = packages.singleWhere((p) => p['name'] == 'media_kit_video');
  final packageRoot = Directory.fromUri(
    config.uri.resolve(package['rootUri'] as String),
  );
  final directory = packageRoot.uri.resolve('common/darwin/Classes/plugin/');

  String replace(String text, String old, String replacement) {
    if (text.contains(replacement)) return text;
    final first = text.indexOf(old);
    if (first < 0 || text.indexOf(old, first + old.length) >= 0) {
      throw StateError('The pinned media_kit iOS renderer has changed');
    }
    return text.replaceRange(first, first + old.length, replacement);
  }

  final output = File.fromUri(directory.resolve('VideoOutput.swift'));
  var outputText = output.readAsStringSync().replaceAll('\r\n', '\n');
  const register = '      that.registerTextureId()';
  outputText = replace(
    outputText,
    '  private var textureId: Int64 = -1\n',
    '  private(set) var renderMode: String?\n'
        '  private var textureId: Int64 = -1\n',
  );
  outputText = replace(
    outputText,
    '''
    DispatchQueue.main.sync { [weak self]() in
      guard let that = self else {
        return
      }
$register''',
    '''
    let selectedRenderMode = hardwareTexture == nil ? "software" : "opengl-es"
    DispatchQueue.main.sync { [weak self]() in
      guard let that = self else {
        return
      }
      that.renderMode = selectedRenderMode
$register''',
  );

  final manager = File.fromUri(directory.resolve('VideoOutputManager.swift'));
  const setSize = '  public func setSize(';
  final managerText = replace(
    manager.readAsStringSync().replaceAll('\r\n', '\n'),
    setSize,
    '''
  func renderMode(handle: Int64) -> String? {
    videoOutputs[handle]?.renderMode
  }

$setSize''',
  );

  final plugin = File.fromUri(directory.resolve('MediaKitVideoPlugin.swift'));
  const dispose = '    case "VideoOutputManager.Dispose":';
  final pluginText = replace(
    plugin.readAsStringSync().replaceAll('\r\n', '\n'),
    dispose,
    '''
    case "VideoOutputManager.GetRenderMode":
      let args = call.arguments as? [String: Any]
      guard let raw = args?["handle"] as? String, let handle = Int64(raw) else {
        result(nil)
        return
      }
      result(videoOutputManager.renderMode(handle: handle))
$dispose''',
  );

  if (args.contains('--check')) return;
  output.writeAsStringSync(outputText);
  manager.writeAsStringSync(managerText);
  plugin.writeAsStringSync(pluginText);
}
