part of 'comic_page.dart';

class _ComicThumbnails extends StatefulWidget {
  const _ComicThumbnails();

  @override
  State<_ComicThumbnails> createState() => _ComicThumbnailsState();
}

class _ComicThumbnailsState extends State<_ComicThumbnails> {
  late _ComicPageState state;

  late List<String> thumbnails;

  bool isInitialLoading = true;

  bool _initialized = false;

  String? next;

  String? error;

  bool isLoading = false;

  @override
  void didChangeDependencies() {
    state = context.findAncestorStateOfType<_ComicPageState>()!;
    if (!_initialized) {
      thumbnails = List.from(state.comic.thumbnails ?? []);
      _initialized = true;
    }
    super.didChangeDependencies();
  }

  void loadNext() async {
    if (isDetailSectionCollapsed('thumbnails') ||
        state.comicSource.loadComicThumbnail == null) {
      return;
    }
    if (!isInitialLoading && next == null) {
      return;
    }
    if (isLoading) {
      return;
    }
    isLoading = true;
    Future.microtask(() {
      if (mounted) {
        setState(() {});
      }
    });
    var res = await state.comicSource.loadComicThumbnail!(state.comic.id, next);
    if (res.success) {
      thumbnails.addAll(res.data);
      next = res.subData;
      isInitialLoading = false;
    } else {
      error = res.errorMessage;
    }
    if (mounted) {
      setState(() {
        isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SliverSectionCard(
      icon: Icons.photo_library_outlined,
      title: "Preview".tl,
      collapseKey: 'thumbnails',
      slivers: [
        SliverLayoutBuilder(
          builder: (context, constraints) {
            if (isInitialLoading && !isLoading && error == null) {
              loadNext();
            }
            return SliverMainAxisGroup(
              slivers: [
                SliverGrid(
                  delegate: SliverChildBuilderDelegate(
                    childCount: thumbnails.length,
                    (context, index) {
                      if (index == thumbnails.length - 1 && error == null) {
                        loadNext();
                      }
                      var url = thumbnails[index];
                      ImagePart? part;
                      if (url.contains('@')) {
                        var params = url.split('@')[1].split('&');
                        url = url.split('@')[0];
                        double? x1, y1, x2, y2;
                        try {
                          for (var p in params) {
                            if (p.startsWith('x')) {
                              var r = p.split('=')[1];
                              x1 = double.parse(r.split('-')[0]);
                              x2 = double.parse(r.split('-')[1]);
                            }
                            if (p.startsWith('y')) {
                              var r = p.split('=')[1];
                              y1 = double.parse(r.split('-')[0]);
                              y2 = double.parse(r.split('-')[1]);
                            }
                          }
                        } catch (_) {
                          // ignore
                        }
                        part = ImagePart(x1: x1, y1: y1, x2: x2, y2: y2);
                      }
                      return Padding(
                        padding: context.width < changePoint
                            ? const EdgeInsets.all(4)
                            : const EdgeInsets.all(8),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Expanded(
                              child: InkWell(
                                onTap: () => state.read(null, index + 1),
                                borderRadius: const BorderRadius.all(
                                  Radius.circular(8),
                                ),
                                child: Container(
                                  foregroundDecoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.outline,
                                    ),
                                  ),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  width: double.infinity,
                                  height: double.infinity,
                                  clipBehavior: Clip.antiAlias,
                                  child: AnimatedImage(
                                    image: CachedImageProvider(
                                      url,
                                      sourceKey: state.widget.sourceKey,
                                    ),
                                    fit: BoxFit.contain,
                                    width: double.infinity,
                                    height: double.infinity,
                                    part: part,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text((index + 1).toString()),
                          ],
                        ),
                      );
                    },
                  ),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 200,
                    childAspectRatio: 0.68,
                  ),
                ),
                if (error != null)
                  SliverToBoxAdapter(
                    child: Column(
                      children: [
                        Text(error!),
                        Button.outlined(
                          onPressed: loadNext,
                          child: Text("Retry".tl),
                        ),
                      ],
                    ),
                  )
                else if (isLoading)
                  const SliverListLoadingIndicator(),
              ],
            );
          },
        ),
      ],
    );
  }
}
