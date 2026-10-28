part of 'components.dart';

class Appbar extends StatefulWidget implements PreferredSizeWidget {
  const Appbar({
    required this.title,
    this.leading,
    this.actions,
    this.backgroundColor,
    this.style = AppbarStyle.blur,
    super.key,
  });

  final Widget title;

  final Widget? leading;

  final List<Widget>? actions;

  final Color? backgroundColor;

  final AppbarStyle style;

  @override
  State<Appbar> createState() => _AppbarState();

  @override
  Size get preferredSize => const Size.fromHeight(56);
}

class _AppbarState extends State<Appbar> {
  ScrollNotificationObserverState? _scrollNotificationObserver;
  bool _scrolledUnder = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scrollNotificationObserver?.removeListener(_handleScrollNotification);
    _scrollNotificationObserver = ScrollNotificationObserver.maybeOf(context);
    _scrollNotificationObserver?.addListener(_handleScrollNotification);
  }

  @override
  void dispose() {
    if (_scrollNotificationObserver != null) {
      _scrollNotificationObserver!.removeListener(_handleScrollNotification);
      _scrollNotificationObserver = null;
    }
    super.dispose();
  }

  void _handleScrollNotification(ScrollNotification notification) {
    if (notification is ScrollUpdateNotification &&
        defaultScrollNotificationPredicate(notification)) {
      final bool oldScrolledUnder = _scrolledUnder;
      final ScrollMetrics metrics = notification.metrics;
      switch (metrics.axisDirection) {
        case AxisDirection.up:
          // Scroll view is reversed
          _scrolledUnder = metrics.extentAfter > 0;
        case AxisDirection.down:
          _scrolledUnder = metrics.extentBefore > 0;
        case AxisDirection.right:
        case AxisDirection.left:
          // Scrolled under is only supported in the vertical axis, and should
          // not be altered based on horizontal notifications of the same
          // predicate since it could be a 2D scroller.
          break;
      }

      if (_scrolledUnder != oldScrolledUnder) {
        setState(() {
          // React to a change in MaterialState.scrolledUnder
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    var content = Container(
      decoration: BoxDecoration(
        color: widget.backgroundColor ??
            context.colorScheme.surface.toOpacity(0.86),
      ),
      height: _kAppBarHeight + context.padding.top,
      child: Row(
        children: [
          const SizedBox(width: 8),
          widget.leading ??
              Tooltip(
                message: "Back".tl,
                child: IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => Navigator.maybePop(context),
                ),
              ),
          const SizedBox(
            width: 16,
          ),
          Expanded(
            child: DefaultTextStyle(
              style: DefaultTextStyle.of(context).style.copyWith(fontSize: 20),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              child: widget.title,
            ),
          ),
          ...?widget.actions,
          const SizedBox(
            width: 8,
          )
        ],
      ).paddingTop(context.padding.top),
    );
    if (widget.style == AppbarStyle.shadow) {
      return Material(
        color: context.colorScheme.surface,
        elevation: _scrolledUnder ? 2 : 0,
        child: content,
      );
    } else {
      return BlurEffect(
        blur: _scrolledUnder ? 15 : 0,
        child: content,
      );
    }
  }
}

enum AppbarStyle {
  blur,
  shadow,
}

class SliverAppbar extends StatelessWidget {
  const SliverAppbar({
    super.key,
    required this.title,
    this.leading,
    this.actions,
    this.radius = 0,
    this.style = AppbarStyle.blur,
  });

  final Widget? leading;

  final Widget title;

  final List<Widget>? actions;

  final double radius;

  final AppbarStyle style;

  @override
  Widget build(BuildContext context) {
    return SliverPersistentHeader(
      pinned: true,
      delegate: _MySliverAppBarDelegate(
        leading: leading,
        title: title,
        actions: actions,
        topPadding: MediaQuery.of(context).padding.top,
        radius: radius,
        style: style,
      ),
    );
  }
}

const _kAppBarHeight = 52.0;

class _MySliverAppBarDelegate extends SliverPersistentHeaderDelegate {
  final Widget? leading;

  final Widget title;

  final List<Widget>? actions;

  final double topPadding;

  final double radius;

  final AppbarStyle style;

  _MySliverAppBarDelegate({
    this.leading,
    required this.title,
    this.actions,
    required this.topPadding,
    this.radius = 0,
    this.style = AppbarStyle.blur,
  });

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    var body = Row(
      children: [
        const SizedBox(width: 8),
        leading ??
            (Navigator.of(context).canPop()
                ? Tooltip(
                    message: "Back".tl,
                    child: IconButton(
                      icon: const Icon(Icons.arrow_back),
                      onPressed: () => Navigator.maybePop(context),
                    ),
                  )
                : const SizedBox()),
        const SizedBox(
          width: 16,
        ),
        Expanded(
          child: DefaultTextStyle(
            style: DefaultTextStyle.of(context).style.copyWith(fontSize: 20),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            child: title,
          ),
        ),
        ...?actions,
        const SizedBox(
          width: 8,
        )
      ],
    ).paddingTop(topPadding);

    if (style == AppbarStyle.blur) {
      return SizedBox.expand(
        child: BlurEffect(
          blur: 15,
          child: Material(
            color: context.colorScheme.surface.toOpacity(0.86),
            elevation: 0,
            borderRadius: BorderRadius.circular(radius),
            child: body,
          ),
        ),
      );
    } else {
      return SizedBox.expand(
        child: Material(
          color: context.colorScheme.surface,
          elevation: shrinkOffset == 0 ? 0 : 2,
          borderRadius: BorderRadius.circular(radius),
          child: body,
        ),
      );
    }
  }

  @override
  double get maxExtent => _kAppBarHeight + topPadding;

  @override
  double get minExtent => _kAppBarHeight + topPadding;

  @override
  bool shouldRebuild(SliverPersistentHeaderDelegate oldDelegate) {
    return oldDelegate is! _MySliverAppBarDelegate ||
        leading != oldDelegate.leading ||
        title != oldDelegate.title ||
        actions != oldDelegate.actions ||
        topPadding != oldDelegate.topPadding ||
        radius != oldDelegate.radius ||
        style != oldDelegate.style;
  }
}

class AppTabBar extends StatefulWidget {
  const AppTabBar({
    super.key,
    this.controller,
    required this.tabs,
    this.actionButton,
    this.withUnderLine = false,
  });

  final TabController? controller;

  final List<Tab> tabs;

  final Widget? actionButton;

  final bool withUnderLine;

  @override
  State<AppTabBar> createState() => _AppTabBarState();
}

class _AppTabBarState extends State<AppTabBar> {
  TabController? _controller;
  late List<GlobalKey> keys;
  int? previousIndex;
  final scrollController = ScrollController();
  ScrollState? scrollParent;
  late final scrollId = -identityHashCode(this);

  @override
  void initState() {
    super.initState();
    keys = widget.tabs.map((e) => GlobalKey()).toList();
  }

  @override
  void dispose() {
    _controller?.animation?.removeListener(onTabChanged);
    scrollParent?.onChildInactive(scrollId);
    scrollController.dispose();
    super.dispose();
  }

  void bindController() {
    final controller = widget.controller ?? DefaultTabController.of(context);
    if (controller == _controller) {
      return;
    }
    _controller?.animation?.removeListener(onTabChanged);
    _controller = controller;
    final prevIndex = PageStorage.of(context).readState(context) as int?;
    if (prevIndex != null && prevIndex >= 0 && prevIndex < widget.tabs.length) {
      controller.index = prevIndex;
    }
    previousIndex = controller.index;
    controller.animation?.addListener(onTabChanged);
    scrollToTab(controller.index);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final parent = ScrollState.maybeOf(context);
    if (parent != scrollParent) {
      scrollParent?.onChildInactive(scrollId);
      scrollParent = parent;
    }
    bindController();
  }

  @override
  void didUpdateWidget(covariant AppTabBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (keys.length != widget.tabs.length) {
      keys = List.generate(
        widget.tabs.length,
        (i) => i < keys.length ? keys[i] : GlobalKey(),
      );
    }
    bindController();
  }

  void onTabChanged() {
    final i = _controller!.index;
    if (i == previousIndex) {
      return;
    }
    previousIndex = i;
    PageStorage.of(context).writeState(context, i);
    scrollToTab(i);
  }

  void scrollToTab(int i) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || i < 0 || i >= keys.length) {
        return;
      }
      final tabContext = keys[i].currentContext;
      if (tabContext != null) {
        final target = tabContext.findRenderObject();
        if (scrollController.hasClients && target != null) {
          scrollController.position.ensureVisible(
            target,
            alignment: 0.5,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
          );
        }
      }
    });
  }

  void onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || keys.isEmpty) {
      return;
    }
    if (!scrollController.hasClients) {
      return;
    }
    final position = scrollController.position;
    if (!position.hasContentDimensions ||
        position.maxScrollExtent <= position.minScrollExtent) {
      return;
    }
    GestureBinding.instance.pointerSignalResolver.register(event, (signal) {
      final delta = event.scrollDelta.dx != 0
          ? event.scrollDelta.dx
          : event.scrollDelta.dy;
      final direction = position.axisDirection == AxisDirection.left ? -1 : 1;
      position.jumpTo(
        (position.pixels + delta * direction).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    return SizedBox(
      height: 48,
      width: double.infinity,
      child: MouseRegion(
        onEnter: (_) {
          if (scrollController.hasClients &&
              scrollController.position.maxScrollExtent > 0) {
            scrollParent?.onChildActive(scrollId);
          }
        },
        onExit: (_) => scrollParent?.onChildInactive(scrollId),
        child: Listener(
          onPointerSignal: onPointerSignal,
          child: ScrollConfiguration(
            behavior: ScrollConfiguration.of(context).copyWith(
              dragDevices: {
                ...ScrollConfiguration.of(context).dragDevices,
                PointerDeviceKind.mouse,
              },
            ),
            child: widget.tabs.isEmpty
                ? const SizedBox.shrink()
                : SingleChildScrollView(
                    key: const PageStorageKey('scroll'),
                    controller: scrollController,
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TabBar(
                          controller: _controller,
                          isScrollable: true,
                          physics: const NeverScrollableScrollPhysics(),
                          tabAlignment: TabAlignment.start,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 6,
                          ),
                          labelPadding: const EdgeInsets.symmetric(horizontal: 16),
                          indicatorSize: TabBarIndicatorSize.tab,
                          indicator: BoxDecoration(
                            color: colors.secondaryContainer,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          dividerColor: Colors.transparent,
                          automaticIndicatorColorAdjustment: false,
                          labelColor: colors.onSecondaryContainer,
                          unselectedLabelColor: colors.onSurfaceVariant,
                          labelStyle: ts.s14.copyWith(fontWeight: FontWeight.w600),
                          unselectedLabelStyle: ts.s14.copyWith(
                            fontWeight: FontWeight.w500,
                          ),
                          splashBorderRadius: BorderRadius.circular(20),
                          tabs: List.generate(widget.tabs.length, (i) => SizedBox(
                            key: keys[i],
                            height: 36,
                            child: widget.tabs[i],
                          )),
                        ),
                        if (widget.actionButton != null)
                          widget.actionButton!.paddingHorizontal(6),
                      ],
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

class TabViewBody extends StatefulWidget {
  /// Create a tab view body, which will show the child at the current tab index.
  const TabViewBody({super.key, required this.children, this.controller});

  final List<Widget> children;

  final TabController? controller;

  @override
  State<TabViewBody> createState() => _TabViewBodyState();
}

class _TabViewBodyState extends State<TabViewBody> {
  late TabController _controller;

  int _currentIndex = 0;

  void updateIndex() {
    if (_controller.index != _currentIndex) {
      setState(() {
        _currentIndex = _controller.index;
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller = widget.controller ?? DefaultTabController.of(context);
    _currentIndex = _controller.index;
    _controller.addListener(updateIndex);
  }

  @override
  void dispose() {
    super.dispose();
    _controller.removeListener(updateIndex);
  }

  @override
  Widget build(BuildContext context) {
    return widget.children[_currentIndex];
  }
}

class SearchBarController {
  _SearchBarMixin? _state;

  final void Function(String text)? onSearch;

  String currentText;

  void setText(String text) {
    _state?.setText(text);
  }

  String get text => _state?.getText() ?? '';

  set text(String text) {
    setText(text);
  }

  SearchBarController({this.onSearch, this.currentText = ''});
}

abstract mixin class _SearchBarMixin {
  void setText(String text);

  String getText();
}

class SliverSearchBar extends StatefulWidget {
  const SliverSearchBar({
    super.key,
    required this.controller,
    this.onChanged,
    this.action,
    this.focusNode,
    this.title,
  });

  final SearchBarController controller;

  final void Function(String)? onChanged;

  final Widget? action;

  final FocusNode? focusNode;

  /// Shown in an app bar row with the back button above the field, which
  /// then has no back button of its own.
  final String? title;

  @override
  State<SliverSearchBar> createState() => _SliverSearchBarState();
}

class _SliverSearchBarState extends State<SliverSearchBar>
    with _SearchBarMixin {
  late TextEditingController _editingController;

  late SearchBarController _controller;

  @override
  void initState() {
    _controller = widget.controller;
    _controller._state = this;
    _editingController = TextEditingController(text: _controller.currentText);
    super.initState();
  }

  @override
  void setText(String text) {
    _editingController.text = text;
  }

  @override
  String getText() {
    return _editingController.text;
  }

  @override
  Widget build(BuildContext context) {
    return SliverPersistentHeader(
      pinned: true,
      delegate: _SliverSearchBarDelegate(
        editingController: _editingController,
        controller: _controller,
        topPadding: MediaQuery.of(context).padding.top,
        onChanged: widget.onChanged,
        action: widget.action,
        focusNode: widget.focusNode,
        title: widget.title,
      ),
    );
  }
}

class _SliverSearchBarDelegate extends SliverPersistentHeaderDelegate {
  final TextEditingController editingController;

  final SearchBarController controller;

  final double topPadding;

  final void Function(String)? onChanged;

  final Widget? action;

  final String? title;

  final FocusNode? focusNode;

  const _SliverSearchBarDelegate({
    required this.editingController,
    required this.controller,
    required this.topPadding,
    this.onChanged,
    this.action,
    this.focusNode,
    this.title,
  });

  static const _kAppBarHeight = 72.0;

  /// The title row of a normal app bar, then the field.
  static const _kTitledHeight = _kAppBarHeight + 52.0;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return _RoundedSearchBar(
      editingController: editingController,
      controller: controller,
      topPadding: topPadding,
      focusNode: focusNode,
      onChanged: onChanged,
      action: action,
      title: title,
    );
  }

  @override
  double get maxExtent =>
      (title == null ? _kAppBarHeight : _kTitledHeight) + topPadding;

  @override
  double get minExtent => maxExtent;

  @override
  bool shouldRebuild(covariant SliverPersistentHeaderDelegate oldDelegate) {
    return oldDelegate is! _SliverSearchBarDelegate ||
        editingController != oldDelegate.editingController ||
        controller != oldDelegate.controller ||
        topPadding != oldDelegate.topPadding ||
        onChanged != oldDelegate.onChanged ||
        action != oldDelegate.action ||
        focusNode != oldDelegate.focusNode ||
        title != oldDelegate.title;
  }
}

class AppSearchBar extends StatefulWidget {
  const AppSearchBar({super.key, required this.controller, this.action});

  final SearchBarController controller;

  final Widget? action;

  @override
  State<AppSearchBar> createState() => _SearchBarState();
}

class _SearchBarState extends State<AppSearchBar> with _SearchBarMixin {
  late TextEditingController _editingController;

  late SearchBarController _controller;

  @override
  void setText(String text) {
    _editingController.text = text;
  }

  @override
  String getText() {
    return _editingController.text;
  }

  @override
  void initState() {
    _controller = widget.controller;
    _controller._state = this;
    _editingController = TextEditingController(text: _controller.currentText);
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.of(context).padding.top;
    return _RoundedSearchBar(
      editingController: _editingController,
      controller: _controller,
      topPadding: topPadding,
      action: widget.action,
    );
  }
}

class _RoundedSearchBar extends StatelessWidget {
  const _RoundedSearchBar({
    required this.editingController,
    required this.controller,
    required this.topPadding,
    this.focusNode,
    this.onChanged,
    this.action,
    this.title,
  });

  final TextEditingController editingController;
  final SearchBarController controller;
  final double topPadding;
  final FocusNode? focusNode;
  final ValueChanged<String>? onChanged;
  final String? title;

  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    final field = Padding(
        padding: title == null
            ? EdgeInsets.fromLTRB(8, topPadding + 8, 16, 8)
            : EdgeInsets.fromLTRB(16, topPadding + 52, 16, 8),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1200),
            child: SizedBox(
              height: 56,
              child: Row(
                children: [
                  if (title == null) ...[
                    const BackButton(),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: TextField(
                      focusNode: focusNode,
                      controller: editingController,
                      textInputAction: TextInputAction.search,
                      decoration: InputDecoration(
                        hintText: "Search".tl,
                        filled: true,
                        fillColor: colors.surfaceContainerHigh,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 16,
                        ),
                        prefixIcon: Icon(
                          Icons.search_rounded,
                          size: 22,
                          color: colors.onSurfaceVariant,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(28),
                          borderSide: BorderSide.none,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(28),
                          borderSide: BorderSide.none,
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(28),
                          borderSide: BorderSide(color: colors.primary),
                        ),
                        suffixIcon: ListenableBuilder(
                          listenable: editingController,
                          builder: (context, child) =>
                              editingController.text.isEmpty
                              ? const SizedBox.shrink()
                              : IconButton(
                                  tooltip: "Clear".tl,
                                  icon: const Icon(Icons.clear, size: 20),
                                  onPressed: () {
                                    editingController.clear();
                                    onChanged?.call("");
                                  },
                                ),
                        ),
                      ),
                      onSubmitted: (text) => controller.onSearch?.call(text),
                      onChanged: onChanged,
                    ),
                  ),
                  if (action != null) action!,
                ],
              ),
            ),
          ),
        ),
      );
    return ColoredBox(
      color: colors.surface,
      child: title == null
          ? field
          : Stack(
              children: [
                // Laid out like the other pages' app bars.
                Positioned(
                  top: topPadding,
                  left: 0,
                  right: 0,
                  height: 52,
                  child: Row(
                    children: [
                      const SizedBox(width: 8),
                      Tooltip(
                        message: "Back".tl,
                        child: IconButton(
                          icon: const Icon(Icons.arrow_back),
                          onPressed: () => Navigator.maybePop(context),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Text(
                          title!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: DefaultTextStyle.of(
                            context,
                          ).style.copyWith(fontSize: 20),
                        ),
                      ),
                    ],
                  ),
                ),
                field,
              ],
            ),
    );
  }
}

class TabActionButton extends StatelessWidget {
  const TabActionButton({
    super.key,
    required this.icon,
    required this.text,
    required this.onPressed,
  });

  final Icon icon;

  final String text;

  final void Function() onPressed;

  static const _kTabHeight = 46.0;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        height: _kTabHeight,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: IconTheme(
          data: IconThemeData(size: 20, color: context.colorScheme.primary),
          child: Row(
            children: [
              icon,
              const SizedBox(width: 8),
              Text(text, style: ts.withColor(context.colorScheme.primary)),
            ],
          ),
        ),
      ),
    );
  }
}
