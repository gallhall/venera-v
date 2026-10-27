part of 'comic_page.dart';

class _CommentsPart extends StatefulWidget {
  const _CommentsPart({
    required this.comments,
    required this.showMore,
  });

  final List<Comment> comments;

  final void Function() showMore;

  @override
  State<_CommentsPart> createState() => _CommentsPartState();
}

class _CommentsPartState extends State<_CommentsPart> {
  final scrollController = ScrollController();

  late List<Comment> comments;

  @override
  void initState() {
    comments = widget.comments.where((c) => !_shouldBlockComment(c)).toList();
    super.initState();
  }

  @override
  void dispose() {
    scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: SectionCard(
        icon: Icons.chat_bubble_outline,
        title: "Comments".tl,
        collapseKey: 'comments',
        bodyPadding: EdgeInsets.zero,
        actions: [
          IconButton(
            constraints: const BoxConstraints(minWidth: 32, minHeight: 40),
            padding: const EdgeInsets.all(4),
            icon: const Icon(Icons.chevron_left),
            onPressed: () {
              if (scrollController.hasClients) {
                scrollController.animateTo(
                  scrollController.position.pixels - 340,
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.ease,
                );
              }
            },
          ),
          IconButton(
            constraints: const BoxConstraints(minWidth: 32, minHeight: 40),
            padding: const EdgeInsets.all(4),
            icon: const Icon(Icons.chevron_right),
            onPressed: () {
              if (scrollController.hasClients) {
                scrollController.animateTo(
                  scrollController.position.pixels + 340,
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.ease,
                );
              }
            },
          ),
          IconButton(
            tooltip: "View more".tl,
            onPressed: widget.showMore,
            icon: const Icon(Icons.more_horiz),
          ),
        ],
        body: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 184,
              child: MediaQuery.removePadding(
                removeTop: true,
                context: context,
                child: ListView.builder(
                  controller: scrollController,
                  scrollDirection: Axis.horizontal,
                  itemCount: comments.length,
                  itemBuilder: (context, index) {
                    return _CommentWidget(comment: comments[index]);
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CommentWidget extends StatelessWidget {
  const _CommentWidget({required this.comment});

  final Comment comment;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 340,
      child: AppCard(
        margin: const EdgeInsets.fromLTRB(16, 8, 0, 8),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          children: [
            Row(
              children: [
                if (comment.avatar != null)
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(18),
                      color: context.colorScheme.surfaceContainer,
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Image(
                      image: CachedImageProvider(comment.avatar!),
                      width: 36,
                      height: 36,
                      fit: BoxFit.cover,
                    ),
                  ).paddingRight(8),
                Text(comment.userName, style: ts.bold),
              ],
            ),
            const SizedBox(height: 4),
            Expanded(
              child: RichCommentContent(
                text: comment.content,
                showImages: false,
              ).fixWidth(324),
            ),
            const SizedBox(height: 4),
            if (comment.time != null)
              Text(comment.time!, style: ts.s12).toAlign(Alignment.centerLeft),
          ],
        ),
      ),
    );
  }
}
