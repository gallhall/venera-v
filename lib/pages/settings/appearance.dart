part of 'settings_page.dart';

class AppearanceSettings extends StatefulWidget {
  const AppearanceSettings({super.key});

  @override
  State<AppearanceSettings> createState() => _AppearanceSettingsState();
}

class _AppearanceSettingsState extends State<AppearanceSettings> {
  @override
  Widget build(BuildContext context) {
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text("Appearance".tl)),
        _SettingsGroup(
          children: [
            SelectSetting(
              title: "Theme Mode".tl,
              settingKey: "theme_mode",
              optionTranslation: {
                "system": "System".tl,
                "light": "Light".tl,
                "dark": "Dark".tl,
              },
              onChanged: () async {
                App.forceRebuild();
              },
            ),
            _SwitchSetting(
              title: "Pure black dark mode".tl,
              settingKey: 'pureBlackDarkMode',
              onChanged: App.forceRebuild,
            ),
            SelectSetting(
              title: "Theme Color".tl,
              settingKey: "color",
              optionTranslation: {
                "system": "System".tl,
                "red": "Red".tl,
                "pink": "Pink".tl,
                "purple": "Purple".tl,
                "green": "Green".tl,
                "orange": "Orange".tl,
                "blue": "Blue".tl,
              },
              onChanged: () async {
                await App.init();
                App.forceRebuild();
              },
            ),
          ],
        ),
        SliverToBoxAdapter(
          child: SizedBox(height: context.padding.bottom + 16),
        ),
      ],
    );
  }
}
