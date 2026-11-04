part of 'components.dart';

class AppLoadingView extends StatelessWidget {
  const AppLoadingView({super.key, this.size = 32});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(
        width: size,
        height: size,
        child: const CircularProgressIndicator(strokeWidth: 3),
      ),
    );
  }
}

class AppErrorView extends StatelessWidget {
  const AppErrorView({
    super.key,
    required this.message,
    this.cause,
    this.retry,
    this.retryText,
    this.action,
    this.withAppbar = false,
  }) : _inline = false;

  const AppErrorView.inline({
    super.key,
    required this.message,
    this.cause,
    this.retry,
    this.retryText,
    this.action,
  }) : _inline = true,
       withAppbar = false;

  final String message;
  final Object? cause;
  final VoidCallback? retry;
  final String? retryText;
  final Widget? action;
  final bool withAppbar;
  final bool _inline;

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    final error = friendlyError(message, cause: cause);
    final cloudflare = CloudflareException.fromString(message) ??
        (cause is CloudflareException ? cause as CloudflareException : null);
    final verify =
        error.kind == FriendlyErrorKind.cloudflare && cloudflare != null;
    final VoidCallback? onRetry;
    if (retry == null) {
      onRetry = null;
    } else if (cloudflare != null &&
        error.kind == FriendlyErrorKind.cloudflare) {
      onRetry = () => passCloudflare(cloudflare, retry!);
    } else {
      onRetry = retry;
    }
    final label = verify ? 'Verify'.tl : retryText ?? 'Retry'.tl;
    final details = TextButton(
      onPressed: () => showErrorDetails(context, message),
      child: Text('Details'.tl),
    );
    if (_inline) {
      const compact = ButtonStyle(
        padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 8)),
        minimumSize: WidgetStatePropertyAll(Size(0, 20)),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
      );
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(Icons.error_outline, size: 18, color: colors.error),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                [error.title, if (error.detail?.isNotEmpty == true) error.detail!]
                    .join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ts.s14.copyWith(color: colors.onSurfaceVariant),
              ),
            ),
            if (action != null) action!,
            if (onRetry != null)
              TextButton(
                onPressed: onRetry,
                style: compact,
                child: Text(label),
              ),
            TextButton(
              onPressed: () => showErrorDetails(context, message),
              style: compact,
              child: Text('Details'.tl),
            ),
          ],
        ),
      );
    }
    Widget body = Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 40, color: colors.error),
              const SizedBox(height: 8),
              Text(
                error.title,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ts.s16.copyWith(
                  fontWeight: FontWeight.w600,
                  color: colors.onSurface,
                ),
              ),
              if (error.detail?.isNotEmpty == true) ...[
                const SizedBox(height: 8),
                Text(
                  error.detail!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: ts.s14.copyWith(color: colors.onSurfaceVariant),
                ),
              ],
              if (action != null || onRetry != null) ...[
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    if (action != null) action!,
                    if (onRetry != null)
                      FilledButton(onPressed: onRetry, child: Text(label)),
                  ],
                ),
              ],
              details,
            ],
          ),
        ),
      ),
    );
    if (withAppbar) {
      body = Column(children: [
        const Appbar(title: Text('')),
        Expanded(child: body),
      ]);
    }
    return Material(child: body);
  }
}

Future<void> showErrorDetails(BuildContext context, String message) async {
  await showOptionsSheet<String>(
    context,
    title: 'Error details'.tl,
    forceBottomSheet: true,
    options: const {},
    content: Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.4,
            ),
            child: SingleChildScrollView(child: SelectableText(message)),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: message));
                  if (context.mounted) {
                    context.showMessage(message: 'Copied'.tl);
                  }
                },
                child: Text('Copy'.tl),
              ),
              TextButton(
                onPressed: () => saveFile(
                  data: utf8.encode(Log().toString()),
                  filename: 'log.txt',
                ),
                child: Text('Export logs'.tl),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class AppEmptyView extends StatelessWidget {
  const AppEmptyView({
    super.key,
    required this.text,
    this.icon = Icons.inbox_outlined,
    this.action,
  }) : _inline = false;

  const AppEmptyView.inline(this.text, {super.key})
      : icon = Icons.inbox_outlined,
        action = null,
        _inline = true;

  final String text;
  final IconData icon;
  final Widget? action;
  final bool _inline;

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    final style = ts.s14.copyWith(color: colors.onSurfaceVariant);
    if (_inline) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(children: [
          Icon(icon, size: 18, color: colors.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: style)),
        ]),
      );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: colors.onSurfaceVariant),
            const SizedBox(height: 8),
            Text(text, style: style, textAlign: TextAlign.center),
            if (action != null) ...[
              const SizedBox(height: 12),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

class ListFooter extends StatelessWidget {
  const ListFooter.loading({super.key})
      : message = null,
        cause = null,
        retry = null;

  const ListFooter.error({
    super.key,
    required String this.message,
    this.cause,
    required VoidCallback this.retry,
  });

  final String? message;
  final Object? cause;
  final VoidCallback? retry;

  @override
  Widget build(BuildContext context) {
    if (message != null) {
      return AppErrorView.inline(message: message!, cause: cause, retry: retry);
    }
    return const SizedBox(height: 56, child: AppLoadingView(size: 24));
  }
}

class SliverListFooter extends StatelessWidget {
  const SliverListFooter.loading({super.key})
      : footer = const ListFooter.loading();

  SliverListFooter.error({
    super.key,
    required String message,
    Object? cause,
    required VoidCallback retry,
  })
      : footer = ListFooter.error(message: message, cause: cause, retry: retry);

  final ListFooter footer;

  @override
  Widget build(BuildContext context) {
    // Keep the footer lazy so offscreen loading indicators do not animate.
    return SliverList.list(children: [const SizedBox(), footer]);
  }
}
