part of 'components.dart';

class FallbackImage extends StatefulWidget {
  const FallbackImage({
    super.key,
    this.image,
    this.fallback,
    this.onFallback,
    this.width,
    this.height,
    this.fit,
  });

  final ImageProvider? image;
  final ImageProvider? fallback;
  final VoidCallback? onFallback;
  final double? width;
  final double? height;
  final BoxFit? fit;

  @override
  State<FallbackImage> createState() => _FallbackImageState();
}

class _FallbackImageState extends State<FallbackImage> {
  bool failed = false;

  @override
  void didUpdateWidget(FallbackImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image != widget.image ||
        oldWidget.fallback != widget.fallback) {
      failed = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    var useFallback = widget.image == null || failed;
    var image = useFallback ? widget.fallback ?? widget.image : widget.image;
    if (image == null) return const SizedBox();
    return AnimatedImage(
      key: ValueKey(image),
      image: image,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      onError: useFallback || widget.fallback == null
          ? null
          : (Object error, StackTrace? stack) {
              // Cached errors may arrive during build.
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted ||
                    widget.image != image ||
                    widget.fallback == null ||
                    failed) {
                  return;
                }
                setState(() => failed = true);
                widget.onFallback?.call();
              });
            },
    );
  }
}
