import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera/components/components.dart';
import 'package:venera/components/rich_comment_content.dart';
import 'package:venera/foundation/bangumi/bangumi.dart';
import 'package:venera/foundation/context.dart';
import 'package:venera/foundation/image_provider/cached_image.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/widget_utils.dart';
import 'package:venera/pages/bangumi/bangumi_panel.dart';
import 'package:venera/pages/comments/comments.dart';
import 'package:venera/utils/translations.dart';

class EpisodeComments extends StatefulWidget {
  const EpisodeComments({
    super.key,
    required this.episodeId,
    required this.binding,
    required this.onLink,
  });

  final int? episodeId;
  final BangumiBinding? binding;
  final VoidCallback onLink;

  @override
  State<EpisodeComments> createState() => _EpisodeCommentsState();
}

class _EpisodeCommentsState extends State<EpisodeComments> {
  final api = BangumiApi();
  List<BangumiEpisodeComment> comments = [];
  final expanded = <int>{};
  bool loading = false;
  String? error;
  int request = 0;

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void didUpdateWidget(covariant EpisodeComments oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.episodeId != widget.episodeId ||
        oldWidget.binding?.subjectId != widget.binding?.subjectId) {
      load();
    }
  }

  Future<void> load() async {
    var token = ++request;
    var id = widget.episodeId;
    setState(() {
      comments = [];
      expanded.clear();
      error = null;
      loading = id != null;
    });
    if (id == null) {
      return;
    }
    try {
      var result = await api.episodeComments(id);
      if (!mounted || token != request) {
        return;
      }
      setState(() {
        comments = result;
        loading = false;
      });
    } catch (e, s) {
      Log.error('Bangumi', e.toString(), s);
      if (mounted && token == request) {
        setState(() {
          error = e.toString();
          loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget body;
    var binding = widget.binding;
    if (binding == null) {
      body = AppEmptyView(
        text: 'Not linked to Bangumi'.tl,
        action: FilledButton(
          onPressed: widget.onLink,
          child: Text('Link to Bangumi'.tl),
        ),
      );
    } else if (loading) {
      body = const AppLoadingView();
    } else if (error != null) {
      body = AppErrorView(message: error!, retry: load, withAppbar: false);
    } else if (comments.isEmpty) {
      body = AppEmptyView(
        text: 'No comments for this episode'.tl,
        action: TextButton(
          onPressed: () => showSubPage(
            context, BangumiCommentsPage(binding: binding)),
          child: Text('View all comments of the anime'.tl),
        ),
      );
    } else {
      body = ListView.builder(
        key: ValueKey(widget.episodeId),
        padding: const EdgeInsets.only(bottom: 88),
        itemCount: comments.length,
        itemBuilder: (context, index) => buildComment(comments[index]),
      );
    }
    return SafeArea(
      top: false,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Padding(
            padding: EdgeInsets.only(
              bottom: comments.isEmpty && widget.episodeId != null ? 80 : 0),
            child: body,
          ),
          if (widget.episodeId != null)
            Positioned(
              right: AppSpacing.lg,
              bottom: AppSpacing.lg,
              child: FloatingActionButton.extended(
                heroTag: null,
                onPressed: () => launchUrlString(
                  'https://bgm.tv/ep/${widget.episodeId}',
                  mode: LaunchMode.externalApplication,
                ),
                icon: const Icon(Icons.edit_outlined),
                label: Text('Post comment'.tl),
              ),
            ),
        ],
      ),
    );
  }

  Widget buildComment(BangumiEpisodeComment comment, {bool reply = false}) {
    var time = comment.time?.toLocal();
    String pad(int value) => value.toString().padLeft(2, '0');
    var isExpanded = expanded.contains(comment.id);
    return CommentCard(
      key: ValueKey(comment.id),
      padding: EdgeInsets.symmetric(
        horizontal: reply ? AppSpacing.sm : AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      avatarSpacing: AppSpacing.md,
      contentSpacing: 6,
      avatar: ClipOval(
        child: Container(
          color: context.colorScheme.surfaceContainerHigh,
          width: 36,
          height: 36,
          child: comment.user.avatar.isEmpty
              ? const Icon(Icons.person_outlined)
              : AnimatedImage(image: CachedImageProvider(comment.user.avatar)),
        ),
      ),
      name: comment.user.displayName,
      meta: Text(
        [
          'Bangumi',
          if (time != null)
            '${time.year}-${pad(time.month)}-${pad(time.day)} '
                '${pad(time.hour)}:${pad(time.minute)}',
        ].join(' · '),
        style: ts.s12.copyWith(color: context.colorScheme.onSurfaceVariant),
      ),
      content: DefaultTextStyle.merge(
        style: ts.s14,
        child: RichCommentContent(
          key: ValueKey(comment.content),
          text: comment.content,
          bangumi: true,
        ),
      ),
      actions: comment.replies.isEmpty ? null : Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextButton(
            onPressed: () => setState(() {
              if (isExpanded) {
                expanded.remove(comment.id);
              } else {
                expanded.add(comment.id);
              }
            }),
            child: Text(isExpanded
                ? 'Hide replies'.tl
                : comment.replies.length == 1
                    ? 'Show 1 reply'.tl
                    : 'Show @n replies'
                        .tlParams({'n': comment.replies.length})),
          ),
          if (isExpanded)
            for (var item in comment.replies) buildComment(item, reply: true),
        ],
      ),
    );
  }
}
