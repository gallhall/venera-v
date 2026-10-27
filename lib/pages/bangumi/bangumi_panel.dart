import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/bangumi/bangumi.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/image_provider/cached_image.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/translations.dart';

part 'bangumi_comments_page.dart';

/// Asks for a Bangumi access token and logs in with it. Returns whether
/// it did.
Future<bool> showBangumiLoginDialog(BuildContext context) async {
  var result = await showDialog<bool>(
    context: context,
    builder: (context) => const _BangumiLoginDialog(),
  );
  return result == true;
}

class _BangumiLoginDialog extends StatefulWidget {
  const _BangumiLoginDialog();

  @override
  State<_BangumiLoginDialog> createState() => _BangumiLoginDialogState();
}

class _BangumiLoginDialogState extends State<_BangumiLoginDialog> {
  final controller = TextEditingController();

  bool isLoading = false;

  String? error;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Future<void> login() async {
    var token = controller.text.trim();
    if (token.isEmpty) return;
    setState(() {
      isLoading = true;
      error = null;
    });
    try {
      var user = await BangumiManager().login(token);
      if (!mounted) return;
      context.showMessage(
        message: "Logged in as @u".tlParams({"u": user.displayName}),
      );
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          isLoading = false;
          error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ContentDialog(
      title: "Bangumi",
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "Create an access token on Bangumi and paste it here".tl,
          ).paddingBottom(4),
          TextButton.icon(
            icon: const Icon(Icons.open_in_new, size: 18),
            label: Text("Create access token".tl),
            onPressed: () => launchUrlString(BangumiApi.tokenUrl),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              labelText: "Access Token".tl,
              border: const OutlineInputBorder(),
              errorText: error,
              errorMaxLines: 3,
            ),
            onSubmitted: (_) => login(),
          ),
        ],
      ).paddingHorizontal(16),
      actions: [
        Button.filled(
          isLoading: isLoading,
          onPressed: login,
          child: Text("Log in".tl),
        ),
      ],
    );
  }
}

/// Links a comic or video to a Bangumi subject, and shows and changes its
/// progress there.
class BangumiPanel extends StatefulWidget {
  const BangumiPanel({
    super.key,
    required this.sourceKey,
    required this.id,
    required this.title,
    required this.isVideo,
    this.chapters,
    this.history,
    this.subject,
  });

  final String sourceKey;

  final String id;

  final String title;

  final bool isVideo;

  final ComicChapters? chapters;

  final History? history;

  final BangumiSubject? subject;

  @override
  State<BangumiPanel> createState() => _BangumiPanelState();
}

class _BangumiPanelState extends State<BangumiPanel> {
  final manager = BangumiManager();

  late final searchController = TextEditingController(
    text: _keyword(widget.title),
  );

  BangumiBinding? binding;

  /// Searching for a subject instead of showing the linked one.
  bool isSearching = false;

  List<BangumiSubject>? results;

  BangumiSubject? subject;

  BangumiCollection? collection;

  bool isLoading = false;

  String? error;

  int get subjectType =>
      widget.isVideo ? BangumiSubjectType.anime : BangumiSubjectType.book;

  @override
  void initState() {
    super.initState();
    binding = widget.subject != null
        ? BangumiBinding.fromSubject(widget.subject!)
        : manager.bindingOf(widget.sourceKey, widget.id);
    if (binding == null) {
      isSearching = true;
      search();
    } else {
      load();
    }
  }

  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }

  /// The title without bracketed tags such as [author] or (C99).
  static String _keyword(String title) {
    var keyword = title
        .replaceAll(RegExp(r'【[^】]*】|\[[^\]]*\]|（[^）]*）|\([^)]*\)'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return keyword.isEmpty ? title : keyword;
  }

  /// Runs [action], showing that it is loading and its error.
  Future<void> run(Future<void> Function() action) async {
    setState(() {
      isLoading = true;
      error = null;
    });
    try {
      await action();
    } catch (e, s) {
      Log.error('Bangumi', e.toString(), s);
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  Future<void> search() {
    var keyword = searchController.text.trim();
    if (keyword.isEmpty) return Future.value();
    return run(() async {
      var id = int.tryParse(keyword);
      var results = id != null
          ? [await manager.api.subject(id)]
          : await manager.api.search(keyword, subjectType);
      if (mounted) setState(() => this.results = results);
    });
  }

  Future<void> load() {
    var binding = this.binding!;
    return run(() async {
      var subject = await manager.api.subject(binding.subjectId);
      if (mounted) setState(() => this.subject = subject);
      await loadCollection();
    });
  }

  Future<void> loadCollection() async {
    var user = manager.user;
    if (!manager.isLoggedIn || user == null) return;
    var collection = await manager.api.collection(
      user.username,
      binding!.subjectId,
    );
    if (mounted) setState(() => this.collection = collection);
  }

  void bind(BangumiSubject subject) {
    var binding = BangumiBinding.fromSubject(subject);
    manager.bind(widget.sourceKey, widget.id, binding);
    setState(() {
      this.binding = binding;
      this.subject = subject;
      collection = null;
      isSearching = false;
    });
    run(loadCollection);
  }

  void unbind() {
    manager.unbind(widget.sourceKey, widget.id);
    setState(() {
      binding = null;
      subject = null;
      collection = null;
      isSearching = true;
    });
    if (results == null) search();
  }

  void setOffset(int offset) {
    var binding = this.binding!.copyWith(offset: offset);
    manager.bind(widget.sourceKey, widget.id, binding);
    setState(() => this.binding = binding);
  }

  Future<void> setStatus(int type) {
    return run(() async {
      await manager.api.updateCollection(binding!.subjectId, type: type);
      await loadCollection();
    });
  }

  Future<void> setProgress(int number) {
    if (number < 0) return Future.value();
    return run(() async {
      await manager.progress.setProgress(binding!, number);
      await loadCollection();
    });
  }

  /// Number on Bangumi of the episode or chapter in the history.
  int? get localProgress {
    var history = widget.history;
    if (history == null || history.ep < 1) return null;
    var chapters = widget.chapters;
    if (chapters == null || chapters.length == 0) return 1;
    String? title;
    try {
      title = history.group == null
          ? chapters.titles.elementAtOrNull(history.ep - 1)
          : chapters
                .getGroupByIndex(history.group! - 1)
                .values
                .elementAtOrNull(history.ep - 1);
    } catch (_) {
      // The group is no longer there.
    }
    if (title == null) return null;
    var number = BangumiEpisodeNumber.of(title, history.ep);
    return number == null ? null : number + binding!.offset;
  }

  @override
  Widget build(BuildContext context) {
    return PopUpWidgetScaffold(
      title: "Bangumi",
      tailing: [
        if (binding != null && !isSearching)
          IconButton(
            icon: const Icon(Icons.open_in_new),
            tooltip: "Open in Bangumi".tl,
            onPressed: () => launchUrlString(binding!.url),
          ),
      ],
      body: isSearching ? buildSearch() : buildLinked(),
    );
  }

  Widget buildError() {
    if (error == null) return const SizedBox();
    return Text(
      error!,
      style: TextStyle(color: context.colorScheme.error),
    ).paddingHorizontal(16).paddingVertical(8);
  }

  Widget buildSearch() {
    var results = this.results;
    return Column(
      children: [
        TextField(
          controller: searchController,
          decoration: InputDecoration(
            labelText: "Search Bangumi".tl,
            hintText: "Name or subject ID".tl,
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              icon: const Icon(Icons.search),
              onPressed: isLoading ? null : search,
            ),
          ),
          onSubmitted: isLoading ? null : (_) => search(),
        ).paddingHorizontal(16).paddingTop(8),
        if (binding != null)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => setState(() => isSearching = false),
              child: Text("Cancel".tl),
            ),
          ).paddingHorizontal(8),
        buildError(),
        if (isLoading) const LinearProgressIndicator().paddingVertical(8),
        Expanded(
          child: results == null
              ? const SizedBox()
              : results.isEmpty
              ? Center(child: Text("No results".tl))
              : ListView.builder(
                  padding: EdgeInsets.only(
                    top: 8,
                    bottom: context.padding.bottom,
                  ),
                  itemCount: results.length,
                  itemBuilder: (context, index) {
                    var subject = results[index];
                    return _SubjectTile(
                      subject: subject,
                      selected: subject.id == binding?.subjectId,
                      onTap: () => bind(subject),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget buildLinked() {
    var binding = this.binding!;
    var subject = this.subject;
    return ListView(
      padding: EdgeInsets.only(bottom: context.padding.bottom + 16),
      children: [
        _SubjectTile(
          subject:
              subject ??
              BangumiSubject(
                id: binding.subjectId,
                type: binding.type,
                name: binding.name,
                nameCn: binding.nameCn,
                image: binding.image,
              ),
        ),
        if (isLoading) const LinearProgressIndicator().paddingVertical(8),
        buildError(),
        if (subject != null && subject.summary.trim().isNotEmpty)
          Text(
            subject.summary.trim(),
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: ts.s14,
          ).paddingHorizontal(16).paddingBottom(8),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.comment_outlined),
          title: Text("Bangumi comments".tl),
          trailing: const Icon(Icons.chevron_right),
          onTap: () =>
              App.rootContext.to(() => BangumiCommentsPage(binding: binding)),
        ),
        if (manager.isLoggedIn) ...buildProgress() else buildLogin(),
        if (widget.subject == null) ...[
          const Divider(),
          ListTile(
            leading: const Icon(Icons.exposure),
            title: Text(
              (binding.isBook ? "Chapter offset" : "Episode offset").tl,
            ),
            subtitle: Text(
              "Added to the numbers of this source to get those on Bangumi".tl,
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.remove),
                  onPressed: () => setOffset(binding.offset - 1),
                ),
                Text("${binding.offset}", style: ts.s16),
                IconButton(
                  icon: const Icon(Icons.add),
                  onPressed: () => setOffset(binding.offset + 1),
                ),
              ],
            ),
          ),
          ListTile(
            leading: const Icon(Icons.swap_horiz),
            title: Text("Link another subject".tl),
            onTap: () {
              setState(() => isSearching = true);
              if (results == null) search();
            },
          ),
          ListTile(
            leading: Icon(Icons.link_off, color: context.colorScheme.error),
            title: Text("Unlink".tl),
            onTap: unbind,
          ),
        ],
      ],
    );
  }

  Widget buildLogin() {
    return ListTile(
      leading: const Icon(Icons.login),
      title: Text("Log in to Bangumi to sync progress".tl),
      trailing: const Icon(Icons.arrow_right),
      onTap: () async {
        if (await showBangumiLoginDialog(context)) {
          setState(() {});
          run(loadCollection);
        }
      },
    );
  }

  Iterable<Widget> buildProgress() sync* {
    var binding = this.binding!;
    var collection = this.collection;
    var isBook = binding.isBook;
    var done = collection?.epStatus ?? 0;
    var total = subject?.eps ?? 0;
    yield Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (var type in BangumiCollectionType.values)
          ChoiceChip(
            label: Text(_statusName(type, isBook)),
            selected: collection?.type == type,
            onSelected: isLoading || collection?.type == type
                ? null
                : (_) => setStatus(type),
          ),
      ],
    ).paddingHorizontal(16).paddingVertical(8);
    yield ListTile(
      leading: const Icon(Icons.checklist),
      title: Text(
        (isBook ? "Read @n chapters" : "Watched @n episodes").tlParams({
          "n": total > 0 ? "$done / $total" : "$done",
        }),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.remove),
            onPressed: isLoading || done <= 0
                ? null
                : () => setProgress(done - 1),
          ),
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: isLoading ? null : () => setProgress(done + 1),
          ),
        ],
      ),
      onTap: isLoading
          ? null
          : () => showInputDialog(
              context: context,
              title: (isBook ? "Chapters read" : "Episodes watched").tl,
              initialValue: "$done",
              inputValidator: RegExp(r"^\d+$"),
              onConfirm: (value) {
                setProgress(int.parse(value));
                return null;
              },
            ),
    );
    var local = localProgress;
    if (local != null && local != done) {
      yield ListTile(
        leading: const Icon(Icons.history),
        title: Text(
          (isBook
                  ? "Set to local progress: chapter @n"
                  : "Set to local progress: episode @n")
              .tlParams({"n": local}),
        ),
        onTap: isLoading ? null : () => setProgress(local),
      );
    }
    yield SwitchListTile(
      secondary: const Icon(Icons.sync),
      title: Text("Sync progress automatically".tl),
      subtitle: Text(
        "Mark episodes and chapters on Bangumi once they are finished".tl,
      ),
      value: manager.autoSync,
      onChanged: (value) {
        manager.autoSync = value;
        setState(() {});
      },
    );
  }
}

String _statusName(int type, bool isBook) {
  return switch (type) {
    BangumiCollectionType.wish => isBook ? "Want to read" : "Want to watch",
    BangumiCollectionType.doing =>
      isBook ? "Currently reading" : "Currently watching",
    BangumiCollectionType.done =>
      isBook ? "Finished reading" : "Finished watching",
    BangumiCollectionType.onHold => "On hold",
    _ => "Dropped",
  }.tl;
}

class _SubjectTile extends StatelessWidget {
  const _SubjectTile({
    required this.subject,
    this.selected = false,
    this.onTap,
  });

  final BangumiSubject subject;

  final bool selected;

  final void Function()? onTap;

  @override
  Widget build(BuildContext context) {
    var details = [
      if (subject.platform.isNotEmpty) subject.platform,
      if (subject.date.isNotEmpty) subject.date,
      if (subject.eps > 0)
        (subject.type == BangumiSubjectType.book
                ? "@n chapters"
                : "@n episodes")
            .tlParams({"n": subject.eps}),
    ].join(" · ");
    return InkWell(
      onTap: onTap,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 64,
            height: 88,
            decoration: BoxDecoration(
              color: context.colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(6),
            ),
            clipBehavior: Clip.antiAlias,
            child: subject.image.isEmpty
                ? const SizedBox()
                : AnimatedImage(
                    image: CachedImageProvider(subject.image),
                    width: 64,
                    height: 88,
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(subject.displayName, style: ts.s16),
                if (subject.nameCn.isNotEmpty && subject.name != subject.nameCn)
                  Text(
                    subject.name,
                    style: ts.s12,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                if (details.isNotEmpty) Text(details, style: ts.s12),
                if (subject.score > 0)
                  Row(
                    children: [
                      Icon(
                        Icons.star,
                        size: 16,
                        color: context.useTextColor(Colors.amber),
                      ),
                      const SizedBox(width: 4),
                      Text(subject.score.toStringAsFixed(1), style: ts.s14),
                      if (subject.rank > 0)
                        Text("  #${subject.rank}", style: ts.s12),
                    ],
                  ),
              ],
            ),
          ),
          if (selected) Icon(Icons.check, color: context.colorScheme.primary),
        ],
      ).paddingHorizontal(16).paddingVertical(8),
    );
  }
}
