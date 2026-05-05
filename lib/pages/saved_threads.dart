import 'dart:async';
import 'dart:io';

import 'package:chan/models/downloaded_thread.dart';
import 'package:chan/models/thread.dart';
import 'package:chan/pages/thread.dart';
import 'package:chan/services/imageboard.dart';
import 'package:chan/services/kuroba_import.dart';
import 'package:chan/services/persistence.dart';
import 'package:chan/services/thread_downloader.dart';
import 'package:chan/services/settings.dart';
import 'package:chan/services/util.dart';
import 'package:chan/widgets/adaptive.dart';
import 'package:chan/widgets/imageboard_scope.dart';
import 'package:chan/widgets/thread_row.dart';
import 'package:chan/widgets/util.dart';
import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:provider/provider.dart';

enum _DownloadSortMethod {
	downloadedAt,
	lastUpdatedAt,
	title,
}

const _kDownloadSortMethodLabels = {
	_DownloadSortMethod.downloadedAt: 'Date added',
	_DownloadSortMethod.lastUpdatedAt: 'Last updated',
	_DownloadSortMethod.title: 'Title',
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
	_DownloadSortMethod _sortMethod = _DownloadSortMethod.downloadedAt;
	bool _sortReversed = false;
	bool _isImporting = false;
	int _importCurrent = 0;
	int _importTotal = 0;
	bool _isSelecting = false;
	final Set<String> _selectedBoxKeys = {};
	final ScrollController _scrollController = ScrollController();
	final Map<String, Thread?> _threadCache = {};

	@override
	void initState() {
		super.initState();
		_reload();
		ThreadDownloadService.instance.purgeSoftDeleted();
		_preloadThreadCache();
		// Rebuild when any record changes
		_sub = ThreadDownloadService.instance.watchAllChanges().listen((_) {
			if (mounted) {
				setState(_reload);
				_preloadThreadCache();
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
				list.sort((a, b) => (b.lastUpdatedAt ?? b.downloadedAt).compareTo(a.lastUpdatedAt ?? a.downloadedAt));
			case _DownloadSortMethod.title:
				list.sort((a, b) => (a.title ?? '').toLowerCase().compareTo((b.title ?? '').toLowerCase()));
		}
		_cachedSortedDownloads = _sortReversed ? list.reversed.toList() : list;
	}

	Future<void> _preloadThreadCache() async {
		final downloads = List<DownloadedThread>.from(_downloads);
		final futures = downloads.map((d) async {
			final thread = await Persistence.getCachedThread(d.imageboardKey, d.board, d.threadId);
			if (mounted) {
				setState(() => _threadCache[d.boxKey] = thread);
			}
		});
		await Future.wait(futures);
	}

	List<DownloadedThread> get _sortedDownloads => _cachedSortedDownloads;

	Future<void> _showSortMenu(BuildContext context) async {
		await showAdaptiveModalPopup<void>(
			context: context,
			builder: (ctx) => AdaptiveActionSheet(
				title: const Text('Sort by...'),
				actions: [
					..._kDownloadSortMethodLabels.entries.map((entry) => AdaptiveActionSheetAction(
						child: Text(
							'${entry.value}${entry.key == _sortMethod && _sortReversed ? ' (reversed)' : ''}',
							style: entry.key == _sortMethod ? const TextStyle(fontWeight: FontWeight.bold) : null,
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
				content: const Text('All downloaded files for this thread will be removed.'),
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
			await ThreadDownloadService.instance.deleteDownload(d.identifier, d.imageboardKey);
			if (mounted) setState(_reload);
		}
	}

	Future<void> _update(DownloadedThread d) async {
		final imageboard = ImageboardRegistry.instance.getImageboard(d.imageboardKey);
		if (imageboard == null) return;
		await ThreadDownloadService.instance.updateThread(d.identifier, imageboard.site, d.imageboardKey);
		if (mounted) setState(_reload);
	}

	void _openThread(DownloadedThread d) {
		final imageboard = ImageboardRegistry.instance.getImageboard(d.imageboardKey);
		if (imageboard == null) {
			showAdaptiveDialog(
				context: context,
				builder: (ctx) => AdaptiveAlertDialog(
					title: const Text('Imageboard unavailable'),
					content: Text('"${d.imageboardKey}" is not configured. Add it in Settings to open this thread.'),
					actions: [AdaptiveDialogAction(child: const Text('OK'), onPressed: () => Navigator.pop(ctx))],
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
		final paths = result.files
				.map((f) => f.path)
				.whereType<String>()
				.toList();
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

	Future<void> _scan() async {
		final result = await ThreadDownloadService.instance.scanDownloadsDirectory();
		if (mounted) {
			showAdaptiveDialog(
				context: context,
				builder: (ctx) => AdaptiveAlertDialog(
					title: const Text('Scan complete'),
					content: Text('Found ${result.found} new thread(s), skipped ${result.skipped} already-known.'),
					actions: [
						AdaptiveDialogAction(
							child: const Text('OK'),
							onPressed: () => Navigator.pop(ctx),
						),
					],
				),
			);
			setState(_reload);
		}
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
				content: const Text('All downloaded files for the selected threads will be removed.'),
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
				await ThreadDownloadService.instance.deleteDownload(d.identifier, d.imageboardKey);
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
		final selected = _sortedDownloads.where((d) => _selectedBoxKeys.contains(d.boxKey)).toList();
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

	/// Export a single thread as a ZIP and share it.
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
							actions: [AdaptiveDialogAction(child: const Text('OK'), onPressed: () => Navigator.pop(ctx))],
						),
					);
				}
				return;
			}
			await Share.shareXFiles([XFile(zipFile.path)]);
		} catch (e) {
			if (mounted) {
				showAdaptiveDialog(
					context: context,
					builder: (ctx) => AdaptiveAlertDialog(
						title: const Text('Export failed'),
						content: Text(e.toString()),
						actions: [AdaptiveDialogAction(child: const Text('OK'), onPressed: () => Navigator.pop(ctx))],
					),
				);
			}
		}
	}

	/// Export all selected threads as ZIPs and share them.
	Future<void> _exportSelected() async {
		final selected = _sortedDownloads.where((d) => _selectedBoxKeys.contains(d.boxKey)).toList();
		final xFiles = <XFile>[];
		for (final d in selected) {
			try {
				final f = await ThreadDownloadService.instance.exportToZip(d);
				if (f != null) xFiles.add(XFile(f.path));
			} catch (_) {}
		}
		if (xFiles.isEmpty) {
			showAdaptiveDialog(
				context: context,
				builder: (ctx) => AdaptiveAlertDialog(
					title: const Text('Nothing to export'),
					content: const Text('None of the selected threads have local files.'),
					actions: [AdaptiveDialogAction(child: const Text('OK'), onPressed: () => Navigator.pop(ctx))],
				),
			);
			return;
		}
		await Share.shareXFiles(xFiles);
	}

	Future<void> _softDeleteSingle(DownloadedThread d) async {
		await ThreadDownloadService.instance.softDelete(d.identifier, d.imageboardKey);
		if (mounted) setState(_reload);
	}

	Future<void> _undoSoftDeleteSingle(DownloadedThread d) async {
		await ThreadDownloadService.instance.undoSoftDelete(d.identifier, d.imageboardKey);
		if (mounted) setState(_reload);
	}

	Future<void> _permanentDeleteSingle(DownloadedThread d) async {
		final confirmed = await showAdaptiveDialog<bool>(
			context: context,
			builder: (ctx) => AdaptiveAlertDialog(
				title: const Text('Delete permanently?'),
				content: const Text('All downloaded files for this thread will be removed immediately and cannot be undone.'),
				actions: [
					AdaptiveDialogAction(child: const Text('Cancel'), onPressed: () => Navigator.pop(ctx, false)),
					AdaptiveDialogAction(isDestructiveAction: true, child: const Text('Delete'), onPressed: () => Navigator.pop(ctx, true)),
				],
			),
		);
		if (confirmed == true) {
			await ThreadDownloadService.instance.permanentDelete(d.identifier, d.imageboardKey);
			if (mounted) setState(_reload);
		}
	}

	Future<void> _softDeleteSelected() async {
		for (final key in List<String>.from(_selectedBoxKeys)) {
			final d = _findByBoxKey(key);
			if (d != null) await ThreadDownloadService.instance.softDelete(d.identifier, d.imageboardKey);
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
				title: Text('Delete $count thread${count == 1 ? "" : "s"} permanently?'),
				content: const Text('All downloaded files for the selected threads will be removed and cannot be undone.'),
				actions: [
					AdaptiveDialogAction(child: const Text('Cancel'), onPressed: () => Navigator.pop(ctx, false)),
					AdaptiveDialogAction(isDestructiveAction: true, child: const Text('Delete'), onPressed: () => Navigator.pop(ctx, true)),
				],
			),
		);
		for (final key in List<String>.from(_selectedBoxKeys)) {
			final d = _findByBoxKey(key);
			if (d != null) await ThreadDownloadService.instance.permanentDelete(d.identifier, d.imageboardKey);
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
												onPressed: () { Navigator.pop(ctx); _updateSelected(); },
											),
											AdaptiveActionSheetAction(
												child: const Text('Export'),
												onPressed: () { Navigator.pop(ctx); _exportSelected(); },
											),
											if (Persistence.settings.copypartyEnabled)
												AdaptiveActionSheetAction(
													child: const Text('Migrate to CopyParty'),
													onPressed: () { Navigator.pop(ctx); _migrateSelected(); },
												),
											AdaptiveActionSheetAction(
												child: const Text('Mark for Deletion (5 days)'),
												onPressed: () { Navigator.pop(ctx); _softDeleteSelected(); },
											),
											AdaptiveActionSheetAction(
												isDestructiveAction: true,
												child: const Text('Delete Permanently'),
												onPressed: () { Navigator.pop(ctx); _permanentDeleteSelected(); },
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
					title: const Text('Downloads'),
					actions: [
						CupertinoButton(
							padding: EdgeInsets.zero,
							onPressed: _isImporting ? null : () => _showSortMenu(context),
							child: Icon(_sortReversed ? CupertinoIcons.sort_up : CupertinoIcons.sort_down),
						),
						if (_isImporting)
							CupertinoButton(
								padding: EdgeInsets.zero,
								onPressed: null,
								child: const CupertinoActivityIndicator(),
							)
						else
							CupertinoButton(
								padding: EdgeInsets.zero,
								onPressed: _importKuroba,
								child: const Icon(CupertinoIcons.arrow_down_doc),
							),
						CupertinoButton(
							padding: EdgeInsets.zero,
							onPressed: _isImporting ? null : _scan,
							child: const Icon(CupertinoIcons.folder_badge_plus),
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
						child: _downloads.isEmpty
							? const Center(child: Text('No downloaded threads'))
							: ListView.builder(
								controller: _scrollController,
								padding: EdgeInsets.only(bottom: MediaQuery.viewPaddingOf(context).bottom),
								itemCount: _cachedSortedDownloads.length,
								itemBuilder: (context, i) {
						final d = _sortedDownloads[i];
						return _DownloadedThreadRow(
							download: d,
						preloadedThread: _threadCache[d.boxKey],
						onTap: _isSelecting ? () => _toggleSelect(d.boxKey) : () => _openThread(d),
						onDelete: () => _delete(d),
						onUpdate: () => _update(d),
						onExport: () => _exportSingle(d),
						onSoftDelete: () => _softDeleteSingle(d),
						onPermanentDelete: () => _permanentDeleteSingle(d),
						onUndoSoftDelete: () => _undoSoftDeleteSingle(d),
						onMigrate: () async {
							await showAdaptiveDialog(
								context: context,
								builder: (ctx) => _MigrateSelectedDialog(records: [d]),
							);
							if (mounted) setState(_reload);
						},
						onCancel: () {
							ThreadDownloadService.instance.cancelDownload(d.identifier, d.imageboardKey);
							setState(_reload);
						},
						onSelect: () => _enterSelectMode(d.boxKey),
						isSelecting: _isSelecting,
						isSelected: _selectedBoxKeys.contains(d.boxKey),
						);
					},
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

	@override
	void initState() {
		super.initState();
		_loadCopypartyThumb();
	}

	@override
	void didUpdateWidget(_DownloadedThreadRow old) {
		super.didUpdateWidget(old);
		if (old.download.boxKey != widget.download.boxKey) {
			_copypartyThumbUri = null;
			_copypartyThumbHeaders = null;
			_loadCopypartyThumb();
		}
	}

	Future<void> _loadCopypartyThumb() async {
		final uri = await ThreadDownloadService.instance.copypartyThumbnailUri(widget.download);
		if (uri == null || !mounted) return;
		final pw = await ThreadDownloadService.instance.getCopypartyPassword();
		if (mounted) {
			setState(() {
				_copypartyThumbUri = uri;
				_copypartyThumbHeaders = (pw != null && pw.isNotEmpty) ? {'Pw': pw} : null;
			});
		}
	}

	@override
	Widget build(BuildContext context) {
		final d = widget.download;
		final imageboard = ImageboardRegistry.instance.getImageboard(d.imageboardKey);
		final thread = widget.preloadedThread;
		final theme = context.watch<SavedTheme>();
		final progress = d.totalFiles > 0 ? d.downloadedFiles / d.totalFiles : null;
		final canOpen = d.status == DownloadStatus.complete || d.status == DownloadStatus.failed || d.status == DownloadStatus.cancelled;

		final isPendingDeletion = d.pendingDeletionAt != null;
		if (imageboard != null && thread != null) {
			return Opacity(
				opacity: isPendingDeletion ? 0.4 : 1.0,
				child: GestureDetector(
				onTap: (canOpen || widget.isSelecting) ? widget.onTap : null,
				onLongPress: widget.isSelecting ? null : () => _showActionSheet(context, d),
				child: Container(
					decoration: BoxDecoration(
						border: Border(bottom: BorderSide(color: theme.primaryColor.withOpacity(0.1))),
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
											),
										),
									),
									_actionsWidget(context, d),
								],
							),
							if (d.status != DownloadStatus.complete)
								Padding(
									padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
									child: _statusWidget(context, d, progress),							)
						else
							Padding(
								padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
								child: _statusWidget(context, d, progress),								),
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
			onLongPress: widget.isSelecting ? null : () => _showActionSheet(context, d),
			child: Container(
				padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
				decoration: BoxDecoration(
					border: Border(bottom: BorderSide(color: theme.primaryColor.withOpacity(0.1))),
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
										style: TextStyle(fontWeight: FontWeight.w600, color: theme.primaryColor),
									),
									if (d.title != null)
										Text(
											d.title!,
											maxLines: 2,
											overflow: TextOverflow.ellipsis,
											style: TextStyle(fontSize: 13, color: theme.primaryColor.withOpacity(0.8)),
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
				errorBuilder: (_, __, ___) => Icon(CupertinoIcons.photo, color: theme.primaryColor),
			);
		}
		final copypartyUri = _copypartyThumbUri;
		if (copypartyUri != null) {
			return Image.network(
				copypartyUri.toString(),
				headers: _copypartyThumbHeaders,
				fit: BoxFit.cover,
				errorBuilder: (_, __, ___) => Icon(CupertinoIcons.photo, color: theme.primaryColor),
			);
		}
		final thumbnailUrl = d.thumbnailUrl;
		if (thumbnailUrl != null) {
			return Image.network(
				thumbnailUrl,
				fit: BoxFit.cover,
				errorBuilder: (_, __, ___) => Icon(CupertinoIcons.photo, color: theme.primaryColor),
			);
		}
		return Icon(CupertinoIcons.photo, color: theme.primaryColor);
	}

	Widget _statusWidget(BuildContext context, DownloadedThread d, double? progress) {
		switch (d.status) {
			case DownloadStatus.pending:
				return const Row(children: [
					SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5)),
					SizedBox(width: 6),
					Text('Queued...', style: TextStyle(fontSize: 12)),
				]);
			case DownloadStatus.downloading:
			case DownloadStatus.updating:
				return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
					if (progress != null)
						LinearProgressIndicator(value: progress, minHeight: 4),
					Text(
						'${d.downloadedFiles}/${d.totalFiles} files',
						style: const TextStyle(fontSize: 12),
					),
				]);
			case DownloadStatus.complete:
				// Show pending deletion countdown if soft-deleted
				if (d.pendingDeletionAt != null) {
					final daysLeft = 5 - DateTime.now().difference(d.pendingDeletionAt!).inDays;
					final label = daysLeft > 0 ? 'Marked for deletion in $daysLeft day${daysLeft == 1 ? "" : "s"}' : 'Marked for deletion';
					return Text(label, style: const TextStyle(fontSize: 12, color: CupertinoColors.destructiveRed));
				}
				return Row(mainAxisSize: MainAxisSize.min, children: [
					_buildStorageIndicator(d),
					if (d.isArchivedOnServer) ...[
						const SizedBox(width: 6),
						Container(
							padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
							decoration: BoxDecoration(
								color: CupertinoColors.systemOrange.withOpacity(0.18),
								borderRadius: BorderRadius.circular(4),
							),
							child: const Text(
								'ARCHIVED',
								style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: CupertinoColors.systemOrange),
							),
						),
					],
				]);
			case DownloadStatus.failed:
				return Row(children: [
					const Icon(CupertinoIcons.exclamationmark_triangle, size: 14, color: CupertinoColors.destructiveRed),
					const SizedBox(width: 4),
					Flexible(child: Text(d.errorMessage ?? 'Failed', style: const TextStyle(fontSize: 12, color: CupertinoColors.destructiveRed))),
				]);
			case DownloadStatus.cancelled:
				return const Row(children: [
					Icon(CupertinoIcons.stop_circle, size: 14, color: CupertinoColors.systemGrey),
					SizedBox(width: 4),
					Text('Cancelled', style: TextStyle(fontSize: 12, color: CupertinoColors.systemGrey)),
				]);
		}
	}

	Widget _buildStorageIndicator(DownloadedThread d) {
		if (d.downloadedFiles == 0) return const SizedBox.shrink();
		if (d.syncedFiles <= 0) {
			// All files are local (on device)
			return const Icon(CupertinoIcons.device_phone_portrait, size: 12, color: CupertinoColors.systemGrey);
		} else if (d.syncedFiles >= d.downloadedFiles) {
			// All files uploaded to CopyParty (no local copies)
			return const Icon(CupertinoIcons.cloud_fill, size: 12, color: CupertinoColors.systemBlue);
		} else {
			// Partial: some local, some on CopyParty
			return const Row(mainAxisSize: MainAxisSize.min, children: [
				Icon(CupertinoIcons.device_phone_portrait, size: 12, color: CupertinoColors.systemGrey),
				SizedBox(width: 2),
				Text('/', style: TextStyle(fontSize: 10, color: CupertinoColors.systemGrey)),
				SizedBox(width: 2),
				Icon(CupertinoIcons.cloud_fill, size: 12, color: CupertinoColors.systemBlue),
			]);
		}
	}

	void _showActionSheet(BuildContext context, DownloadedThread d) {
		mediumHapticFeedback();
		showAdaptiveModalPopup(
			context: context,
			builder: (popupContext) => AdaptiveActionSheet(
				actions: [
					if (d.status == DownloadStatus.complete || d.status == DownloadStatus.failed || d.status == DownloadStatus.cancelled)
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
					if (Persistence.settings.copypartyEnabled && d.status == DownloadStatus.complete)
						AdaptiveActionSheetAction(
							child: const Text('Migrate to CopyParty'),
							onPressed: () {
								Navigator.pop(popupContext);
								widget.onMigrate();
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

	Widget _actionsWidget(BuildContext context, DownloadedThread d) {
		if (widget.isSelecting) {
			return Padding(
				padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
				child: Icon(
					widget.isSelected ? CupertinoIcons.checkmark_circle_fill : CupertinoIcons.circle,
					color: widget.isSelected ? CupertinoColors.activeBlue : CupertinoColors.systemGrey,
					size: 22,
				),
			);
		}
		if (d.status == DownloadStatus.downloading || d.status == DownloadStatus.updating || d.status == DownloadStatus.pending) {
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
		_sub = ThreadDownloadService.instance.migrateLocalFilesToCopyparty(only: widget.records).listen(
			(p) { if (mounted) { setState(() => _progress = p); } },
			onError: (e) {
				if (mounted) { setState(() => _progress = MigrationProgress(
					totalFiles: _progress?.totalFiles ?? 0,
					processedFiles: _progress?.processedFiles ?? 0,
					uploadedFiles: _progress?.uploadedFiles ?? 0,
					error: e.toString(),
					isDone: true,
				)); }
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
		final frac = (p == null || p.totalFiles == 0) ? null : p.processedFiles / p.totalFiles;

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
							Text(error, style: const TextStyle(color: CupertinoColors.destructiveRed))
						else if (isDone)
							Text('Done — ${p.uploadedFiles} file${p.uploadedFiles == 1 ? '' : 's'} migrated.')
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
