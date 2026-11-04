part of 'comic_page.dart';

class _CommentsPart extends StatefulWidget {
  const _CommentsPart({
    required this.comments,
    required this.showMore,
    required this.target,
  });

  final List<Comment> comments;

  final CommentTarget target;

  final void Function() showMore;

  @override
  State<_CommentsPart> createState() => _CommentsPartState();
}

class _CommentsPartState extends State<_CommentsPart> {
  final scrollController = ScrollController();

  late List<Comment> comments;

  @override
  void initState() {
    comments = widget.comments.where((c) => !shouldBlockComment(c)).toList();
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
            tooltip: 'Previous comments'.tl,
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
            tooltip: 'Next comments'.tl,
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
                child: HorizontalCoverList(
                  child: ListView.builder(
                    controller: scrollController,
                    scrollDirection: Axis.horizontal,
                    itemCount: comments.length,
                    itemBuilder: (context, index) {
                      return _CommentWidget(
                        comment: comments[index],
                        target: widget.target,
                      );
                    },
                  ),
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
  const _CommentWidget({required this.comment, required this.target});

  final Comment comment;

  final CommentTarget target;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 340,
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 8, 0, 8),
        decoration: BoxDecoration(
          color: context.colorScheme.surfaceContainer,
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: CommentTile(
          comment: comment,
          target: target,
          compact: true,
          showAvatar: comment.avatar != null,
          showActions: false,
        ),
      ),
    );
  }
}
