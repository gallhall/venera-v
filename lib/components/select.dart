part of 'components.dart';

class Select extends StatelessWidget {
  const Select({
    super.key,
    required this.current,
    required this.values,
    this.onTap,
    this.minWidth,
    this.title,
  });

  final String? current;

  final List<String> values;

  final void Function(int index)? onTap;

  final double? minWidth;

  final String? title;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        minimumSize: Size(minWidth ?? 0, 32),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.xs),
        ),
      ),
      onPressed: () async {
        final index = await showOptionsSheet<int>(
          context,
          title: title,
          options: {for (var i = 0; i < values.length; i++) i: values[i]},
          selected: current == null ? null : values.indexOf(current!),
        );
        if (index != null) {
          onTap?.call(index);
        }
      },
      icon: const Icon(Icons.expand_more_outlined, size: 20),
      iconAlignment: IconAlignment.end,
      label: Text(current ?? ' ', style: ts.s14),
    );
  }
}
