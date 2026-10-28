part of 'comic_page.dart';

bool _shouldBlockComment(Comment comment) {
  var blockedWords = appdata.settings["blockedCommentWords"] as List;
  if (blockedWords.isEmpty) {
    return false;
  }

  var content = comment.content.toLowerCase();
  for (var word in blockedWords) {
    if (content.contains(word.toString().toLowerCase())) {
      return true;
    }
  }
  return false;
}

class CommentsPage extends StatefulWidget {
  const CommentsPage({
    super.key,
    required this.data,
    required this.source,
    this.replyComment,
  });

  final ComicDetails data;

  final ComicSource source;

  final Comment? replyComment;

  @override
  State<CommentsPage> createState() => _CommentsPageState();
}

class _CommentsPageState extends State<CommentsPage> {
  bool _loading = true;
  List<Comment>? _comments;
  String? _error;
  int _page = 1;
  int? maxPage;
  var controller = TextEditingController();
  bool sending = false;

  void firstLoad() async {
    var res = await widget.source.commentsLoader!(
      widget.data.comicId,
      widget.data.subId,
      1,
      widget.replyComment?.id,
    );
    if (res.error) {
      setState(() {
        _error = res.errorMessage;
        _loading = false;
      });
    } else if (mounted) {
      var filteredComments = res.data
          .where((c) => !_shouldBlockComment(c))
          .toList();
      setState(() {
        _comments = filteredComments;
        _loading = false;
        maxPage = res.subData;
      });
    }
  }

  void loadMore() async {
    var res = await widget.source.commentsLoader!(
      widget.data.comicId,
      widget.data.subId,
      _page + 1,
      widget.replyComment?.id,
    );
    if (res.error) {
      context.showMessage(message: res.errorMessage ?? "Unknown Error");
    } else {
      var filteredComments = res.data
          .where((c) => !_shouldBlockComment(c))
          .toList();
      setState(() {
        _comments!.addAll(filteredComments);
        _page++;
        if (maxPage == null && res.data.isEmpty) {
          maxPage = _page;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: Appbar(title: Text("Comments".tl)),
      body: AppContentWidth(maxWidth: 800, child: buildBody(context)),
    );
  }

  Widget buildBody(BuildContext context) {
    if (_loading) {
      firstLoad();
      return const Center(child: CircularProgressIndicator());
    } else if (_error != null) {
      return NetworkError(
        message: _error!,
        retry: () {
          setState(() {
            _loading = true;
          });
        },
        withAppbar: false,
      );
    } else {
      var showAvatar =
          _comments!.any((e) {
            return e.avatar != null;
          }) ||
          (widget.replyComment?.avatar != null);
      return Column(
        children: [
          Expanded(
            child: SmoothScrollProvider(
              builder: (context, controller, physics) {
                return ListView.builder(
                  controller: controller,
                  physics: physics,
                  primary: false,
                  padding: EdgeInsets.zero,
                  itemCount: _comments!.length + 2,
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      if (widget.replyComment != null) {
                        return Column(
                          children: [
                            Container(
                              margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                              decoration: BoxDecoration(
                                color: context.colorScheme.surfaceContainer,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: _CommentTile(
                                comment: widget.replyComment!,
                                source: widget.source,
                                comic: widget.data,
                                showAvatar: showAvatar,
                                showActions: false,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Container(
                              alignment: Alignment.centerLeft,
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                border: Border(
                                  top: BorderSide(
                                    color: context.colorScheme.outlineVariant,
                                    width: 0.6,
                                  ),
                                ),
                              ),
                              child: Text(
                                "Replies".tl,
                                style: ts.s14.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        );
                      } else {
                        return _comments!.isEmpty
                            ? SectionEmptyState('No comments yet'.tl)
                            : const SizedBox();
                      }
                    }
                    index--;

                    if (index == _comments!.length) {
                      if (_page < (maxPage ?? _page + 1)) {
                        loadMore();
                        return const ListLoadingIndicator();
                      } else {
                        return const SizedBox();
                      }
                    }

                    return _CommentTile(
                      comment: _comments![index],
                      source: widget.source,
                      comic: widget.data,
                      showAvatar: showAvatar,
                    );
                  },
                );
              },
            ),
          ),
          buildBottom(context),
        ],
      );
    }
  }

  Widget buildBottom(BuildContext context) {
    if (widget.source.sendCommentFunc == null) {
      return const SizedBox(height: 0);
    }
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
      decoration: BoxDecoration(color: context.colorScheme.surfaceContainer),
      child: Material(
        color: context.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(28),
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
                    borderRadius: BorderRadius.circular(28),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(28),
                    borderSide: BorderSide(color: context.colorScheme.primary),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  hintText: "Comment".tl,
                ),
                minLines: 1,
                maxLines: 5,
              ),
            ),
            const SizedBox(width: 8),
            if (sending)
              const Padding(
                padding: EdgeInsets.all(8),
                child: SizedBox(
                  width: 24,
                  height: 24,
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
                  var b = await widget.source.sendCommentFunc!(
                    widget.data.comicId,
                    widget.data.subId,
                    controller.text,
                    widget.replyComment?.id,
                  );
                  if (!b.error) {
                    controller.text = "";
                    setState(() {
                      sending = false;
                      _loading = true;
                      _comments?.clear();
                      _page = 1;
                      maxPage = null;
                    });
                  } else {
                    context.showMessage(message: b.errorMessage ?? "Error");
                    setState(() {
                      sending = false;
                    });
                  }
                },
                icon: const Icon(Icons.send),
              ),
          ],
        ).paddingRight(4),
      ),
    );
  }
}

class _CommentTile extends StatefulWidget {
  const _CommentTile({
    required this.comment,
    required this.source,
    required this.comic,
    required this.showAvatar,
    this.showActions = true,
  });

  final Comment comment;

  final ComicSource source;

  final ComicDetails comic;

  final bool showAvatar;

  final bool showActions;

  @override
  State<_CommentTile> createState() => _CommentTileState();
}

class _CommentTileState extends State<_CommentTile> {
  @override
  void initState() {
    likes = widget.comment.score ?? 0;
    isLiked = widget.comment.isLiked ?? false;
    voteStatus = widget.comment.voteStatus;
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.showAvatar)
            Container(
              width: 36,
              height: 36,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                color: context.colorScheme.surfaceContainerHigh,
              ),
              child: widget.comment.avatar == null
                  ? null
                  : AnimatedImage(
                      image: CachedImageProvider(
                        widget.comment.avatar!,
                        sourceKey: widget.source.key,
                      ),
                    ),
            ).paddingRight(8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.comment.userName,
                  style: ts.s14.copyWith(fontWeight: FontWeight.w600),
                ),
                if (widget.comment.time != null)
                  Text(
                    widget.comment.time!,
                    style: ts.s12.copyWith(
                      color: context.colorScheme.onSurfaceVariant,
                    ),
                  ),
                const SizedBox(height: 4),
                _CommentContent(text: widget.comment.content),
                buildActions(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget buildActions() {
    if (!widget.showActions) {
      return const SizedBox();
    }
    if (widget.comment.score == null && widget.comment.replyCount == null) {
      return const SizedBox();
    }
    return Align(
      alignment: Alignment.centerRight,
      child: Wrap(
        alignment: WrapAlignment.end,
        runSpacing: 4,
        children: [
          if (widget.comment.score != null &&
              widget.source.voteCommentFunc != null)
            buildVote(),
          if (widget.comment.score != null &&
              widget.source.likeCommentFunc != null)
            buildLike(),
          if (widget.comment.replyCount != null) buildReply(),
        ],
      ),
    ).paddingTop(8);
  }

  Widget buildReply() {
    return TextButton(
      style: TextButton.styleFrom(
        backgroundColor: context.colorScheme.surfaceContainerHigh,
        foregroundColor: context.colorScheme.onSurfaceVariant,
        minimumSize: const Size(0, 32),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      onPressed: () {
        showSideBar(
          context,
          CommentsPage(
            data: widget.comic,
            source: widget.source,
            replyComment: widget.comment,
          ),
          showBarrier: false,
        );
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.insert_comment_outlined, size: 16),
          const SizedBox(width: 8),
          Text(widget.comment.replyCount.toString()),
        ],
      ),
    ).paddingLeft(8);
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
        padding: const EdgeInsets.symmetric(horizontal: 12),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      onPressed: () async {
        if (isLiking) {
          return;
        }
        setState(() {
          isLiking = true;
        });
        var res = await widget.source.likeCommentFunc!(
          widget.comic.comicId,
          widget.comic.subId,
          widget.comment.id!,
          !isLiked,
        );
        if (res.success) {
          isLiked = !isLiked;
          likes += isLiked ? 1 : -1;
        } else {
          context.showMessage(message: res.errorMessage ?? "Error");
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
              width: 16,
              height: 16,
              child: CircularProgressIndicator(),
            )
          else if (isLiked)
            Icon(Icons.favorite, size: 16, color: context.colorScheme.primary)
          else
            const Icon(Icons.favorite_border, size: 16),
          const SizedBox(width: 8),
          Text(likes.toString()),
        ],
      ),
    ).paddingLeft(8);
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
    var res = await widget.source.voteCommentFunc!(
      widget.comic.comicId,
      widget.comic.subId,
      widget.comment.id!,
      isUp,
      isCancel,
    );
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
      context.showMessage(message: res.errorMessage ?? "Error");
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
      margin: const EdgeInsets.only(left: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: context.colorScheme.surfaceContainerHigh,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Button.icon(
            isLoading: isVotingUp,
            icon: const Icon(Icons.arrow_upward),
            size: 18,
            color: upColor,
            onPressed: () => vote(true),
          ),
          const SizedBox(width: 4),
          Text(widget.comment.score.toString()),
          const SizedBox(width: 4),
          Button.icon(
            isLoading: isVotingDown,
            icon: const Icon(Icons.arrow_downward),
            size: 18,
            color: downColor,
            onPressed: () => vote(false),
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
