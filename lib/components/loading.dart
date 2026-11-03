part of 'components.dart';

abstract class LoadingState<T extends StatefulWidget, S extends Object>
    extends State<T> {
  bool isLoading = false;

  S? data;

  String? error;

  Object? errorCause;

  Future<Res<S>> loadData();

  Future<Res<S>> loadDataWithRetry() async {
    int retry = 0;
    while (true) {
      var res = await loadData();
      if (res.success) {
        return res;
      } else {
        if (!mounted) return res;
        if (retry >= 3) {
          return res;
        }
        retry++;
        await Future.delayed(const Duration(milliseconds: 200));
      }
    }
  }

  FutureOr<void> onDataLoaded() {}

  Widget buildContent(BuildContext context, S data);

  Widget? buildFrame(BuildContext context, Widget child) => null;

  Widget buildLoading() {
    return const AppLoadingView();
  }

  void retry() {
    setState(() {
      isLoading = true;
      error = null;
      errorCause = null;
    });
    loadDataWithRetry().then((value) async {
      if (value.success) {
        data = value.data;
        await onDataLoaded();
        setState(() {
          isLoading = false;
        });
      } else {
        setState(() {
          isLoading = false;
          error = value.errorMessage!;
          errorCause = value.errorCause;
        });
      }
    });
  }

  Widget buildError() {
    return AppErrorView(
      message: error!,
      cause: errorCause,
      retry: retry,
      withAppbar: true,
    );
  }

  @override
  @mustCallSuper
  void initState() {
    isLoading = true;
    Future.microtask(() {
      loadDataWithRetry().then((value) async {
        if (!mounted) return;
        if (value.success) {
          data = value.data;
          await onDataLoaded();
          setState(() {
            isLoading = false;
          });
        } else {
          setState(() {
            isLoading = false;
            error = value.errorMessage!;
            errorCause = value.errorCause;
          });
        }
      });
    });
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    Widget child;

    if (isLoading) {
      child = buildLoading();
    } else if (error != null) {
      child = buildError();
    } else {
      child = buildContent(context, data!);
    }

    return buildFrame(context, child) ?? child;
  }
}

abstract class MultiPageLoadingState<T extends StatefulWidget, S extends Object>
    extends State<T> {
  bool _isFirstLoading = true;

  bool _isLoading = false;

  List<S>? data;

  String? _error;

  Object? _errorCause;

  String? _nextPageError;

  Object? _nextPageCause;

  int _page = 1;

  int? _maxPage;

  Future<Res<List<S>>> loadData(int page);

  Widget? buildFrame(BuildContext context, Widget child) => null;

  Widget buildContent(BuildContext context, List<S> data);

  bool get isLoading => _isLoading || _isFirstLoading;

  bool get isFirstLoading => _isFirstLoading;

  bool get haveNextPage => _maxPage == null || _page <= _maxPage!;

  void nextPage() {
    if (!haveNextPage || _isLoading || _nextPageError != null) {
      return;
    }
    _isLoading = true;
    loadData(_page).then((value) {
      _isLoading = false;
      if (!mounted) {
        return;
      }
      setState(() {
        if (value.success) {
          _page++;
          if (value.subData is int) {
            _maxPage = value.subData as int;
          }
          if (value.data.isEmpty) {
            _maxPage = _page - 1;
          }
          data!.addAll(value.data);
        } else {
          _nextPageError = value.errorMessage ?? "Failed to load".tl;
          _nextPageCause = value.errorCause;
        }
      });
    });
  }

  void retryNextPage() {
    setState(() {
      _nextPageError = null;
      _nextPageCause = null;
    });
    nextPage();
  }

  Widget buildListFooter(BuildContext context) {
    if (_nextPageError != null) {
      return SliverListFooter.error(message: _nextPageError!,
          cause: _nextPageCause, retry: retryNextPage);
    }
    if (haveNextPage) {
      return const SliverListFooter.loading();
    }
    return const SliverToBoxAdapter(child: SizedBox());
  }

  void reset() {
    setState(() {
      _isFirstLoading = true;
      _isLoading = false;
      data = null;
      _error = null;
      _errorCause = null;
      _nextPageError = null;
      _nextPageCause = null;
      _maxPage = null;
      _page = 1;
    });
    firstLoad();
  }

  void firstLoad() {
    Future.microtask(() {
      loadData(_page).then((value) {
        if (!mounted) return;
        if (value.success) {
          _page++;
          if (value.subData is int) {
            _maxPage = value.subData as int;
          }
          if (value.data.isEmpty) {
            _maxPage = _page - 1;
          }
          setState(() {
            _isFirstLoading = false;
            data = value.data;
          });
        } else {
          setState(() {
            _isFirstLoading = false;
            _error = value.errorMessage!;
            _errorCause = value.errorCause;
          });
        }
      });
    });
  }

  @override
  void initState() {
    firstLoad();
    super.initState();
  }

  Widget buildLoading(BuildContext context) {
    return const AppLoadingView();
  }

  Widget buildError(BuildContext context, String error) {
    return AppErrorView(message: error, cause: _errorCause, retry: reset);
  }

  @override
  Widget build(BuildContext context) {
    Widget child;

    if (_isFirstLoading) {
      child = buildLoading(context);
    } else if (_error != null) {
      child = buildError(context, _error!);
    } else {
      child = NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification.metrics.pixels ==
              notification.metrics.maxScrollExtent) {
            nextPage();
          }
          return false;
        },
        child: buildContent(context, data!),
      );
    }

    return buildFrame(context, child) ?? child;
  }
}
