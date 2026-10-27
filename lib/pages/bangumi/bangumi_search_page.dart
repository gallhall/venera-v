import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/bangumi/bangumi.dart';
import 'package:venera/utils/translations.dart';
import 'bangumi_subject_page.dart';

class BangumiSearchPage extends StatefulWidget {
  const BangumiSearchPage({super.key, this.keyword = ''});
  final String keyword;
  @override
  State<BangumiSearchPage> createState() => _BangumiSearchPageState();
}

class _BangumiSearchPageState extends State<BangumiSearchPage> {
  late final controller = TextEditingController(text: widget.keyword);
  final results = <BangumiSubject>[];
  String keyword = '';
  String? error;
  bool loading = false, more = false;
  int generation = 0;

  @override
  void initState() {
    super.initState();
    if (widget.keyword.trim().isNotEmpty) search();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Future<void> search({bool next = false}) async {
    if (next && loading) return;
    if (!next) {
      keyword = controller.text.trim();
      results.clear();
    }
    var token = ++generation;
    if (keyword.isEmpty) {
      setState(() {
        loading = false;
        error = null;
        more = false;
      });
      return;
    }
    setState(() {
      loading = true;
      error = null;
    });
    try {
      var page = await BangumiManager().api.search(
        keyword,
        BangumiSubjectType.anime,
        offset: results.length,
      );
      if (!mounted || token != generation) return;
      setState(() {
        results.addAll(page);
        more = page.length == 20;
      });
    } catch (e) {
      if (mounted && token == generation) setState(() => error = e.toString());
    } finally {
      if (mounted && token == generation) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: Appbar(title: Text('Search anime on Bangumi'.tl)),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            controller: controller,
            onSubmitted: (_) => search(),
            decoration: InputDecoration(
              labelText: 'Search Bangumi'.tl,
              suffixIcon: IconButton(
                icon: const Icon(Icons.search),
                onPressed: search,
              ),
            ),
          ),
        ),
        if (loading) const LinearProgressIndicator(),
        if (error != null)
          ListTile(
            title: Text(error!),
            trailing: TextButton(
              onPressed: () => search(next: results.isNotEmpty),
              child: Text('Retry'.tl),
            ),
          ),
        Expanded(
          child: ListView(
            children: [
              for (var subject in results)
                BangumiSubjectTile(
                  subject: subject,
                  onTap: () => context.to(
                    () => BangumiSubjectPage(
                      subjectId: subject.id,
                      preview: subject,
                    ),
                  ),
                ),
              if (!loading &&
                  results.isEmpty &&
                  keyword.isNotEmpty &&
                  error == null)
                Center(child: Text('No results'.tl)),
              if (more && !loading)
                TextButton(
                  onPressed: () => search(next: true),
                  child: Text('Load more'.tl),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}
