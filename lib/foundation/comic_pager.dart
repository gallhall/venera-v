import 'package:flutter/foundation.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/utils/translations.dart';

/// The pages of a list of comics from a source, loaded on demand: by page
/// number with [loadPage], or one after another with [loadNext], which gets
/// the previous page's link to the next (null for the first).
///
/// A page number source tells the number of pages in `subData`, or ends at
/// its first empty page. A next-link source ends at the page with no link
/// or no comics.
class ComicPager with ChangeNotifier {
  ComicPager({this.loadPage, this.loadNext});

  final Future<Res<List<Comic>>> Function(int page)? loadPage;
  final Future<Res<List<Comic>>> Function(String? next)? loadNext;

  final _data = <int, List<Comic>>{};
  final _loading = <int>{};
  String? _next;
  int? _maxPage;
  String? _error;
  Object? _errorCause;

  /// Increased by [refresh]: loads started before it are dropped.
  int _generation = 0;

  /// The comics of page [n] (from 1), or null if not loaded.
  List<Comic>? page(int n) => _data[n];

  /// The pages loaded so far.
  int get loadedPages => _data.length;

  /// The comics of every loaded page, in order.
  List<Comic> get all => [
    for (var n in _data.keys.toList()..sort()) ..._data[n]!,
  ];

  /// Whether no loaded page has comics.
  bool get allEmpty => _data.values.every((p) => p.isEmpty);

  /// The number of pages, once known.
  int? get maxPage => _maxPage;

  /// Whether there may be pages after the loaded ones.
  bool get hasMore => _maxPage == null || _data.length < _maxPage!;

  String? get error => _error;
  Object? get errorCause => _errorCause;

  bool isLoading(int n) => _loading.contains(n);

  /// Forgets the error, to try again.
  void clearError() {
    _error = null;
    _errorCause = null;
    notifyListeners();
  }

  /// Loads page [n] if needed. A next-link source loads every page before
  /// it, and stops at its last page: a page beyond it stays unloaded.
  Future<void> load(int n) async {
    if (loadPage == null && loadNext == null) {
      _error = "loadPage and loadNext can't be null at the same time";
      notifyListeners();
      return;
    }
    if (_data[n] != null || _loading.contains(n)) {
      return;
    }
    var generation = _generation;
    _loading.add(n);
    _errorCause = null;
    try {
      if (loadPage != null) {
        var res = await loadPage!(n);
        if (generation != _generation) return;
        if (res.error) {
          _fail(res.errorMessage ?? "Unknown error".tl, res.errorCause);
        } else if (res.data.isEmpty) {
          _data[n] = const [];
          _maxPage = n;
        } else {
          _data[n] = res.data;
          if (res.subData is int) {
            _maxPage = res.subData;
          }
        }
      } else {
        while (_data[n] == null && hasMore) {
          var res = await loadNext!(_next);
          if (generation != _generation) return;
          if (res.error) {
            _fail(res.errorMessage, res.errorCause);
            break;
          }
          _data[_data.length + 1] = res.data;
          if (res.subData == null || res.data.isEmpty) {
            _maxPage = _data.length;
          } else {
            _next = res.subData;
          }
        }
      }
    } catch (e) {
      if (generation != _generation) return;
      _fail(e.toString(), e);
    } finally {
      if (generation == _generation) {
        _loading.remove(n);
        notifyListeners();
      }
    }
  }

  void _fail(String? message, Object? cause) {
    _error ??= message ?? "Unknown error".tl;
    _errorCause ??= cause;
  }

  /// Forgets every page, to load them again.
  void refresh() {
    _generation++;
    _data.clear();
    _loading.clear();
    _next = null;
    _maxPage = null;
    _error = null;
    _errorCause = null;
    notifyListeners();
  }

  /// Removes [comic], looking on page [near] first.
  void remove(Comic comic, {int? near}) {
    if (_data[near]?.remove(comic) != true) {
      for (var page in _data.values) {
        if (page.remove(comic)) {
          break;
        }
      }
    }
    notifyListeners();
  }

  /// What [restore] takes back, for page storage.
  Map<String, dynamic> get state => {
    'maxPage': _maxPage,
    'data': Map<int, List<Comic>>.of(_data),
    'error': _error,
    'nextUrl': _next,
  };

  /// Takes back a [state]. Loads in progress are not restored: they belong
  /// to the pager that started them.
  void restore(Map<String, dynamic> state) {
    _generation++;
    _maxPage = state['maxPage'];
    _data
      ..clear()
      ..addAll((state['data'] as Map).cast<int, List<Comic>>());
    _error = state['error'];
    _next = state['nextUrl'];
    _loading.clear();
  }
}
