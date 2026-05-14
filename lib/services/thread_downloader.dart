import 'dart:async';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:chan/models/attachment.dart';
import 'package:chan/models/downloaded_thread.dart';
import 'package:chan/models/thread.dart';
import 'package:chan/services/copyparty_sync.dart';
import 'package:chan/services/imageboard.dart';
import 'package:chan/services/persistence.dart';
import 'package:chan/services/thread_html.dart';
import 'package:chan/services/settings.dart';
import 'package:chan/services/streaming_mp4.dart';
import 'package:chan/sites/imageboard_site.dart';
import 'package:dio/dio.dart';
import 'package:extended_image_library/extended_image_library.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive/hive.dart';
import 'package:mutex/mutex.dart';

class ImportScanResult {
  final int found;
  final int skipped;
  const ImportScanResult(this.found, this.skipped);
}

class MigrationProgress {
  final int totalFiles;
  final int processedFiles;
  final int uploadedFiles;
  final String? error;
  final bool isDone;
  const MigrationProgress({
    required this.totalFiles,
    required this.processedFiles,
    required this.uploadedFiles,
    this.error,
    this.isDone = false,
  });
}

class ThreadDownloadService {
  static late final ThreadDownloadService instance;

  static const _boxName = 'downloadedThreads';

  final Box<DownloadedThread> _box;
  Box<DownloadedThread> get downloadsBox => _box;
  final Directory _downloadsDir;
  final storage = const FlutterSecureStorage();

  // Per-thread mutex: one operation at a time per thread key
  final Map<String, Mutex> _mutexes = {};
  // Active cancel tokens for in-progress downloads
  final Map<String, CancelToken> _cancelTokens = {};
  // Keys where a cancel was requested before the CancelToken was registered
  final Set<String> _pendingCancels = {};

  StreamSubscription<PersistentThreadState>? _threadStateSubscription;
  static Timer? _autoSyncTimer;
  bool _migrationCancelled = false;
  bool _migrationRunning = false;
  final List<DownloadedThread> _migrationQueue = [];

  /// In-memory set of thread `boxKey`s currently being synced to CopyParty
  /// in the background. Rows listen to this to show a syncing indicator.
  final ValueNotifier<Set<String>> activeMigrations =
      ValueNotifier<Set<String>>({});

  /// Per-run file count for each thread currently migrating.
  /// Used as the denominator for the progress bar so it always starts at 0.
  final Map<String, int> _migrationRunTotals = {};

  /// Returns the number of files to upload for [boxKey] in the current run.
  int migrationRunTotal(String boxKey) => _migrationRunTotals[boxKey] ?? 1;

  ThreadDownloadService._(this._box, this._downloadsDir);

  static Future<void> initializeStatic() async {
    final box = Hive.box<DownloadedThread>(_boxName);
    final downloadsDir = Persistence.downloadsDirectory;
    instance = ThreadDownloadService._(box, downloadsDir);
    // Reset any interrupted downloads to pending so resumePending() can restart them
    for (final record in box.values) {
      if (record.status == DownloadStatus.downloading ||
          record.status == DownloadStatus.updating) {
        record.status = DownloadStatus.pending;
        if (record.isInBox) await record.save();
      }
      // Migration: reset threads that failed due to the null-int hot-reload bug
      // (downloadInterFileDelayMs was null in memory after a hot-reload).
      if (record.status == DownloadStatus.failed &&
          (record.errorMessage
                  ?.contains("'Null' is not a subtype of type 'int'") ==
              true)) {
        record.status = DownloadStatus.complete;
        record.errorMessage = null;
        if (record.isInBox) await record.save();
      }
    }
    // Subscribe to thread state changes for auto-update
    instance._threadStateSubscription =
        Persistence.sharedThreadStateStream.listen(
      instance._onThreadStateUpdated,
    );
    // Auto-sync timer: re-fetch live threads every 30 minutes while app is in foreground
    _autoSyncTimer?.cancel();
    _autoSyncTimer = Timer.periodic(const Duration(minutes: 30), (_) {
      instance._autoSync();
    });
  }

  /// Call this after imageboards are fully initialized to restart pending downloads.
  /// Processes sequentially to avoid saturating the connection.
  Future<void> resumePending() async {
    final pending = _box.values
        .where((r) => r.status == DownloadStatus.pending)
        .toList(); // snapshot — box may change during processing
    for (final record in pending) {
      if (record.status != DownloadStatus.pending) {
        continue; // may have changed since snapshot
      }
      final imageboard =
          ImageboardRegistry.instance.getImageboard(record.imageboardKey);
      if (imageboard == null) continue;
      await _runDownload(record, imageboard.site);
    }
  }

  void _onThreadStateUpdated(PersistentThreadState state) {
    final key = _key(state.imageboardKey, state.identifier);
    final record = _box.get(key);
    if (record == null || record.status != DownloadStatus.complete) return;
    // Archived threads can't receive new posts — skip to avoid unnecessary network
    // requests and potential storageLocation corruption (E2).
    if (record.isArchivedOnServer) return;
    final thread = state.thread;
    if (thread == null) return;

    // Compare remote slot count (using same filename-parseability logic) to local totalFiles
    final remoteSlots = thread.posts_
        .expand((p) => p.attachments_)
        .where((a) => !a.type.isNonMedia)
        .fold<int>(0, (n, a) {
      if (Uri.tryParse(a.url)?.pathSegments.lastOrNull != null) n++;
      if (Uri.tryParse(a.thumbnailUrl)?.pathSegments.lastOrNull != null) n++;
      return n;
    });
    if (remoteSlots > record.totalFiles) {
      final imageboard =
          ImageboardRegistry.instance.getImageboard(state.imageboardKey);
      if (imageboard != null) {
        updateThread(state.identifier, imageboard.site, state.imageboardKey);
      }
    }
  }

  /// Periodically re-fetch all live (non-archived) complete threads while the
  /// app is in the foreground.
  void _autoSync() {
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      // Defer to next app resume so we don't waste battery/data in background
      Settings.instance.addAppResumeCallback(_autoSync);
      return;
    }
    for (final record in _box.values) {
      if (record.status != DownloadStatus.complete) continue;
      if (record.isArchivedOnServer) continue;
      if (record.pendingDeletionAt != null) {
        continue; // skip pending-deletion threads
      }
      final imageboard =
          ImageboardRegistry.instance.getImageboard(record.imageboardKey);
      if (imageboard == null) continue;
      updateThread(record.identifier, imageboard.site, record.imageboardKey);
    }
  }

  // ── Public API ──────────────────────────────────────────────

  /// Start a new download. No-op if already complete or in progress.
  Future<void> downloadThread(
      ThreadIdentifier id, ImageboardSite site, String imageboardKey) async {
    final key = _key(imageboardKey, id);
    DownloadedThread? record = _box.get(key);

    if (record != null && record.status == DownloadStatus.complete) {
      return; // Already done
    }

    if (record == null) {
      record = DownloadedThread(
        imageboardKey: imageboardKey,
        board: id.board,
        threadId: id.id,
        downloadedAt: DateTime.now(),
        status: DownloadStatus.pending,
      );
      await _box.put(key, record);
    } else if (record.status == DownloadStatus.downloading ||
        record.status == DownloadStatus.updating ||
        record.status == DownloadStatus.pending) {
      return; // Already in progress
    } else {
      // failed or cancelled — retry
      record.status = DownloadStatus.pending;
      record.errorMessage = null;
      if (record.isInBox) await record.save();
    }

    _runDownload(record, site); // fire and forget
  }

  /// Re-fetch thread and download any new attachments.
  Future<void> updateThread(
      ThreadIdentifier id, ImageboardSite site, String imageboardKey) async {
    final key = _key(imageboardKey, id);
    // Guard is inside the mutex to prevent TOCTOU races
    bool shouldRun = false;
    final mutex = _mutexFor(key);
    await mutex.protect(() async {
      final record = _box.get(key);
      if (record == null || !record.isInBox) return;
      // Don't update threads that are pending soft-deletion
      if (record.pendingDeletionAt != null) return;
      if (record.status == DownloadStatus.downloading ||
          record.status == DownloadStatus.updating ||
          record.status == DownloadStatus.pending) {
        return;
      }
      record.status = DownloadStatus.updating;
      await record.save();
      shouldRun = true;
    });
    if (shouldRun) {
      final record = _box.get(key);
      if (record != null) _runDownload(record, site);
    }
  }

  /// Cancel an in-progress download. Partial files are kept for resume.
  void cancelDownload(ThreadIdentifier id, String imageboardKey) {
    final key = _key(imageboardKey, id);
    // Mark pending cancel so _runDownload sees it before CancelToken is created
    _pendingCancels.add(key);
    _cancelTokens[key]?.cancel('User cancelled');
  }

  /// Delete all local files and the DB record for a thread.
  Future<void> deleteDownload(ThreadIdentifier id, String imageboardKey) async {
    final key = _key(imageboardKey, id);
    cancelDownload(id, imageboardKey);

    final mutex = _mutexFor(key);
    await mutex.protect(() async {
      final record = _box.get(key);
      if (record == null) return;

      final dir = _threadDirFor(record);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
      await _box.delete(key);
    });
    _pendingCancels.remove(key);
    _mutexes.remove(key);
  }

  /// Current status record; null if not downloaded.
  DownloadedThread? getStatus(ThreadIdentifier id, String imageboardKey) {
    return _box.get(_key(imageboardKey, id));
  }

  /// Registers an externally-imported thread (e.g. from a KurobaEx ZIP) as a
  /// completed download. Idempotent: no-op if a complete record already exists.
  /// Returns true if a new record was created, false if it already existed.
  Future<bool> registerImportedThread({
    required String imageboardKey,
    required String board,
    required int threadId,
    String? title,
    String? thumbnailUrl,
    required DateTime downloadedAt,
    required int totalFiles,
    bool isArchivedOnServer = true,
  }) async {
    final key = _key(imageboardKey, ThreadIdentifier(board, threadId));
    final existing = _box.get(key);
    if (existing != null && existing.status == DownloadStatus.complete) {
      // Update metadata that may have changed (e.g. re-import of updated ZIP).
      bool changed = false;
      if (existing.totalFiles != totalFiles) {
        existing.totalFiles = totalFiles;
        existing.downloadedFiles = totalFiles;
        changed = true;
      }
      if (existing.isArchivedOnServer != isArchivedOnServer) {
        existing.isArchivedOnServer = isArchivedOnServer;
        changed = true;
      }
      if (changed) await existing.save();
      return false;
    }
    final localThumbnailFilename = thumbnailUrl != null
        ? Uri.tryParse(thumbnailUrl)?.pathSegments.lastOrNull
        : null;
    // Compute total size from already-extracted files.
    final threadDir =
        Directory('${_downloadsDir.path}/$imageboardKey/$board/$threadId');
    int sizeBytes = 0;
    if (threadDir.existsSync()) {
      await for (final entity in threadDir.list()) {
        if (entity is File && !entity.path.endsWith('.part')) {
          try {
            sizeBytes += entity.lengthSync();
          } catch (_) {}
        }
      }
    }
    final record = DownloadedThread(
      imageboardKey: imageboardKey,
      board: board,
      threadId: threadId,
      title: title,
      thumbnailUrl: thumbnailUrl,
      localThumbnailFilename: localThumbnailFilename,
      downloadedAt: downloadedAt,
      lastUpdatedAt: downloadedAt,
      status: DownloadStatus.complete,
      totalFiles: totalFiles,
      downloadedFiles: totalFiles,
      isArchivedOnServer: isArchivedOnServer,
      totalSizeBytes: sizeBytes > 0 ? sizeBytes : null,
    );
    await _box.put(key, record);
    return true;
  }

  /// Live stream of status changes for a specific thread.
  Stream<DownloadedThread?> watchThread(
      ThreadIdentifier id, String imageboardKey) {
    final key = _key(imageboardKey, id);
    return _box.watch(key: key).map((_) => _box.get(key));
  }

  /// All downloaded threads, most recent first.
  List<DownloadedThread> get allDownloads {
    return _box.values.toList()
      ..sort((a, b) => b.downloadedAt.compareTo(a.downloadedAt));
  }

  /// Stream of all box change events (for rebuilding the full list).
  Stream<BoxEvent> watchAllChanges() => _box.watch();

  /// Used by AttachmentCache to serve local files in gallery/thumbnails.
  /// Returns null if not downloaded or file missing.
  File? findDownloadedFile(Attachment attachment) {
    final threadId = attachment.threadId;
    if (threadId == null) return null;

    // Match by URL hostname to avoid cross-imageboard collision
    final attachmentHost = Uri.tryParse(attachment.url)?.host;

    for (final r in _box.values) {
      if (r.board != attachment.board || r.threadId != threadId) continue;
      if (r.status == DownloadStatus.cancelled ||
          r.status == DownloadStatus.failed) {
        continue;
      }
      // Skip records known to have no local files — all content is on Copyparty.
      if (r.effectiveStorageLocation == ThreadStorageLocation.remote) continue;
      // Verify imageboard matches: check against both the site base URL and the CDN
      // image URL, since some sites (e.g. 4chan) serve media from a different host
      // (i.4cdn.org) than their base URL (boards.4chan.org).
      if (attachmentHost != null) {
        final imageboard =
            ImageboardRegistry.instance.getImageboard(r.imageboardKey);
        if (imageboard == null) continue;
        final siteBaseHost = Uri.tryParse(imageboard.site.baseUrl)?.host ?? '';
        final siteImageHost = imageboard.site.imageUrl ?? '';
        if (attachmentHost != siteBaseHost && attachmentHost != siteImageHost) {
          continue;
        }
      }

      final filename = Uri.parse(attachment.url).pathSegments.lastOrNull;
      if (filename == null) continue;
      final file = _fileForName(r, filename);
      return file.existsSync() ? file : null;
    }
    return null;
  }

  /// Like [findDownloadedFile] but resolves the thumbnail file (from [Attachment.thumbnailUrl]).
  /// Used to serve local thumbnail files instead of fetching from CDN.
  File? findDownloadedThumbnailFile(Attachment attachment) {
    final threadId = attachment.threadId;
    if (threadId == null) return null;
    final thumbUrl = attachment.thumbnailUrl;
    if (thumbUrl.isEmpty) return null;
    // Re-use the same host check as findDownloadedFile — thumbnail is served from same CDN host
    final thumbHost = Uri.tryParse(thumbUrl)?.host;
    for (final r in _box.values) {
      if (r.board != attachment.board || r.threadId != threadId) continue;
      if (r.status == DownloadStatus.cancelled ||
          r.status == DownloadStatus.failed) {
        continue;
      }
      // Skip records known to have no local files — all content is on Copyparty.
      if (r.effectiveStorageLocation == ThreadStorageLocation.remote) continue;
      if (thumbHost != null) {
        final imageboard =
            ImageboardRegistry.instance.getImageboard(r.imageboardKey);
        if (imageboard == null) continue;
        final siteBaseHost = Uri.tryParse(imageboard.site.baseUrl)?.host ?? '';
        final siteImageHost = imageboard.site.imageUrl ?? '';
        if (thumbHost != siteBaseHost && thumbHost != siteImageHost) continue;
      }
      final filename = Uri.tryParse(thumbUrl)?.pathSegments.lastOrNull;
      if (filename == null) continue;
      final file = _fileForName(r, filename);
      return file.existsSync() ? file : null;
    }
    return null;
  }

  /// Returns a CopyParty download URI for the attachment if CopyParty is enabled
  /// and a matching completed download exists. Auth is provided via the `Pw:` request header.
  /// Returns a CopyParty download URI for [attachment].
  /// Pass [urlForFilename] to look up by a specific URL (e.g. thumbnail URL)
  /// instead of the full attachment URL.
  Future<Uri?> copypartySourceUri(Attachment attachment,
      {String? urlForFilename}) async {
    if (!Persistence.settings.copypartyEnabled) return null;
    final serverUrl = Persistence.settings.copypartyServerUrl;
    if (serverUrl.isEmpty) return null;
    final destRoot = Persistence.settings.copypartyDestRoot;
    final base = serverUrl.endsWith('/')
        ? serverUrl.substring(0, serverUrl.length - 1)
        : serverUrl;
    final baseRoot = destRoot.endsWith('/')
        ? destRoot.substring(0, destRoot.length - 1)
        : destRoot;

    final threadId = attachment.threadId;
    if (threadId == null) return null;
    final targetUrl = urlForFilename ?? attachment.url;
    final attachmentHost = Uri.tryParse(targetUrl)?.host;

    for (final r in _box.values) {
      if (r.board != attachment.board || r.threadId != threadId) continue;
      if (r.status != DownloadStatus.complete) continue;
      // Skip records known to have no files on Copyparty — all content is local.
      if (r.effectiveStorageLocation == ThreadStorageLocation.local) continue;
      if (attachmentHost != null) {
        final imageboard =
            ImageboardRegistry.instance.getImageboard(r.imageboardKey);
        if (imageboard == null) continue;
        final siteBaseHost = Uri.tryParse(imageboard.site.baseUrl)?.host ?? '';
        final siteImageHost = imageboard.site.imageUrl ?? '';
        if (attachmentHost != siteBaseHost && attachmentHost != siteImageHost) {
          continue;
        }
      }
      final filename = Uri.tryParse(targetUrl)?.pathSegments.lastOrNull;
      if (filename == null) return null;
      return Uri.parse(
          '$base$baseRoot/${r.imageboardKey}/${r.board}/${r.threadId}/$filename');
    }
    return null;
  }

  /// Cancel an in-progress migration started by [migrateLocalFilesToCopyparty].
  void cancelMigration() => _migrationCancelled = true;

  /// Starts a background CopyParty upload for [records].
  /// - Resets each record's [syncedFiles] to 0 so progress always starts from 0.
  /// - If a migration is already running, queues records to run immediately after.
  /// - Duplicate keys (already active or already queued) are skipped.
  Future<void> startBackgroundMigration(List<DownloadedThread> records) async {
    // Skip records already tracked (active or queued).
    final current = activeMigrations.value;
    final newRecords = records.where((r) {
      if (current.contains(r.boxKey)) return false;
      if (_migrationQueue.any((q) => q.boxKey == r.boxKey)) return false;
      return true;
    }).toList();
    if (newRecords.isEmpty) return;

    // Reset progress counter so the bar starts at 0 regardless of past runs.
    // Skip the reset if _runDownload is actively in progress for this record
    // to avoid clobbering syncedFiles it is currently incrementing (E3).
    for (final r in newRecords) {
      if (r.status == DownloadStatus.downloading ||
          r.status == DownloadStatus.updating) {
        continue;
      }
      r.syncedFiles = 0;
      if (r.isInBox) await r.save();
    }

    if (_migrationRunning) {
      // Already busy — queue and show spinner so the row gives immediate feedback.
      _migrationQueue.addAll(newRecords);
      activeMigrations.value = {...current, ...newRecords.map((r) => r.boxKey)};
      return;
    }
    await _runMigrationBatch(newRecords);
  }

  /// Runs a foreground (user-initiated) migration for [records] with full state
  /// management: deduplicates against the background queue, resets progress
  /// counters, updates [activeMigrations] so rows show the syncing indicator,
  /// and sets [_migrationRunTotals] for accurate progress bars.
  /// Use this instead of calling [migrateLocalFilesToCopyparty] directly so
  /// the row UI stays in sync (L1 fix).
  Stream<MigrationProgress> runForegroundMigration(
      List<DownloadedThread> records) async* {
    // Remove from background queue — these will be handled by this foreground run.
    _migrationQueue
        .removeWhere((r) => records.any((req) => req.boxKey == r.boxKey));

    // Skip records already being migrated by the background batch to prevent
    // concurrent uploads and syncedFiles double-increments (F3).
    final runRecords = records
        .where((r) => !activeMigrations.value.contains(r.boxKey))
        .toList();
    if (runRecords.isEmpty) {
      // Nothing to run — all records are handled by the background batch.
      // Yield a terminal event so the dialog can show "Done" instead of
      // getting stuck with a spinner (N1).
      yield const MigrationProgress(
        totalFiles: 0,
        processedFiles: 0,
        uploadedFiles: 0,
        isDone: true,
      );
      return;
    }

    // Reset progress counters (same logic as startBackgroundMigration).
    for (final r in runRecords) {
      if (r.status == DownloadStatus.downloading ||
          r.status == DownloadStatus.updating) {
        continue;
      }
      r.syncedFiles = 0;
      if (r.isInBox) await r.save();
    }

    // Count local files for accurate progress denominator.
    final keys = runRecords.map((r) => r.boxKey).toSet();
    for (final r in runRecords) {
      final dir = _threadDirFor(r);
      int count = 0;
      if (dir.existsSync()) {
        await for (final entity in dir.list()) {
          if (entity is File && !entity.path.endsWith('.part')) count++;
        }
      }
      _migrationRunTotals[r.boxKey] = count;
    }

    activeMigrations.value = {...activeMigrations.value, ...keys};
    try {
      await for (final progress
          in migrateLocalFilesToCopyparty(only: runRecords)) {
        yield progress;
      }
    } finally {
      for (final key in keys) {
        _migrationRunTotals.remove(key);
      }
      activeMigrations.value = activeMigrations.value.difference(keys);
    }
  }

  Future<void> _runMigrationBatch(List<DownloadedThread> records) async {
    _migrationRunning = true;
    final keys = records.map((r) => r.boxKey).toSet();
    activeMigrations.value = {...activeMigrations.value, ...keys};

    // Count actual local files per record so the progress bar denominator is
    // accurate and always starts from 0/N instead of jumping to 100%.
    for (final r in records) {
      final dir = _threadDirFor(r);
      int count = 0;
      if (dir.existsSync()) {
        await for (final entity in dir.list()) {
          if (entity is File && !entity.path.endsWith('.part')) count++;
        }
      }
      _migrationRunTotals[r.boxKey] = count;
    }

    try {
      await for (final _ in migrateLocalFilesToCopyparty(only: records)) {
        // per-record syncedFiles++ + save happens inside the stream;
        // Hive watch on the page triggers row rebuilds automatically.
      }
    } finally {
      for (final key in keys) {
        _migrationRunTotals.remove(key);
      }
      activeMigrations.value = activeMigrations.value.difference(keys);

      // Keep _migrationRunning=true until the queue is fully drained so a
      // concurrent startBackgroundMigration can't launch a second batch in
      // the window between cleanup and the recursive call (L1).
      if (_migrationQueue.isNotEmpty) {
        final next = List<DownloadedThread>.from(_migrationQueue);
        _migrationQueue.clear();
        await _runMigrationBatch(next);
      } else {
        _migrationRunning = false;
      }
    }
  }

  /// Scans all [complete] thread directories for local files and uploads each to
  /// CopyParty, deleting the local copy only after a confirmed [CopyPartySyncResult.ok].
  /// Any auth or server failure stops the migration immediately — unprocessed files
  /// remain on disk. Yields [MigrationProgress] snapshots throughout.
  Stream<MigrationProgress> migrateLocalFilesToCopyparty(
      {List<DownloadedThread>? only}) async* {
    _migrationCancelled = false;

    final serverUrl = Persistence.settings.copypartyServerUrl;
    final destRoot = Persistence.settings.copypartyDestRoot;
    print(
        '[CopyParty] migrateLocalFilesToCopyparty: serverUrl=$serverUrl destRoot=$destRoot');
    if (serverUrl.isEmpty) {
      print(
          '[CopyParty] migrateLocalFilesToCopyparty: serverUrl is empty, aborting');
      yield const MigrationProgress(
          totalFiles: 0,
          processedFiles: 0,
          uploadedFiles: 0,
          error: 'Server URL not configured',
          isDone: true);
      return;
    }

    final password = await storage.read(key: 'copypartyPassword') ?? '';
    print(
        '[CopyParty] migrateLocalFilesToCopyparty: password=${password.isNotEmpty ? 'set' : 'empty'}');
    final base = serverUrl.endsWith('/')
        ? serverUrl.substring(0, serverUrl.length - 1)
        : serverUrl;
    final baseRoot = destRoot.endsWith('/')
        ? destRoot.substring(0, destRoot.length - 1)
        : destRoot;

    // Phase 1: discover all eligible local files across complete thread dirs.
    final completeRecords = (only ?? _box.values)
        .where((r) =>
            r.status == DownloadStatus.complete &&
            r.storagePreference != ThreadStoragePreference.localOnly)
        .toList();
    final filesToUpload =
        <({File file, String remotePath, DownloadedThread record})>[];
    for (final record in completeRecords) {
      final dir = _threadDirFor(record);
      if (!dir.existsSync()) continue;
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (name.endsWith('.part')) continue;
        // Guard against path traversal in the remotePath sent to the server
        if (record.imageboardKey.contains('..') ||
            record.board.contains('..') ||
            name.contains('..') ||
            name.contains('/') ||
            name.contains('\\')) {
          continue;
        }
        final remotePath =
            '$baseRoot/${record.imageboardKey}/${record.board}/${record.threadId}/$name';
        filesToUpload
            .add((file: entity, remotePath: remotePath, record: record));
      }
    }

    final total = filesToUpload.length;
    print(
        '[CopyParty] migrateLocalFilesToCopyparty: Phase 1 found $total files to upload');
    yield MigrationProgress(
        totalFiles: total, processedFiles: 0, uploadedFiles: 0);

    // Phase 2: upload one-by-one; delete only after confirmed ok.
    int processed = 0;
    int uploaded = 0;
    final Set<DownloadedThread> touchedRecords = {};
    // Tracks bytes uploaded this run per record so totalSizeBytes stays accurate
    // for remoteOnly threads where local files are deleted after upload.
    final Map<DownloadedThread, int> uploadedSizePerRecord = {};

    // Saves syncedFiles/lastSyncedAt/storageLocation/totalSizeBytes for all
    // touched records. storageLocation is derived from actual remaining local files.
    Future<void> flushTouched() async {
      final now = DateTime.now();
      for (final r in touchedRecords) {
        r.lastSyncedAt = now;
        // Determine storage location: check if any local files remain.
        final dir = _threadDirFor(r);
        bool hasLocalFiles = false;
        if (dir.existsSync()) {
          await for (final entity in dir.list()) {
            if (entity is File && !entity.path.endsWith('.part')) {
              hasLocalFiles = true;
              break;
            }
          }
        }
        if (r.storagePreference == ThreadStoragePreference.both) {
          // Files intentionally kept locally — always mixed if synced.
          r.storageLocation = r.syncedFiles > 0
              ? ThreadStorageLocation.mixed
              : ThreadStorageLocation.local;
        } else if (!hasLocalFiles && r.syncedFiles > 0) {
          r.storageLocation = ThreadStorageLocation.remote;
          // Update totalSizeBytes from bytes uploaded this run so the size
          // display stays accurate now that local files have been deleted.
          final accumulated = uploadedSizePerRecord[r] ?? 0;
          if (accumulated > 0) {
            r.totalSizeBytes = (r.totalSizeBytes ?? 0) + accumulated;
          }
        } else if (hasLocalFiles && r.syncedFiles > 0) {
          r.storageLocation = ThreadStorageLocation.mixed;
        }
        if (r.isInBox) await r.save();
      }
    }

    for (final entry in filesToUpload) {
      if (_migrationCancelled) break;
      // Re-check: if record left complete state since Phase 1 (e.g. download started), skip safely
      if (entry.record.status != DownloadStatus.complete) continue;
      // Re-check: storagePreference may have been changed to localOnly since the
      // Phase 1 snapshot. Never delete files for a record that now explicitly wants
      // local storage (F1 — prevents migration continuing after pref change mid-run).
      if (entry.record.storagePreference == ThreadStoragePreference.localOnly) {
        processed++;
        yield MigrationProgress(
            totalFiles: total,
            processedFiles: processed,
            uploadedFiles: uploaded);
        continue;
      }
      // File may have been deleted by concurrent _runDownload since Phase 1 snapshot — skip safely
      if (!entry.file.existsSync()) {
        processed++;
        yield MigrationProgress(
            totalFiles: total,
            processedFiles: processed,
            uploadedFiles: uploaded);
        continue;
      }
      CopyPartySyncResult result;
      try {
        // Skip upload if the file is already present on CopyParty.
        // This prevents duplicates when the preference is 'both' (local files
        // are kept after upload, so a second migration run would re-upload them).
        final alreadyExists = await CopyPartySyncService.instance.fileExists(
          remoteRelativePath: entry.remotePath,
          serverUrl: serverUrl,
          password: password,
        );
        if (alreadyExists) {
          print(
              '[CopyParty] migrateLocalFilesToCopyparty: already exists, skipping ${entry.remotePath}');
          // Delete the local copy only for remoteOnly / follow-global preferences.
          // Never delete for 'both' (keep-local) or 'localOnly' (guarded above, but
          // defence-in-depth for any code path that reaches here — F1).
          if (entry.record.storagePreference != ThreadStoragePreference.both &&
              entry.record.storagePreference !=
                  ThreadStoragePreference.localOnly) {
            // Capture size before deletion so totalSizeBytes stays accurate (E3).
            try {
              final fileSize =
                  entry.file.existsSync() ? entry.file.lengthSync() : 0;
              if (fileSize > 0) {
                uploadedSizePerRecord[entry.record] =
                    (uploadedSizePerRecord[entry.record] ?? 0) + fileSize;
              }
            } catch (_) {}
            try {
              await entry.file.delete();
            } catch (_) {}
          }
          processed++;
          entry.record.syncedFiles++;
          touchedRecords.add(entry.record);
          uploaded++;
          if (entry.record.isInBox) await entry.record.save();
          yield MigrationProgress(
              totalFiles: total,
              processedFiles: processed,
              uploadedFiles: uploaded);
          continue;
        }
        print(
            '[CopyParty] migrateLocalFilesToCopyparty: uploading ${entry.remotePath}');
        result = await CopyPartySyncService.instance.putFile(
          file: entry.file,
          remoteRelativePath: entry.remotePath,
          serverUrl: serverUrl,
          password: password,
        );
      } catch (e) {
        try {
          await flushTouched();
        } catch (_) {}
        yield MigrationProgress(
            totalFiles: total,
            processedFiles: processed,
            uploadedFiles: uploaded,
            error:
                'Unexpected error: $e — migration stopped, remaining files are safe',
            isDone: true);
        return;
      }
      processed++;
      if (result == CopyPartySyncResult.ok) {
        // Capture size before deletion so totalSizeBytes stays accurate
        // for remoteOnly threads where the local file is about to be removed.
        try {
          final fileSize =
              entry.file.existsSync() ? entry.file.lengthSync() : 0;
          if (fileSize > 0) {
            uploadedSizePerRecord[entry.record] =
                (uploadedSizePerRecord[entry.record] ?? 0) + fileSize;
          }
        } catch (_) {}
        // Delete local file only for remoteOnly / follow-global preferences.
        // Never delete for 'both' (keep-local) or 'localOnly' (preference may have
        // changed mid-run — guarded by the loop re-check above, but defence-in-depth
        // for any race that slips through — F1).
        if (entry.record.storagePreference != ThreadStoragePreference.both &&
            entry.record.storagePreference !=
                ThreadStoragePreference.localOnly) {
          try {
            await entry.file.delete();
          } catch (_) {}
        }
        entry.record.syncedFiles++;
        touchedRecords.add(entry.record);
        if (entry.record.isInBox) await entry.record.save();
        uploaded++;
        yield MigrationProgress(
            totalFiles: total,
            processedFiles: processed,
            uploadedFiles: uploaded);
      } else if (result == CopyPartySyncResult.authFailed) {
        try {
          await flushTouched();
        } catch (_) {}
        yield MigrationProgress(
            totalFiles: total,
            processedFiles: processed,
            uploadedFiles: uploaded,
            error: 'Authentication failed — check password in settings',
            isDone: true);
        return;
      } else {
        // serverError or networkError — stop, leave remaining files safe
        try {
          await flushTouched();
        } catch (_) {}
        yield MigrationProgress(
            totalFiles: total,
            processedFiles: processed,
            uploadedFiles: uploaded,
            error:
                'Server unreachable or returned an error — migration stopped, remaining files are safe',
            isDone: true);
        return;
      }
    }

    try {
      await flushTouched();
    } catch (_) {}
    yield MigrationProgress(
        totalFiles: total,
        processedFiles: processed,
        uploadedFiles: uploaded,
        isDone: true);
  }

  /// Returns the local thumbnail file for a DownloadedThread record (for list UI).
  File? findLocalThumbnail(DownloadedThread record) {
    final filename = record.localThumbnailFilename;
    if (filename == null) return null;
    final file = _fileForName(record, filename);
    return file.existsSync() ? file : null;
  }

  /// Computes the total size of all local files in a thread's download directory.
  /// Returns 0 if the directory does not exist or has no files.
  Future<int> computeThreadDirSize(DownloadedThread record) async {
    final dir = _threadDirFor(record);
    if (!dir.existsSync()) return 0;
    int total = 0;
    await for (final entity in dir.list()) {
      if (entity is File && !entity.path.endsWith('.part')) {
        try {
          total += await entity.length();
        } catch (_) {}
      }
    }
    return total;
  }

  /// Constructs a CopyParty URL for the OP thumbnail of a downloaded thread record.
  /// Returns null if CopyParty is not configured, password is missing, or no thumbnail filename is stored.
  Future<Uri?> copypartyThumbnailUri(DownloadedThread record) async {
    if (!Persistence.settings.copypartyEnabled) return null;
    final serverUrl = Persistence.settings.copypartyServerUrl;
    if (serverUrl.isEmpty) return null;
    final filename = record.localThumbnailFilename;
    if (filename == null) return null;
    final destRoot = Persistence.settings.copypartyDestRoot;
    final base = serverUrl.endsWith('/')
        ? serverUrl.substring(0, serverUrl.length - 1)
        : serverUrl;
    final baseRoot = destRoot.endsWith('/')
        ? destRoot.substring(0, destRoot.length - 1)
        : destRoot;
    return Uri.parse(
        '$base$baseRoot/${record.imageboardKey}/${record.board}/${record.threadId}/$filename');
  }

  /// Returns the stored CopyParty password, or null/empty if not set.
  Future<String?> getCopypartyPassword() async =>
      storage.read(key: 'copypartyPassword');

  /// Scan the downloads directory and create records for any folders not yet known.
  /// Used to import downloads from Kuroba or other sources after a manual folder copy.
  Future<ImportScanResult> scanDownloadsDirectory() async {
    int found = 0;
    int skipped = 0;

    if (!_downloadsDir.existsSync()) return ImportScanResult(found, skipped);

    // Use async listing (E3) to avoid blocking the event loop on slow storage
    await for (final ibEntry in _downloadsDir.list()) {
      if (ibEntry is! Directory) continue;
      final imageboardKey = ibEntry.path.split(RegExp(r'[/\\]')).last;
      if (ImageboardRegistry.instance.getImageboard(imageboardKey) == null) {
        continue;
      }

      await for (final boardEntry in ibEntry.list()) {
        if (boardEntry is! Directory) continue;
        final board = boardEntry.path.split(RegExp(r'[/\\]')).last;

        await for (final threadEntry in boardEntry.list()) {
          if (threadEntry is! Directory) continue;
          final threadIdStr = threadEntry.path.split(RegExp(r'[/\\]')).last;
          final threadId = int.tryParse(threadIdStr);
          if (threadId == null) continue;

          final key = _key(imageboardKey, ThreadIdentifier(board, threadId));
          if (_box.containsKey(key)) {
            skipped++;
            continue;
          }

          // Async file listing (E3)
          final files = <File>[];
          await for (final f in threadEntry.list()) {
            if (f is File && !f.path.endsWith('.part')) files.add(f);
          }

          // E4: skip empty/corrupt directories
          if (files.isEmpty) {
            skipped++;
            continue;
          }

          // Try to get title/thumbnail from in-memory thread cache (no disk IO)
          String? title;
          String? thumbnailUrl;
          String? localThumbFilename;
          if (Persistence.isThreadCached(imageboardKey, board, threadId)) {
            final thread = await Persistence.getCachedThread(
                imageboardKey, board, threadId);
            final op = thread?.posts_.firstOrNull;
            final rawTitle = thread?.title ?? op?.text.trim();
            title = rawTitle != null && rawTitle.length > 100
                ? rawTitle.substring(0, 100)
                : rawTitle;
            thumbnailUrl = op?.attachments_.firstOrNull?.thumbnailUrl;
            localThumbFilename = thumbnailUrl != null
                ? Uri.tryParse(thumbnailUrl)?.pathSegments.lastOrNull
                : null;
          }

          DateTime downloadedAt;
          try {
            downloadedAt = threadEntry.statSync().modified;
          } catch (_) {
            downloadedAt = DateTime.now();
          }

          final record = DownloadedThread(
            imageboardKey: imageboardKey,
            board: board,
            threadId: threadId,
            title: title,
            thumbnailUrl: thumbnailUrl,
            localThumbnailFilename: localThumbFilename,
            downloadedAt: downloadedAt,
            status: DownloadStatus.complete,
            totalFiles: files.length,
            downloadedFiles: files.length,
            storageLocation: ThreadStorageLocation.local,
            totalSizeBytes: files.fold<int>(
                0, (sum, f) => sum + (f.existsSync() ? f.lengthSync() : 0)),
          );
          await _box.put(key, record);
          found++;
        }
      }
    }
    return ImportScanResult(found, skipped);
  }

  void dispose() {
    _threadStateSubscription?.cancel();
  }

  // ── Internal ────────────────────────────────────────────────

  String _key(String imageboardKey, ThreadIdentifier id) =>
      '${imageboardKey}_${id.board}_${id.id}';

  Mutex _mutexFor(String key) => _mutexes.putIfAbsent(key, Mutex.new);

  Directory _threadDirFor(DownloadedThread record) => Directory(
      '${_downloadsDir.path}/${record.imageboardKey}/${record.board}/${record.threadId}');

  /// Public accessor for the local directory of a downloaded/imported thread.
  Directory getThreadDir(DownloadedThread record) => _threadDirFor(record);

  File _fileForName(DownloadedThread record, String filename) =>
      File('${_threadDirFor(record).path}/$filename');

  /// Try to populate [dest] by copying from an in-app cache (extended_image or
  /// VideoServer). Returns true if [dest] was successfully written so that the
  /// caller can skip the network download.
  ///
  /// Videos are looked up in VideoServer (which stores the original format).
  /// Images/thumbnails are looked up in the extended_image disk cache.
  /// On any error (file evicted between check and copy, I/O error, etc.) the
  /// method returns false so the caller falls back to `_downloadFile`.
  Future<bool> _tryCopyFromCache(String url, File dest) async {
    try {
      final uri = Uri.tryParse(url);
      if (uri == null) return false;

      File? source;

      // VideoServer caches mp4/webm/mp3 in original format
      final vsFile = VideoServer.instance.optimisticallyGetFile(uri);
      if (vsFile != null && vsFile.existsSync()) {
        source = vsFile;
      }

      // extended_image caches images (and is a fallback for anything else)
      source ??= await getCachedImageFile(url);

      if (source != null && source.existsSync()) {
        await source.copy(dest.path);
        return dest.existsSync();
      }
    } catch (_) {
      // Race: file evicted or I/O error — fall through to network download
    }
    return false;
  }

  Future<void> _runDownload(
      DownloadedThread record, ImageboardSite site) async {
    final key = record.boxKey;
    final mutex = _mutexFor(key);

    await mutex.protect(() async {
      // Check pending cancel set — user cancelled before we got the lock
      if (_pendingCancels.contains(key)) {
        _pendingCancels.remove(key);
        if (record.isInBox) {
          record.status = DownloadStatus.cancelled;
          record.errorMessage = null;
          await record.save();
        }
        return;
      }

      // Guard: another operation may have completed before we got the lock
      if (!record.isInBox || record.status == DownloadStatus.complete) return;

      // Track whether this is a re-download of a previously complete thread
      // (status = updating) vs. an initial download. Used later to decide
      // whether a transient network error should reset back to complete.
      final wasUpdating = record.status == DownloadStatus.updating;

      print(
          '[ThreadDownloader] START: ${record.boxKey} status=${record.status}');
      final cancelToken = CancelToken();
      _cancelTokens[key] = cancelToken;

      try {
        // 1. Fetch full thread
        final thread = await site.getThread(
          record.identifier,
          priority: RequestPriority.lowest,
          cancelToken: cancelToken,
        );

        // 1b. Persist thread data so offline viewer can display it without network
        await Persistence.setCachedThread(
            record.imageboardKey, record.board, record.threadId, thread);

        // 2. Update metadata from thread
        final opPost = thread.posts_.firstOrNull;
        final rawTitle = thread.title ?? opPost?.text.trim();
        record.title = rawTitle != null && rawTitle.length > 100
            ? rawTitle.substring(0, 100)
            : rawTitle;
        record.thumbnailUrl = opPost?.attachments_.firstOrNull?.thumbnailUrl;

        // 3. Collect all attachments
        final attachments = thread.posts_
            .expand((p) => p.attachments_)
            .where((a) => !a.type.isNonMedia)
            .toList();

        // Count only slots with parseable filenames so totalFiles is accurate.
        // Pre-count already-present files so the progress bar starts correctly on retries/updates.
        int totalSlots = 0;
        int alreadyDone = 0;
        for (final a in attachments) {
          final mf = Uri.tryParse(a.url)?.pathSegments.lastOrNull;
          if (mf != null) {
            totalSlots++;
            if (_fileForName(record, mf).existsSync()) alreadyDone++;
          }
          final tf = Uri.tryParse(a.thumbnailUrl)?.pathSegments.lastOrNull;
          if (tf != null) {
            totalSlots++;
            if (_fileForName(record, tf).existsSync()) alreadyDone++;
          }
        }
        record.status = DownloadStatus.downloading;
        record.totalFiles = totalSlots;
        record.downloadedFiles = alreadyDone;
        if (record.isInBox) await record.save();

        // 4. Ensure directory exists
        final threadDir = _threadDirFor(record);
        await threadDir.create(recursive: true);

        // 5. Download each attachment + thumbnail
        final copypartyEnabled = Persistence.settings.copypartyEnabled;
        // Effective upload decision: per-thread preference overrides global autoUpload setting.
        final pref = record.storagePreference;
        final shouldUpload = copypartyEnabled &&
            (pref == ThreadStoragePreference.remoteOnly ||
                pref == ThreadStoragePreference.both ||
                (pref == null && Persistence.settings.copypartyAutoUpload));
        final shouldDeleteAfterUpload = pref != ThreadStoragePreference.both;
        // Always reset sync counter so it accurately reflects uploads done in
        // THIS run. Without this, stale syncedFiles from a previous remoteOnly
        // run can cause _runDownload to set storageLocation = remote at the end
        // even when nothing was uploaded (e.g. after switching to localOnly).
        record.syncedFiles = 0;
        final serverUrl = Persistence.settings.copypartyServerUrl;
        final destRoot = Persistence.settings.copypartyDestRoot;
        final password = copypartyEnabled
            ? (await storage.read(key: 'copypartyPassword') ?? '')
            : '';
        final baseDestRoot = destRoot.endsWith('/')
            ? destRoot.substring(0, destRoot.length - 1)
            : destRoot;

        bool copypartyAuthFailed = false;
        bool copypartyServerFailed = false;
        int saveCount = 0;
        int newSizeBytes = 0;

        for (final attachment in attachments) {
          if (cancelToken.isCancelled) break;

          // Main file
          final mainFilename =
              Uri.tryParse(attachment.url)?.pathSegments.lastOrNull;
          if (mainFilename != null) {
            final mainFile = _fileForName(record, mainFilename);
            final mainPreExisted = mainFile.existsSync();
            bool mainOk = mainPreExisted;
            // HEAD check for all shouldUpload threads:
            // - remoteOnly (shouldDeleteAfterUpload=true): skip download + upload
            //   if already on server — no local copy needed.
            // - 'both' (shouldDeleteAfterUpload=false): skip the re-upload only;
            //   still download to ensure a local copy exists.
            bool mainAlreadyOnServer = false;
            if (!mainOk &&
                shouldUpload &&
                serverUrl.isNotEmpty &&
                !copypartyAuthFailed &&
                !copypartyServerFailed &&
                !mainFilename.contains('..') &&
                !mainFilename.contains('/') &&
                !mainFilename.contains('\\') &&
                !record.imageboardKey.contains('..') &&
                !record.board.contains('..')) {
              final remoteCheckPath =
                  '$baseDestRoot/${record.imageboardKey}/${record.board}/${record.threadId}/$mainFilename';
              mainAlreadyOnServer =
                  await CopyPartySyncService.instance.fileExists(
                remoteRelativePath: remoteCheckPath,
                serverUrl: serverUrl,
                password: password,
              );
            }
            // For remoteOnly: skip download when already on server (no local copy needed).
            // For 'both': always download even if on server, to get the local copy.
            if (!mainOk && !(mainAlreadyOnServer && shouldDeleteAfterUpload)) {
              try {
                final cached =
                    await _tryCopyFromCache(attachment.url, mainFile);
                if (!cached) {
                  await _downloadFile(
                      attachment.url, mainFile, cancelToken, site);
                }
                mainOk = mainFile.existsSync();
              } on DioError catch (e) {
                if (e.type == DioErrorType.cancel) rethrow;
                final status = e.response?.statusCode ?? 0;
                if (status >= 400) {
                  print(
                      '[ThreadDownloader] SKIP main 404: ${attachment.url} ($status)');
                } else {
                  rethrow;
                }
              }
            }
            if (!mainPreExisted && mainOk) {
              record.downloadedFiles++;
              saveCount++;
              if (saveCount % 10 == 0 && record.isInBox) await record.save();
            }
            // Accumulate size for newly downloaded files (before potential Copyparty deletion).
            if (!mainPreExisted && mainOk) {
              try {
                newSizeBytes += mainFile.lengthSync();
              } catch (_) {}
            }

            if ((mainOk || mainAlreadyOnServer) &&
                shouldUpload &&
                serverUrl.isNotEmpty &&
                !copypartyAuthFailed &&
                !copypartyServerFailed &&
                !mainFilename.contains('..') &&
                !mainFilename.contains('/') &&
                !mainFilename.contains('\\') &&
                !record.imageboardKey.contains('..') &&
                !record.board.contains('..')) {
              final remotePath =
                  '$baseDestRoot/${record.imageboardKey}/${record.board}/${record.threadId}/$mainFilename';
              // For 'both' preference, file is kept locally after upload. On
              // subsequent update runs the file pre-exists locally. Skip the
              // upload (and the existence HEAD check) if this is a pre-existing
              // file that we would keep anyway — it's already on the server.
              // Also skip if the HEAD check above confirmed the file is already
              // on the server (remoteOnly thread on a subsequent update run).
              final skipUpload = (mainPreExisted && !shouldDeleteAfterUpload) ||
                  mainAlreadyOnServer;
              if (skipUpload) {
                // Already uploaded in a previous run; count it without re-uploading.
                record.syncedFiles++;
                if (record.isInBox) await record.save();
              } else {
                final result = await CopyPartySyncService.instance.putFile(
                  file: mainFile,
                  remoteRelativePath: remotePath,
                  serverUrl: serverUrl,
                  password: password,
                );
                if (result == CopyPartySyncResult.ok) {
                  record.syncedFiles++;
                  // Re-read pref: user may have changed to localOnly/both mid-run (F1).
                  final livePref = record.storagePreference;
                  if (livePref != ThreadStoragePreference.both &&
                      livePref != ThreadStoragePreference.localOnly) {
                    try {
                      await mainFile.delete();
                    } catch (_) {}
                  }
                  if (record.isInBox) await record.save();
                } else if (result == CopyPartySyncResult.authFailed) {
                  copypartyAuthFailed = true;
                  record.errorMessage =
                      'CopyParty: auth failed — check password in settings';
                } else {
                  copypartyServerFailed = true;
                  record.errorMessage ??=
                      'CopyParty sync incomplete — server unreachable or error';
                }
              }
            }
          }

          if (cancelToken.isCancelled) break;

          // Thumbnail
          final thumbFilename =
              Uri.tryParse(attachment.thumbnailUrl)?.pathSegments.lastOrNull;
          if (thumbFilename != null) {
            final thumbFile = _fileForName(record, thumbFilename);
            final thumbPreExisted = thumbFile.existsSync();
            bool thumbOk = thumbPreExisted;
            // Same HEAD check as main file — covers both remoteOnly and 'both'.
            bool thumbAlreadyOnServer = false;
            if (!thumbOk &&
                shouldUpload &&
                serverUrl.isNotEmpty &&
                !copypartyAuthFailed &&
                !copypartyServerFailed &&
                !thumbFilename.contains('..') &&
                !thumbFilename.contains('/') &&
                !thumbFilename.contains('\\') &&
                !record.imageboardKey.contains('..') &&
                !record.board.contains('..')) {
              final remoteCheckPath =
                  '$baseDestRoot/${record.imageboardKey}/${record.board}/${record.threadId}/$thumbFilename';
              thumbAlreadyOnServer =
                  await CopyPartySyncService.instance.fileExists(
                remoteRelativePath: remoteCheckPath,
                serverUrl: serverUrl,
                password: password,
              );
            }
            if (!thumbOk &&
                !(thumbAlreadyOnServer && shouldDeleteAfterUpload)) {
              try {
                final cached =
                    await _tryCopyFromCache(attachment.thumbnailUrl, thumbFile);
                if (!cached) {
                  await _downloadFile(
                      attachment.thumbnailUrl, thumbFile, cancelToken, site);
                }
                thumbOk = thumbFile.existsSync();
              } on DioError catch (e) {
                if (e.type == DioErrorType.cancel) rethrow;
                final status = e.response?.statusCode ?? 0;
                if (status >= 400) {
                  print(
                      '[ThreadDownloader] SKIP thumb 404: ${attachment.thumbnailUrl} ($status)');
                } else {
                  rethrow;
                }
              }
            }
            if (!thumbPreExisted && thumbOk) {
              record.downloadedFiles++;
              // Store first OP thumbnail filename for the list UI
              record.localThumbnailFilename ??= thumbFilename;
              saveCount++;
              if (saveCount % 10 == 0 && record.isInBox) await record.save();
            }
            // Accumulate size for newly downloaded thumbnails (before potential Copyparty deletion).
            if (!thumbPreExisted && thumbOk) {
              try {
                newSizeBytes += thumbFile.lengthSync();
              } catch (_) {}
            }

            if ((thumbOk || thumbAlreadyOnServer) &&
                shouldUpload &&
                serverUrl.isNotEmpty &&
                !copypartyAuthFailed &&
                !copypartyServerFailed &&
                !thumbFilename.contains('..') &&
                !thumbFilename.contains('/') &&
                !thumbFilename.contains('\\') &&
                !record.imageboardKey.contains('..') &&
                !record.board.contains('..')) {
              final remotePath =
                  '$baseDestRoot/${record.imageboardKey}/${record.board}/${record.threadId}/$thumbFilename';
              final skipUpload =
                  (thumbPreExisted && !shouldDeleteAfterUpload) ||
                      thumbAlreadyOnServer;
              if (skipUpload) {
                record.syncedFiles++;
                if (record.isInBox) await record.save();
              } else {
                final result = await CopyPartySyncService.instance.putFile(
                  file: thumbFile,
                  remoteRelativePath: remotePath,
                  serverUrl: serverUrl,
                  password: password,
                );
                if (result == CopyPartySyncResult.ok) {
                  record.syncedFiles++;
                  // Re-read pref: user may have changed to localOnly/both mid-run (F1).
                  final livePrefThumb = record.storagePreference;
                  if (livePrefThumb != ThreadStoragePreference.both &&
                      livePrefThumb != ThreadStoragePreference.localOnly) {
                    try {
                      await thumbFile.delete();
                    } catch (_) {}
                  }
                  if (record.isInBox) await record.save();
                } else if (result == CopyPartySyncResult.authFailed) {
                  copypartyAuthFailed = true;
                  record.errorMessage =
                      'CopyParty: auth failed — check password in settings';
                } else {
                  copypartyServerFailed = true;
                  record.errorMessage ??=
                      'CopyParty sync incomplete — server unreachable or error';
                }
              }
            }
          }

          // Throttle: optional inter-file delay to avoid CDN rate-limiting.
          // Use try/catch to guard against null during hot-reload (field may be
          // uninitialised in the in-memory instance when the field was just added).
          int delayMs;
          try {
            delayMs = Persistence.settings.downloadInterFileDelayMs;
          } on TypeError {
            delayMs = 0;
          }
          if (!cancelToken.isCancelled && delayMs > 0) {
            await Future.delayed(Duration(milliseconds: delayMs));
          }
        }

        if (!cancelToken.isCancelled) {
          record.status = DownloadStatus.complete;
          record.lastUpdatedAt = DateTime.now();
          print(
              '[ThreadDownloader] COMPLETE: ${record.boxKey} downloaded=${record.downloadedFiles}/${record.totalFiles}');
          // Re-read pref: user may have changed preference mid-run (F1).
          final finalPref = record.storagePreference;
          // Delete CopyParty folder for localOnly threads regardless of
          // copypartyEnabled guard — the guard is for upload decisions, not
          // for deletion intent set by the user.
          // Also covers legacy records where storageLocation==local but
          // syncedFiles>0 indicates remote files exist (pre-field-16 records).
          if (finalPref == ThreadStoragePreference.localOnly &&
              (record.effectiveStorageLocation != ThreadStorageLocation.local ||
                  record.syncedFiles > 0)) {
            print(
                '[ThreadDownloader] localOnly complete, firing CopyParty deletion for ${record.boxKey}');
            _deleteCopypartyFolder(record);
          }
          if (copypartyEnabled &&
              !copypartyAuthFailed &&
              !copypartyServerFailed) {
            record.lastSyncedAt = DateTime.now();
            // Determine final storage location based on sync outcome and live pref.
            if (finalPref == ThreadStoragePreference.localOnly) {
              record.syncedFiles = 0;
              record.storageLocation = ThreadStorageLocation.local;
            } else if (finalPref == ThreadStoragePreference.both &&
                record.syncedFiles > 0) {
              // Files exist both locally and on Copyparty.
              record.storageLocation = ThreadStorageLocation.mixed;
            } else if (record.syncedFiles >= record.totalFiles &&
                record.totalFiles > 0) {
              record.storageLocation = ThreadStorageLocation.remote;
            } else if (record.syncedFiles > 0) {
              record.storageLocation = ThreadStorageLocation.mixed;
            } else {
              record.storageLocation = ThreadStorageLocation.local;
            }
          } else {
            // CopyParty auth or server failure: partial upload+delete may have
            // occurred. Update storageLocation so gallery lookup stays correct (F2).
            if (shouldUpload &&
                shouldDeleteAfterUpload &&
                record.syncedFiles > 0) {
              if (record.syncedFiles >= record.totalFiles &&
                  record.totalFiles > 0) {
                record.storageLocation = ThreadStorageLocation.remote;
              } else {
                record.storageLocation = ThreadStorageLocation.mixed;
              }
            } else {
              record.storageLocation = ThreadStorageLocation.local;
            }
          }
          // Compute total media size.
          // For remoteOnly threads (files deleted after upload), accumulate the
          // bytes that were downloaded this run — local files are gone so a
          // directory scan would return 0.
          // For all other cases (localOnly, both, global-off) the files remain
          // on disk; scan the directory so the stored value always reflects what
          // is actually present regardless of how many runs have happened.
          if (shouldUpload && shouldDeleteAfterUpload) {
            // remoteOnly path: accumulate bytes downloaded this run.
            if (newSizeBytes > 0) {
              record.totalSizeBytes =
                  (record.totalSizeBytes ?? 0) + newSizeBytes;
            }
          } else {
            // Local-files-kept path: scan dir for ground-truth size.
            int actualSize = 0;
            final sizeDir = _threadDirFor(record);
            if (sizeDir.existsSync()) {
              await for (final entity in sizeDir.list()) {
                if (entity is File && !entity.path.endsWith('.part')) {
                  try {
                    actualSize += entity.lengthSync();
                  } catch (_) {}
                }
              }
            }
            if (actualSize > 0) record.totalSizeBytes = actualSize;
          }
        } else {
          record.status = DownloadStatus.cancelled;
          record.errorMessage = null;
        }
        if (record.isInBox) await record.save();
      } on DioError catch (e) {
        if (e.type == DioErrorType.cancel) {
          record.status = DownloadStatus.cancelled;
          record.errorMessage = null;
          print('[ThreadDownloader] CANCELLED: ${record.boxKey}');
        } else {
          final statusCode = e.response?.statusCode;
          // Transient = no HTTP response AND a known network-layer error type.
          // Deliberately excludes DioErrorType.other to avoid treating parse
          // or SSL errors as retryable network blips.
          final isTransientNetworkError = statusCode == null &&
              (e.error is SocketException ||
                  e.type == DioErrorType.connectTimeout ||
                  e.type == DioErrorType.receiveTimeout ||
                  e.type == DioErrorType.sendTimeout);
          if (isTransientNetworkError && wasUpdating) {
            // Transient failure (DNS/TCP) while re-downloading a thread that
            // was already complete.  The existing local files are intact.
            // Reset to complete so _onThreadStateUpdated and _autoSync can
            // retry automatically when connectivity recovers — instead of
            // permanently stalling updates until the user taps "Update".
            record.status = DownloadStatus.complete;
            record.errorMessage = null;
            print('[ThreadDownloader] TRANSIENT ERROR (will retry): ${record.boxKey} | ${e.message}');
          } else {
            record.status = DownloadStatus.failed;
            record.errorMessage =
                statusCode != null ? 'HTTP $statusCode' : e.message;
            print(
                '[ThreadDownloader] DioError FAILED: ${record.boxKey} | ${record.errorMessage} | type=${e.type} | url=${e.requestOptions.uri}');
            // Partial sync may have uploaded and deleted some local files before the
            // error. Update storageLocation so the icon accurately reflects what is
            // actually on CopyParty vs disk, preventing findDownloadedFile from
            // skipping records that still have remote files (F2).
            if (record.syncedFiles > 0) {
              final p = record.storagePreference;
              final cpEnabled = Persistence.settings.copypartyEnabled;
              final effectiveUpload = cpEnabled &&
                  (p == ThreadStoragePreference.remoteOnly ||
                      p == ThreadStoragePreference.both ||
                      (p == null && Persistence.settings.copypartyAutoUpload));
              final wouldDelete = p != ThreadStoragePreference.both;
              if (effectiveUpload && wouldDelete) {
                if (record.syncedFiles >= record.totalFiles &&
                    record.totalFiles > 0) {
                  record.storageLocation = ThreadStorageLocation.remote;
                } else {
                  record.storageLocation = ThreadStorageLocation.mixed;
                }
              }
            }
          } // end else (non-transient or initial download)
        }
        if (record.isInBox) await record.save();
      } on ThreadNotFoundException {
        if (record.status == DownloadStatus.updating) {
          // Thread was deleted/archived server-side during an update run.
          // Keep the data intact — just mark archived so the UI can open it offline.
          record.isArchivedOnServer = true;
          record.status = DownloadStatus.complete;
          record.lastUpdatedAt = DateTime.now();
          print('[ThreadDownloader] ARCHIVED: ${record.boxKey}');
          // If the user explicitly switched to localOnly (download-first path),
          // honour the deletion intent even though we couldn't download new files.
          if (record.storagePreference == ThreadStoragePreference.localOnly &&
              (record.effectiveStorageLocation != ThreadStorageLocation.local ||
                  record.syncedFiles > 0)) {
            print(
                '[ThreadDownloader] localOnly+archived, firing CopyParty deletion for ${record.boxKey}');
            _deleteCopypartyFolder(record);
            record.syncedFiles = 0;
            record.storageLocation = ThreadStorageLocation.local;
          }
        } else {
          // Thread not found on first download attempt
          record.status = DownloadStatus.failed;
          record.errorMessage = 'Thread not found (404)';
          print('[ThreadDownloader] NOT FOUND: ${record.boxKey}');
        }
        if (record.isInBox) await record.save();
      } catch (e, st) {
        record.status = DownloadStatus.failed;
        record.errorMessage = e.toString();
        if (record.isInBox) await record.save();
        print(
            '[ThreadDownloader] EXCEPTION FAILED: ${record.boxKey} | $e\n$st');
      } finally {
        _cancelTokens.remove(key);
        _pendingCancels.remove(key);
        // Mutex is NOT removed here: removing it while a second waiter
        // holds a reference causes a dangling-mutex race.
        // deleteDownload() is the only safe removal point.
      }
    });
  }

  Future<void> _downloadFile(String url, File dest, CancelToken cancelToken,
      ImageboardSite site) async {
    // Use site.client so cookies (cf_clearance, board cookies), user-agent,
    // and the built-in HTTP429BackoffInterceptor are all applied automatically.
    final partialFile = File('${dest.path}.part');
    final headers = partialFile.existsSync() && partialFile.lengthSync() > 0
        ? {'Range': 'bytes=${partialFile.lengthSync()}-'}
        : <String, String>{};
    final options = Options(headers: headers);

    try {
      await site.client.download(
        url,
        partialFile.path,
        options: options,
        cancelToken: cancelToken,
        deleteOnError: false,
      );
      await partialFile.rename(dest.path);
    } on DioError catch (e) {
      if (e.type == DioErrorType.cancel) return;

      // 416: stale .part — delete and retry without Range header
      if (e.response?.statusCode == 416) {
        try {
          await partialFile.delete();
        } catch (_) {}
        await site.client.download(
          url,
          partialFile.path,
          options: Options(),
          cancelToken: cancelToken,
          deleteOnError: false,
        );
        await partialFile.rename(dest.path);
        return;
      }

      // Other HTTP errors: server wrote error body to .part — delete it.
      // Network drops (no response) keep .part intact for valid resume.
      final statusCode = e.response?.statusCode;
      if (statusCode != null && statusCode >= 400) {
        try {
          await partialFile.delete();
        } catch (_) {}
      }
      rethrow;
    }
  }

  // ── Soft-delete (mark for scheduled deletion) ──────────────────────────────

  /// Marks [thread] for deletion after 7 days. The files are NOT removed yet.
  Future<void> softDelete(ThreadIdentifier thread, String imageboardKey) async {
    final key = _key(imageboardKey, thread);
    final record = _box.get(key);
    if (record == null) return;
    record.pendingDeletionAt = DateTime.now().add(const Duration(days: 7));
    await record.save();
  }

  /// Cancels a pending soft-delete.
  Future<void> undoSoftDelete(
      ThreadIdentifier thread, String imageboardKey) async {
    final key = _key(imageboardKey, thread);
    final record = _box.get(key);
    if (record == null) return;
    record.pendingDeletionAt = null;
    await record.save();
  }

  /// Deletes the CopyParty remote folder for [record] silently.
  /// No-ops if CopyParty is not configured or the record has no remote files.
  Future<void> _deleteCopypartyFolder(DownloadedThread record) async {
    if (!Persistence.settings.copypartyEnabled) return;
    final serverUrl = Persistence.settings.copypartyServerUrl;
    if (serverUrl.isEmpty) return;
    if (record.syncedFiles == 0 &&
        record.storageLocation == ThreadStorageLocation.local) {
      return;
    }
    final destRoot = Persistence.settings.copypartyDestRoot;
    final baseRoot = destRoot.endsWith('/')
        ? destRoot.substring(0, destRoot.length - 1)
        : destRoot;
    final folderPath =
        '$baseRoot/${record.imageboardKey}/${record.board}/${record.threadId}';
    final password = await storage.read(key: 'copypartyPassword') ?? '';
    try {
      await CopyPartySyncService.instance.deleteFolder(
        remoteFolderPath: folderPath,
        serverUrl: serverUrl,
        password: password,
      );
    } catch (e) {
      print('[ThreadDownloader] _deleteCopypartyFolder failed (ignored): $e');
    }
  }

  /// Public fire-and-forget wrapper for external callers (e.g. saved_threads.dart)
  /// when switching a thread to localOnly preference.
  void deleteCopypartyFolderForThread(DownloadedThread record) {
    _deleteCopypartyFolder(record);
  }

  /// Immediately removes files and the Hive record for [thread].
  /// Also deletes the remote CopyParty folder if the thread had remote files.
  Future<void> permanentDelete(
      ThreadIdentifier thread, String imageboardKey) async {
    final key = _key(imageboardKey, thread);
    final record = _box.get(key);
    if (record != null) {
      // Delete remote folder first (fire-and-forget errors) so it is cleaned up
      // even if the thread was remoteOnly and has no local directory.
      await _deleteCopypartyFolder(record);
      final dir = _threadDirFor(record);
      if (dir.existsSync()) {
        await dir.delete(recursive: true);
      }
      await _box.delete(key);
    }
    await Persistence.setCachedThread(
        imageboardKey, thread.board, thread.id, null);
  }

  /// Purges all records whose [pendingDeletionAt] is before [cutoff] (default: now).
  Future<void> purgeSoftDeleted({DateTime? cutoff}) async {
    final deadline = cutoff ?? DateTime.now();
    final toDelete = _box.values
        .where((r) =>
            r.pendingDeletionAt != null &&
            r.pendingDeletionAt!.isBefore(deadline))
        .toList();
    for (final record in toDelete) {
      await permanentDelete(record.identifier, record.imageboardKey);
    }
  }

  // ── ZIP export ──────────────────────────────────────────────────────────────

  /// Creates a ZIP of all files in the thread's download directory.
  /// Returns the zip [File], or null if there are no local files.
  Future<File?> exportToZip(DownloadedThread record) async {
    final threadDir = _threadDirFor(record);
    if (!threadDir.existsSync()) return null;

    final zipName =
        '${record.imageboardKey}_${record.board}_${record.threadId}.zip';
    final zipPath = '${Persistence.shareCacheDirectory.path}/$zipName';
    final zipFile = File(zipPath);
    if (zipFile.existsSync()) zipFile.deleteSync();

    // Generate thread_data.html from cached thread data so the ZIP is
    // self-contained and can be re-imported even if the thread is 404.
    final thread = await Persistence.getCachedThread(
        record.imageboardKey, record.board, record.threadId,
        syncIO: true);
    final htmlFile = thread != null
        ? File(
            '${Persistence.shareCacheDirectory.path}/thread_data_${record.threadId}.html')
        : null;
    if (thread != null && htmlFile != null) {
      htmlFile.writeAsStringSync(generateThreadHtml(thread));
    }

    final enc = ZipFileEncoder();
    bool zipClosed = false;
    try {
      enc.create(zipPath);
      // Add all thread files individually, skipping any stale thread_data.html
      // so the freshly-generated one below is the sole copy in the ZIP.
      for (final f in threadDir.listSync().whereType<File>()) {
        final name = f.uri.pathSegments.last;
        if (name == 'thread_data.html') continue;
        await enc.addFile(f, name);
      }
      // Add the freshly-generated HTML; fall back to the one already on disk.
      if (htmlFile != null && htmlFile.existsSync()) {
        await enc.addFile(htmlFile, 'thread_data.html');
      } else {
        final existing = File('${threadDir.path}/thread_data.html');
        if (existing.existsSync()) {
          await enc.addFile(existing, 'thread_data.html');
        }
      }
      enc.close();
      zipClosed = true;
    } finally {
      // Always clean up the temp HTML file.
      try {
        htmlFile?.deleteSync();
      } catch (_) {}
      // Remove partial ZIP on failure.
      if (!zipClosed && zipFile.existsSync()) {
        try {
          zipFile.deleteSync();
        } catch (_) {}
      }
    }

    return zipFile;
  }
}
