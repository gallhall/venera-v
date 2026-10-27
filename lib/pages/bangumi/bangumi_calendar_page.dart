import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/bangumi/bangumi.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/image_provider/cached_image.dart';
import 'package:venera/foundation/log.dart';
import 'bangumi_search_page.dart';
import 'bangumi_subject_page.dart';
import 'package:venera/utils/translations.dart';

const _weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

/// The anime of [day] with those the user is watching first.
List<BangumiSubject> _sorted(List<BangumiSubject> day, Set<int> watching) {
  return [
    ...day.where((s) => watching.contains(s.id)),
    ...day.where((s) => !watching.contains(s.id)),
  ];
}

class _SubjectCover extends StatelessWidget {
  const _SubjectCover({required this.subject, required this.watching});

  final BangumiSubject subject;

  final bool watching;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => context.to(
        () => BangumiSubjectPage(subjectId: subject.id, preview: subject),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: context.colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(8),
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                children: [
                  if (subject.image.isNotEmpty)
                    Positioned.fill(
                      child: AnimatedImage(
                        image: CachedImageProvider(subject.image),
                        width: double.infinity,
                        height: double.infinity,
                      ),
                    ),
                  if (watching)
                    Positioned(
                      left: 4,
                      top: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: context.colorScheme.primary,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          "Currently watching".tl,
                          style: ts.s12.copyWith(
                            color: context.colorScheme.onPrimary,
                          ),
                        ),
                      ),
                    ),
                  if (subject.score > 0)
                    Positioned(
                      right: 4,
                      bottom: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          subject.score.toStringAsFixed(1),
                          style: ts.s12.copyWith(color: Colors.white),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subject.displayName,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: ts.s12,
          ).fixHeight(32),
        ],
      ),
    );
  }
}

/// The anime airing this season on Bangumi, by weekday.
class BangumiCalendarPage extends StatefulWidget {
  const BangumiCalendarPage({super.key});

  @override
  State<BangumiCalendarPage> createState() => _BangumiCalendarPageState();
}

class _BangumiCalendarPageState extends State<BangumiCalendarPage>
    with SingleTickerProviderStateMixin {
  late final controller = TabController(
    length: 7,
    vsync: this,
    initialIndex: DateTime.now().weekday - 1,
  );

  List<List<BangumiSubject>>? calendar;

  Set<int> watching = {};

  String? error;

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Future<void> load({bool refresh = false}) async {
    setState(() => error = null);
    try {
      var calendar = await BangumiManager().calendar(refresh: refresh);
      if (mounted) setState(() => this.calendar = calendar);
    } catch (e, s) {
      Log.error('Bangumi', 'Failed to load the calendar: $e', s);
      if (mounted) setState(() => error = e.toString());
      return;
    }
    try {
      var watching = await BangumiManager().watching(refresh: refresh);
      if (mounted) setState(() => this.watching = watching);
    } catch (e) {
      Log.warning('Bangumi', 'Failed to load the anime being watched: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget body;
    var calendar = this.calendar;
    if (error != null) {
      body = NetworkError(
        message: error!,
        retry: () => load(refresh: true),
        withAppbar: false,
      );
    } else if (calendar == null) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      body = Column(
        children: [
          AppTabBar(
            controller: controller,
            tabs: [
              for (var i = 0; i < 7; i++)
                Tab(text: _weekdays[i].tl, key: Key(_weekdays[i])),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: controller,
              children: [
                for (var day in calendar) buildDay(_sorted(day, watching)),
              ],
            ),
          ),
        ],
      );
    }
    return Scaffold(
      appBar: Appbar(
        title: Text("Airing Schedule".tl),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Search anime on Bangumi'.tl,
            onPressed: () => context.to(() => const BangumiSearchPage()),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: "Refresh".tl,
            onPressed: () => load(refresh: true),
          ),
        ],
      ),
      body: body,
    );
  }

  Widget buildDay(List<BangumiSubject> day) {
    if (day.isEmpty) return Center(child: Text("Nothing airing".tl));
    return GridView.builder(
      padding: EdgeInsets.fromLTRB(8, 8, 8, context.padding.bottom + 8),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 140,
        childAspectRatio: 0.56,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: day.length,
      itemBuilder: (context, index) => _SubjectCover(
        subject: day[index],
        watching: watching.contains(day[index].id),
      ),
    );
  }
}

bool get isHomeBangumiCalendarShown =>
    appdata.settings['showBangumiCalendar'] != false &&
    ComicSource.enabled().any((s) => s.isVideoSource);

/// Today's anime on the home page, for users with video sources.
class BangumiCalendarWidget extends StatefulWidget {
  const BangumiCalendarWidget({super.key, this.onCountChanged});

  final ValueChanged<int>? onCountChanged;

  @override
  State<BangumiCalendarWidget> createState() => _BangumiCalendarWidgetState();
}

class _BangumiCalendarWidgetState extends State<BangumiCalendarWidget> {
  List<BangumiSubject>? today;

  Set<int> watching = {};

  String? error;

  bool get isShown => isHomeBangumiCalendarShown;

  @override
  void initState() {
    super.initState();
    appdata.settings.addListener(onSettingsChanged);
    ComicSourceManager().addListener(onSettingsChanged);
    BangumiManager().addListener(onAccountChanged);
    if (isShown) {
      load();
    }
  }

  @override
  void dispose() {
    appdata.settings.removeListener(onSettingsChanged);
    ComicSourceManager().removeListener(onSettingsChanged);
    BangumiManager().removeListener(onAccountChanged);
    super.dispose();
  }

  void onSettingsChanged() {
    if (!mounted) {
      return;
    }
    setState(() {});
    if (isShown && today == null && error == null) {
      load();
    }
  }

  /// The user the anime being watched were loaded for.
  String? watchingOf;

  void onAccountChanged() {
    var user = BangumiManager().isLoggedIn
        ? BangumiManager().user?.username
        : null;
    if (!mounted || user == watchingOf) {
      return;
    }
    setState(() => watching = {});
    if (today != null) {
      loadWatching();
    }
  }

  Future<void> loadWatching() async {
    var manager = BangumiManager();
    var user = manager.isLoggedIn ? manager.user?.username : null;
    watchingOf = user;
    try {
      var watching = await manager.watching();
      // Not for an account logged out of meanwhile.
      if (mounted && watchingOf == user) {
        setState(() => this.watching = watching);
      }
    } catch (e) {
      Log.warning('Bangumi', 'Failed to load the anime being watched: $e');
    }
  }

  Future<void> load() async {
    try {
      var calendar = await BangumiManager().calendar();
      var day = calendar[DateTime.now().weekday - 1];
      if (mounted) {
        setState(() => today = day);
        widget.onCountChanged?.call(day.length);
      }
    } catch (e) {
      Log.warning('Bangumi', 'Failed to load the calendar: $e');
      if (mounted) {
        setState(() => error = e.toString());
      }
      return;
    }
    await loadWatching();
  }

  @override
  Widget build(BuildContext context) {
    if (!isShown) {
      return const SliverToBoxAdapter();
    }
    var today = this.today;
    return SliverToBoxAdapter(
      child: SectionCard(
        icon: Icons.calendar_month_outlined,
        title: 'Airing Schedule'.tl,
        collapseKey: 'home_bangumi_calendar',
        onTap: () => context.to(() => const BangumiCalendarPage()),
        leadingActions: [
          const SizedBox(width: 8),
          AppBadge(_weekdays[DateTime.now().weekday - 1].tl),
        ],
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Search anime on Bangumi'.tl,
            onPressed: () => context.to(() => const BangumiSearchPage()),
          ),
        ],
        bodyPadding: EdgeInsets.zero,
        body: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (error != null)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      error!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: ts.s12,
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      setState(() => error = null);
                      load();
                    },
                    child: Text("Retry".tl),
                  ),
                ],
              ).paddingHorizontal(16).paddingBottom(8)
            else if (today == null)
              const SizedBox(
                height: 168,
                child: Center(child: CircularProgressIndicator()),
              )
            else if (today.isNotEmpty)
              SizedBox(
                height: 168,
                child: HorizontalCoverList(
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    children: [
                      for (var subject in _sorted(today, watching))
                        SizedBox(
                          width: 88,
                          child: _HomeSubjectCover(
                            subject: subject,
                            watching: watching.contains(subject.id),
                          ),
                        ).paddingHorizontal(4),
                    ],
                  ),
                ),
              ).paddingBottom(12)
            else
              SectionEmptyState('Nothing airing'.tl),
          ],
        ),
      ),
    );
  }
}

/// Home covers use an ink overlay above the image and theme-based score badges.
class _HomeSubjectCover extends StatelessWidget {
  const _HomeSubjectCover({required this.subject, required this.watching});

  final BangumiSubject subject;
  final bool watching;

  @override
  Widget build(BuildContext context) {
    return CoverButton(
      label: subject.displayName,
      onTap: () => context.to(
        () => BangumiSubjectPage(subjectId: subject.id, preview: subject),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: ColoredBox(
                color: context.colorScheme.surfaceContainerHigh,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (subject.image.isNotEmpty)
                      AnimatedImage(
                        image: CachedImageProvider(subject.image),
                        width: double.infinity,
                        height: double.infinity,
                      ),
                    if (watching)
                      Positioned(
                        left: 4,
                        top: 4,
                        child: Tooltip(
                          message: 'Currently watching'.tl,
                          child: AppBadge(
                            'Currently watching'.tl,
                            highlighted: true,
                          ),
                        ),
                      ),
                    if (subject.score > 0)
                      Positioned(
                        right: 4,
                        bottom: 4,
                        child: AppBadge(subject.score.toStringAsFixed(1)),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subject.displayName,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: ts.s12,
          ).fixHeight(32),
        ],
      ),
    );
  }
}
