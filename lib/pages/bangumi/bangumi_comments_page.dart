part of 'bangumi_panel.dart';

class BangumiCommentsPage extends StatefulWidget {
  const BangumiCommentsPage({super.key, required this.binding});

  final BangumiBinding binding;

  @override
  State<BangumiCommentsPage> createState() => _BangumiCommentsPageState();
}

class _BangumiCommentsPageState extends State<BangumiCommentsPage> {
  final comments = <BangumiComment>[];
  final controller = ScrollController();
  final api = BangumiApi();

  bool isLoading = false;
  bool hasMore = true;
  int offset = 0;
  String? error;

  @override
  void initState() {
    super.initState();
    controller.addListener(onScroll);
    load();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void onScroll() {
    if (controller.hasClients &&
        controller.position.extentAfter < 300 &&
        error == null) {
      load();
    }
  }

  Future<void> load() async {
    if (isLoading || !hasMore) {
      return;
    }
    setState(() {
      isLoading = true;
      error = null;
    });
    try {
      var page = await api.comments(widget.binding.subjectId, offset: offset);
      if (!mounted) {
        return;
      }
      setState(() {
        comments.addAll(page.data);
        offset += page.count;
        hasMore = page.count > 0 && offset < page.total;
      });
    } catch (e, s) {
      Log.error('Bangumi', e.toString(), s);
      if (mounted) {
        setState(() => error = e.toString());
      }
    } finally {
      if (mounted) {
        setState(() => isLoading = false);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            onScroll();
          }
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget body;
    if (comments.isEmpty && isLoading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (comments.isEmpty && error != null) {
      body = NetworkError(message: error!, retry: load, withAppbar: false);
    } else if (comments.isEmpty && !hasMore) {
      body = SectionEmptyState("No comments yet".tl);
    } else {
      body = ListView.builder(
        controller: controller,
        padding: EdgeInsets.only(bottom: context.padding.bottom + 16),
        itemCount: comments.length + 1,
        itemBuilder: (context, index) {
          if (index < comments.length) {
            return buildComment(comments[index]);
          }
          if (error != null) {
            return Column(
              children: [
                Text(error!, textAlign: TextAlign.center),
                TextButton(onPressed: load, child: Text("Retry".tl)),
              ],
            ).paddingAll(16);
          }
          return isLoading
              ? const Center(child: CircularProgressIndicator()).paddingAll(16)
              : const SizedBox();
        },
      );
    }
    return Scaffold(
      body: Column(
        children: [
          Appbar(title: Text("Bangumi comments".tl)),
          Expanded(child: AppContentWidth(maxWidth: 800, child: body)),
        ],
      ),
    );
  }

  Widget buildComment(BangumiComment comment) {
    var time = comment.time?.toLocal();
    String pad(int value) => value.toString().padLeft(2, '0');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipOval(
            child: Container(
              color: context.colorScheme.surfaceContainerHigh,
              width: 36,
              height: 36,
              child: comment.user.avatar.isEmpty
                  ? const Icon(Icons.person)
                  : AnimatedImage(
                      image: CachedImageProvider(comment.user.avatar),
                    ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  comment.user.displayName,
                  style: ts.s14.copyWith(fontWeight: FontWeight.w600),
                ),
                Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (comment.rate > 0)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.star,
                            size: 16,
                            color: context.colorScheme.primary,
                          ),
                          Text('${comment.rate} / 10', style: ts.s12),
                        ],
                      ),
                    if (BangumiCollectionType.values.contains(comment.type))
                      Text(
                        _statusName(comment.type, widget.binding.isBook),
                        style: ts.s12.copyWith(
                          color: context.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    if (time != null)
                      Text(
                        '${time.year}-${pad(time.month)}-${pad(time.day)} '
                        '${pad(time.hour)}:${pad(time.minute)}',
                        style: ts.s12.copyWith(
                          color: context.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                SelectableText(comment.comment, style: ts.s14),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
