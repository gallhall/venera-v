import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:venera/components/components.dart';
import 'package:venera/components/rich_comment_content.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/image_provider/cached_image.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/utils/translations.dart';

/// What a comment thread belongs to: a comic, or one chapter of it.
class CommentTarget {
  CommentTarget.comic({
    required ComicSource source,
    required String comicId,
    String? subId,
    required String title,
  }) : this.custom(
         source: source,
         comicId: comicId,
         subId: subId,
         title: title,
         load: (page, replyTo) =>
             source.commentsLoader!(comicId, subId, page, replyTo),
         send: source.sendCommentFunc == null
             ? null
             : (content, replyTo) =>
                   source.sendCommentFunc!(comicId, subId, content, replyTo),
       );

  CommentTarget.chapter({
    required ComicSource source,
    required String comicId,
    required String epId,
    required String title,
    String? chapterTitle,
  }) : this.custom(
         source: source,
         comicId: comicId,
         subId: epId,
         title: title,
         isChapter: true,
         chapterTitle: chapterTitle,
         load: (page, replyTo) =>
             source.chapterCommentsLoader!(comicId, epId, page, replyTo),
         send: source.sendChapterCommentFunc == null
             ? null
             : (content, replyTo) => source.sendChapterCommentFunc!(
                 comicId,
                 epId,
                 content,
                 replyTo,
               ),
       );

  const CommentTarget.custom({
    required this.load,
    Future<Res<bool>> Function(String, String?)? send,
    this.source,
    this.comicId = '',
    this.subId,
    this.title = '',
    this.chapterTitle,
    this.isChapter = false,
  }) : _send = send;

  final ComicSource? source;
  final String comicId;

  /// Comic sub-id, or the chapter episode id.
  final String? subId;
  final String title;
  final String? chapterTitle;
  final bool isChapter;
  final Future<Res<List<Comment>>> Function(int page, String? replyTo) load;
  final Future<Res<bool>> Function(String content, String? replyTo)? _send;
  bool get canSend => _send != null;
  bool get canLike => source?.likeCommentFunc != null;
  bool get canVote => source?.voteCommentFunc != null;
  Future<Res<bool>> send(String content, String? replyTo) =>
      _send!(content, replyTo);
  Future<Res<int?>> like(String id, bool liking) =>
      source!.likeCommentFunc!(comicId, subId, id, liking);
  Future<Res<int?>> vote(String id, bool up, bool cancel) =>
      source!.voteCommentFunc!(comicId, subId, id, up, cancel);
}

bool shouldBlockComment(Comment comment) {
  var words = appdata.settings['blockedCommentWords'] as List;
  var content = comment.content.toLowerCase();
  return words.any((word) => content.contains(word.toString().toLowerCase()));
}

Widget _chapterHeading(CommentTarget target) => Column(
  crossAxisAlignment: CrossAxisAlignment.start,
  mainAxisSize: MainAxisSize.min,
  children: [
    Text(
      'Chapter Comments'.tl,
      style: ts.s14.copyWith(fontWeight: FontWeight.w600),
    ),
    Text(target.chapterTitle ?? '', style: ts.s12),
  ],
);

class CommentsPage extends StatelessWidget {
  const CommentsPage({super.key, required this.target, this.replyComment});
  final CommentTarget target;
  final Comment? replyComment;

  @override
  Widget build(BuildContext context) => Scaffold(
    resizeToAvoidBottomInset: false,
    appBar: Appbar(
      title: target.isChapter ? _chapterHeading(target) : Text('Comments'.tl),
    ),
    body: AppContentWidth(
      maxWidth: 800,
      child: CommentsView(target: target, replyComment: replyComment),
    ),
  );
}

class CommentsView extends StatefulWidget {
  const CommentsView({
    super.key,
    required this.target,
    this.replyComment,
    this.embedded = false,
    this.header,
  });
  final CommentTarget target;
  final Comment? replyComment;
  final bool embedded;
  final Widget? header;

  @override
  State<CommentsView> createState() => _CommentsViewState();
}

class _CommentsViewState extends State<CommentsView> {
  bool _loading = true;
  bool _loadingMore = false;
  final _comments = <Comment>[];
  String? _error;
  Object? _errorCause;
  String? _moreError;
  Object? _moreErrorCause;
  int _page = 1;
  int? maxPage;
  final controller = TextEditingController();
  final _scrollController = ScrollController();
  bool sending = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    firstLoad();
  }

  @override
  void didUpdateWidget(covariant CommentsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Reader rebuilds can create a new target for the same thread.
    if (oldWidget.target.source != widget.target.source ||
        oldWidget.target.comicId != widget.target.comicId ||
        oldWidget.target.subId != widget.target.subId ||
        oldWidget.target.isChapter != widget.target.isChapter ||
        oldWidget.replyComment?.id != widget.replyComment?.id ||
        (widget.target.source == null &&
            oldWidget.target.load != widget.target.load)) {
      firstLoad();
    }
  }

  @override
  void dispose() {
    controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<Res<List<Comment>>> _load(int page) async {
    try {
      return await widget.target.load(page, widget.replyComment?.id);
    } catch (e) {
      return Res.error(e.toString(), errorCause: e);
    }
  }

  Future<void> firstLoad() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
      _errorCause = null;
      _moreError = null;
      _moreErrorCause = null;
      _loadingMore = false;
      _page = 1;
      maxPage = null;
      _comments.clear();
    });
    var res = await _load(1);
    if (!mounted || generation != _generation) {
      return;
    }
    setState(() {
      _loading = false;
      if (res.error) {
        _error = res.errorMessage;
        _errorCause = res.errorCause;
      } else {
        _comments.addAll(res.data.where((c) => !shouldBlockComment(c)));
        maxPage = res.subData;
        if (maxPage == null && res.data.isEmpty) {
          maxPage = 1;
        }
      }
    });
  }

  Future<void> loadMore() async {
    if (_loadingMore || _page >= (maxPage ?? _page + 1)) {
      return;
    }
    final generation = _generation;
    _loadingMore = true;
    var res = await _load(_page + 1);
    if (!mounted || generation != _generation) {
      return;
    }
    setState(() {
      _loadingMore = false;
      if (res.error) {
        _moreError = res.errorMessage;
        _moreErrorCause = res.errorCause;
      } else {
        _moreError = null;
        _comments.addAll(res.data.where((c) => !shouldBlockComment(c)));
        _page++;
        if (maxPage == null && res.data.isEmpty) {
          maxPage = _page;
        }
      }
    });
  }

  Widget _footer() {
    if (_moreError != null) {
      return AppErrorView.inline(
        message: _moreError!,
        cause: _moreErrorCause,
        retry: loadMore,
      );
    }
    if (_page >= (maxPage ?? _page + 1)) {
      return const SizedBox();
    }
    // Schedule outside build and guard against repeated footer builds.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_loading && _moreError == null) {
        loadMore();
      }
    });
    return const ListFooter.loading();
  }

  Widget _list() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return AppErrorView(
        message: _error!,
        cause: _errorCause,
        retry: firstLoad,
        withAppbar: false,
      );
    }
    final showAvatar =
        _comments.any((c) => c.avatar != null) ||
        widget.replyComment?.avatar != null;
    Widget item(BuildContext context, int index) {
      if (index == 0) {
        return Column(
          children: [
            if (widget.replyComment != null) ...[
              Container(
                margin: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  AppSpacing.sm,
                  AppSpacing.lg,
                  0,
                ),
                decoration: BoxDecoration(
                  color: context.colorScheme.surfaceContainer,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: CommentTile(
                  comment: widget.replyComment!,
                  target: widget.target,
                  showAvatar: showAvatar,
                  showActions: false,
                ),
              ),
              Container(
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.all(AppSpacing.lg),
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(
                      color: context.colorScheme.outlineVariant,
                      width: 0.6,
                    ),
                  ),
                ),
                child: Text(
                  'Replies'.tl,
                  style: ts.s14.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            ],
            if (_comments.isEmpty) AppEmptyView.inline('No comments yet'.tl),
          ],
        );
      }
      if (index == _comments.length + 1) {
        return _footer();
      }
      return CommentTile(
        key: ObjectKey(_comments[index - 1]),
        comment: _comments[index - 1],
        target: widget.target,
        showAvatar: showAvatar,
      );
    }

    if (widget.embedded) {
      return Scrollbar(
        controller: _scrollController,
        thumbVisibility: true,
        thickness: AppSpacing.sm,
        child: MasonryGridView.count(
          controller: _scrollController,
          crossAxisCount:
              MediaQuery.orientationOf(context) == Orientation.landscape
              ? 2
              : 1,
          mainAxisSpacing: 0,
          crossAxisSpacing: 0,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
          itemCount: _comments.length + 2,
          itemBuilder: item,
        ),
      );
    }
    return SmoothScrollProvider(
      builder: (context, scroll, physics) => ListView.builder(
        controller: scroll,
        physics: physics,
        primary: false,
        padding: EdgeInsets.zero,
        itemCount: _comments.length + 2,
        itemBuilder: item,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.embedded) {
      return Column(
        children: [
          if (widget.header != null) widget.header!,
          Expanded(child: _list()),
          if (!_loading && _error == null) buildBottom(context),
        ],
      );
    }
    return Container(
      color: context.colorScheme.surface,
      child: SafeArea(
        child: Column(
          children: [
            widget.header ??
                Container(
                  padding: const EdgeInsets.all(AppSpacing.sm),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: context.colorScheme.outlineVariant,
                        width: 0.6,
                      ),
                    ),
                  ),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back_outlined),
                        tooltip: 'Exit'.tl,
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      const Icon(Icons.comment_outlined, size: 24),
                      const SizedBox(width: AppSpacing.md),
                      Expanded(child: _chapterHeading(widget.target)),
                    ],
                  ),
                ),
            Expanded(child: AppContentWidth(maxWidth: 800, child: _list())),
            AppContentWidth(maxWidth: 800, child: buildBottom(context)),
            SizedBox(height: MediaQuery.viewInsetsOf(context).bottom),
          ],
        ),
      ),
    );
  }

  Widget buildBottom(BuildContext context) {
    if (!widget.target.canSend) {
      return const SizedBox(height: 0);
    }
    return Container(
      padding: const EdgeInsets.symmetric(
        vertical: AppSpacing.sm,
        horizontal: AppSpacing.sm,
      ),
      decoration: BoxDecoration(color: context.colorScheme.surfaceContainer),
      child: Material(
        color: context.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(AppRadius.xl),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                decoration: InputDecoration(
                  border: InputBorder.none,
                  filled: true,
                  fillColor: context.colorScheme.surfaceContainerHigh,
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadius.xl),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadius.xl),
                    borderSide: BorderSide(color: context.colorScheme.primary),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.lg,
                    vertical: AppSpacing.md,
                  ),
                  hintText: "Comment".tl,
                ),
                minLines: 1,
                maxLines: 5,
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            if (sending)
              const Padding(
                padding: EdgeInsets.all(AppSpacing.sm),
                child: SizedBox(
                  width: AppSpacing.xl,
                  height: AppSpacing.xl,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else
              IconButton.filled(
                tooltip: "Send".tl,
                onPressed: () async {
                  if (controller.text.isEmpty) {
                    return;
                  }
                  setState(() {
                    sending = true;
                  });
                  var b = await widget.target.send(
                    controller.text,
                    widget.replyComment?.id,
                  );
                  if (!mounted) {
                    return;
                  }
                  setState(() => sending = false);
                  if (!b.error) {
                    controller.clear();
                    firstLoad();
                  } else {
                    context.showMessage(message: b.errorMessage ?? "Error".tl);
                  }
                },
                icon: const Icon(Icons.send_outlined),
              ),
          ],
        ).paddingRight(AppSpacing.xs),
      ),
    );
  }
}

/// Shared presentation only; callers retain their own comment models and actions.
class CommentCard extends StatelessWidget {
  const CommentCard({
    super.key,
    this.avatar,
    required this.name,
    this.meta,
    required this.content,
    this.actions,
    this.compact = false,
    this.padding = const EdgeInsets.symmetric(
      vertical: AppSpacing.sm,
      horizontal: AppSpacing.lg,
    ),
    this.avatarSpacing = AppSpacing.sm,
    this.contentSpacing = AppSpacing.xs,
  });
  final Widget? avatar;
  final String name;
  final Widget? meta;
  final Widget content;
  final Widget? actions;
  final bool compact;
  final EdgeInsetsGeometry padding;
  final double avatarSpacing;
  final double contentSpacing;

  @override
  Widget build(BuildContext context) {
    final nameWidget = Text(
      name,
      maxLines: compact ? 1 : null,
      overflow: compact ? TextOverflow.ellipsis : null,
      style: ts.s14.copyWith(fontWeight: FontWeight.w600),
    );
    if (compact) {
      return Padding(
        padding: padding,
        child: Column(
          children: [
            Row(
              children: [
                if (avatar != null) ...[
                  avatar!,
                  SizedBox(width: avatarSpacing),
                ],
                Expanded(child: nameWidget),
              ],
            ),
            SizedBox(height: contentSpacing),
            Expanded(child: content),
            SizedBox(height: contentSpacing),
            if (meta != null)
              Align(alignment: Alignment.centerLeft, child: meta!),
          ],
        ),
      );
    }
    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (avatar != null) ...[avatar!, SizedBox(width: avatarSpacing)],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                nameWidget,
                if (meta != null) meta!,
                SizedBox(height: contentSpacing),
                content,
                if (actions != null) actions!,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class CommentTile extends StatefulWidget {
  const CommentTile({
    super.key,
    required this.comment,
    required this.target,
    this.showAvatar = false,
    this.compact = false,
    this.showActions = true,
  });

  final Comment comment;

  final CommentTarget target;

  final bool showAvatar;

  final bool showActions;

  final bool compact;

  @override
  State<CommentTile> createState() => _CommentTileState();
}

class _CommentTileState extends State<CommentTile> {
  @override
  void initState() {
    likes = widget.comment.score ?? 0;
    isLiked = widget.comment.isLiked ?? false;
    voteStatus = widget.comment.voteStatus;
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return CommentCard(
      compact: widget.compact,
      padding: widget.compact
          ? const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            )
          : const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.sm,
            ),
      avatar: widget.showAvatar
          ? Container(
              width: 36,
              height: 36,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadius.lg),
                color: context.colorScheme.surfaceContainerHigh,
              ),
              child: widget.comment.avatar == null
                  ? null
                  : widget.compact
                  ? Image(
                      image: CachedImageProvider(widget.comment.avatar!),
                      width: 36,
                      height: 36,
                      fit: BoxFit.cover,
                    )
                  : AnimatedImage(
                      image: CachedImageProvider(
                        widget.comment.avatar!,
                        sourceKey: widget.target.source?.key,
                      ),
                    ),
            )
          : null,
      name: widget.comment.userName,
      meta: widget.comment.time == null
          ? null
          : Text(
              widget.comment.time!,
              style: ts.s12.copyWith(
                color: context.colorScheme.onSurfaceVariant,
              ),
            ),
      content: widget.compact
          ? RichCommentContent(
              text: widget.comment.content,
              showImages: false,
            ).fixWidth(324)
          : _CommentContent(text: widget.comment.content),
      actions: buildActions(),
    );
  }

  Widget buildActions() {
    if (!widget.showActions || widget.compact) {
      return const SizedBox();
    }
    if (widget.comment.score == null && widget.comment.replyCount == null) {
      return const SizedBox();
    }
    return Align(
      alignment: Alignment.centerRight,
      child: Wrap(
        alignment: WrapAlignment.end,
        runSpacing: AppSpacing.xs,
        children: [
          if (widget.comment.score != null && widget.target.canVote)
            buildVote(),
          if (widget.comment.score != null && widget.target.canLike)
            buildLike(),
          if (widget.comment.replyCount != null && widget.comment.id != null)
            buildReply(),
        ],
      ),
    ).paddingTop(AppSpacing.sm);
  }

  Widget buildReply() {
    return TextButton(
      style: TextButton.styleFrom(
        backgroundColor: context.colorScheme.surfaceContainerHigh,
        foregroundColor: context.colorScheme.onSurfaceVariant,
        minimumSize: const Size(0, 32),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      onPressed: () {
        showSideBar(
          context,
          CommentsPage(target: widget.target, replyComment: widget.comment),
          showBarrier: false,
        );
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.insert_comment_outlined, size: 16),
          const SizedBox(width: AppSpacing.sm),
          Text(widget.comment.replyCount.toString()),
        ],
      ),
    ).paddingLeft(AppSpacing.sm);
  }

  bool isLiking = false;

  bool isLiked = false;

  var likes = 0;

  Widget buildLike() {
    return TextButton(
      style: TextButton.styleFrom(
        backgroundColor: context.colorScheme.surfaceContainerHigh,
        foregroundColor: isLiked
            ? context.colorScheme.primary
            : context.colorScheme.onSurfaceVariant,
        minimumSize: const Size(0, 32),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      onPressed: () async {
        if (isLiking) {
          return;
        }
        setState(() {
          isLiking = true;
        });
        var res = await widget.target.like(widget.comment.id!, !isLiked);
        if (!mounted) {
          return;
        }
        if (res.success) {
          isLiked = !isLiked;
          likes += isLiked ? 1 : -1;
        } else {
          context.showMessage(message: res.errorMessage ?? "Error".tl);
        }
        setState(() {
          isLiking = false;
        });
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isLiking)
            const SizedBox(
              width: AppSpacing.lg,
              height: AppSpacing.lg,
              child: CircularProgressIndicator(),
            )
          else if (isLiked)
            Icon(
              Icons.favorite_outlined,
              size: 16,
              color: context.colorScheme.primary,
            )
          else
            const Icon(Icons.favorite_border_outlined, size: 16),
          const SizedBox(width: AppSpacing.sm),
          Text(likes.toString()),
        ],
      ),
    ).paddingLeft(AppSpacing.sm);
  }

  int? voteStatus;

  bool isVotingUp = false;

  bool isVotingDown = false;

  void vote(bool isUp) async {
    if (isVotingUp || isVotingDown) {
      return;
    }
    setState(() {
      if (isUp) {
        isVotingUp = true;
      } else {
        isVotingDown = true;
      }
    });
    var isCancel = (isUp && voteStatus == 1) || (!isUp && voteStatus == -1);
    var res = await widget.target.vote(widget.comment.id!, isUp, isCancel);
    if (!mounted) {
      return;
    }
    if (res.success) {
      if (isCancel) {
        voteStatus = 0;
      } else {
        if (isUp) {
          voteStatus = 1;
        } else {
          voteStatus = -1;
        }
      }
      widget.comment.voteStatus = voteStatus;
      widget.comment.score = res.data ?? widget.comment.score;
    } else {
      context.showMessage(message: res.errorMessage ?? "Error".tl);
    }
    setState(() {
      isVotingUp = false;
      isVotingDown = false;
    });
  }

  Widget buildVote() {
    var upColor = context.colorScheme.outline;
    if (voteStatus == 1) {
      upColor = context.colorScheme.primary;
    }
    var downColor = context.colorScheme.outline;
    if (voteStatus == -1) {
      downColor = context.colorScheme.primary;
    }

    return Container(
      margin: const EdgeInsets.only(left: AppSpacing.sm),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        color: context.colorScheme.surfaceContainerHigh,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Tooltip(
            message: "Upvote".tl,
            child: Button.icon(
              isLoading: isVotingUp,
              icon: const Icon(Icons.arrow_upward_outlined),
              size: 18,
              color: upColor,
              onPressed: () => vote(true),
            ),
          ),
          const SizedBox(width: AppSpacing.xs),
          Text(widget.comment.score.toString()),
          const SizedBox(width: AppSpacing.xs),
          Tooltip(
            message: "Downvote".tl,
            child: Button.icon(
              isLoading: isVotingDown,
              icon: const Icon(Icons.arrow_downward_outlined),
              size: 18,
              color: downColor,
              onPressed: () => vote(false),
            ),
          ),
        ],
      ),
    );
  }
}

class _CommentContent extends StatelessWidget {
  const _CommentContent({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    if (!text.contains('<') && !text.contains('http')) {
      return SelectableText(text, style: ts.s14);
    } else {
      return DefaultTextStyle.merge(
        style: ts.s14,
        child: RichCommentContent(text: text),
      );
    }
  }
}
