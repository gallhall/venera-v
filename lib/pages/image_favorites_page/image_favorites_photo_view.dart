part of 'image_favorites_page.dart';

class ImageFavoritesPhotoView extends StatefulWidget {
  const ImageFavoritesPhotoView({
    super.key,
    required this.comic,
    required this.imageFavorite,
  });

  final ImageFavoritesComic comic;
  final ImageFavorite imageFavorite;

  @override
  State<ImageFavoritesPhotoView> createState() =>
      _ImageFavoritesPhotoViewState();
}

class _ImageFavoritesPhotoViewState extends State<ImageFavoritesPhotoView> {
  late PageController controller;
  Map<ImageFavorite, bool> cancelImageFavorites = {};

  var images = <ImageFavorite>[];

  int currentPage = 0;

  bool isAppBarShow = false;

  @override
  void initState() {
    var current = 0;
    for (var ep in widget.comic.imageFavoritesEp) {
      for (var image in ep.imageFavorites) {
        images.add(image);
        if (image == widget.imageFavorite) {
          current = images.length - 1;
        }
      }
    }
    currentPage = current;
    controller = PageController(initialPage: current);
    super.initState();
  }

  void onPop() {
    List<ImageFavorite> tempList = cancelImageFavorites.entries
        .where((e) => e.value == true)
        .map((e) => e.key)
        .toList();
    if (tempList.isNotEmpty) {
      ImageFavoriteManager().deleteImageFavorite(tempList);
      showToast(
        message: "Delete @a images".tlParams({'a': tempList.length}),
        context: context,
      );
    }
  }

  PhotoViewGalleryPageOptions _buildItem(BuildContext context, int index) {
    var image = images[index];
    return PhotoViewGalleryPageOptions(
      // 图片加载器 支持本地、网络
      imageProvider: ImageFavoritesProvider(image),
      // 初始化大小 全部展示
      minScale: PhotoViewComputedScale.contained * 1.0,
      maxScale: PhotoViewComputedScale.covered * 10.0,
      onTapUp: (context, details, controllerValue) {
        setState(() {
          isAppBarShow = !isAppBarShow;
        });
      },
      heroAttributes: PhotoViewHeroAttributes(
        tag: "${image.sourceKey}${image.ep}${image.page}",
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      onPopInvokedWithResult: (bool didPop, Object? result) async {
        if (didPop) {
          onPop();
        }
      },
      child: Listener(
        onPointerSignal: (event) {
          if (HardwareKeyboard.instance.isControlPressed) {
            return;
          }
          if (event is PointerScrollEvent) {
            if (event.scrollDelta.dy > 0) {
              if (controller.page! >= images.length - 1) {
                return;
              }
              controller.nextPage(
                duration: Duration(milliseconds: 180),
                curve: Curves.ease,
              );
            } else {
              if (controller.page! <= 0) {
                return;
              }
              controller.previousPage(
                duration: Duration(milliseconds: 180),
                curve: Curves.ease,
              );
            }
          }
        },
        child: Stack(
          children: [
            Positioned.fill(
              child: PhotoViewGallery.builder(
                backgroundDecoration: BoxDecoration(
                  color: context.colorScheme.surface,
                ),
                builder: _buildItem,
                itemCount: images.length,
                loadingBuilder: (context, event) => Center(
                  child: SizedBox(
                    width: 20.0,
                    height: 20.0,
                    child: CircularProgressIndicator(
                      backgroundColor: context.colorScheme.surfaceContainerHigh,
                      value: event == null || event.expectedTotalBytes == null
                          ? null
                          : event.cumulativeBytesLoaded /
                                event.expectedTotalBytes!,
                    ),
                  ),
                ),
                pageController: controller,
                onPageChanged: (index) {
                  setState(() {
                    currentPage = index;
                  });
                },
              ),
            ),
            buildPageInfo(),
            AnimatedPositioned(
              top: isAppBarShow ? 0 : -(context.padding.top + 52),
              left: 0,
              right: 0,
              duration: Duration(milliseconds: 180),
              child: buildAppBar(),
            ),
          ],
        ),
      ),
    );
  }

  Widget buildPageInfo() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: context.padding.bottom + 8,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(28),
          ),
          child: Text(
            '${currentPage + 1}/${images.length}',
            style: ts.s14.copyWith(color: Colors.white),
          ),
        ),
      ),
    );
  }

  Widget buildAppBar() {
    return Padding(
      padding: EdgeInsets.fromLTRB(8, context.padding.top, 8, 0),
      child: Material(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(28),
        clipBehavior: Clip.antiAlias,
        child: IconButtonTheme(
          data: IconButtonThemeData(
            style: IconButton.styleFrom(
              foregroundColor: Colors.white,
              shape: const CircleBorder(),
            ),
          ),
          child: SizedBox(
            height: 52,
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Close'.tl,
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    widget.comic.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ts.s14.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'More'.tl,
                  icon: const Icon(Icons.more_vert),
                  onPressed: showMenu,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void showMenu() {
    showMenuX(context, Offset(context.width, context.padding.top), [
      MenuEntry(
        icon: Icons.image_outlined,
        text: "Save Image".tl,
        onClick: () async {
          var temp = images[currentPage];
          var imageProvider = ImageFavoritesProvider(temp);
          var data = await imageProvider.load(null, null);
          var fileType = detectFileType(data);
          var fileName = "${currentPage + 1}.${fileType.ext}";
          await saveFile(filename: fileName, data: data);
        },
      ),
      MenuEntry(
        icon: Icons.menu_book_outlined,
        text: "Read".tl,
        onClick: () async {
          var comic = widget.comic;
          var ep = images[currentPage].ep;
          var page = images[currentPage].page;
          App.rootContext.to(
            () => ReaderWithLoading(
              id: comic.id,
              sourceKey: comic.sourceKey,
              initialEp: ep,
              initialPage: page,
            ),
          );
        },
      ),
    ]);
  }
}
