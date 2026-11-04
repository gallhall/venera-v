part of 'components.dart';

/// Keeps the label's footprint while an action is in progress.
/// The enclosing Material button must set onPressed to null while loading.
class LoadingButtonChild extends StatelessWidget {
  const LoadingButtonChild({
    super.key,
    required this.isLoading,
    required this.child,
    required this.color,
  });

  final bool isLoading;
  final Widget child;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        Visibility(
          visible: !isLoading,
          maintainSize: true,
          maintainAnimation: true,
          maintainState: true,
          child: child,
        ),
        if (isLoading)
          SizedBox(
            width: AppSpacing.lg,
            height: AppSpacing.lg,
            child: CircularProgressIndicator(strokeWidth: 2, color: color),
          ),
      ],
    );
  }
}

class MenuButton extends StatefulWidget {
  const MenuButton({
    super.key,
    required this.entries,
    this.icon = Icons.more_horiz_outlined,
    this.tooltip,
    this.title,
    this.color,
  });

  final IconData icon;
  final String? tooltip;
  final String? title;
  final Color? color;

  final List<MenuEntry> entries;

  @override
  State<MenuButton> createState() => _MenuButtonState();
}

class _MenuButtonState extends State<MenuButton> {
  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: widget.tooltip ?? 'more'.tl,
      icon: Icon(widget.icon, color: widget.color),
      onPressed: () {
        var renderBox = context.findRenderObject() as RenderBox;
        var offset = renderBox.localToGlobal(Offset.zero);
        showMenuX(
          context,
          offset,
          widget.entries,
          title: widget.title,
        );
      },
    );
  }
}
