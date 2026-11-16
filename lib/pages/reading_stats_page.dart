import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/duration_records.dart';
import 'package:venera/foundation/reading_stats.dart';
import 'package:venera/pages/open_work.dart';
import 'package:venera/utils/translations.dart';

/// 统计: what the 时长记录 add up to, comics and anime apart.
class ReadingStatsPage extends StatefulWidget {
  const ReadingStatsPage({super.key});

  @override
  State<ReadingStatsPage> createState() => _ReadingStatsPageState();
}

class _ReadingStatsPageState extends State<ReadingStatsPage> {
  /// The kinds that have records.
  var kinds = DurationRecords().kinds();

  /// Reading or watching from a ranking entry adds records meanwhile.
  void reload() {
    if (mounted) setState(() => kinds = DurationRecords().kinds());
  }

  @override
  void initState() {
    super.initState();
    DurationRecords().addListener(reload);
  }

  @override
  void dispose() {
    DurationRecords().removeListener(reload);
    super.dispose();
  }

  StatsRange range = StatsRange.week;

  late DurationKind kind =
      kinds.contains(DurationKind.anime) && !kinds.contains(DurationKind.comic)
      ? DurationKind.anime
      : DurationKind.comic;

  void clear() {
    showConfirmDialog(
      context: context,
      title: 'Clear Statistics'.tl,
      content:
          'All reading and watching time records will be deleted. History is kept.'
              .tl,
      confirmText: 'Clear'.tl,
      btnColor: context.colorScheme.error,
      onConfirm: () {
        DurationRecords().clear();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    var stats = DurationRecords().stats(kind, range);
    return Scaffold(
      body: AppContentWidth(
        child: SmoothCustomScrollView(
          slivers: [
            SliverAppbar(
              title: Text('Statistics'.tl),
              actions: [
                IconButton(
                  tooltip: 'Clear Statistics'.tl,
                  icon: const Icon(Icons.delete_sweep_outlined),
                  onPressed: kinds.isEmpty ? null : clear,
                ),
              ],
            ),
            SliverToBoxAdapter(child: buildFilters(context)),
            if (stats.seconds == 0)
              SliverFillRemaining(
                hasScrollBody: false,
                child: AppEmptyView(
                  icon: Icons.insights_outlined,
                  text: kinds.isEmpty
                      ? 'No records yet. Time spent reading and watching is recorded from now on.'
                            .tl
                      : 'Nothing in this period'.tl,
                ),
              )
            else ...[
              SliverToBoxAdapter(child: buildSummary(context, stats)),
              SliverToBoxAdapter(
                child: SectionCard(
                  icon: Icons.bar_chart_outlined,
                  title: switch (range) {
                    StatsRange.today => 'By Hour'.tl,
                    StatsRange.all => 'By Month'.tl,
                    _ => 'By Day'.tl,
                  },
                  body: _BarChart(buckets: stats.buckets, range: range),
                ),
              ),
              SliverToBoxAdapter(
                child: SectionCard(
                  icon: Icons.emoji_events_outlined,
                  title: kind == DurationKind.anime
                      ? 'Most Watched'.tl
                      : 'Most Read'.tl,
                  bodyPadding: const EdgeInsets.symmetric(vertical: 8),
                  body: Column(
                    children: [
                      for (var (i, w) in stats.ranking.indexed)
                        _RankingTile(rank: i + 1, total: w, kind: kind),
                    ],
                  ),
                ),
              ),
              const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
            ],
          ],
        ),
      ),
    );
  }

  Widget buildFilters(BuildContext context) {
    final colors = context.colorScheme;
    Widget chip(String text, bool selected, VoidCallback onTap) {
      return ChoiceChip(
        label: Text(text),
        selected: selected,
        showCheckmark: false,
        shape: const StadiumBorder(),
        side: BorderSide.none,
        backgroundColor: colors.surfaceContainerHigh,
        selectedColor: colors.secondaryContainer,
        labelStyle: TextStyle(
          color: selected ? colors.onSecondaryContainer : colors.onSurface,
        ),
        onSelected: (_) => setState(onTap),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              chip(
                'Comics'.tl,
                kind == DurationKind.comic,
                () => kind = DurationKind.comic,
              ),
              chip(
                'Anime series'.tl,
                kind == DurationKind.anime,
                () => kind = DurationKind.anime,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var (r, text) in [
                (StatsRange.today, 'Today'.tl),
                (StatsRange.week, 'This Week'.tl),
                (StatsRange.month, 'This Month'.tl),
                (StatsRange.all, 'All Time'.tl),
              ])
                chip(text, range == r, () => range = r),
            ],
          ),
        ],
      ),
    );
  }

  Widget buildSummary(BuildContext context, KindStats stats) {
    final colors = context.colorScheme;
    Widget figure(String value, String label) {
      return Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(value, style: ts.s18.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text(label, style: ts.s12.copyWith(color: colors.onSurfaceVariant)),
          ],
        ),
      );
    }

    var anime = kind == DurationKind.anime;
    return AppCard(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          figure(
            formatStatsDuration(stats.seconds),
            anime ? 'Watching Time'.tl : 'Reading Time'.tl,
          ),
          figure(
            '${stats.finished}',
            anime ? 'Episodes Watched'.tl : 'Chapters Read'.tl,
          ),
          figure('${stats.works}', 'Works'.tl),
        ],
      ),
    );
  }
}

/// 1 h 5 min, 12 min, < 1 min.
String formatStatsDuration(int seconds) {
  var minutes = seconds ~/ 60;
  if (minutes == 0) return '< 1 min'.tl;
  var h = minutes ~/ 60;
  var m = minutes % 60;
  if (h == 0) return '@m min'.tlParams({'m': m});
  if (m == 0) return '@h h'.tlParams({'h': h});
  return '@h h @m min'.tlParams({'h': h, 'm': m});
}

class _BarChart extends StatelessWidget {
  const _BarChart({required this.buckets, required this.range});

  final List<StatsBucket> buckets;
  final StatsRange range;

  static const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  String? label(int i, DateTime start) {
    return switch (range) {
      StatsRange.today => i % 6 == 0 ? '${start.hour}' : null,
      StatsRange.week => _weekdays[i].tl,
      StatsRange.month => i == 0 || (i + 1) % 5 == 0 ? '${start.day}' : null,
      StatsRange.all =>
        buckets.length <= 12 || i % (buckets.length ~/ 6) == 0
            ? (start.month == 1 || i == 0
                  ? '${start.year}.${start.month}'
                  : '${start.month}')
            : null,
    };
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    var max = buckets.fold(0, (m, b) => b.seconds > m ? b.seconds : m);
    var peak = buckets.firstWhere((b) => b.seconds == max);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Longest: @t'.tlParams({'t': formatStatsDuration(peak.seconds)}),
          style: ts.s12.copyWith(color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 140,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var b in buckets)
                Expanded(
                  child: Tooltip(
                    message: formatStatsDuration(b.seconds),
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: buckets.length > 12 ? 1 : 4,
                      ),
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: Container(
                          constraints: const BoxConstraints(maxWidth: 40),
                          height: max == 0
                              ? 0
                              : (b.seconds / max * 140).clamp(
                                  b.seconds > 0 ? 3.0 : 0.0,
                                  140.0,
                                ),
                          decoration: BoxDecoration(
                            color: colors.primary,
                            borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(4),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            for (var (i, b) in buckets.indexed)
              Expanded(
                child: Text(
                  label(i, b.start) ?? '',
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.visible,
                  style: ts.s12.copyWith(color: colors.onSurfaceVariant),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _RankingTile extends StatelessWidget {
  const _RankingTile({
    required this.rank,
    required this.total,
    required this.kind,
  });

  final int rank;
  final WorkTotal total;
  final DurationKind kind;

  void open() => openWork(
    sourceKey: total.work.type.sourceKey,
    id: total.work.id,
    title: total.work.title,
    cover: total.work.cover,
    // Anime are ranked by the subject their records kept; a comic's is a
    // book, read from the comic's own page.
    animeSubject: kind == DurationKind.anime ? total.work.subjectId : null,
  );

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    return ListTile(
      onTap: open,
      leading: SizedBox(
        width: 28,
        child: Text(
          '$rank',
          textAlign: TextAlign.center,
          style: ts.s16.copyWith(
            fontWeight: FontWeight.w600,
            color: rank <= 3 ? colors.primary : colors.onSurfaceVariant,
          ),
        ),
      ),
      title: Text(
        total.work.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Text(
        formatStatsDuration(total.seconds),
        style: ts.s14.copyWith(color: colors.onSurfaceVariant),
      ),
    );
  }
}
