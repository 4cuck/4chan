import 'dart:async';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:chan/models/downloaded_thread.dart';
import 'package:chan/models/thread.dart';
import 'package:chan/pages/thread.dart';
import 'package:chan/services/imageboard.dart';
import 'package:chan/pages/gallery.dart';
import 'package:chan/services/kuroba_import.dart';
import 'package:chan/widgets/attachment_thumbnail.dart';
import 'package:chan/services/persistence.dart';
import 'package:chan/services/thread_downloader.dart';
import 'package:chan/services/settings.dart';
import 'package:chan/services/util.dart';
import 'package:chan/widgets/adaptive.dart';
import 'package:chan/widgets/imageboard_scope.dart';
import 'package:chan/widgets/thread_row.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

enum _DownloadSortMethod {
  downloadedAt,
  lastUpdatedAt,
  threadDate,
  title,
}

const _kDownloadSortMethodLabels = {
  _DownloadSortMethod.downloadedAt: 'Order added',
  _DownloadSortMethod.lastUpdatedAt: 'Last updated',
  _DownloadSortMethod.threadDate: 'Thread date',
  _DownloadSortMethod.title: 'Alphabetically',
};

class DownloadedThreadsPage extends StatefulWidget {
  const DownloadedThreadsPage({super.key});

  @override
  State<DownloadedThreadsPage> createState() => _DownloadedThreadsPageState();
}

class _DownloadedThreadsPageState extends State<DownloadedThreadsPage> {
  List<DownloadedThread> _downloads = [];
  List<DownloadedThread> _cachedSortedDownloads = [];
  StreamSubscription<Object?>? _sub;
  _DownloadSortMethod get _sortMethod {
    final v = Settings.instance.downloadedThreadsSortingMethod;
    switch (v) {
      case ThreadSortingMethod.alphabeticByTitle:
        return _DownloadSortMethod.title;
      case ThreadSortingMethod.lastPostTime:
        return _DownloadSortMethod.lastUpdatedAt;
      case ThreadSortingMethod.threadPostTime:
        return _DownloadSortMethod.threadDate;
      default:
        return _DownloadSortMethod.downloadedAt;
    }
  }
  set _sortMethod(_DownloadSortMethod method) {
    switch (method) {
      case _DownloadSortMethod.title:
        Settings.instance.downloadedThreadsSortingMethod = ThreadSortingMethod.alphabeticByTitle;
      case _DownloadSortMethod.lastUpdatedAt:
        Settings.instance.downloadedThreadsSortingMethod = ThreadSortingMethod.lastPostTime;
      case _DownloadSortMethod.threadDate:
        Settings.instance.downloadedThreadsSortingMethod = ThreadSortingMethod.threadPostTime;
      default:
        Settings.instance.downloadedThreadsSortingMethod = ThreadSortingMethod.savedTime;
    }
  }
  bool get _sortReversed => Settings.instance.reverseDownloadedThreadsSorting;
  set _sortReversed(bool v) => Settings.instance.reverseDownloadedThreadsSorting = v;
  bool _isImporting = false;
  int _importCurrent = 0;
  int _importTotal = 0;
  bool _isSelecting = false;
  final Set<String> _selectedBoxKeys = {};
  final ScrollController _scrollController = ScrollController();
  final Map<String, Thread?> _threadCache = {};
  /// Tracks the last known lastUpdatedAt per boxKey so we know when thread
  /// content actually changed (vs a status-only box write).
  final Map<String, DateTime?> _lastUpdatedAt = {};

  @override
  void initState() {
    super.initState();
    _reload();
    ThreadDownloadService.instance.purgeSoftDeleted();
    _preloadThreadCache().then((_) {
      if (mounted) {
        setState(_rebuildSortedList);
      }
    });
    // Rebuild when any download record changes, but avoid re-reading all
    // thread content from Hive on every status update.
    _sub = ThreadDownloadService.instance.watchAllChanges().listen((event) {
      if (!mounted) return;
      final boxKey = event.key as String? ?? '';

      if (event.deleted) {
        // Record removed — drop from cache and rebuild list.
        setState(() {
          _threadCache.remove(boxKey);
          _lastUpdatedAt.remove(boxKey);
    _reload();
        });
      } else if (_threadCache[boxKey] == null) {
        // New record (or previously null cache entry) — reload list then load
        // this thread from Hive.
        setState(_reload);
        final d = _downloads.firstWhereOrNull((d) => d.boxKey == boxKey);
        if (d != null) _loadOneThread(d).then((_) {
          if (mounted) setState(_rebuildSortedList);
        });
      } else {
        // Existing record — only re-read thread content if lastUpdatedAt
        // changed (i.e. new posts arrived). Status-only updates (syncedFiles,
        // progress, etc.) are ignored for the thread cache.
        final newRecord =
            event.value is DownloadedThread ? event.value as DownloadedThread : null;
        if (newRecord?.lastUpdatedAt != _lastUpdatedAt[boxKey]) {
          _lastUpdatedAt[boxKey] = newRecord?.lastUpdatedAt;
          final d = _downloads.firstWhereOrNull((d) => d.boxKey == boxKey);
          if (d != null) _loadOneThread(d).then((_) {
          if (mounted) setState(_rebuildSortedList);
        });
        }
        setState(_reload);
      }
    });
  }

  void _reload() {
    _downloads = ThreadDownloadService.instance.allDownloads;
    _rebuildSortedList();
  }

  void _rebuildSortedList() {
    final list = List<DownloadedThread>.from(_downloads);
    switch (_sortMethod) {
      case _DownloadSortMethod.downloadedAt:
        list.sort((a, b) => b.downloadedAt.compareTo(a.downloadedAt));
      case _DownloadSortMethod.lastUpdatedAt:
        list.sort((a, b) => (b.lastUpdatedAt ?? b.downloadedAt)
            .compareTo(a.lastUpdatedAt ?? a.downloadedAt));
      case _DownloadSortMethod.threadDate:
        list.sort((a, b) {
          final aTime = _threadCache[a.boxKey]?.time ?? a.downloadedAt;
          final bTime = _threadCache[b.boxKey]?.time ?? b.downloadedAt;
          return bTime.compareTo(aTime);
        });
      case _DownloadSortMethod.title:
        list.sort((a, b) => (a.title ?? '')
            .toLowerCase()
            .compareTo((b.title ?? '').toLowerCase()));
    }
    _cachedSortedDownloads = _sortReversed ? list.reversed.toList() : list;
    if (Settings.instance.showActiveDownloadsAboveArchivedDownloads) {
      final active = _cachedSortedDownloads.where((t) =>
          t.status == DownloadStatus.downloading ||
          t.status == DownloadStatus.updating ||
          t.status == DownloadStatus.pending).toList();
      final archived = _cachedSortedDownloads.where((t) =>
          t.status == DownloadStatus.complete ||
          t.status == DownloadStatus.failed ||
          t.status == DownloadStatus.cancelled).toList();
      _cachedSortedDownloads = [...active, ...archived];
    }
  }

  Future<void> _preloadThreadCache() async {
    final downloads = List<DownloadedThread>.from(_downloads)
        .where((d) => _threadCache[d.boxKey] == null)
        .toList();
    if (downloads.isEmpty) return;
    // Load in batches to avoid flooding Hive I/O
    const batchSize = 10;
    for (var i = 0; i < downloads.length; i += batchSize) {
      final batch = downloads.skip(i).take(batchSize).toList();
      // Load individually so one failure doesn't kill the whole batch
      for (final d in batch) {
        final thread = await _loadThreadData(d)
            .catchError((e, st) {
              print('[SavedThreads] Load failed for ${d.board}/${d.threadId}: $e');
              print(st);
              return null;
            });
        if (!mounted) return;
        setState(() {
          _threadCache[d.boxKey] = thread;
          _lastUpdatedAt[d.boxKey] = d.lastUpdatedAt;
        });
      }
      // Yield between batches
      await Future.delayed(Duration.zero);
    }
  }

  List<DownloadedThread> get _sortedDownloads => _cachedSortedDownloads;

  /// Loads thread data from Hive (with HTML recovery fallback).
  /// Does NOT call setState — the caller batches updates.
  /// Returns null on any error (Hive model mismatch, corrupt data, etc.)
  /// so the UI falls back to the simple row instead of crashing.
  Future<Thread?> _loadThreadData(DownloadedThread d) async {
    Thread? thread;
    try {
      thread = await Persistence.getCachedThread(
          d.imageboardKey, d.board, d.threadId);
    } catch (e, st) {
      print('[SavedThreads] Failed to load thread ${d.board}/${d.threadId} from Hive: $e');
      print(st);
      // Hive deserialization failed — likely model change with old data.
      // Don't crash; show fallback row. Thread can be re-downloaded.
      return null;
    }
    // Recovery: if thread not in Hive but thread_data.html exists on disk,
    // re-parse and restore it (Fix D: use async read).
    if (thread == null && d.status == DownloadStatus.complete) {
      final htmlFile = File(
          '${Persistence.downloadsDirectory.path}/${d.imageboardKey}/${d.board}/${d.threadId}/thread_data.html');
      if (htmlFile.existsSync()) {
        try {
          final recovered = parseKurobaThreadHtml(d.imageboardKey, d.board,
              d.threadId, await htmlFile.readAsString());
          if (recovered != null) {
            await Persistence.setCachedThread(
                d.imageboardKey, d.board, d.threadId, recovered);
            thread = recovered;
          }
        } catch (_) {
          // Corrupt HTML — leave thread as null, fallback row will show
        }
      }
    }
    return thread;
  }

  /// Loads a single thread and updates state. Used by watch listener for
  /// individual thread updates (new download, content change).
  Future<void> _loadOneThread(DownloadedThread d) async {
    final thread = await _loadThreadData(d);
    if (mounted) {
      setState(() {
        _threadCache[d.boxKey] = thread;
        _lastUpdatedAt[d.boxKey] = d.lastUpdatedAt;
      });
    }
  }

  Future<void> _showSortMenu(BuildContext context) async {
    await showAdaptiveModalPopup<void>(
      context: context,
      builder: (ctx) => AdaptiveActionSheet(
        title: const Text('Sort by...'),
        actions: [
          ..._kDownloadSortMethodLabels.entries
              .map((entry) => AdaptiveActionSheetAction(
                    child: Text(
                      '${entry.value}${entry.key == _sortMethod && _sortReversed ? ' (reversed)' : ''}',
                      style: entry.key == _sortMethod
                          ? const TextStyle(fontWeight: FontWeight.bold)
                          : null,
                    ),
                    onPressed: () {
                      Navigator.of(ctx, rootNavigator: true).pop();
                      setState(() {
                        if (_sortMethod == entry.key) {
                          _sortReversed = !_sortReversed;
                        } else {
                          _sortMethod = entry.key;
                          _sortReversed = false;
                        }
                        _rebuildSortedList();
                      });
                    },
                  )),
          AdaptiveActionSheetAction(
            onPressed: () {
              Navigator.of(ctx, rootNavigator: true).pop();
              setState(() {
                _sortReversed = !_sortReversed;
                _rebuildSortedList();
              });
            },
            trailing: _sortReversed
                ? const Icon(CupertinoIcons.checkmark_square)
                : const Icon(CupertinoIcons.square),
            child: const Text('Reverse order')
          ),
          AdaptiveActionSheetAction(
            onPressed: () {
              Navigator.of(ctx, rootNavigator: true).pop();
              setState(() {
                Settings.instance.showActiveDownloadsAboveArchivedDownloads =
                    !Settings.instance.showActiveDownloadsAboveArchivedDownloads;
                _rebuildSortedList();
              });
            },
            trailing: Settings.instance.showActiveDownloadsAboveArchivedDownloads
                ? const Icon(CupertinoIcons.checkmark_square)
                : const Icon(CupertinoIcons.square),
            child: const Text('Active downloads above archived')
          ),
        ],
        cancelButton: AdaptiveActionSheetAction(
          child: const Text('Cancel'),
          onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _delete(DownloadedThread d) async {
    final confirmed = await showAdaptiveDialog<bool>(
      context: context,
      builder: (ctx) => AdaptiveAlertDialog(
        title: const Text('Delete download?'),
        content:
            const Text('All downloaded files for this thread will be removed.'),
        actions: [
          AdaptiveDialogAction(
            child: const Text('Cancel'),
            onPressed: () => Navigator.pop(ctx, false),
          ),
          AdaptiveDialogAction(
            isDestructiveAction: true,
            child: const Text('Delete'),
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ThreadDownloadService.instance
          .deleteDownload(d.identifier, d.imageboardKey);
      if (mounted) setState(_reload);
    }
  }

  Future<void> _update(DownloadedThread d) async {
    final imageboard =
        ImageboardRegistry.instance.getImageboard(d.imageboardKey);
    if (imageboard == null) return;
    await ThreadDownloadService.instance
        .updateThread(d.identifier, imageboard.site, d.imageboardKey);
    if (mounted) setState(_reload);
  }

  /// Pull-to-refresh handler: triggers a media-download update for every live
  /// (complete, non-archived, non-locked) thread in the list, then scans the
  /// downloads directory for any manually-copied folders not yet registered.
  Future<void> _refreshAll() async {
    // 1. Kick off media-download updates for all live threads (fire-and-forget;
    //    rows update via watchAllChanges() as each download progresses).
    final live = _downloads
        .where((d) =>
            d.status == DownloadStatus.complete &&
            !d.isArchivedOnServer &&
            !d.isLockedOnServer &&
            d.pendingDeletionAt == null)
        .toList();
    for (final d in live) {
      final imageboard =
          ImageboardRegistry.instance.getImageboard(d.imageboardKey);
      if (imageboard == null) continue;
      ThreadDownloadService.instance
          .updateThread(d.identifier, imageboard.site, d.imageboardKey);
    }
    // 2. Scan the downloads directory for folders that exist on disk but have
    //    no Hive record (manually copied, backup-restored, etc.).
    await ThreadDownloadService.instance.scanDownloadsDirectory();
  }

  void _openThread(DownloadedThread d) {
    final imageboard =
        ImageboardRegistry.instance.getImageboard(d.imageboardKey);
    if (imageboard == null) {
      showAdaptiveDialog(
        context: context,
        builder: (ctx) => AdaptiveAlertDialog(
          title: const Text('Imageboard unavailable'),
          content: Text(
              '"${d.imageboardKey}" is not configured. Add it in Settings to open this thread.'),
          actions: [
            AdaptiveDialogAction(
                child: const Text('OK'), onPressed: () => Navigator.pop(ctx))
          ],
        ),
      );
      return;
    }
    Navigator.of(context, rootNavigator: true).push(adaptivePageRoute(
      builder: (_) => ImageboardScope(
        imageboardKey: null,
        imageboard: imageboard,
        child: ThreadPage(
          thread: d.identifier,
          boardSemanticId: -1,
        ),
      ),
    ));
  }

  Future<void> _importKuroba() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip'],
      allowMultiple: true,
    );
    if (result == null || result.files.isEmpty) return;
    final paths = result.files.map((f) => f.path).whereType<String>().toList();
    setState(() {
      _isImporting = true;
      _importCurrent = 0;
      _importTotal = paths.length;
    });
    int succeeded = 0;
    final errors = <String>[];
    for (int i = 0; i < paths.length; i++) {
      if (mounted) setState(() => _importCurrent = i + 1);
      final r = await importKurobaZip(paths[i]);
      if (r is KurobaImportSuccess) {
        succeeded++;
      } else if (r is KurobaImportFailure) {
        errors.add('${paths[i].split('/').last}: ${r.error}');
      }
    }
    if (!mounted) return;
    setState(() {
      _isImporting = false;
    _reload();
    });
    showAdaptiveDialog(
      context: context,
      builder: (ctx) => AdaptiveAlertDialog(
        title: const Text('Import complete'),
        content: Text(
          'Imported $succeeded/${paths.length} thread(s)'
          '${errors.isEmpty ? '' : '\n\nErrors:\n${errors.join('\n')}'}',
        ),
        actions: [
          AdaptiveDialogAction(
            child: const Text('OK'),
            onPressed: () => Navigator.pop(ctx),
          ),
        ],
      ),
    );
  }

  void _enterSelectMode(String boxKey) {
    setState(() {
      _isSelecting = true;
      _selectedBoxKeys.add(boxKey);
    });
  }

  void _clearSelection() {
    setState(() {
      _isSelecting = false;
      _selectedBoxKeys.clear();
    });
  }

  void _toggleSelectAll() {
    final allKeys = _sortedDownloads.map((d) => d.boxKey).toSet();
    setState(() {
      if (_selectedBoxKeys.containsAll(allKeys)) {
        _selectedBoxKeys.clear();
      } else {
        _selectedBoxKeys
          ..clear()
          ..addAll(allKeys);
      }
    });
  }

  void _toggleSelect(String key) {
    setState(() {
      if (_selectedBoxKeys.contains(key)) {
        _selectedBoxKeys.remove(key);
      } else {
        _selectedBoxKeys.add(key);
      }
    });
  }

  DownloadedThread? _findByBoxKey(String key) {
    for (final d in _downloads) {
      if (d.boxKey == key) return d;
    }
    return null;
  }

  Future<void> _deleteSelected() async {
    final count = _selectedBoxKeys.length;
    final confirmed = await showAdaptiveDialog<bool>(
      context: context,
      builder: (ctx) => AdaptiveAlertDialog(
        title: Text('Delete $count thread${count == 1 ? '' : 's'}?'),
        content: const Text(
            'All downloaded files for the selected threads will be removed.'),
        actions: [
          AdaptiveDialogAction(
            child: const Text('Cancel'),
            onPressed: () => Navigator.pop(ctx, false),
          ),
          AdaptiveDialogAction(
            isDestructiveAction: true,
            child: const Text('Delete'),
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    for (final key in List<String>.from(_selectedBoxKeys)) {
      final d = _findByBoxKey(key);
      if (d != null) {
        await ThreadDownloadService.instance
            .deleteDownload(d.identifier, d.imageboardKey);
      }
    }
    if (mounted) {
      setState(() {
        _selectedBoxKeys.clear();
        _isSelecting = false;
    _reload();
      });
    }
  }

  Future<void> _migrateSelected() async {
    final selected = _sortedDownloads
        .where((d) => _selectedBoxKeys.contains(d.boxKey))
        .toList();
    await showAdaptiveDialog(
      context: context,
      builder: (ctx) => _MigrateSelectedDialog(records: selected),
    );
    if (mounted) {
      setState(() {
        _selectedBoxKeys.clear();
        _isSelecting = false;
    _reload();
      });
    }
  }

  void _showMultiStoragePreferenceSheet() {
    showAdaptiveModalPopup<void>(
      context: context,
      builder: (ctx) => AdaptiveActionSheet(
        title: Text(
            'Storage preference for ${_selectedBoxKeys.length} thread${_selectedBoxKeys.length == 1 ? "" : "s"}'),
        message: const Text(
            'Overrides the global "Auto-upload" setting for each selected thread.'),
        actions: [
          AdaptiveActionSheetAction(
            child: const Text('Follow global setting'),
            onPressed: () {
              Navigator.pop(ctx);
              _setStoragePreferenceForSelected(null);
            },
          ),
          AdaptiveActionSheetAction(
            child: const Text('Local only (never upload)'),
            onPressed: () {
              Navigator.pop(ctx);
              _setStoragePreferenceForSelected(
                  ThreadStoragePreference.localOnly);
            },
          ),
          AdaptiveActionSheetAction(
            child: const Text('Remote only (upload then delete local)'),
            onPressed: () {
              Navigator.pop(ctx);
              _setStoragePreferenceForSelected(
                  ThreadStoragePreference.remoteOnly);
            },
          ),
          AdaptiveActionSheetAction(
            child: const Text('Keep both (upload + keep local copy)'),
            onPressed: () {
              Navigator.pop(ctx);
              _setStoragePreferenceForSelected(ThreadStoragePreference.both);
            },
          ),
        ],
        cancelButton: AdaptiveActionSheetAction(
          child: const Text('Cancel'),
          onPressed: () => Navigator.pop(ctx),
        ),
      ),
    );
  }

  Future<void> _setStoragePreferenceForSelected(
      ThreadStoragePreference? pref) async {
    final selected = _sortedDownloads
        .where((d) => _selectedBoxKeys.contains(d.boxKey))
        .toList();
    // Warn if any selected thread has files only on CopyParty.
    if (pref == ThreadStoragePreference.localOnly) {
      final remoteCount = selected
          .where(
              (d) => d.effectiveStorageLocation == ThreadStorageLocation.remote)
          .length;
      if (remoteCount > 0) {
        if (!mounted) return;
        final confirmed = await showAdaptiveDialog<bool>(
          context: context,
          builder: (ctx) => AdaptiveAlertDialog(
            title: const Text('Files on CopyParty only'),
            content: Text(
              '$remoteCount '
              '${remoteCount == 1 ? 'thread has its files' : 'threads have their files'} '
              'only on CopyParty — not on your device.\n\nSwitching to '
              '"Local only" will not download them back. Files will remain '
              'on CopyParty but won\'t be accessible offline.',
            ),
            actions: [
              AdaptiveDialogAction(
                child: const Text('Cancel'),
                onPressed: () => Navigator.pop(ctx, false),
              ),
              AdaptiveDialogAction(
                child: const Text('Switch anyway'),
                onPressed: () => Navigator.pop(ctx, true),
              ),
            ],
          ),
        );
        if (!mounted || confirmed != true) return;
      }
    }
    for (final d in selected) {
      d.storagePreference = pref;
      // Same immediate reset as _setStoragePreference for localOnly.
      // Fire CopyParty deletion BEFORE zeroing fields — the guard inside
      // _deleteCopypartyFolder reads syncedFiles/storageLocation synchronously.
      if (pref == ThreadStoragePreference.localOnly) {
        final hadRemoteFiles = d.syncedFiles > 0 ||
            d.effectiveStorageLocation != ThreadStorageLocation.local;
        if (hadRemoteFiles) {
          ThreadDownloadService.instance.deleteCopypartyFolderForThread(d);
        }
        d.syncedFiles = 0;
        d.storageLocation = ThreadStorageLocation.local;
        d.totalSizeBytes = null;
      }
      if (d.isInBox) await d.save();
    }
    // Kick off background migration or re-download for complete threads.
    if (Persistence.settings.copypartyEnabled &&
        (pref == ThreadStoragePreference.remoteOnly ||
            pref == ThreadStoragePreference.both)) {
      final complete =
          selected.where((d) => d.status == DownloadStatus.complete).toList();
      if (complete.isNotEmpty) {
        if (pref == ThreadStoragePreference.both) {
          // For 'both': threads with files only on CopyParty need a re-download
          // to restore local copies; others migrate un-synced local files (F3).
          final needReDownload = complete
              .where((d) =>
                  d.effectiveStorageLocation == ThreadStorageLocation.remote &&
                  !d.isArchivedOnServer)
              .toList();
          final archivedRemote = complete
              .where((d) =>
                  d.effectiveStorageLocation == ThreadStorageLocation.remote &&
                  d.isArchivedOnServer)
              .toList();
          final needMigrate = complete
              .where((d) =>
                  d.effectiveStorageLocation != ThreadStorageLocation.remote)
              .toList();
          for (final d in needReDownload) {
            final imageboard =
                ImageboardRegistry.instance.getImageboard(d.imageboardKey);
            if (imageboard != null) {
              ThreadDownloadService.instance
                  .updateThread(d.identifier, imageboard.site, d.imageboardKey);
            }
          }
          if (archivedRemote.isNotEmpty && mounted) {
            showAdaptiveDialog(
              context: context,
              builder: (ctx) => AdaptiveAlertDialog(
                title: const Text('Cannot restore local files'),
                content: Text(
                  '${archivedRemote.length} '
                  '${archivedRemote.length == 1 ? 'thread is archived' : 'threads are archived'} — '
                  'files cannot be re-downloaded from the imageboard. '
                  'Files will remain on CopyParty but won\'t be available offline.',
                ),
                actions: [
                  AdaptiveDialogAction(
                    child: const Text('OK'),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
            );
          }
          if (needMigrate.isNotEmpty) {
            ThreadDownloadService.instance
                .startBackgroundMigration(needMigrate);
          }
        } else {
          // remoteOnly: always migrate.
          ThreadDownloadService.instance.startBackgroundMigration(complete);
        }
      }
    }
    if (mounted) {
      setState(() {
        _selectedBoxKeys.clear();
        _isSelecting = false;
    _reload();
      });
    }
  }

  /// Export a single thread as a ZIP, saving it to a user-chosen folder.
  Future<void> _exportSingle(DownloadedThread d) async {
    try {
      final zipFile = await ThreadDownloadService.instance.exportToZip(d);
      if (zipFile == null) {
        if (mounted) {
          showAdaptiveDialog(
            context: context,
            builder: (ctx) => AdaptiveAlertDialog(
              title: const Text('Nothing to export'),
              content: const Text('No local files found for this thread.'),
              actions: [
                AdaptiveDialogAction(
                    child: const Text('OK'),
                    onPressed: () => Navigator.pop(ctx))
              ],
            ),
          );
        }
        return;
      }
      final destDir = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Choose folder to save ZIP',
      );
      if (destDir == null) return; // user cancelled
      final destFile = File('$destDir/${zipFile.uri.pathSegments.last}');
      await zipFile.copy(destFile.path);
      if (mounted) {
        // If the thread's files are remote-only, the ZIP contains only metadata.
        final remoteNote =
            d.effectiveStorageLocation == ThreadStorageLocation.remote
                ? '\n\nNote: media files are stored on CopyParty and were '
                    'not included in the ZIP.'
                : '';
        showAdaptiveDialog(
          context: context,
          builder: (ctx) => AdaptiveAlertDialog(
            title: const Text('Exported'),
            content: Text('Saved to ${destFile.path}$remoteNote'),
            actions: [
              AdaptiveDialogAction(
                  child: const Text('OK'), onPressed: () => Navigator.pop(ctx))
            ],
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        showAdaptiveDialog(
          context: context,
          builder: (ctx) => AdaptiveAlertDialog(
            title: const Text('Export failed'),
            content: Text(e.toString()),
            actions: [
              AdaptiveDialogAction(
                  child: const Text('OK'), onPressed: () => Navigator.pop(ctx))
            ],
          ),
        );
      }
    }
  }

  /// Export all selected threads as ZIPs, saving them to a user-chosen folder.
  Future<void> _exportSelected() async {
    final selected = _sortedDownloads
        .where((d) => _selectedBoxKeys.contains(d.boxKey))
        .toList();
    final zipFiles = <File>[];
    for (final d in selected) {
      try {
        final f = await ThreadDownloadService.instance.exportToZip(d);
        if (f != null) zipFiles.add(f);
      } catch (_) {}
    }
    if (zipFiles.isEmpty) {
      if (mounted) {
        showAdaptiveDialog(
          context: context,
          builder: (ctx) => AdaptiveAlertDialog(
            title: const Text('Nothing to export'),
            content:
                const Text('None of the selected threads have local files.'),
            actions: [
              AdaptiveDialogAction(
                  child: const Text('OK'), onPressed: () => Navigator.pop(ctx))
            ],
          ),
        );
      }
      return;
    }
    final destDir = await FilePicker.platform.getDirectoryPath(
      dialogTitle:
          'Choose folder to save ${zipFiles.length} ZIP${zipFiles.length == 1 ? '' : 's'}',
    );
    if (destDir == null) return; // user cancelled
    int saved = 0;
    for (final zip in zipFiles) {
      try {
        await zip.copy('$destDir/${zip.uri.pathSegments.last}');
        saved++;
      } catch (_) {}
    }
    if (mounted) {
      showAdaptiveDialog(
        context: context,
        builder: (ctx) => AdaptiveAlertDialog(
          title: const Text('Exported'),
          content: Text(
              'Saved $saved/${zipFiles.length} ZIP${zipFiles.length == 1 ? '' : 's'} to $destDir'),
          actions: [
            AdaptiveDialogAction(
                child: const Text('OK'), onPressed: () => Navigator.pop(ctx))
          ],
        ),
      );
    }
  }

  Future<void> _softDeleteSingle(DownloadedThread d) async {
    await ThreadDownloadService.instance
        .softDelete(d.identifier, d.imageboardKey);
    if (mounted) setState(_reload);
  }

  Future<void> _undoSoftDeleteSingle(DownloadedThread d) async {
    await ThreadDownloadService.instance
        .undoSoftDelete(d.identifier, d.imageboardKey);
    if (mounted) setState(_reload);
  }

  Future<void> _permanentDeleteSingle(DownloadedThread d) async {
    final confirmed = await showAdaptiveDialog<bool>(
      context: context,
      builder: (ctx) => AdaptiveAlertDialog(
        title: const Text('Delete permanently?'),
        content: const Text(
            'All downloaded files for this thread will be removed immediately and cannot be undone.'),
        actions: [
          AdaptiveDialogAction(
              child: const Text('Cancel'),
              onPressed: () => Navigator.pop(ctx, false)),
          AdaptiveDialogAction(
              isDestructiveAction: true,
              child: const Text('Delete'),
              onPressed: () => Navigator.pop(ctx, true)),
        ],
      ),
    );
    if (confirmed == true) {
      await ThreadDownloadService.instance
          .permanentDelete(d.identifier, d.imageboardKey);
      if (mounted) setState(_reload);
    }
  }

  Future<void> _softDeleteSelected() async {
    for (final key in List<String>.from(_selectedBoxKeys)) {
      final d = _findByBoxKey(key);
      if (d != null) {
        await ThreadDownloadService.instance
            .softDelete(d.identifier, d.imageboardKey);
      }
    }
    if (mounted) {
      setState(() {
        _selectedBoxKeys.clear();
        _isSelecting = false;
    _reload();
      });
    }
  }

  Future<void> _permanentDeleteSelected() async {
    final count = _selectedBoxKeys.length;
    final confirmed = await showAdaptiveDialog<bool>(
      context: context,
      builder: (ctx) => AdaptiveAlertDialog(
        title:
            Text('Delete $count thread${count == 1 ? "" : "s"} permanently?'),
        content: const Text(
            'All downloaded files for the selected threads will be removed and cannot be undone.'),
        actions: [
          AdaptiveDialogAction(
              child: const Text('Cancel'),
              onPressed: () => Navigator.pop(ctx, false)),
          AdaptiveDialogAction(
              isDestructiveAction: true,
              child: const Text('Delete'),
              onPressed: () => Navigator.pop(ctx, true)),
        ],
      ),
    );
    if (confirmed != true) return;
    for (final key in List<String>.from(_selectedBoxKeys)) {
      final d = _findByBoxKey(key);
      if (d != null) {
        await ThreadDownloadService.instance
            .permanentDelete(d.identifier, d.imageboardKey);
      }
    }
    if (mounted) {
      setState(() {
        _selectedBoxKeys.clear();
        _isSelecting = false;
    _reload();
      });
    }
  }

  Future<void> _updateSelected() async {
    for (final key in List<String>.from(_selectedBoxKeys)) {
      final d = _findByBoxKey(key);
      if (d != null) await _update(d);
    }
    if (mounted) {
      setState(() {
        _selectedBoxKeys.clear();
        _isSelecting = false;
    _reload();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<SavedTheme>();
    return AdaptiveScaffold(
      bar: _isSelecting
          ? AdaptiveBar(
              leadings: [
                AdaptiveBarAction(
                  title: 'Cancel',
                  icon: const Icon(CupertinoIcons.xmark),
                  onPressed: _clearSelection,
                ),
              ],
              title: Text('${_selectedBoxKeys.length} selected'),
              actions: [
                CupertinoButton(
                  padding: EdgeInsets.zero,
                  onPressed: _toggleSelectAll,
                  child: Icon(
                    _selectedBoxKeys.length == _sortedDownloads.length
                        ? CupertinoIcons.checkmark_square_fill
                        : CupertinoIcons.checkmark_square,
                  ),
                ),
                if (_selectedBoxKeys.isNotEmpty)
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: () => showAdaptiveModalPopup(
                      context: context,
                      builder: (ctx) => AdaptiveActionSheet(
                        actions: [
                          AdaptiveActionSheetAction(
                            child: const Text('Update'),
                            onPressed: () {
                              Navigator.pop(ctx);
                              _updateSelected();
                            },
                          ),
                          AdaptiveActionSheetAction(
                            child: const Text('Export'),
                            onPressed: () {
                              Navigator.pop(ctx);
                              _exportSelected();
                            },
                          ),
                          if (Persistence.settings.copypartyEnabled)
                            AdaptiveActionSheetAction(
                              child: const Text('Migrate to CopyParty'),
                              onPressed: () {
                                Navigator.pop(ctx);
                                _migrateSelected();
                              },
                            ),
                          if (Persistence.settings.copypartyEnabled)
                            AdaptiveActionSheetAction(
                              child: const Text('Set storage preference...'),
                              onPressed: () {
                                Navigator.pop(ctx);
                                _showMultiStoragePreferenceSheet();
                              },
                            ),
                          AdaptiveActionSheetAction(
                            child: const Text('Mark for Deletion (5 days)'),
                            onPressed: () {
                              Navigator.pop(ctx);
                              _softDeleteSelected();
                            },
                          ),
                          AdaptiveActionSheetAction(
                            isDestructiveAction: true,
                            child: const Text('Delete Permanently'),
                            onPressed: () {
                              Navigator.pop(ctx);
                              _permanentDeleteSelected();
                            },
                          ),
                        ],
                        cancelButton: AdaptiveActionSheetAction(
                          child: const Text('Cancel'),
                          onPressed: () => Navigator.pop(ctx),
                        ),
                      ),
                    ),
                    child: const Icon(CupertinoIcons.ellipsis),
                  ),
              ],
            )
          : AdaptiveBar(
              title: Text('Downloads (${_downloads.length})'),
              actions: [
                CupertinoButton(
                  padding: EdgeInsets.zero,
                  onPressed: _isImporting ? null : () => _showSortMenu(context),
                  child: Icon(_sortReversed
                      ? CupertinoIcons.sort_up
                      : CupertinoIcons.sort_down),
                ),
                if (_isImporting)
                  const CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: null,
                    child: CupertinoActivityIndicator(),
                  )
                else
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: _importKuroba,
                    child: const Icon(CupertinoIcons.arrow_down_doc),
                  ),
              ],
            ),
      body: Column(
        children: [
          if (_isImporting)
            Container(
              color: theme.primaryColor.withOpacity(0.1),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  const CupertinoActivityIndicator(),
                  const SizedBox(width: 10),
                  Text(
                    'Importing $_importCurrent of $_importTotal…',
                    style: const TextStyle(fontSize: 13),
                  ),
                ],
              ),
            ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _refreshAll,
              child: _downloads.isEmpty
                  ? const CustomScrollView(
                      physics: AlwaysScrollableScrollPhysics(),
                      slivers: [
                        SliverFillRemaining(
                            child: Center(
                                child: Text('No downloaded threads')))
                      ],
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: EdgeInsets.only(
                          bottom: MediaQuery.viewPaddingOf(context).bottom),
                      itemCount: _cachedSortedDownloads.length,
                    itemBuilder: (context, i) {
                      final d = _sortedDownloads[i];
                      return _DownloadedThreadRow(
                        download: d,
                        preloadedThread: _threadCache[d.boxKey],
                        onTap: _isSelecting
                            ? () => _toggleSelect(d.boxKey)
                            : () => _openThread(d),
                        onDelete: () => _delete(d),
                        onUpdate: () => _update(d),
                        onExport: () => _exportSingle(d),
                        onSoftDelete: () => _softDeleteSingle(d),
                        onPermanentDelete: () => _permanentDeleteSingle(d),
                        onUndoSoftDelete: () => _undoSoftDeleteSingle(d),
                        onMigrate: () async {
                          await showAdaptiveDialog(
                            context: context,
                            builder: (ctx) =>
                                _MigrateSelectedDialog(records: [d]),
                          );
                          if (mounted) setState(_reload);
                        },
                        onCancel: () {
                          ThreadDownloadService.instance
                              .cancelDownload(d.identifier, d.imageboardKey);
                          setState(_reload);
                        },
                        onSelect: () => _enterSelectMode(d.boxKey),
                        isSelecting: _isSelecting,
                        isSelected: _selectedBoxKeys.contains(d.boxKey),
                      );
                    },
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DownloadedThreadRow extends StatefulWidget {
  final DownloadedThread download;
  final Thread? preloadedThread;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback onUpdate;
  final VoidCallback onExport;
  final VoidCallback onSoftDelete;
  final VoidCallback onPermanentDelete;
  final VoidCallback onUndoSoftDelete;
  final Future<void> Function() onMigrate;
  final VoidCallback onCancel;
  final VoidCallback onSelect;
  final bool isSelecting;
  final bool isSelected;

  const _DownloadedThreadRow({
    required this.download,
    this.preloadedThread,
    required this.onTap,
    required this.onDelete,
    required this.onUpdate,
    required this.onExport,
    required this.onSoftDelete,
    required this.onPermanentDelete,
    required this.onUndoSoftDelete,
    required this.onMigrate,
    required this.onCancel,
    required this.onSelect,
    required this.isSelecting,
    required this.isSelected,
  });

  @override
  State<_DownloadedThreadRow> createState() => _DownloadedThreadRowState();
}

class _DownloadedThreadRowState extends State<_DownloadedThreadRow> {
  Uri? _copypartyThumbUri;
  Map<String, String>? _copypartyThumbHeaders;
  int? _displaySizeBytes;

  @override
  void initState() {
    super.initState();
    _loadCopypartyThumb();
    _refreshSize();
    ThreadDownloadService.instance.activeMigrations
        .addListener(_onMigrationStateChanged);
  }

  void _onMigrationStateChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    ThreadDownloadService.instance.activeMigrations
        .removeListener(_onMigrationStateChanged);
    super.dispose();
  }

  @override
  void didUpdateWidget(_DownloadedThreadRow old) {
    super.didUpdateWidget(old);
    if (old.download.boxKey != widget.download.boxKey) {
      _copypartyThumbUri = null;
      _copypartyThumbHeaders = null;
      _loadCopypartyThumb();
    }
    final d = widget.download;
    final o = old.download;
    if (d.downloadedFiles != o.downloadedFiles ||
        d.totalSizeBytes != o.totalSizeBytes ||
        d.status != o.status) {
      _refreshSize();
    }
  }

  void _refreshSize() {
    final d = widget.download;
    // For remoteOnly threads (no local files), use the stored totalSizeBytes
    // which was captured when files were downloaded and uploaded.
    // For all other threads, scan the directory for the ground-truth current size
    // so the display always matches what is actually on disk.
    if (d.effectiveStorageLocation == ThreadStorageLocation.remote) {
      if (d.totalSizeBytes != null && d.totalSizeBytes! > 0) {
        if (mounted) setState(() => _displaySizeBytes = d.totalSizeBytes);
      }
      return;
    }
    ThreadDownloadService.instance.computeThreadDirSize(d).then((size) {
      if (mounted && size > 0) {
        setState(() => _displaySizeBytes = size);
      } else if (mounted && d.totalSizeBytes != null && d.totalSizeBytes! > 0) {
        // Fallback to stored value (e.g. files were just deleted mid-run).
        setState(() => _displaySizeBytes = d.totalSizeBytes);
      }
    });
  }

  static String _formatBytes(int bytes) {
    if (bytes <= 0) return '';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  Future<void> _loadCopypartyThumb() async {
    final uri = await ThreadDownloadService.instance
        .copypartyThumbnailUri(widget.download);
    if (uri == null || !mounted) return;
    final pw = await ThreadDownloadService.instance.getCopypartyPassword();
    if (mounted) {
      setState(() {
        _copypartyThumbUri = uri;
        _copypartyThumbHeaders =
            (pw != null && pw.isNotEmpty) ? {'Pw': pw} : null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.download;
    final imageboard =
        ImageboardRegistry.instance.getImageboard(d.imageboardKey);
    final thread = widget.preloadedThread;
    final theme = context.watch<SavedTheme>();
    final progress = d.totalFiles > 0 ? d.downloadedFiles / d.totalFiles : null;
    final canOpen = d.status != DownloadStatus.pending;

    final isPendingDeletion = d.pendingDeletionAt != null;
    if (imageboard != null && thread != null) {
      return Opacity(
        opacity: isPendingDeletion ? 0.4 : 1.0,
        child: GestureDetector(
          onTap: (canOpen || widget.isSelecting) ? widget.onTap : null,
          onLongPress:
              widget.isSelecting ? null : () => _showActionSheet(context, d),
          child: Container(
            decoration: BoxDecoration(
              border: Border(
                  bottom:
                      BorderSide(color: theme.primaryColor.withOpacity(0.1))),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: ImageboardScope(
                        imageboardKey: null,
                        imageboard: imageboard,
                        child: ThreadRow(
                          thread: thread,
                          isSelected: false,
                          showBoardName: true,
                          showSiteIcon: true,
                          forceShowInHistory: true,
                          semanticParentIds: const [-5],
                          dimReadThreads: false,
                          showLastReplies:
                              Settings.instance.showLastRepliesInCatalog,
                          onThumbnailTap: (initialAttachment) {
                            final allAttachments = thread.posts_
                                .expand((p) =>
                                    p.attachments_.map((a) => TaggedAttachment(
                                          imageboard: imageboard,
                                          attachment: a,
                                          semanticParentIds: const [-5],
                                          postId: thread.id,
                                        )))
                                .toList();
                            showGalleryPretagged(
                              context: context,
                              attachments: allAttachments,
                              initialAttachment: initialAttachment,
                              heroOtherEndIsBoxFitCover:
                                  Settings.instance.squareThumbnails,
                            );
                          },
                        ),
                      ),
                    ),
                    _actionsWidget(context, d),
                  ],
                ),
                if (d.status != DownloadStatus.complete)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    child: Align(
                        alignment: Alignment.centerLeft,
                        child: _statusWidget(context, d, progress)),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                    child: Align(
                        alignment: Alignment.centerLeft,
                        child: _statusWidget(context, d, progress)),
                  ),
              ],
            ),
          ),
        ),
      );
    }

    // Fallback when thread data is not yet cached
    final thumbnailUrl = d.thumbnailUrl;
    return Opacity(
      opacity: isPendingDeletion ? 0.4 : 1.0,
      child: GestureDetector(
        onTap: (canOpen || widget.isSelecting) ? widget.onTap : null,
        onLongPress:
            widget.isSelecting ? null : () => _showActionSheet(context, d),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            border: Border(
                bottom: BorderSide(color: theme.primaryColor.withOpacity(0.1))),
          ),
          child: Row(
            children: [
              Container(
                width: 60,
                height: 60,
                margin: const EdgeInsets.only(right: 12),
                decoration: BoxDecoration(
                  color: theme.primaryColor.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: d.localThumbnailFilename != null || thumbnailUrl != null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: _buildThumbnail(d, theme),
                      )
                    : Icon(CupertinoIcons.doc_text, color: theme.primaryColor),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${d.imageboardKey} /${d.board}/ #${d.threadId}',
                      style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: theme.primaryColor),
                    ),
                    if (d.title != null)
                      Text(
                        d.title!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 13,
                            color: theme.primaryColor.withOpacity(0.8)),
                      ),
                    const SizedBox(height: 4),
                    _statusWidget(context, d, progress),
                  ],
                ),
              ),
              _actionsWidget(context, d),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildThumbnail(DownloadedThread d, SavedTheme theme) {
    final localFile = ThreadDownloadService.instance.findLocalThumbnail(d);
    if (localFile != null) {
      return Image.file(
        localFile,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) =>
            Icon(CupertinoIcons.photo, color: theme.primaryColor),
      );
    }
    final copypartyUri = _copypartyThumbUri;
    if (copypartyUri != null) {
      return Image.network(
        copypartyUri.toString(),
        headers: _copypartyThumbHeaders,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) =>
            Icon(CupertinoIcons.photo, color: theme.primaryColor),
      );
    }
    final thumbnailUrl = d.thumbnailUrl;
    if (thumbnailUrl != null) {
      return Image.network(
        thumbnailUrl,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) =>
            Icon(CupertinoIcons.photo, color: theme.primaryColor),
      );
    }
    return Icon(CupertinoIcons.photo, color: theme.primaryColor);
  }

  Widget _statusWidget(
      BuildContext context, DownloadedThread d, double? progress) {
    // Background CopyParty sync in progress — show syncing indicator regardless
    // of the stored status so the user can see live progress.
    if (ThreadDownloadService.instance.activeMigrations.value
        .contains(d.boxKey)) {
      final runTotal =
          ThreadDownloadService.instance.migrationRunTotal(d.boxKey);
      final syncProgress =
          runTotal > 0 ? (d.syncedFiles / runTotal).clamp(0.0, 1.0) : null;
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (syncProgress != null)
          LinearProgressIndicator(value: syncProgress, minHeight: 4),
        Row(children: [
          const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 1.5)),
          const SizedBox(width: 6),
          Text(
            'Syncing ${d.syncedFiles}/$runTotal…',
            style: const TextStyle(fontSize: 12),
          ),
        ]),
      ]);
    }
    switch (d.status) {
      case DownloadStatus.pending:
        return const Row(children: [
          SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 1.5)),
          SizedBox(width: 6),
          Text('Queued...', style: TextStyle(fontSize: 12)),
        ]);
      case DownloadStatus.downloading:
      case DownloadStatus.updating:
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (progress != null)
            LinearProgressIndicator(value: progress, minHeight: 4),
          Row(children: [
            Text(
              '${d.downloadedFiles}/${d.totalFiles} files',
              style: const TextStyle(fontSize: 12),
            ),
            if (_displaySizeBytes != null && _displaySizeBytes! > 0) ...[
              const SizedBox(width: 6),
              const Text('·',
                  style: TextStyle(
                      fontSize: 12, color: CupertinoColors.systemGrey)),
              const SizedBox(width: 6),
              Text(
                _formatBytes(_displaySizeBytes!),
                style: const TextStyle(
                    fontSize: 12, color: CupertinoColors.systemGrey),
              ),
            ],
          ]),
        ]);
      case DownloadStatus.complete:
        // Show pending deletion countdown if soft-deleted
        if (d.pendingDeletionAt != null) {
          final daysLeft =
              d.pendingDeletionAt!.difference(DateTime.now()).inDays;
          final label = daysLeft > 0
              ? 'Marked for deletion in $daysLeft day${daysLeft == 1 ? "" : "s"}'
              : 'Marked for deletion';
          return Text(label,
              style: const TextStyle(
                  fontSize: 12, color: CupertinoColors.destructiveRed));
        }
        // Show transient-error message (e.g. "Network error — retrying").
        // errorMessage is set when a transient failure occurred during an
        // update run and is cleared on the next successful completion.
        if (d.errorMessage != null) {
          return Row(children: [
            const Icon(CupertinoIcons.wifi_slash,
                size: 14, color: CupertinoColors.systemOrange),
            const SizedBox(width: 4),
            Flexible(
                child: Text(d.errorMessage!,
                    style: const TextStyle(
                        fontSize: 12, color: CupertinoColors.systemOrange))),
          ]);
        }
        return _buildStorageIndicator(d);
      case DownloadStatus.failed:
        return Row(children: [
          const Icon(CupertinoIcons.exclamationmark_triangle,
              size: 14, color: CupertinoColors.destructiveRed),
          const SizedBox(width: 4),
          Flexible(
              child: Text(d.errorMessage ?? 'Failed',
                  style: const TextStyle(
                      fontSize: 12, color: CupertinoColors.destructiveRed))),
        ]);
      case DownloadStatus.cancelled:
        return const Row(children: [
          Icon(CupertinoIcons.stop_circle,
              size: 14, color: CupertinoColors.systemGrey),
          SizedBox(width: 4),
          Text('Cancelled',
              style:
                  TextStyle(fontSize: 12, color: CupertinoColors.systemGrey)),
        ]);
    }
  }

  Widget _buildStorageIndicator(DownloadedThread d) {
    if (d.downloadedFiles == 0 && d.syncedFiles == 0) {
      return const SizedBox.shrink();
    }

    Widget iconWidget;
    switch (d.effectiveStorageLocation) {
      case ThreadStorageLocation.local:
        iconWidget = const Icon(CupertinoIcons.device_phone_portrait,
            size: 12, color: CupertinoColors.systemGrey);
      case ThreadStorageLocation.remote:
        iconWidget = const Icon(CupertinoIcons.cloud_fill,
            size: 12, color: CupertinoColors.systemBlue);
      case ThreadStorageLocation.mixed:
        iconWidget = const Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(CupertinoIcons.device_phone_portrait,
              size: 12, color: CupertinoColors.systemGrey),
          SizedBox(width: 2),
          Text('/',
              style:
                  TextStyle(fontSize: 10, color: CupertinoColors.systemGrey)),
          SizedBox(width: 2),
          Icon(CupertinoIcons.cloud_fill,
              size: 12, color: CupertinoColors.systemBlue),
        ]);
    }

    final sizeStr = _displaySizeBytes != null && _displaySizeBytes! > 0
        ? _formatBytes(_displaySizeBytes!)
        : null;
    if (sizeStr == null) return iconWidget;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Text(sizeStr,
          style:
              const TextStyle(fontSize: 12, color: CupertinoColors.systemGrey)),
      const SizedBox(width: 4),
      iconWidget,
    ]);
  }

  void _showActionSheet(BuildContext context, DownloadedThread d) {
    mediumHapticFeedback();
    showAdaptiveModalPopup(
      context: context,
      builder: (popupContext) => AdaptiveActionSheet(
        actions: [
          if (d.status == DownloadStatus.complete ||
              d.status == DownloadStatus.failed ||
              d.status == DownloadStatus.cancelled)
            AdaptiveActionSheetAction(
              child: const Text('Update'),
              onPressed: () {
                Navigator.pop(popupContext);
                widget.onUpdate();
              },
            ),
          AdaptiveActionSheetAction(
            child: const Text('Export'),
            onPressed: () {
              Navigator.pop(popupContext);
              widget.onExport();
            },
          ),
          if (Persistence.settings.copypartyEnabled &&
              d.status == DownloadStatus.complete)
            AdaptiveActionSheetAction(
              child: const Text('Migrate to CopyParty'),
              onPressed: () {
                Navigator.pop(popupContext);
                widget.onMigrate();
              },
            ),
          if (Persistence.settings.copypartyEnabled)
            AdaptiveActionSheetAction(
              child: Text(_storagePreferenceLabel(d.storagePreference)),
              onPressed: () {
                Navigator.pop(popupContext);
                _showStoragePreferenceSheet(context, d);
              },
            ),
          AdaptiveActionSheetAction(
            child: const Text('Select'),
            onPressed: () {
              Navigator.pop(popupContext);
              widget.onSelect();
            },
          ),
          if (d.pendingDeletionAt != null)
            AdaptiveActionSheetAction(
              child: const Text('Undo Mark for Deletion'),
              onPressed: () {
                Navigator.pop(popupContext);
                widget.onUndoSoftDelete();
              },
            )
          else
            AdaptiveActionSheetAction(
              child: const Text('Mark for Deletion (5 days)'),
              onPressed: () {
                Navigator.pop(popupContext);
                widget.onSoftDelete();
              },
            ),
          AdaptiveActionSheetAction(
            isDestructiveAction: true,
            child: const Text('Delete Permanently'),
            onPressed: () {
              Navigator.pop(popupContext);
              widget.onPermanentDelete();
            },
          ),
        ],
        cancelButton: AdaptiveActionSheetAction(
          child: const Text('Cancel'),
          onPressed: () => Navigator.pop(popupContext),
        ),
      ),
    );
  }

  String _storagePreferenceLabel(ThreadStoragePreference? pref) {
    switch (pref) {
      case ThreadStoragePreference.localOnly:
        return 'Storage: Local only';
      case ThreadStoragePreference.remoteOnly:
        return 'Storage: Remote only';
      case ThreadStoragePreference.both:
        return 'Storage: Keep both';
      case null:
        return 'Storage: Follow global setting';
    }
  }

  void _showStoragePreferenceSheet(BuildContext context, DownloadedThread d) {
    showAdaptiveModalPopup<void>(
      context: context,
      builder: (ctx) => AdaptiveActionSheet(
        title: const Text('Storage preference for this thread'),
        message: const Text(
            'Overrides the global "Auto-upload" setting for this thread.'),
        actions: [
          AdaptiveActionSheetAction(
            child: Text(
              'Follow global setting',
              style: d.storagePreference == null
                  ? const TextStyle(fontWeight: FontWeight.bold)
                  : null,
            ),
            onPressed: () {
              Navigator.pop(ctx);
              _setStoragePreference(d, null);
            },
          ),
          AdaptiveActionSheetAction(
            child: Text(
              'Local only (never upload)',
              style: d.storagePreference == ThreadStoragePreference.localOnly
                  ? const TextStyle(fontWeight: FontWeight.bold)
                  : null,
            ),
            onPressed: () {
              Navigator.pop(ctx);
              _setStoragePreference(d, ThreadStoragePreference.localOnly);
            },
          ),
          AdaptiveActionSheetAction(
            child: Text(
              'Remote only (upload then delete local)',
              style: d.storagePreference == ThreadStoragePreference.remoteOnly
                  ? const TextStyle(fontWeight: FontWeight.bold)
                  : null,
            ),
            onPressed: () {
              Navigator.pop(ctx);
              _setStoragePreference(d, ThreadStoragePreference.remoteOnly);
            },
          ),
          AdaptiveActionSheetAction(
            child: Text(
              'Keep both (upload + keep local copy)',
              style: d.storagePreference == ThreadStoragePreference.both
                  ? const TextStyle(fontWeight: FontWeight.bold)
                  : null,
            ),
            onPressed: () {
              Navigator.pop(ctx);
              _setStoragePreference(d, ThreadStoragePreference.both);
            },
          ),
        ],
        cancelButton: AdaptiveActionSheetAction(
          child: const Text('Cancel'),
          onPressed: () => Navigator.pop(ctx),
        ),
      ),
    );
  }

  Future<void> _setStoragePreference(
      DownloadedThread d, ThreadStoragePreference? pref) async {
    // Switching to localOnly when files are only on CopyParty:
    // - Live threads: download to device first, then delete from CopyParty
    //   on download completion (_runDownload detects remote storageLocation).
    // - Archived threads: can't re-download, warn about permanent deletion.
    if (pref == ThreadStoragePreference.localOnly &&
        d.effectiveStorageLocation == ThreadStorageLocation.remote) {
      if (!mounted) return;
      if (!d.isArchivedOnServer) {
        // Live thread: download first, CopyParty deletion fires on completion.
        final confirmed = await showAdaptiveDialog<bool>(
          context: context,
          builder: (ctx) => AdaptiveAlertDialog(
            title: const Text('Download before switching?'),
            content: const Text(
              'This thread\'s files are only stored on CopyParty. They will be '
              'downloaded to your device first, then removed from CopyParty '
              'once the download is complete.',
            ),
            actions: [
              AdaptiveDialogAction(
                child: const Text('Cancel'),
                onPressed: () => Navigator.pop(ctx, false),
              ),
              AdaptiveDialogAction(
                child: const Text('Download & switch'),
                onPressed: () => Navigator.pop(ctx, true),
              ),
            ],
          ),
        );
        if (!mounted || confirmed != true) return;
        // Set preference — storageLocation intentionally left as 'remote' so
        // _runDownload can detect it at completion and fire CopyParty deletion.
        d.storagePreference = pref;
        if (d.isInBox) await d.save();
        if (mounted) setState(() {});
        final imageboard =
            ImageboardRegistry.instance.getImageboard(d.imageboardKey);
        if (imageboard != null) {
          ThreadDownloadService.instance
              .updateThread(d.identifier, imageboard.site, d.imageboardKey);
        }
        return;
      }
      // Archived thread: cannot re-download — warn about permanent loss.
      final confirmed = await showAdaptiveDialog<bool>(
        context: context,
        builder: (ctx) => AdaptiveAlertDialog(
          title: const Text('Permanently delete from CopyParty?'),
          content: const Text(
            'This thread is archived — its files cannot be re-downloaded '
            'from the imageboard. Switching to "Local only" will permanently '
            'delete them from CopyParty with no way to recover them.',
          ),
          actions: [
            AdaptiveDialogAction(
              child: const Text('Cancel'),
              onPressed: () => Navigator.pop(ctx, false),
            ),
            AdaptiveDialogAction(
              isDestructiveAction: true,
              child: const Text('Delete anyway'),
              onPressed: () => Navigator.pop(ctx, true),
            ),
          ],
        ),
      );
      if (!mounted || confirmed != true) return;
      // Fall through to immediate deletion below.
    }
    d.storagePreference = pref;
    // For mixed (local+remote) and archived remoteOnly threads, clear remote
    // state fields immediately. Live remoteOnly threads returned early above;
    // their state is cleaned up by _runDownload on completion.
    final hadRemoteFiles = pref == ThreadStoragePreference.localOnly &&
        (d.syncedFiles > 0 || d.effectiveStorageLocation != ThreadStorageLocation.local);
    // Fire-and-forget BEFORE zeroing fields — the guard inside
    // _deleteCopypartyFolder checks syncedFiles/storageLocation synchronously,
    // so it must run while they still reflect the old remote state.
    if (hadRemoteFiles) {
      ThreadDownloadService.instance.deleteCopypartyFolderForThread(d);
    }
    if (pref == ThreadStoragePreference.localOnly) {
      d.syncedFiles = 0;
      d.storageLocation = ThreadStorageLocation.local;
      d.totalSizeBytes = null;
    }
    if (d.isInBox) await d.save();
    if (mounted) setState(() {});
    // If the new preference implies uploading and the thread already has local
    // files, kick off background migration so the user sees progress directly
    // on the row — no blocking dialog.
    if (mounted &&
        Persistence.settings.copypartyEnabled &&
        d.status == DownloadStatus.complete) {
      if (pref == ThreadStoragePreference.both &&
          d.effectiveStorageLocation == ThreadStorageLocation.remote) {
        if (d.isArchivedOnServer) {
          // Archived threads can't be re-downloaded — show an informational
          // dialog so the user isn't left wondering why nothing happened (E2/D1).
          if (mounted) {
            showAdaptiveDialog(
              context: context,
              builder: (ctx) => AdaptiveAlertDialog(
                title: const Text('Cannot restore local files'),
                content: const Text(
                  'This thread is archived — its files cannot be re-downloaded '
                  'from the imageboard. Files will remain on CopyParty but '
                  "won't be available offline until you re-import a ZIP.",
                ),
                actions: [
                  AdaptiveDialogAction(
                    child: const Text('OK'),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
            );
          }
        } else {
          // All files are on CopyParty only — trigger a re-download to restore
          // local copies. A migration on an empty local dir would find nothing.
          final imageboard =
              ImageboardRegistry.instance.getImageboard(d.imageboardKey);
          if (imageboard != null) {
            ThreadDownloadService.instance
                .updateThread(d.identifier, imageboard.site, d.imageboardKey);
          }
        }
      } else if (pref == ThreadStoragePreference.remoteOnly ||
          pref == ThreadStoragePreference.both) {
        ThreadDownloadService.instance.startBackgroundMigration([d]);
      }
    }
  }

  Widget _actionsWidget(BuildContext context, DownloadedThread d) {
    if (widget.isSelecting) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Icon(
          widget.isSelected
              ? CupertinoIcons.checkmark_circle_fill
              : CupertinoIcons.circle,
          color: widget.isSelected
              ? CupertinoColors.activeBlue
              : CupertinoColors.systemGrey,
          size: 22,
        ),
      );
    }
    if (d.status == DownloadStatus.downloading ||
        d.status == DownloadStatus.updating ||
        d.status == DownloadStatus.pending) {
      return CupertinoButton(
        padding: EdgeInsets.zero,
        onPressed: widget.onCancel,
        child: const Icon(CupertinoIcons.xmark_circle),
      );
    }
    return CupertinoButton(
      padding: EdgeInsets.zero,
      onPressed: () => _showActionSheet(context, d),
      child: const Icon(CupertinoIcons.ellipsis),
    );
  }

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inDays == 0) return 'Today';
    if (diff.inDays == 1) return 'Yesterday';
    return '${dt.month}/${dt.day}/${dt.year}';
  }
}

class _MigrateSelectedDialog extends StatefulWidget {
  final List<DownloadedThread> records;
  const _MigrateSelectedDialog({required this.records});
  @override
  State<_MigrateSelectedDialog> createState() => _MigrateSelectedDialogState();
}

class _MigrateSelectedDialogState extends State<_MigrateSelectedDialog> {
  late final StreamSubscription<MigrationProgress> _sub;
  MigrationProgress? _progress;

  @override
  void initState() {
    super.initState();
    _sub = ThreadDownloadService.instance
        .runForegroundMigration(widget.records)
        .listen(
      (p) {
        if (mounted) {
          setState(() => _progress = p);
        }
      },
      onError: (e) {
        if (mounted) {
          setState(() => _progress = MigrationProgress(
                totalFiles: _progress?.totalFiles ?? 0,
                processedFiles: _progress?.processedFiles ?? 0,
                uploadedFiles: _progress?.uploadedFiles ?? 0,
                error: e.toString(),
                isDone: true,
              ));
        }
      },
    );
  }

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = _progress;
    final isDone = p?.isDone ?? false;
    final error = p?.error;
    final frac = (p == null || p.totalFiles == 0)
        ? null
        : p.processedFiles / p.totalFiles;

    return AdaptiveAlertDialog(
      title: const Text('Migrate to CopyParty'),
      content: Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (p == null)
              const Center(child: CircularProgressIndicator.adaptive())
            else if (error != null)
              Text(error,
                  style: const TextStyle(color: CupertinoColors.destructiveRed))
            else if (isDone)
              Text(
                  'Done — ${p.uploadedFiles} file${p.uploadedFiles == 1 ? '' : 's'} migrated.')
            else ...[
              Text('Uploading ${p.processedFiles} / ${p.totalFiles}…'),
              const SizedBox(height: 10),
              LinearProgressIndicator(value: frac),
            ],
          ],
        ),
      ),
      actions: [
        if (isDone || error != null)
          AdaptiveDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.pop(context),
            child: const Text('Done'),
          )
        else
          AdaptiveDialogAction(
            onPressed: () {
              ThreadDownloadService.instance.cancelMigration();
              Navigator.pop(context);
            },
            child: const Text('Cancel'),
          ),
      ],
    );
  }
}
