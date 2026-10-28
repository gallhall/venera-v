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
    return AppContentWidth(
      maxWidth: 800,
      child: SmoothCustomScrollView(
        slivers: [
          SliverAppbar(title: Text("About".tl)),
          SliverToBoxAdapter(
            child: AppCard(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: const Image(
                      image: AssetImage('assets/app_icon.png'),
                      width: 72,
                      height: 72,
                      filterQuality: FilterQuality.medium,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'venera-v',
                    style: ts.s18.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  AppBadge('V${App.version}'),
                  const SizedBox(height: 8),
                  Text(
                    'venera-v is a free and open-source app for comics and videos.'
                        .tl,
                    textAlign: TextAlign.center,
                    style: ts.s14.copyWith(
                      color: context.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          _SettingsGroup(
            children: [
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
              ),
              _SwitchSetting(
                title: "Check for updates on startup".tl,
                settingKey: "checkUpdateOnStart",
              ),
              ListTile(
                leading: const AppIconBox(Icons.code, size: 36),
                title: const Text("Github"),
                trailing: const Icon(Icons.open_in_new),
                onTap: () {
                  launchUrlString("https://github.com/gallhall/venera-v");
                },
              ),
              ListTile(
                leading: const AppIconBox(Icons.send_outlined, size: 36),
                title: const Text("Telegram"),
                trailing: const Icon(Icons.open_in_new),
                onTap: () {
                  launchUrlString("https://t.me/VeneraV_Updates");
                },
              ),
            ],
          ),
          SliverToBoxAdapter(
            child: SizedBox(height: context.padding.bottom + 16),
          ),
        ],
      ),
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

Future<void> checkUpdateUi([
  bool showMessageIfNoUpdate = true,
  bool delay = false,
]) async {
  try {
    var value = await checkUpdate();
    if (value) {
      if (delay) {
        await Future.delayed(const Duration(seconds: 2));
      }
      showDialog(
        context: App.rootContext,
        builder: (context) {
          return AppSurfaceDialog(
            title: "New version available".tl,
            content: Text(
              "A new version is available. Do you want to update now?".tl,
            ).paddingHorizontal(16),
            actions: [
              Button.text(
                onPressed: () {
                  Navigator.pop(context);
                  launchUrlString(
                    "https://github.com/gallhall/venera-v/releases",
                  );
                },
                child: Text("Update".tl),
              ),
            ],
          );
        },
      );
    } else if (showMessageIfNoUpdate) {
      App.rootContext.showMessage(message: "No new version available".tl);
    }
  } catch (e, s) {
    Log.error("Check Update", e.toString(), s);
  }
}
