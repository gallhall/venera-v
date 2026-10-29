/// Resolution of the playing video, using the shorter side for portrait.
String? videoResolutionLabel(num? width, num? height) {
  if (width == null ||
      height == null ||
      !width.isFinite ||
      !height.isFinite ||
      width <= 0 ||
      height <= 0) {
    return null;
  }
  final shorter = (width < height ? width : height).floor();
  if (shorter >= 2160) {
    return '4K';
  }
  for (final threshold in [1440, 1080, 720, 480]) {
    if (shorter >= threshold) {
      return '${threshold}P';
    }
  }
  return '${shorter}P';
}
