part of 'components.dart';

/// Colours for chrome drawn directly over video frames or comic pages, which
/// can be any colour: a dark scrim with light content, independent of theme.
abstract final class MediaOverlayColors {
  static const scrim = Color(0x99000000);
  static const scrimLight = Color(0x59000000);
  static const content = Colors.white;
  static const contentMuted = Colors.white70;
  static const track = Colors.white24;
  static const shade = Color(0x8A000000);
  static const dim = Color(0x66000000);
  static const warning = Colors.redAccent;
}

/// The one pill for text/icon hints and small buttons over media.
class MediaPill extends StatelessWidget {
  const MediaPill({
    super.key,
    this.icon,
    this.label,
    this.child,
    this.onTap,
    this.tooltip,
  }) : assert(child == null || (icon == null && label == null));

  final IconData? icon;
  final String? label;
  final Widget? child;
  final VoidCallback? onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(AppRadius.pill);
    final body = ConstrainedBox(
      constraints: BoxConstraints(minHeight: onTap == null ? 36 : 40),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        child: DefaultTextStyle.merge(
          style: ts.s14.copyWith(color: MediaOverlayColors.content),
          child: IconTheme(
            data: const IconThemeData(
              size: 20,
              color: MediaOverlayColors.content,
            ),
            child:
                child ??
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (icon != null)
                      Icon(icon, size: 20, color: MediaOverlayColors.content),
                    if (icon != null && label != null)
                      const SizedBox(width: AppSpacing.sm),
                    if (label != null)
                      Flexible(
                        child: Text(
                          label!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ts.s14.copyWith(
                            color: MediaOverlayColors.content,
                          ),
                        ),
                      ),
                  ],
                ),
          ),
        ),
      ),
    );
    if (onTap == null) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: MediaOverlayColors.scrim,
          borderRadius: radius,
        ),
        child: body,
      );
    }
    Widget button = Semantics(
      button: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Material(
          color: MediaOverlayColors.scrim,
          borderRadius: radius,
          clipBehavior: Clip.antiAlias,
          child: InkWell(onTap: onTap, borderRadius: radius, child: body),
        ),
      ),
    );
    if (tooltip != null) {
      button = Tooltip(message: tooltip!, child: button);
    }
    return button;
  }
}

/// Round button drawn directly over media.
class MediaRoundButton extends StatelessWidget {
  const MediaRoundButton({
    super.key,
    required this.icon,
    required this.onPressed,
    required this.tooltip,
    this.size = 56,
    this.iconSize = 24,
    this.light = false,
  });

  final IconData icon;
  final double size;
  final double iconSize;
  final VoidCallback? onPressed;
  final String tooltip;
  final bool light;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon),
      style: IconButton.styleFrom(
        fixedSize: Size.square(size),
        iconSize: iconSize,
        foregroundColor: MediaOverlayColors.content,
        disabledForegroundColor: MediaOverlayColors.content,
        backgroundColor: light
            ? MediaOverlayColors.scrimLight
            : MediaOverlayColors.scrim,
        disabledBackgroundColor: light
            ? MediaOverlayColors.scrimLight
            : MediaOverlayColors.scrim,
        shape: const CircleBorder(),
      ),
    );
  }
}

class MediaErrorView extends StatelessWidget {
  const MediaErrorView({
    super.key,
    required this.message,
    this.cause,
    this.title,
    this.retry,
    this.secondaryLabel,
    this.onSecondary,
    this.onBack,
    this.backTooltip,
  }) : assert(onSecondary == null || secondaryLabel != null);

  final String message;
  final Object? cause;
  final String? title;
  final VoidCallback? retry;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;
  final VoidCallback? onBack;
  final String? backTooltip;

  @override
  Widget build(BuildContext context) {
    final error = friendlyError(message, cause: cause);
    return Material(
      color: Colors.black,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxHeight < 300;
          return Stack(
            children: [
              Center(
                child: SingleChildScrollView(
                  padding: EdgeInsets.symmetric(
                    horizontal: 56,
                    vertical: compact ? AppSpacing.sm : AppSpacing.lg,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title ?? error.title,
                        textAlign: TextAlign.center,
                        style: ts.s16.copyWith(
                          fontWeight: FontWeight.w600,
                          color: MediaOverlayColors.content,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      Text(
                        error.summary,
                        maxLines: compact ? 2 : 3,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: ts.s14.copyWith(
                          color: MediaOverlayColors.contentMuted,
                        ),
                      ),
                      SizedBox(height: compact ? AppSpacing.sm : AppSpacing.lg),
                      Wrap(
                        spacing: AppSpacing.sm,
                        runSpacing: AppSpacing.xs,
                        alignment: WrapAlignment.center,
                        children: [
                          if (retry != null)
                            FilledButton(
                              onPressed: retry,
                              child: Text('Retry'.tl),
                            ),
                          if (onSecondary != null)
                            OutlinedButton(
                              onPressed: onSecondary,
                              style: OutlinedButton.styleFrom(
                                foregroundColor: MediaOverlayColors.content,
                                side: const BorderSide(
                                  color: MediaOverlayColors.content,
                                ),
                              ),
                              child: Text(secondaryLabel!),
                            ),
                          TextButton(
                            style: TextButton.styleFrom(
                              foregroundColor: MediaOverlayColors.contentMuted,
                            ),
                            onPressed: () => showErrorDetails(context, message),
                            child: Text('Details'.tl),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              if (onBack != null)
                Positioned.fill(
                  child: SafeArea(
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: Padding(
                        padding: const EdgeInsets.all(AppSpacing.sm),
                        child: IconButton(
                          tooltip: backTooltip ?? 'Back'.tl,
                          color: MediaOverlayColors.content,
                          icon: const Icon(Icons.arrow_back_outlined),
                          onPressed: onBack,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
