part of "components.dart";

void showMenuX(BuildContext context, Offset location, List<MenuEntry> entries,
    {String? title}) {
  if (App.isDesktop) {
    Navigator.of(context, rootNavigator: true).push(_MenuRoute(entries, location));
  } else {
    showActionSheet(context, entries, title: title);
  }
}

class _MenuRoute<T> extends PopupRoute<T> {
  final List<MenuEntry> entries;

  final Offset location;

  _MenuRoute(this.entries, this.location);

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => "menu";

  double get entryHeight => 36;

  @override
  Widget buildPage(BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation) {
    var width = entries.first.icon == null ? 216.0 : 242.0;
    final size = MediaQuery.of(context).size;
    var left = location.dx;
    if (left < 10) {
      left = 10;
    } 
    if (left + width > size.width - 10) {
      left = size.width - width - 10;
    }
    var top = location.dy;
    var height = 16 + entryHeight * entries.length;
    if (top + height > size.height - 15) {
      top = size.height - height - 15;
    }
    return Stack(
      children: [
        Positioned(
          left: left,
          top: top,
          child: Material(
            color: context.colorScheme.surfaceContainer,
            elevation: 3,
            shadowColor: context.colorScheme.shadow,
            surfaceTintColor: context.colorScheme.surface.withValues(alpha: 0),
            borderRadius: BorderRadius.circular(AppRadius.md),
            clipBehavior: Clip.antiAlias,
            child: Container(
              width: width,
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: entries.map((e) => buildEntry(e, context)).toList(),
              ),
            ),
          ),
        )
      ],
    );
  }

  Widget buildEntry(MenuEntry entry, BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.sm),
      onTap: () {
        Navigator.of(context).pop();
        entry.onClick();
      },
      child: SizedBox(
        height: entryHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              if (entry.icon != null)
                Icon(
                  entry.icon,
                  size: 18,
                  color: entry.color ?? context.colorScheme.onSurface,
                ),
              const SizedBox(width: 12),
              Text(
                entry.text,
                style: ts.s14.copyWith(
                  color: entry.color ?? context.colorScheme.onSurface),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Duration get transitionDuration => const Duration(milliseconds: 200);

  @override
  Widget buildTransitions(BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation, Widget child) {
    return FadeTransition(
      opacity: animation.drive(Tween<double>(begin: 0, end: 1)
          .chain(CurveTween(curve: Curves.ease))),
      child: child,
    );
  }
}

class MenuEntry {
  final String text;
  final IconData? icon;
  final Color? color;
  final void Function() onClick;

  MenuEntry({required this.text, this.icon, this.color, required this.onClick});
}
