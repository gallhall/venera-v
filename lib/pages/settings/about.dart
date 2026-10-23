part of 'settings_page.dart';

class AboutSettings extends StatefulWidget {
  const AboutSettings({super.key});

  @override
  State<AboutSettings> createState() => _AboutSettingsState();
}

class _AboutSettingsState extends State<AboutSettings> {
  bool isCheckingUpdate = false;

  @override
  Widget build(BuildContext context) {
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text("About".tl)),
        SizedBox(
          height: 112,
          width: double.infinity,
          child: Center(
            child: Container(
              width: 112,
              height: 112,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(136),
              ),
              clipBehavior: Clip.antiAlias,
              child: const Image(
                image: AssetImage("assets/app_icon.png"),
                filterQuality: FilterQuality.medium,
              ),
            ),
          ),
        ).paddingTop(16).toSliver(),
        Column(
          children: [
            const SizedBox(height: 8),
            Text(
              "V${App.version}",
              style: const TextStyle(fontSize: 16),
            ),
            Text("venera-v is a free and open-source app for comics and videos.".tl),
            const SizedBox(height: 8),
          ],
        ).toSliver(),
        ListTile(
          title: Text("Check for updates".tl),
          trailing: Button.filled(
            isLoading: isCheckingUpdate,
            child: Text("Check".tl),
            onPressed: () {
              setState(() {
                isCheckingUpdate = true;
              });
              checkUpdateUi().then((value) {
                setState(() {
                  isCheckingUpdate = false;
                });
              });
            },
          ).fixHeight(32),
        ).toSliver(),
        _SwitchSetting(
          title: "Check for updates on startup".tl,
          settingKey: "checkUpdateOnStart",
        ).toSliver(),
        ListTile(
          title: const Text("Github"),
          trailing: const Icon(Icons.open_in_new),
          onTap: () {
            launchUrlString("https://github.com/gallhall/venera-v");
          },
        ).toSliver(),
        ListTile(
          title: const Text("Telegram"),
          trailing: const Icon(Icons.open_in_new),
          onTap: () {
            launchUrlString("https://t.me/VeneraV_Updates");
          },
        ).toSliver(),
      ],
    );
  }
}

Future<bool> checkUpdate() async {
  var res = await AppDio().get<String>(latestPubspecUrl);
  if (res.statusCode == 200 && res.data != null) {
    return hasNewerVersion(res.data!, App.version);
  }
  return false;
}

Future<void> checkUpdateUi([bool showMessageIfNoUpdate = true, bool delay = false]) async {
  try {
    var value = await checkUpdate();
    if (value) {
      if (delay) {
        await Future.delayed(const Duration(seconds: 2));
      }
      showDialog(
          context: App.rootContext,
          builder: (context) {
            return ContentDialog(
              title: "New version available".tl,
              content: Text(
                      "A new version is available. Do you want to update now?"
                          .tl)
                  .paddingHorizontal(16),
              actions: [
                Button.text(
                  onPressed: () {
                    Navigator.pop(context);
                    launchUrlString(
                        "https://github.com/gallhall/venera-v/releases");
                  },
                  child: Text("Update".tl),
                ),
              ],
            );
          });
    } else if (showMessageIfNoUpdate) {
      App.rootContext.showMessage(message: "No new version available".tl);
    }
  } catch (e, s) {
    Log.error("Check Update", e.toString(), s);
  }
}
