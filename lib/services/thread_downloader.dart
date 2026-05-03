import 'dart:async';
import 'dart:io';

import 'package:chan/models/attachment.dart';
import 'package:chan/models/downloaded_thread.dart';
import 'package:chan/models/thread.dart';
import 'package:chan/services/copyparty_sync.dart';
import 'package:chan/services/imageboard.dart';
import 'package:chan/services/persistence.dart';
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

	ThreadDownloadService._(this._box, this._downloadsDir);

	static Future<void> initializeStatic() async {
		final box = Hive.box<DownloadedThread>(_boxName);
		final downloadsDir = Persistence.downloadsDirectory;
		instance = ThreadDownloadService._(box, downloadsDir);
		// Reset any interrupted downloads to pending so resumePending() can restart them
		for (final record in box.values) {
			if (record.status == DownloadStatus.downloading || record.status == DownloadStatus.updating) {
				record.status = DownloadStatus.pending;
				if (record.isInBox) await record.save();
			}
		}
		// Subscribe to thread state changes for auto-update
		instance._threadStateSubscription = Persistence.sharedThreadStateStream.listen(
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
			if (record.status != DownloadStatus.pending) continue; // may have changed since snapshot
			final imageboard = ImageboardRegistry.instance.getImageboard(record.imageboardKey);
			if (imageboard == null) continue;
			await _runDownload(record, imageboard.site);
		}
	}

	void _onThreadStateUpdated(PersistentThreadState state) {
		final key = _key(state.imageboardKey, state.identifier);
		final record = _box.get(key);
		if (record == null || record.status != DownloadStatus.complete) return;
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
			final imageboard = ImageboardRegistry.instance.getImageboard(state.imageboardKey);
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
			final imageboard = ImageboardRegistry.instance.getImageboard(record.imageboardKey);
			if (imageboard == null) continue;
			updateThread(record.identifier, imageboard.site, record.imageboardKey);
		}
	}

	// ── Public API ──────────────────────────────────────────────

	/// Start a new download. No-op if already complete or in progress.
	Future<void> downloadThread(ThreadIdentifier id, ImageboardSite site, String imageboardKey) async {
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
	Future<void> updateThread(ThreadIdentifier id, ImageboardSite site, String imageboardKey) async {
		final key = _key(imageboardKey, id);
		// Guard is inside the mutex to prevent TOCTOU races
		bool shouldRun = false;
		final mutex = _mutexFor(key);
		await mutex.protect(() async {
			final record = _box.get(key);
			if (record == null || !record.isInBox) return;
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
	}) async {
		final key = _key(imageboardKey, ThreadIdentifier(board, threadId));
		final existing = _box.get(key);
		if (existing != null && existing.status == DownloadStatus.complete) {
			return false;
		}
		final localThumbnailFilename = thumbnailUrl != null
				? Uri.tryParse(thumbnailUrl)?.pathSegments.lastOrNull
				: null;
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
			isArchivedOnServer: true,
		);
		await _box.put(key, record);
		return true;
	}

	/// Live stream of status changes for a specific thread.
	Stream<DownloadedThread?> watchThread(ThreadIdentifier id, String imageboardKey) {
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
			if (r.status == DownloadStatus.cancelled || r.status == DownloadStatus.failed) continue;
			// Verify imageboard matches: check against both the site base URL and the CDN
			// image URL, since some sites (e.g. 4chan) serve media from a different host
			// (i.4cdn.org) than their base URL (boards.4chan.org).
			if (attachmentHost != null) {
				final imageboard = ImageboardRegistry.instance.getImageboard(r.imageboardKey);
				if (imageboard == null) continue;
				final siteBaseHost = Uri.tryParse(imageboard.site.baseUrl)?.host ?? '';
				final siteImageHost = imageboard.site.imageUrl ?? '';
				if (attachmentHost != siteBaseHost && attachmentHost != siteImageHost) continue;
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
			if (r.status == DownloadStatus.cancelled || r.status == DownloadStatus.failed) continue;
			if (thumbHost != null) {
				final imageboard = ImageboardRegistry.instance.getImageboard(r.imageboardKey);
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
	Future<Uri?> copypartySourceUri(Attachment attachment, {String? urlForFilename}) async {
		if (!Persistence.settings.copypartyEnabled) return null;
		final serverUrl = Persistence.settings.copypartyServerUrl;
		if (serverUrl.isEmpty) return null;
		final destRoot = Persistence.settings.copypartyDestRoot;
		final base = serverUrl.endsWith('/') ? serverUrl.substring(0, serverUrl.length - 1) : serverUrl;
		final baseRoot = destRoot.endsWith('/') ? destRoot.substring(0, destRoot.length - 1) : destRoot;

		final threadId = attachment.threadId;
		if (threadId == null) return null;
		final targetUrl = urlForFilename ?? attachment.url;
		final attachmentHost = Uri.tryParse(targetUrl)?.host;

		for (final r in _box.values) {
			if (r.board != attachment.board || r.threadId != threadId) continue;
			if (r.status != DownloadStatus.complete) continue;
			if (attachmentHost != null) {
				final imageboard = ImageboardRegistry.instance.getImageboard(r.imageboardKey);
				if (imageboard == null) continue;
				final siteBaseHost = Uri.tryParse(imageboard.site.baseUrl)?.host ?? '';
				final siteImageHost = imageboard.site.imageUrl ?? '';
				if (attachmentHost != siteBaseHost && attachmentHost != siteImageHost) continue;
			}
			final filename = Uri.tryParse(targetUrl)?.pathSegments.lastOrNull;
			if (filename == null) return null;
			return Uri.parse('$base$baseRoot/${r.imageboardKey}/${r.board}/${r.threadId}/$filename');
		}
		return null;
	}

	/// Cancel an in-progress migration started by [migrateLocalFilesToCopyparty].
	void cancelMigration() => _migrationCancelled = true;

	/// Scans all [complete] thread directories for local files and uploads each to
	/// CopyParty, deleting the local copy only after a confirmed [CopyPartySyncResult.ok].
	/// Any auth or server failure stops the migration immediately — unprocessed files
	/// remain on disk. Yields [MigrationProgress] snapshots throughout.
	Stream<MigrationProgress> migrateLocalFilesToCopyparty({List<DownloadedThread>? only}) async* {
		_migrationCancelled = false;

		final serverUrl = Persistence.settings.copypartyServerUrl;
		final destRoot = Persistence.settings.copypartyDestRoot;
		print('[CopyParty] migrateLocalFilesToCopyparty: serverUrl=$serverUrl destRoot=$destRoot');
		if (serverUrl.isEmpty) {
			print('[CopyParty] migrateLocalFilesToCopyparty: serverUrl is empty, aborting');
			yield const MigrationProgress(totalFiles: 0, processedFiles: 0, uploadedFiles: 0, error: 'Server URL not configured', isDone: true);
			return;
		}

		final password = await storage.read(key: 'copypartyPassword') ?? '';
		print('[CopyParty] migrateLocalFilesToCopyparty: password=${password.isNotEmpty ? 'set' : 'empty'}');
		final base = serverUrl.endsWith('/') ? serverUrl.substring(0, serverUrl.length - 1) : serverUrl;
		final baseRoot = destRoot.endsWith('/') ? destRoot.substring(0, destRoot.length - 1) : destRoot;

		// Phase 1: discover all eligible local files across complete thread dirs.
		final completeRecords = (only ?? _box.values).where((r) => r.status == DownloadStatus.complete).toList();
		final filesToUpload = <({File file, String remotePath, DownloadedThread record})>[];
		for (final record in completeRecords) {
			final dir = _threadDirFor(record);
			if (!dir.existsSync()) continue;
			await for (final entity in dir.list()) {
				if (entity is! File) continue;
				final name = entity.uri.pathSegments.last;
				if (name.endsWith('.part')) continue;
				// Guard against path traversal in the remotePath sent to the server
				if (record.imageboardKey.contains('..') || record.board.contains('..') || name.contains('..') || name.contains('/') || name.contains('\\')) continue;
				final remotePath = '$baseRoot/${record.imageboardKey}/${record.board}/${record.threadId}/$name';
				filesToUpload.add((file: entity, remotePath: remotePath, record: record));
			}
		}

		final total = filesToUpload.length;
		print('[CopyParty] migrateLocalFilesToCopyparty: Phase 1 found $total files to upload');
		yield MigrationProgress(totalFiles: total, processedFiles: 0, uploadedFiles: 0);

		// Phase 2: upload one-by-one; delete only after confirmed ok.
		int processed = 0;
		int uploaded = 0;
		final Set<DownloadedThread> touchedRecords = {};

		// Saves syncedFiles/lastSyncedAt for all records that had at least one file uploaded.
		Future<void> flushTouched() async {
			final now = DateTime.now();
			for (final r in touchedRecords) {
				r.lastSyncedAt = now;
				if (r.isInBox) await r.save();
			}
		}

		for (final entry in filesToUpload) {
			if (_migrationCancelled) break;
			// Re-check: if record left complete state since Phase 1 (e.g. download started), skip safely
			if (entry.record.status != DownloadStatus.complete) continue;
			// File may have been deleted by concurrent _runDownload since Phase 1 snapshot — skip safely
			if (!entry.file.existsSync()) {
				processed++;
				yield MigrationProgress(totalFiles: total, processedFiles: processed, uploadedFiles: uploaded);
				continue;
			}
			CopyPartySyncResult result;
			try {
				print('[CopyParty] migrateLocalFilesToCopyparty: uploading ${entry.remotePath}');
				result = await CopyPartySyncService.instance.putFile(
					file: entry.file,
					remoteRelativePath: entry.remotePath,
					serverUrl: serverUrl,
					password: password,
				);
			} catch (e) {
				try { await flushTouched(); } catch (_) {}
				yield MigrationProgress(totalFiles: total, processedFiles: processed, uploadedFiles: uploaded, error: 'Unexpected error: $e — migration stopped, remaining files are safe', isDone: true);
				return;
			}
			processed++;
			if (result == CopyPartySyncResult.ok) {
				try { await entry.file.delete(); } catch (_) {}
				entry.record.syncedFiles++;
				touchedRecords.add(entry.record);
				uploaded++;
				yield MigrationProgress(totalFiles: total, processedFiles: processed, uploadedFiles: uploaded);
			} else if (result == CopyPartySyncResult.authFailed) {
				try { await flushTouched(); } catch (_) {}
				yield MigrationProgress(totalFiles: total, processedFiles: processed, uploadedFiles: uploaded, error: 'Authentication failed — check password in settings', isDone: true);
				return;
			} else {
				// serverError or networkError — stop, leave remaining files safe
				try { await flushTouched(); } catch (_) {}
				yield MigrationProgress(totalFiles: total, processedFiles: processed, uploadedFiles: uploaded, error: 'Server unreachable or returned an error — migration stopped, remaining files are safe', isDone: true);
				return;
			}
		}

		try { await flushTouched(); } catch (_) {}
		yield MigrationProgress(totalFiles: total, processedFiles: processed, uploadedFiles: uploaded, isDone: true);
	}

	/// Returns the local thumbnail file for a DownloadedThread record (for list UI).
	File? findLocalThumbnail(DownloadedThread record) {
		final filename = record.localThumbnailFilename;
		if (filename == null) return null;
		final file = _fileForName(record, filename);
		return file.existsSync() ? file : null;
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
		final base = serverUrl.endsWith('/') ? serverUrl.substring(0, serverUrl.length - 1) : serverUrl;
		final baseRoot = destRoot.endsWith('/') ? destRoot.substring(0, destRoot.length - 1) : destRoot;
		return Uri.parse('$base$baseRoot/${record.imageboardKey}/${record.board}/${record.threadId}/$filename');
	}

	/// Returns the stored CopyParty password, or null/empty if not set.
	Future<String?> getCopypartyPassword() async => storage.read(key: 'copypartyPassword');

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
			if (ImageboardRegistry.instance.getImageboard(imageboardKey) == null) continue;

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
						final thread = await Persistence.getCachedThread(imageboardKey, board, threadId);
						final op = thread?.posts_.firstOrNull;
						final rawTitle = thread?.title ?? op?.text?.trim();
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

	Directory _threadDirFor(DownloadedThread record) =>
			Directory('${_downloadsDir.path}/${record.imageboardKey}/${record.board}/${record.threadId}');

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
			if (source == null) {
				source = await getCachedImageFile(url);
			}

			if (source != null && source.existsSync()) {
				await source.copy(dest.path);
				return dest.existsSync();
			}
		} catch (_) {
			// Race: file evicted or I/O error — fall through to network download
		}
		return false;
	}

	Future<void> _runDownload(DownloadedThread record, ImageboardSite site) async {
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

			print('[ThreadDownloader] START: ${record.boxKey} status=${record.status}');
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
				await Persistence.setCachedThread(record.imageboardKey, record.board, record.threadId, thread);

				// 2. Update metadata from thread
				final opPost = thread.posts_.firstOrNull;
				final rawTitle = thread.title ?? opPost?.text?.trim();
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

				for (final attachment in attachments) {
					if (cancelToken.isCancelled) break;

					// Main file
					final mainFilename = Uri.tryParse(attachment.url)?.pathSegments.lastOrNull;
					if (mainFilename != null) {
						final mainFile = _fileForName(record, mainFilename);
						final mainPreExisted = mainFile.existsSync();
						bool mainOk = mainPreExisted;
						if (!mainOk) {
							try {
								final cached = await _tryCopyFromCache(attachment.url, mainFile);
								if (!cached) await _downloadFile(attachment.url, mainFile, cancelToken, site);
								mainOk = mainFile.existsSync();
							} on DioError catch (e) {
								if (e.type == DioErrorType.cancel) rethrow;
								final status = e.response?.statusCode ?? 0;
								if (status >= 400) {
									print('[ThreadDownloader] SKIP main 404: ${attachment.url} ($status)');
								} else {
									rethrow;
								}
							}
						}
						if (!mainPreExisted) {
							record.downloadedFiles++;
							saveCount++;
							if (saveCount % 10 == 0 && record.isInBox) await record.save();
						}

					if (mainOk && copypartyEnabled && serverUrl.isNotEmpty && !copypartyAuthFailed && !copypartyServerFailed &&
						!mainFilename.contains('..') && !mainFilename.contains('/') && !mainFilename.contains('\\') &&
						!record.imageboardKey.contains('..') && !record.board.contains('..')) {
						final remotePath = '$baseDestRoot/${record.imageboardKey}/${record.board}/${record.threadId}/$mainFilename';
						final result = await CopyPartySyncService.instance.putFile(
							file: mainFile,
							remoteRelativePath: remotePath,
							serverUrl: serverUrl,
							password: password,
						);
						if (result == CopyPartySyncResult.ok) {
							record.syncedFiles++;
							try { await mainFile.delete(); } catch (_) {}
							if (record.isInBox) await record.save();
						} else if (result == CopyPartySyncResult.authFailed) {
							copypartyAuthFailed = true;
							record.errorMessage = 'CopyParty: auth failed — check password in settings';
						} else {
							copypartyServerFailed = true;
							record.errorMessage ??= 'CopyParty sync incomplete — server unreachable or error';
							}
						}
					}

					if (cancelToken.isCancelled) break;

					// Thumbnail
					final thumbFilename = Uri.tryParse(attachment.thumbnailUrl)?.pathSegments.lastOrNull;
					if (thumbFilename != null) {
						final thumbFile = _fileForName(record, thumbFilename);
						final thumbPreExisted = thumbFile.existsSync();
						bool thumbOk = thumbPreExisted;
						if (!thumbOk) {
							try {
								final cached = await _tryCopyFromCache(attachment.thumbnailUrl, thumbFile);
								if (!cached) await _downloadFile(attachment.thumbnailUrl, thumbFile, cancelToken, site);
								thumbOk = thumbFile.existsSync();
							} on DioError catch (e) {
								if (e.type == DioErrorType.cancel) rethrow;
								final status = e.response?.statusCode ?? 0;
								if (status >= 400) {
									print('[ThreadDownloader] SKIP thumb 404: ${attachment.thumbnailUrl} ($status)');
								} else {
									rethrow;
								}
							}
						}
						if (!thumbPreExisted) {
							record.downloadedFiles++;
							// Store first OP thumbnail filename for the list UI
							if (record.localThumbnailFilename == null) {
								record.localThumbnailFilename = thumbFilename;
							}
							saveCount++;
							if (saveCount % 10 == 0 && record.isInBox) await record.save();
						}

					if (thumbOk && copypartyEnabled && serverUrl.isNotEmpty && !copypartyAuthFailed && !copypartyServerFailed &&
						!thumbFilename.contains('..') && !thumbFilename.contains('/') && !thumbFilename.contains('\\') &&
						!record.imageboardKey.contains('..') && !record.board.contains('..')) {
						final remotePath = '$baseDestRoot/${record.imageboardKey}/${record.board}/${record.threadId}/$thumbFilename';
						final result = await CopyPartySyncService.instance.putFile(
							file: thumbFile,
							remoteRelativePath: remotePath,
							serverUrl: serverUrl,
							password: password,
						);
						if (result == CopyPartySyncResult.ok) {
							record.syncedFiles++;
							try { await thumbFile.delete(); } catch (_) {}
							if (record.isInBox) await record.save();
						} else if (result == CopyPartySyncResult.authFailed) {
							copypartyAuthFailed = true;
							record.errorMessage = 'CopyParty: auth failed — check password in settings';
						} else {
							copypartyServerFailed = true;
							record.errorMessage ??= 'CopyParty sync incomplete — server unreachable or error';
							}
						}
					}
				}

				if (!cancelToken.isCancelled) {
					record.status = DownloadStatus.complete;
					record.lastUpdatedAt = DateTime.now();
					print('[ThreadDownloader] COMPLETE: ${record.boxKey} downloaded=${record.downloadedFiles}/${record.totalFiles}');
					if (copypartyEnabled && !copypartyAuthFailed && !copypartyServerFailed) {
						record.lastSyncedAt = DateTime.now();
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
					record.status = DownloadStatus.failed;
					final statusCode = e.response?.statusCode;
					record.errorMessage = statusCode != null
						? 'HTTP $statusCode'
						: e.message;
					print('[ThreadDownloader] DioError FAILED: ${record.boxKey} | ${record.errorMessage} | type=${e.type} | url=${e.requestOptions.uri}');
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
				print('[ThreadDownloader] EXCEPTION FAILED: ${record.boxKey} | $e\n$st');
			} finally {
				_cancelTokens.remove(key);
				_pendingCancels.remove(key);
				// Mutex is NOT removed here: removing it while a second waiter
				// holds a reference causes a dangling-mutex race.
				// deleteDownload() is the only safe removal point.
			}
		});
	}

	Future<void> _downloadFile(String url, File dest, CancelToken cancelToken, ImageboardSite site) async {
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
				try { await partialFile.delete(); } catch (_) {}
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
				try { await partialFile.delete(); } catch (_) {}
			}
			rethrow;
		}
	}
}



