part of 'components.dart';

class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.highlighted = false,
    this.margin = const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    this.padding,
  }) : _sliver = false;

  /// The same card surface around lazy sliver content.
  const AppCard.sliver({
    super.key,
    required this.child,
    this.highlighted = false,
    this.margin = const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    this.padding = const EdgeInsets.all(8),
  }) : _sliver = true,
       onTap = null,
       onLongPress = null;

  final bool _sliver;
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool highlighted;
  final EdgeInsetsGeometry margin;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
      side: BorderSide(
        color: highlighted ? colors.primary : colors.outlineVariant,
        width: highlighted ? 1.5 : 0.6,
      ),
    );
    if (_sliver) {
      return SliverPadding(
        padding: margin,
        sliver: DecoratedSliver(
          decoration: ShapeDecoration(
            color: colors.surfaceContainerLow,
            shape: shape,
          ),
          sliver: SliverPadding(
            padding: padding ?? EdgeInsets.zero,
            sliver: child,
          ),
        ),
      );
    }
    Widget content = padding == null
        ? child
        : Padding(padding: padding!, child: child);
    if (onTap != null || onLongPress != null) {
      content = InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        mouseCursor: SystemMouseCursors.click,
        child: content,
      );
    }
    return Card(
      elevation: 0,
      color: colors.surfaceContainerLow,
      margin: margin,
      clipBehavior: Clip.antiAlias,
      shape: shape,
      child: content,
    );
  }
}

class AppBadge extends StatelessWidget {
  const AppBadge(
    this.text, {
    super.key,
    this.highlighted = false,
    this.backgroundColor,
    this.foregroundColor,
  });

  final String text;
  final bool highlighted;
  final Color? backgroundColor;
  final Color? foregroundColor;

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    final background = highlighted
        ? colors.primaryContainer
        : colors.surfaceContainerHigh;
    final foreground = highlighted
        ? colors.onPrimaryContainer
        : colors.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: backgroundColor ?? background,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: ts.s12.copyWith(color: foregroundColor ?? foreground),
      ),
    );
  }
}

class AppIconBox extends StatelessWidget {
  const AppIconBox(
    this.icon, {
    super.key,
    this.size = 44,
    this.color,
    this.iconColor,
  });

  final IconData icon;
  final double size;
  final Color? color;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    final foreground =
        iconColor ??
        (color == null
            ? colors.onSecondaryContainer
            : ThemeData.estimateBrightnessForColor(color!) == Brightness.dark
            ? Colors.white
            : Colors.black);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color ?? colors.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(icon, color: foreground),
    );
  }
}

class CollapsibleBody extends StatefulWidget {
  const CollapsibleBody({
    super.key,
    required this.expanded,
    required this.builder,
  });

  final bool expanded;
  final WidgetBuilder builder;

  @override
  State<CollapsibleBody> createState() => _CollapsibleBodyState();
}

class _CollapsibleBodyState extends State<CollapsibleBody>
    with SingleTickerProviderStateMixin {
  late final controller =
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 200),
        value: widget.expanded ? 1 : 0,
      )..addStatusListener((status) {
        if (status == AnimationStatus.dismissed) {
          setState(() {});
        }
      });
  late final animation = CurvedAnimation(
    parent: controller,
    curve: Curves.easeInOut,
  );

  @override
  void didUpdateWidget(covariant CollapsibleBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.expanded != oldWidget.expanded) {
      if (widget.expanded) {
        controller.forward();
      } else {
        controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    animation.dispose();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizeTransition(
      sizeFactor: animation,
      axisAlignment: -1,
      child: FadeTransition(
        opacity: animation,
        child: !widget.expanded && controller.isDismissed
            ? const SizedBox.shrink()
            : widget.builder(context),
      ),
    );
  }
}

Future<T?> showOptionsSheet<T>(
  BuildContext context, {
  String? title,
  required Map<T, String> options,
  T? selected,
}) {
  final colors = context.colorScheme;
  final screen = MediaQuery.sizeOf(context);

  Widget buildContent(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: screen.height * 0.7),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (title != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Text(title, style: ts.s18),
              ),
            Flexible(
              child: _PickerOptions<T>(options: options, selected: selected),
            ),
          ],
        ),
      ),
    );
  }

  if (screen.width < 600) {
    return showModalBottomSheet<T>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: colors.surfaceContainerLow,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: buildContent,
    );
  }
  return showDialog<T>(
    context: context,
    builder: (context) => Dialog(
      backgroundColor: colors.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      child: SizedBox(
        width: 400,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: buildContent(context),
        ),
      ),
    ),
  );
}

/// Player options use a side panel even on narrow landscape screens.
Future<T?> showSidePicker<T>(
  BuildContext context, {
  required String title,
  required Map<T, String> options,
  T? selected,
}) {
  final media = MediaQuery.of(context);
  if (media.size.width < 600 && media.orientation == Orientation.portrait) {
    return showOptionsSheet<T>(
      context,
      title: title,
      options: options,
      selected: selected,
    );
  }
  return showDialog<T>(
    context: context,
    useSafeArea: false,
    builder: (context) => Dialog(
      alignment: Alignment.centerRight,
      insetPadding: EdgeInsets.zero,
      constraints: const BoxConstraints(maxWidth: 360),
      backgroundColor: context.colorScheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.horizontal(left: Radius.circular(28)),
      ),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 360,
        height: double.infinity,
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(title, style: ts.s18),
              ),
              Expanded(
                child: _PickerOptions<T>(options: options, selected: selected),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _PickerOptions<T> extends StatefulWidget {
  const _PickerOptions({required this.options, this.selected});

  final Map<T, String> options;
  final T? selected;

  @override
  State<_PickerOptions<T>> createState() => _PickerOptionsState<T>();
}

class _PickerOptionsState<T> extends State<_PickerOptions<T>> {
  final selectedKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final selectedContext = selectedKey.currentContext;
      if (mounted && selectedContext != null) {
        Scrollable.ensureVisible(selectedContext, alignment: 0.5);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // Build all rows so ensureVisible can locate even a late episode before
    // the route's entrance animation finishes. Labels may wrap at any scale.
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final option in widget.options.entries)
            OptionRow(
              key: option.key == widget.selected ? selectedKey : null,
              text: option.value,
              selected: option.key == widget.selected,
              onTap: () => Navigator.of(context).pop(option.key),
            ),
        ],
      ),
    );
  }
}

class OptionRow extends StatelessWidget {
  const OptionRow({
    super.key,
    required this.text,
    required this.selected,
    required this.onTap,
    this.leftPadding = 24,
  });

  final String text;
  final bool selected;
  final VoidCallback onTap;
  final double leftPadding;

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.fromLTRB(leftPadding, 12, 24, 12),
        child: Row(
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              color: selected ? colors.primary : colors.onSurfaceVariant,
              size: 20,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                text,
                style: ts.s14.copyWith(
                  color: selected ? colors.primary : colors.onSurface,
                  fontWeight: selected ? FontWeight.w600 : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class InlineSelectTile<T> extends StatefulWidget {
  const InlineSelectTile({
    super.key,
    required this.title,
    required this.options,
    required this.selected,
    required this.onChanged,
    this.sheetTitle,
  });

  final Widget title;
  final Map<T, String> options;
  final T? selected;
  final ValueChanged<T> onChanged;
  final String? sheetTitle;

  @override
  State<InlineSelectTile<T>> createState() => _InlineSelectTileState<T>();
}

class _InlineSelectTileState<T> extends State<InlineSelectTile<T>> {
  bool expanded = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          title: widget.title,
          subtitle: Text(
            widget.options[widget.selected] ?? 'None'.tl,
            style: TextStyle(color: context.colorScheme.primary),
          ),
          // Long lists open a sheet instead of expanding.
          trailing: widget.options.length > 8
              ? const Icon(Icons.chevron_right)
              : AnimatedChevron(expanded: expanded),
          onTap: () async {
            if (widget.options.length > 8) {
              final value = await showOptionsSheet<T>(
                context,
                title: widget.sheetTitle,
                options: widget.options,
                selected: widget.selected,
              );
              if (mounted && value != null) {
                widget.onChanged(value);
              }
            } else {
              setState(() {
                expanded = !expanded;
              });
            }
          },
        ),
        CollapsibleBody(
          expanded: expanded,
          builder: (context) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final option in widget.options.entries)
                OptionRow(
                  text: option.value,
                  selected: option.key == widget.selected,
                  leftPadding: 16,
                  onTap: () {
                    setState(() {
                      expanded = false;
                    });
                    widget.onChanged(option.key);
                  },
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class AnimatedChevron extends StatelessWidget {
  const AnimatedChevron({super.key, required this.expanded});

  final bool expanded;

  @override
  Widget build(BuildContext context) {
    return AnimatedRotation(
      turns: expanded ? 0.5 : 0,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      child: const Icon(Icons.expand_more),
    );
  }
}

/// A toolbar that floats over a poster until the details scroll underneath it.
class FloatingDetailsAppBar extends StatelessWidget {
  const FloatingDetailsAppBar({
    super.key,
    required this.title,
    this.actions,
    required this.solid,
  });

  final Widget title;
  final List<Widget>? actions;
  final bool solid;

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    final topPadding = MediaQuery.paddingOf(context).top;
    final brightness = Theme.of(context).brightness;
    final normalStyle = brightness == Brightness.light
        ? SystemUiOverlayStyle.dark
        : SystemUiOverlayStyle.light;
    final overlayStyle = (solid ? normalStyle : SystemUiOverlayStyle.light)
        .copyWith(
          statusBarColor: Colors.transparent,
          systemNavigationBarColor: Colors.transparent,
          systemNavigationBarIconBrightness: brightness == Brightness.light
              ? Brightness.dark
              : Brightness.light,
        );

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: overlayStyle,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: solid ? 1 : 0),
        duration: const Duration(milliseconds: 200),
        builder: (context, value, child) {
          final foreground = Color.lerp(Colors.white, colors.onSurface, value)!;
          return SizedBox(
            height: topPadding + 56,
            child: Stack(
              fit: StackFit.expand,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.25 * (1 - value)),
                        Colors.black.withValues(alpha: 0),
                      ],
                    ),
                  ),
                ),
                if (value > 0)
                  BlurEffect(
                    blur: 15 * value,
                    child: ColoredBox(
                      color: colors.surface.toOpacity(0.86 * value),
                    ),
                  ),
                Material(
                  type: MaterialType.transparency,
                  child: IconTheme.merge(
                    data: IconThemeData(color: foreground),
                    child: IconButtonTheme(
                      data: IconButtonThemeData(
                        style: IconButton.styleFrom(
                          foregroundColor: foreground,
                        ),
                      ),
                      child: Padding(
                        padding: EdgeInsets.only(top: topPadding),
                        child: Row(
                          children: [
                            const SizedBox(width: 8),
                            if (Navigator.of(context).canPop())
                              IconButton(
                                tooltip: "Back".tl,
                                icon: const Icon(Icons.arrow_back),
                                onPressed: () => Navigator.maybePop(context),
                              ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: DefaultTextStyle(
                                style: DefaultTextStyle.of(context).style
                                    .copyWith(fontSize: 20, color: foreground),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                child: title,
                              ),
                            ),
                            ...?actions,
                            const SizedBox(width: 8),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// A cover and metadata over a softly blurred poster backdrop.
class PosterHeader extends StatelessWidget {
  const PosterHeader({
    super.key,
    this.backdrop,
    required this.cover,
    required this.title,
    this.details = const [],
    this.coverHeight = 168,
    this.topInset = 0,
  });

  final ImageProvider? backdrop;
  final Widget cover;
  final Widget title;
  final List<Widget> details;
  final double coverHeight;
  final double topInset;

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    final position = Scrollable.maybeOf(context)?.position;
    return AnimatedBuilder(
      animation: position ?? const AlwaysStoppedAnimation<double>(0),
      builder: (context, child) {
        final overscroll =
            position != null &&
                position.hasPixels &&
                position.hasContentDimensions
            ? math.max(0.0, position.minScrollExtent - position.pixels)
            : 0.0;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            // Keep the backdrop behind the toolbar during a pull past the top.
            Positioned(
              top: -overscroll,
              left: 0,
              right: 0,
              bottom: 0,
              child: ClipRect(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Positioned.fill(
                      child: ColoredBox(
                        color: colors.surface,
                        child: backdrop == null
                            ? null
                            : RepaintBoundary(
                                child: Opacity(
                                  opacity: 0.45,
                                  child: ImageFiltered(
                                    imageFilter: ui.ImageFilter.blur(
                                      sigmaX: 24,
                                      sigmaY: 24,
                                    ),
                                    child: Image(
                                      image: backdrop!,
                                      fit: BoxFit.cover,
                                      excludeFromSemantics: true,
                                      errorBuilder: (context, error, stack) =>
                                          const SizedBox.shrink(),
                                    ),
                                  ),
                                ),
                              ),
                      ),
                    ),
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              colors.surface.withValues(alpha: 0),
                              colors.surface.withValues(alpha: 0.35),
                              colors.surface,
                            ],
                            stops: const [0, 0.55, 1],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            child!,
          ],
        );
      },
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, topInset + 8, 16, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: coverHeight * 0.72,
              height: coverHeight,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black26,
                    blurRadius: 12,
                    offset: Offset(0, 4),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: cover,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  title,
                  for (final detail in details) ...[
                    const SizedBox(height: 6),
                    detail,
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The poster and floating back button shown while details are loading.
class DetailsLoadingView extends StatelessWidget {
  const DetailsLoadingView({
    super.key,
    this.cover,
    this.title,
    this.coverHeroTag,
  });

  final ImageProvider? cover;
  final String? title;
  final Object? coverHeroTag;

  @override
  Widget build(BuildContext context) {
    Widget coverWidget = cover == null
        ? ColoredBox(color: context.colorScheme.surfaceContainerHigh)
        : AnimatedImage(
            image: cover!,
            width: double.infinity,
            height: double.infinity,
            fit: BoxFit.cover,
          );
    if (coverHeroTag != null) {
      coverWidget = Hero(tag: coverHeroTag!, child: coverWidget);
    }
    return Stack(
      children: [
        Column(
          children: [
            PosterHeader(
              topInset: MediaQuery.paddingOf(context).top + 56,
              backdrop: cover,
              cover: coverWidget,
              title: title == null
                  ? const SizedBox.shrink()
                  : Text(
                      title!,
                      style: ts.s20.copyWith(fontWeight: FontWeight.w600),
                    ),
            ),
            const DetailsLoadingIndicator(),
          ],
        ),
        const Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: FloatingDetailsAppBar(title: SizedBox(), solid: false),
        ),
      ],
    );
  }
}

class DetailsLoadingIndicator extends StatelessWidget {
  const DetailsLoadingIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(top: 48),
      child: Center(
        child: SizedBox(
          width: 32,
          height: 32,
          child: CircularProgressIndicator(strokeWidth: 3),
        ),
      ),
    );
  }
}

/// Applies poster accents while retaining the application's surface palette.
ThemeData posterTheme(ThemeData theme, ColorScheme? tint) {
  if (tint == null) {
    return theme;
  }
  final colors = theme.colorScheme;
  return theme.copyWith(
    colorScheme: tint.copyWith(
      surface: colors.surface,
      surfaceDim: colors.surfaceDim,
      surfaceBright: colors.surfaceBright,
      surfaceContainerLowest: colors.surfaceContainerLowest,
      surfaceContainerLow: colors.surfaceContainerLow,
      surfaceContainer: colors.surfaceContainer,
      surfaceContainerHigh: colors.surfaceContainerHigh,
      surfaceContainerHighest: colors.surfaceContainerHighest,
      onSurface: colors.onSurface,
      onSurfaceVariant: colors.onSurfaceVariant,
    ),
  );
}

class ActionPill extends StatelessWidget {
  const ActionPill({
    super.key,
    required this.icon,
    required this.text,
    required this.onPressed,
    this.activeIcon,
    this.isActive,
    this.onLongPressed,
    this.isLoading,
  });

  final Widget icon;
  final Widget? activeIcon;
  final bool? isActive;
  final String text;
  final VoidCallback onPressed;
  final VoidCallback? onLongPressed;
  final bool? isLoading;

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    final active = isActive ?? false;
    final foreground = active ? colors.onSecondaryContainer : colors.primary;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Material(
        color: active ? colors.secondaryContainer : colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          onTap: (isLoading ?? false) ? null : onPressed,
          onLongPress: onLongPressed,
          borderRadius: BorderRadius.circular(20),
          child: SizedBox(
            height: 40,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: IconTheme.merge(
                data: IconThemeData(size: 20, color: foreground),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isLoading ?? false)
                      SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.8,
                          color: foreground,
                        ),
                      )
                    else
                      active ? (activeIcon ?? icon) : icon,
                    const SizedBox(width: 8),
                    Text(
                      text,
                      style: ts.s14.copyWith(
                        color: active
                            ? colors.onSecondaryContainer
                            : colors.onSurface,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Whether a detail section is collapsed in the local preferences.
bool isDetailSectionCollapsed(String key) {
  final stored = appdata.implicitData['collapsedDetailSections'];
  return stored is List && stored.contains(key);
}

void _setDetailSectionCollapsed(String key, bool collapsed) {
  final stored = appdata.implicitData['collapsedDetailSections'];
  final keys = stored is List ? stored.whereType<String>().toSet() : <String>{};
  if (collapsed) {
    keys.add(key);
  } else {
    keys.remove(key);
  }
  appdata.implicitData['collapsedDetailSections'] = keys.toList();
  appdata.writeImplicitData();
}

class _SectionCardHeader extends StatelessWidget {
  const _SectionCardHeader({
    required this.icon,
    this.dense = false,
    required this.title,
    required this.actions,
    required this.leadingActions,
    required this.expanded,
    this.onToggle,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final List<Widget> actions;
  final List<Widget> leadingActions;
  final bool expanded;
  final VoidCallback? onToggle;
  final bool dense;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    return InkWell(
      onTap: onTap ?? onToggle,
      child: Padding(
        padding: dense
            ? const EdgeInsets.fromLTRB(12, 6, 4, 6)
            : const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Row(
          children: [
            AppIconBox(
              icon,
              size: dense ? 32 : 40,
              color: colors.primaryContainer,
              iconColor: colors.onPrimaryContainer,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      title,
                      style: ts.s16.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  ...leadingActions,
                ],
              ),
            ),
            ...actions,
            if (onToggle != null)
              IconButton(
                tooltip: (expanded ? 'Collapse' : 'Expand').tl,
                onPressed: onToggle,
                icon: AnimatedChevron(expanded: expanded),
              ),
          ],
        ),
      ),
    );
  }
}

class SectionCard extends StatefulWidget {
  const SectionCard({
    super.key,
    this.dense = false,
    required this.icon,
    required this.title,
    this.actions = const [],
    this.leadingActions = const [],
    this.footer,
    required this.body,
    this.bodyPadding = const EdgeInsets.all(16),
    this.collapseKey,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final List<Widget> actions;
  final List<Widget> leadingActions;
  final Widget? footer;
  final Widget body;
  final EdgeInsets bodyPadding;

  /// Smaller header without a divider, for dense pages like search.
  final bool dense;
  final String? collapseKey;
  final VoidCallback? onTap;

  @override
  State<SectionCard> createState() => _SectionCardState();
}

class _SectionCardState extends State<SectionCard> {
  late bool expanded =
      widget.collapseKey == null ||
      !isDetailSectionCollapsed(widget.collapseKey!);

  void toggle() {
    setState(() => expanded = !expanded);
    _setDetailSectionCollapsed(widget.collapseKey!, !expanded);
  }

  @override
  void didUpdateWidget(covariant SectionCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.collapseKey != widget.collapseKey) {
      expanded =
          widget.collapseKey == null ||
          !isDetailSectionCollapsed(widget.collapseKey!);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _SectionCardHeader(
            icon: widget.icon,
            dense: widget.dense,
            title: widget.title,
            actions: widget.actions,
            leadingActions: widget.leadingActions,
            expanded: expanded,
            onTap: widget.onTap,
            onToggle: widget.collapseKey == null ? null : toggle,
          ),
          CollapsibleBody(
            expanded: expanded,
            builder: (context) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!widget.dense)
                  const Divider(height: 1, indent: 16, endIndent: 16),
                Padding(
                  padding: widget.dense
                      ? const EdgeInsets.fromLTRB(12, 0, 12, 12)
                      : widget.bodyPadding,
                  child: widget.body,
                ),
                if (widget.footer != null) widget.footer!,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class SliverSectionCard extends StatefulWidget {
  const SliverSectionCard({
    super.key,
    required this.icon,
    required this.title,
    this.actions = const [],
    this.leadingActions = const [],
    this.footer,
    required this.slivers,
    this.bodyPadding = const EdgeInsets.all(16),
    this.collapseKey,
  });

  final IconData icon;
  final String title;
  final List<Widget> actions;
  final List<Widget> leadingActions;
  final Widget? footer;
  final List<Widget> slivers;
  final EdgeInsets bodyPadding;
  final String? collapseKey;

  @override
  State<SliverSectionCard> createState() => _SliverSectionCardState();
}

class _SliverSectionCardState extends State<SliverSectionCard> {
  late bool expanded =
      widget.collapseKey == null ||
      !isDetailSectionCollapsed(widget.collapseKey!);

  void toggle() {
    setState(() => expanded = !expanded);
    _setDetailSectionCollapsed(widget.collapseKey!, !expanded);
  }

  @override
  void didUpdateWidget(covariant SliverSectionCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.collapseKey != widget.collapseKey) {
      expanded =
          widget.collapseKey == null ||
          !isDetailSectionCollapsed(widget.collapseKey!);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppCard.sliver(
      padding: EdgeInsets.zero,
      child: SliverMainAxisGroup(
        slivers: [
          SliverToBoxAdapter(
            child: Material(
              type: MaterialType.transparency,
              borderRadius: BorderRadius.circular(16),
              clipBehavior: Clip.antiAlias,
              child: _SectionCardHeader(
                icon: widget.icon,
                title: widget.title,
                actions: widget.actions,
                leadingActions: widget.leadingActions,
                expanded: expanded,
                onToggle: widget.collapseKey == null ? null : toggle,
              ),
            ),
          ),
          if (expanded) ...[
            const SliverToBoxAdapter(
              child: Divider(height: 1, indent: 16, endIndent: 16),
            ),
            SliverPadding(
              padding: widget.bodyPadding,
              sliver: SliverMainAxisGroup(slivers: widget.slivers),
            ),
            if (widget.footer != null)
              SliverToBoxAdapter(child: widget.footer!),
          ],
        ],
      ),
    );
  }
}

/// Aligned plain labels and the existing interactive values of an info card.
class DetailInformation extends StatelessWidget {
  const DetailInformation({super.key, required this.rows});

  final List<(String?, Widget)> rows;

  @override
  Widget build(BuildContext context) {
    final style = ts.s14.copyWith(color: context.colorScheme.onSurfaceVariant);
    final textStyle = DefaultTextStyle.of(context).style.merge(style);
    var labelWidth = 56.0;
    for (final row in rows) {
      if (row.$1 == null) {
        continue;
      }
      final painter = TextPainter(
        text: TextSpan(text: row.$1, style: textStyle),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        locale: Localizations.localeOf(context),
      )..layout();
      labelWidth = math
          .max(labelWidth, painter.width)
          .clamp(56.0, 96.0)
          .toDouble();
      painter.dispose();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          if (rows[i].$1 == null)
            rows[i].$2
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: labelWidth,
                  child: Text(rows[i].$1!, style: style),
                ),
                const SizedBox(width: 16),
                Expanded(child: rows[i].$2),
              ],
            ),
        ],
      ],
    );
  }
}

class DescriptionBody extends StatefulWidget {
  const DescriptionBody({super.key, required this.text});

  final String text;

  @override
  State<DescriptionBody> createState() => _DescriptionBodyState();
}

class _DescriptionBodyState extends State<DescriptionBody> {
  bool expanded = false;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final style = DefaultTextStyle.of(context).style;
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: style),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          locale: Localizations.localeOf(context),
          maxLines: 2,
        )..layout(maxWidth: constraints.maxWidth);
        final overflows = painter.didExceedMaxLines;
        painter.dispose();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (expanded)
              SelectableText(widget.text, style: style)
            else
              Text(
                widget.text,
                style: style,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            if (overflows)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  style: TextButton.styleFrom(
                    foregroundColor: context.colorScheme.primary,
                    minimumSize: Size.zero,
                    padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () => setState(() => expanded = !expanded),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text((expanded ? 'Show less' : 'Show full text').tl),
                      const SizedBox(width: 4),
                      Icon(
                        expanded ? Icons.expand_less : Icons.expand_more,
                        size: 18,
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Mouse dragging and Shift-wheel scrolling, scoped to a horizontal cover list.
/// Scrollable reads only dx normally, leaving vertical wheel input to the page.
class HorizontalCoverList extends StatelessWidget {
  const HorizontalCoverList({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final behavior = ScrollConfiguration.of(context);
    return ScrollConfiguration(
      behavior: behavior.copyWith(
        dragDevices: {...behavior.dragDevices, PointerDeviceKind.mouse},
        pointerAxisModifiers: {
          LogicalKeyboardKey.shiftLeft,
          LogicalKeyboardKey.shiftRight,
        },
      ),
      child: child,
    );
  }
}

/// Paint the interaction overlay above opaque cover images.
class CoverButton extends StatelessWidget {
  const CoverButton({
    super.key,
    required this.onTap,
    required this.child,
    required this.label,
    this.onLongPress,
    this.borderRadius = const BorderRadius.all(Radius.circular(8)),
  });

  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final Widget child;
  final String label;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: borderRadius,
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          ExcludeSemantics(
            child: ExcludeFocus(child: IgnorePointer(child: child)),
          ),
          Positioned.fill(
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                onTap: onTap,
                onLongPress: onLongPress,
                mouseCursor: SystemMouseCursors.click,
                child: Semantics(label: label, child: const SizedBox.expand()),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class SectionEmptyState extends StatelessWidget {
  const SectionEmptyState(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Icon(Icons.inbox_outlined, size: 18, color: colors.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: ts.s14.copyWith(color: colors.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

class ComicCoverButton extends StatelessWidget {
  const ComicCoverButton({
    super.key,
    required this.comic,
    required this.heroID,
    required this.onTap,
  });

  final Comic comic;
  final int heroID;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 98,
      child: CoverButton(
        label: comic.title,
        onTap: onTap,
        child: Hero(
          tag: 'cover$heroID',
          child: ColoredBox(
            color: context.colorScheme.surfaceContainerHigh,
            child: FallbackImage(
              image: comicCoverProvider(comic),
              fallback: _historyCoverFallback(comic),
              width: 98,
              height: 132,
              fit: BoxFit.cover,
            ),
          ),
        ),
      ),
    );
  }
}

class EpisodeGridItem {
  const EpisodeGridItem({
    required this.label,
    required this.onTap,
    this.selected = false,
    this.watched = false,
    this.downloaded = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool selected;
  final bool watched;
  final bool downloaded;
}

/// Equal-width episode tiles: narrow ones for numbers, wider ones for titles.
/// Long lists show a few rows and "Show all", always including the selected
/// episode.
class EpisodeGrid extends StatefulWidget {
  const EpisodeGrid({super.key, required this.items, this.maxRows = 4});

  final List<EpisodeGridItem> items;
  final int maxRows;

  @override
  State<EpisodeGrid> createState() => _EpisodeGridState();
}

class _EpisodeGridState extends State<EpisodeGrid> {
  bool showAll = false;

  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    final numeric = items.every((e) => e.label.length <= 4);
    final minWidth = numeric ? 64.0 : 160.0;
    const spacing = 8.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = math.max(
          1,
          ((constraints.maxWidth + spacing) / (minWidth + spacing)).floor(),
        );
        final width =
            (constraints.maxWidth - spacing * (columns - 1)) / columns;
        var count = items.length;
        if (!showAll) {
          var limit = columns * widget.maxRows;
          final selected = items.indexWhere((e) => e.selected);
          if (selected >= limit) {
            limit = (selected ~/ columns + 1) * columns;
          }
          count = math.min(count, limit);
        }
        return Column(
          children: [
            Wrap(
              spacing: spacing,
              runSpacing: spacing,
              children: [
                for (var i = 0; i < count; i++)
                  SizedBox(width: width, child: _EpisodeTile(items[i])),
              ],
            ),
            if (count < items.length)
              TextButton(
                style: TextButton.styleFrom(
                  minimumSize: Size.zero,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: () => setState(() => showAll = true),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text("${"Show all".tl} (${items.length})"),
                    const SizedBox(width: 4),
                    const Icon(Icons.expand_more, size: 18),
                  ],
                ),
              ).paddingTop(8),
          ],
        );
      },
    );
  }
}

class _EpisodeTile extends StatelessWidget {
  const _EpisodeTile(this.item);

  final EpisodeGridItem item;

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    return Material(
      color: item.selected
          ? colors.secondaryContainer
          : colors.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: item.selected ? null : item.onTap,
        child: SizedBox(
          height: 44,
          child: Stack(
            children: [
              Center(
                child: Text(
                  item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ts.s14.copyWith(
                    fontWeight: item.selected ? FontWeight.w600 : null,
                    color: item.selected
                        ? colors.onSecondaryContainer
                        : item.watched
                        ? colors.outline
                        : colors.onSurface,
                  ),
                ).paddingHorizontal(8),
              ),
              if (item.downloaded)
                Positioned(
                  right: 6,
                  top: 4,
                  child: Icon(
                    Icons.download_done_rounded,
                    size: 12,
                    color: colors.primary,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Centers secondary page content without changing its scroll viewport height.
class AppContentWidth extends StatelessWidget {
  const AppContentWidth({super.key, required this.child, this.maxWidth = 1200});

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: SizedBox(width: double.infinity, child: child),
      ),
    );
  }
}

/// A compact, scrollable dialog for secondary page forms.
class AppSurfaceDialog extends StatelessWidget {
  const AppSurfaceDialog({
    super.key,
    this.title,
    required this.content,
    this.actions = const [],
  });

  final String? title;
  final Widget content;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: context.colorScheme.surfaceContainerLow,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (title != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 12, 12),
                  child: Row(
                    children: [
                      Expanded(child: Text(title!, style: ts.s18)),
                      IconButton(
                        tooltip: 'Close'.tl,
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
              content,
              if (actions.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 8,
                    runSpacing: 8,
                    children: actions,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
