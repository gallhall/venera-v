part of 'components.dart';

/// Screens at least this wide show a sub-page as a right-side panel.
const double kSubPagePanelBreakpoint = 600;

/// Opens [page] over the current screen: a right-side panel of [width] on
/// wide screens, full screen otherwise. Pickers use [showSidePanel] instead.
Future<T?> showSubPage<T>(
  BuildContext context,
  Widget page, {
  double width = 500,
  bool showBarrier = true,
}) {
  return Navigator.of(context, rootNavigator: true).push<T>(
    SubPageRoute<T>(page, width: width, showBarrier: showBarrier),
  );
}

class SubPageRoute<T> extends PopupRoute<T> {
  SubPageRoute(this.page, {this.width = 500, this.showBarrier = true});

  final Widget page;

  final double width;

  final bool showBarrier;

  bool _barrierSawPointerDown = false;

  @override
  Color? get barrierColor => showBarrier ? Colors.black54 : null;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => "exit";

  @override
  TickerFuture didPush() {
    _barrierSawPointerDown = false;
    return super.didPush();
  }

  @override
  Widget buildModalBarrier() {
    if (!showBarrier) {
      return const SizedBox.shrink();
    }
    // Ignore the tap that opened the page, which may end on the barrier.
    // Fades with the page, so a back swipe uncovers the page below instead
    // of a fully dimmed one.
    return FadeTransition(opacity: animation!, child: Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (event) {
        if (event.position == Offset.zero) {
          return;
        }
        _barrierSawPointerDown = true;
      },
      child: ModalBarrier(
        onDismiss: () {
          if (_barrierSawPointerDown) {
            navigator?.maybePop();
          }
        },
        color: barrierColor,
        semanticsLabel: barrierLabel,
      ),
    ));
  }

  @override
  Widget buildPage(BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation) {
    final media = MediaQuery.of(context);
    final panel = media.size.width >= kSubPagePanelBreakpoint;
    final colors = context.colorScheme;

    Widget body = _SubPageScope(
      panel: panel,
      child: MediaQuery.removePadding(
        context: context,
        removeLeft: panel,
        removeRight: true,
        removeBottom: true,
        child: page,
      ),
    );

    body = Container(
      width: panel ? math.min(width, media.size.width) : media.size.width,
      height: media.size.height,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: panel ? colors.surfaceContainerLow : colors.surface,
        borderRadius: panel
            ? const BorderRadius.horizontal(left: Radius.circular(AppRadius.xl))
            : null,
      ),
      padding: EdgeInsets.only(
        right: media.padding.right,
        bottom: media.padding.bottom,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: body,
      ),
    );

    if (App.isIOS) {
      body = IOSBackGestureDetector(
        enabledCallback: () =>
            animation.status == AnimationStatus.completed &&
            !navigator!.userGestureInProgress,
        gestureWidth: 20.0,
        onStartPopGesture: () =>
            IOSBackGestureController(controller!, navigator!),
        child: body,
      );
    }

    // The page or panel covers the status bar icons of the page below it.
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: context.brightness == Brightness.dark
          ? SystemUiOverlayStyle.light
          : SystemUiOverlayStyle.dark,
      child: Align(alignment: Alignment.centerRight, child: body),
    );
  }

  @override
  Duration get transitionDuration => const Duration(milliseconds: 300);

  @override
  Widget buildTransitions(BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation, Widget child) {
    // Linear while a back swipe drags the page, so it follows the finger.
    final dragging = navigator?.userGestureInProgress ?? false;
    return SlideTransition(
      position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
          .animate(dragging
              ? animation
              : CurvedAnimation(parent: animation, curve: Curves.fastOutSlowIn)),
      child: child,
    );
  }
}

class _SubPageScope extends InheritedWidget {
  const _SubPageScope({required this.panel, required super.child});

  final bool panel;

  @override
  bool updateShouldNotify(_SubPageScope oldWidget) => panel != oldWidget.panel;
}

/// The header and body of a page opened with [showSubPage].
class SubPage extends StatefulWidget {
  const SubPage({
    required this.title,
    required this.body,
    this.subtitle,
    this.actions,
    super.key,
  });

  final String title;

  final String? subtitle;

  final Widget body;

  final List<Widget>? actions;

  /// Whether the enclosing sub-page is shown as a side panel.
  static bool isPanel(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_SubPageScope>()?.panel ??
      false;

  @override
  State<SubPage> createState() => _SubPageState();
}

class _SubPageState extends State<SubPage> {
  bool scrolled = false;

  bool onScroll(ScrollNotification notification) {
    if (notification.depth != 0 ||
        notification.metrics.axis != Axis.vertical) {
      return false;
    }
    final value = notification.metrics.extentBefore > 0;
    if (value != scrolled) {
      setState(() => scrolled = value);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    final panel = SubPage.isPanel(context);
    final topPadding = MediaQuery.paddingOf(context).top;
    return Material(
      color: panel ? colors.surfaceContainerLow : colors.surface,
      child: Column(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            constraints: BoxConstraints(minHeight: 56 + topPadding),
            padding: EdgeInsets.only(
              top: topPadding,
              left: AppSpacing.sm,
              right: AppSpacing.sm,
            ),
            width: double.infinity,
            color: scrolled
                ? (panel ? colors.surfaceContainer : colors.surfaceContainerLow)
                : colors.surface.withValues(alpha: 0),
            child: Row(
              children: [
                const SubPageBackButton(),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ts.s18.copyWith(fontWeight: FontWeight.w600),
                      ),
                      if (widget.subtitle != null)
                        Text(
                          widget.subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ts.s12.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                ...?widget.actions,
              ],
            ),
          ),
          Expanded(
            child: NotificationListener<ScrollNotification>(
              onNotification: onScroll,
              // The keyboard inset is taken below, so the body sees none.
              child: MediaQuery(
                data: MediaQuery.of(context)
                    .removePadding(removeTop: true)
                    .removeViewInsets(removeBottom: true),
                child: widget.body,
              ),
            ),
          ),
          SizedBox(height: MediaQuery.viewInsetsOf(context).bottom),
        ],
      ),
    );
  }
}

/// Closes a sub-page shown as a panel, or goes back otherwise.
class SubPageBackButton extends StatelessWidget {
  const SubPageBackButton({super.key});

  @override
  Widget build(BuildContext context) {
    final panel = SubPage.isPanel(context);
    return IconButton(
      tooltip: panel ? "Close".tl : "Back".tl,
      icon: Icon(panel ? Icons.close_outlined : Icons.arrow_back_outlined),
      onPressed: () => Navigator.maybePop(context),
    );
  }
}
