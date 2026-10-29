part of 'settings_page.dart';

class DanmakuSettings extends StatefulWidget {
  const DanmakuSettings({super.key});

  @override
  State<DanmakuSettings> createState() => _DanmakuSettingsState();
}

class _DanmakuSettingsState extends State<DanmakuSettings> {
  late final appId = TextEditingController(
    text: appdata.settings['dandanplayAppId'] as String? ?? '',
  );
  late final secret = TextEditingController(
    text: appdata.settings['dandanplayAppSecret'] as String? ?? '',
  );

  /// With built-in credentials, the user's own are optional and hidden
  /// until asked for (or already entered).
  late bool showOwn = !DanDanPlayApi.hasBuiltInCredentials ||
      appId.text.isNotEmpty ||
      secret.text.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final builtIn = DanDanPlayApi.hasBuiltInCredentials;
    return SmoothCustomScrollView(slivers: [
      SliverAppbar(title: Text('Danmaku'.tl)),
      _SettingsGroup(children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('DanDanPlay credentials'.tl, style: ts.s16),
              if (builtIn) ...[
                const SizedBox(height: 8),
                Text('This build has DanDanPlay credentials built in'.tl),
              ],
              if (builtIn && !showOwn)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () => setState(() => showOwn = true),
                    child: Text('Use my own credentials'.tl),
                  ),
                ),
              if (showOwn) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: appId,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: 'DanDanPlay App ID'.tl,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: secret,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: 'DanDanPlay App Secret'.tl,
                  ),
                ),
                if (builtIn) ...[
                  const SizedBox(height: 12),
                  Text('Empty fields use build-time DanDanPlay credentials'.tl),
                ],
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () async {
                    appdata.settings['dandanplayAppId'] = appId.text.trim();
                    appdata.settings['dandanplayAppSecret'] =
                        secret.text.trim();
                    await appdata.saveData();
                    if (context.mounted) {
                      context.showMessage(message: 'Saved'.tl);
                    }
                  },
                  child: Text('Save'.tl),
                ),
              ],
            ],
          ),
        ),
      ]),
    ]);
  }

  @override
  void dispose() {
    appId.dispose();
    secret.dispose();
    super.dispose();
  }
}
