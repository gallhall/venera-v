part of 'components.dart';

class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.onTap,
    this.highlighted = false,
    this.margin = const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    this.padding,
  });

  final Widget child;
  final VoidCallback? onTap;
  final bool highlighted;
  final EdgeInsetsGeometry margin;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    Widget content = padding == null
        ? child
        : Padding(padding: padding!, child: child);
    if (onTap != null) {
      content = InkWell(onTap: onTap, child: content);
    }
    return Card(
      elevation: 0,
      color: colors.surfaceContainerLow,
      margin: margin,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: highlighted ? colors.primary : colors.outlineVariant,
          width: highlighted ? 1.5 : 0.6,
        ),
      ),
      child: content,
    );
  }
}

class AppBadge extends StatelessWidget {
  const AppBadge(this.text, {super.key, this.highlighted = false});

  final String text;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: highlighted ? colors.primaryContainer : colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: ts.s12.copyWith(
          color: highlighted ? colors.onPrimaryContainer : colors.onSurfaceVariant,
        ),
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
    final foreground = iconColor ??
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
  late final controller = AnimationController(
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
              child: ListView(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                children: [
                  for (final option in options.entries)
                    OptionRow(
                      text: option.value,
                      selected: option.key == selected,
                      onTap: () => Navigator.of(context).pop(option.key),
                    ),
                ],
              ),
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
              selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
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
