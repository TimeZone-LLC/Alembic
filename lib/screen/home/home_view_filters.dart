import 'package:alembic/core/arcane_repository.dart';
import 'package:alembic/domain/repository_dto.dart';
import 'package:flutter/foundation.dart';
import 'package:github/github.dart';

enum HomeStateFilter {
  all,
  active,
  archived,
  cloud,
  syncing;

  static HomeStateFilter fromStorage(String? value) {
    for (HomeStateFilter filter in HomeStateFilter.values) {
      if (filter.name == value) {
        return filter;
      }
    }
    return HomeStateFilter.all;
  }
}

enum HomeSortMode {
  attention,
  archiveSoon,
  updated,
  state,
  name,
  owner,
}

extension HomeSortModeMeta on HomeSortMode {
  String get label => switch (this) {
        HomeSortMode.attention => 'Needs attention',
        HomeSortMode.archiveSoon => 'Archive soon',
        HomeSortMode.updated => 'Recently updated',
        HomeSortMode.state => 'State',
        HomeSortMode.name => 'Name',
        HomeSortMode.owner => 'Owner',
      };
}

class HomeRepositoryEntry {
  final RepositoryDto dto;
  final Repository repository;
  final RepoState repoState;
  final bool syncing;
  final int daysUntilArchive;

  const HomeRepositoryEntry({
    required this.dto,
    required this.repository,
    required this.repoState,
    required this.syncing,
    required this.daysUntilArchive,
  });

  String get fullName => dto.fullName;

  String get lowerKey => dto.fullName.toLowerCase();

  int get stateRank => syncing
      ? 0
      : switch (repoState) {
          RepoState.active => 1,
          RepoState.archived => 2,
          RepoState.cloud => 3,
        };
}

class HomeStats {
  static const int archiveDueSoonDays = 3;

  final int total;
  final int active;
  final int archived;
  final int cloud;
  final int syncing;
  final int private;
  final int forks;
  final int archiveDueSoon;

  const HomeStats({
    required this.total,
    required this.active,
    required this.archived,
    required this.cloud,
    required this.syncing,
    required this.private,
    required this.forks,
    required this.archiveDueSoon,
  });

  const HomeStats.empty()
      : total = 0,
        active = 0,
        archived = 0,
        cloud = 0,
        syncing = 0,
        private = 0,
        forks = 0,
        archiveDueSoon = 0;

  factory HomeStats.fromEntries(List<HomeRepositoryEntry> entries) {
    int active = 0;
    int archived = 0;
    int cloud = 0;
    int syncing = 0;
    int private = 0;
    int forks = 0;
    int archiveDueSoon = 0;
    for (HomeRepositoryEntry entry in entries) {
      if (entry.repoState == RepoState.active) {
        active += 1;
        if (entry.daysUntilArchive <= archiveDueSoonDays) {
          archiveDueSoon += 1;
        }
      } else if (entry.repoState == RepoState.archived) {
        archived += 1;
      } else {
        cloud += 1;
      }
      if (entry.syncing) {
        syncing += 1;
      }
      if (entry.dto.isPrivate) {
        private += 1;
      }
      if (entry.dto.isFork) {
        forks += 1;
      }
    }
    return HomeStats(
      total: entries.length,
      active: active,
      archived: archived,
      cloud: cloud,
      syncing: syncing,
      private: private,
      forks: forks,
      archiveDueSoon: archiveDueSoon,
    );
  }
}

class HomeSelectionController extends ChangeNotifier {
  final Set<String> _keys = <String>{};
  String? _anchor;
  String? _cursor;

  bool get active => _keys.isNotEmpty;
  int get count => _keys.length;
  String? get cursor => _cursor;
  bool isSelected(String key) => _keys.contains(key);

  void select(String key, List<String> order,
      {bool extend = false, bool toggle = false}) {
    final Set<String> next = <String>{};
    if (extend && _anchor != null && order.contains(_anchor)) {
      final int from = order.indexOf(_anchor!);
      final int to = order.indexOf(key);
      if (to < 0) return;
      next.addAll(
          order.sublist(from < to ? from : to, (from > to ? from : to) + 1));
      if (toggle) next.addAll(_keys);
    } else {
      _anchor = key;
      if (toggle) {
        next.addAll(_keys);
        if (!next.remove(key)) next.add(key);
      } else {
        next.add(key);
      }
    }
    _cursor = key;
    _replace(next);
  }

  void move(List<String> order, int offset, {bool extend = false}) {
    if (order.isEmpty) return;
    final int current = _cursor == null ? -1 : order.indexOf(_cursor!);
    final int index = current < 0
        ? (offset < 0 ? order.length - 1 : 0)
        : (current + offset).clamp(0, order.length - 1);
    select(order[index], order, extend: extend);
  }

  void toggle(String key, bool selected) {
    _anchor = key;
    _cursor = key;
    final Set<String> next = <String>{..._keys};
    selected ? next.add(key) : next.remove(key);
    _replace(next);
  }

  void selectAll(Iterable<String> keys) {
    final List<String> order = keys.toList();
    if (order.isNotEmpty) {
      _anchor ??= order.first;
      _cursor ??= order.first;
    }
    _replace(<String>{..._keys, ...order});
  }

  void clear() {
    _anchor = null;
    _cursor = null;
    _replace(<String>{});
  }

  void prune(Set<String> validKeys) {
    if (!validKeys.contains(_anchor)) _anchor = null;
    if (!validKeys.contains(_cursor)) _cursor = null;
    _replace(_keys.intersection(validKeys));
  }

  void _replace(Set<String> next) {
    if (setEquals(_keys, next)) return;
    _keys
      ..clear()
      ..addAll(next);
    notifyListeners();
  }
}

class HomeFilterState {
  final HomeStateFilter stateFilter;
  final HomeSortMode sortMode;
  final String? ownerFilter;
  final String? query;

  const HomeFilterState({
    required this.stateFilter,
    required this.sortMode,
    required this.ownerFilter,
    required this.query,
  });

  const HomeFilterState.initial()
      : stateFilter = HomeStateFilter.all,
        sortMode = HomeSortMode.attention,
        ownerFilter = null,
        query = null;

  bool get hasActiveFilters =>
      stateFilter != HomeStateFilter.all ||
      ownerFilter != null ||
      (query != null && query!.trim().isNotEmpty);

  HomeFilterState copyWith({
    HomeStateFilter? stateFilter,
    HomeSortMode? sortMode,
    String? ownerFilter,
    bool clearOwnerFilter = false,
    String? query,
    bool clearQuery = false,
  }) =>
      HomeFilterState(
        stateFilter: stateFilter ?? this.stateFilter,
        sortMode: sortMode ?? this.sortMode,
        ownerFilter:
            clearOwnerFilter ? null : (ownerFilter ?? this.ownerFilter),
        query: clearQuery ? null : (query ?? this.query),
      );
}
