import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/bangumi/bangumi.dart';
import 'package:venera/utils/translations.dart';
import 'bangumi_calendar_page.dart';

/// Built-in Explore tab, available when a video source is installed.
class BangumiTrendingPage extends StatefulWidget {
  const BangumiTrendingPage({super.key});

  @override
  State<BangumiTrendingPage> createState() => BangumiTrendingPageState();
}

class BangumiTrendingPageState extends State<BangumiTrendingPage>
    with AutomaticKeepAliveClientMixin {
  final scrollController = ScrollController();
  final subjects = <BangumiSubject>[];
  bool loading = false, more = true;
  int offset = 0, generation = 0;
  String? error;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    load();
    scrollController.addListener(() {
      if (scrollController.position.extentAfter < 500 &&
          more &&
          error == null) {
        load();
      }
    });
  }

  @override
  void dispose() {
    scrollController.dispose();
    super.dispose();
  }

  void toTop() {
    if (scrollController.hasClients) {
      scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
      );
    }
  }

  void refresh() {
    generation++;
    subjects.clear();
    offset = 0;
    more = true;
    loading = false;
    toTop();
    load();
  }

  Future<void> load() async {
    if (loading || !more) {
      return;
    }
    var token = generation;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      var page = await BangumiManager().api.trending(offset: offset);
      if (!mounted || token != generation) {
        return;
      }
      setState(() {
        offset += page.count;
        subjects.addAll(
          page.subjects.where((s) => !subjects.any((old) => old.id == s.id)),
        );
        more = page.count == 20 && (page.total == null || offset < page.total!);
      });
    } catch (e) {
      if (mounted && token == generation) {
        setState(() => error = '$e');
      }
    } finally {
      if (mounted && token == generation) {
        setState(() => loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return RefreshIndicator(
      onRefresh: () async {
        refresh();
      },
      child: AppContentWidth(
        child: CustomScrollView(
          controller: scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 180,
                  childAspectRatio: 0.58,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                ),
                delegate: SliverChildBuilderDelegate((context, index) {
                  var subject = subjects[index];
                  return BangumiGridCover(subject: subject);
                }, childCount: subjects.length),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    if (loading) const CircularProgressIndicator(),
                    if (error != null) Text(error!),
                    if (!loading && (more || error != null))
                      TextButton(
                        onPressed: load,
                        child: Text((error == null ? 'Load more' : 'Retry').tl),
                      ),
                    if (!loading && error == null && subjects.isEmpty)
                      SectionEmptyState('No results'.tl),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
