import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:chan/models/attachment.dart';
import 'package:chan/models/post.dart';
import 'package:chan/models/thread.dart';
import 'package:chan/services/imageboard.dart';
import 'package:chan/services/persistence.dart';
import 'package:chan/services/thread_downloader.dart';
import 'package:chan/sites/4chan.dart';import 'package:chan/sites/4chan.dart';import 'package:chan/sites/4chan.dart';
import 'package:chan/sites/imageboard_site.dart';
import 'package:html/parser.dart' show parse;

sealed class KurobaImportResult {}

class KurobaImportSuccess extends KurobaImportResult {
	final String description;
	KurobaImportSuccess(this.description);
}

class KurobaImportFailure extends KurobaImportResult {
	final String error;
	KurobaImportFailure(this.error);
}

/// Imports a KurobaEx ZIP thread export into the Flutter chan app.
///
/// ZIP filename format: `{siteName}_{board}_{threadId}.zip`
/// ZIP contents: `thread_data.html`, `tomorrow.css`, and media files.
Future<KurobaImportResult> importKurobaZip(String zipPath) async {
	try {
		final zipFile = File(zipPath);
		if (!zipFile.existsSync()) {
			return KurobaImportFailure('File not found: $zipPath');
		}

		// 1. Parse filename to get siteName, board, threadId
		final basename = zipFile.uri.pathSegments.last;
		final withoutExt = basename.endsWith('.zip')
				? basename.substring(0, basename.length - 4)
				: basename;
		final parts = withoutExt.split('_');
		if (parts.length < 3) {
			return KurobaImportFailure('Unexpected filename format: $basename');
		}
		final threadIdStr = parts.last;
		final board = parts[parts.length - 2];
		final siteName = parts.sublist(0, parts.length - 2).join('_');
		final threadId = int.tryParse(threadIdStr);
		if (threadId == null) {
			return KurobaImportFailure('Could not parse thread ID from: $withoutExt');
		}
		if (board.contains('..') || board.contains('/') || board.contains('\\')) {
			return KurobaImportFailure('Invalid board name in filename: $board');
		}

		// 2. Find matching imageboard by siteType or name
		Imageboard? imageboard;
		for (final ib in ImageboardRegistry.instance.imageboards) {
			if (ib.site.siteType == siteName) {
				imageboard = ib;
				break;
			}
		}
		if (imageboard == null) {
			for (final ib in ImageboardRegistry.instance.imageboards) {
				if (ib.site.name.toLowerCase() == siteName.toLowerCase()) {
					imageboard = ib;
					break;
				}
			}
		}
		if (imageboard == null) {
			return KurobaImportFailure('No imageboard configured for site: $siteName');
		}

		// 3. Determine CDN host for building attachment URLs (4chan-specific)
		String? imageUrl;
		if (imageboard.site is Site4Chan) {
			imageUrl = (imageboard.site as Site4Chan).imageUrl;
		}

		// 4. Validate ZIP entries against path traversal before extraction
		{
			final inputStream = InputFileStream(zipPath);
			try {
				final archive = ZipDecoder().decodeStream(inputStream);
				for (final file in archive.files) {
					final name = file.name;
					if (name.contains('..') || name.startsWith('/') || name.startsWith('\\')) {
						return KurobaImportFailure('Unsafe ZIP entry: $name');
					}
				}
			} finally {
				await inputStream.close();
			}
		}

		// Extract ZIP to the thread's download directory
		final threadDir = Directory(
			'${Persistence.downloadsDirectory.path}/${imageboard.key}/$board/$threadId',
		);
		threadDir.createSync(recursive: true);
		await extractFileToDisk(zipPath, threadDir.path);

		// 5. Read thread_data.html if present (KurobaEx exports include it; our own exports do not)
		final htmlFile = File('${threadDir.path}/thread_data.html');
		final htmlContent = htmlFile.existsSync() ? htmlFile.readAsStringSync() : null;
		// Remove only the stylesheet; keep thread_data.html as recovery artifact
		final cssFile = File('${threadDir.path}/tomorrow.css');
		if (cssFile.existsSync()) cssFile.deleteSync();

		// Count remaining media files (excluding thread_data.html which we intentionally keep)
		var mediaFiles = threadDir
				.listSync()
				.whereType<File>()
				.where((f) => f.uri.pathSegments.last != 'thread_data.html')
				.map((f) => f.uri.pathSegments.last)
				.toSet();

		// 6. Try network fetch first — gives full API data and enables live updates.
		// Falls back to HTML parsing (KurobaEx ZIPs only) if the thread is 404 or offline.
		Thread thread;
		bool isArchivedOnServer;
		try {
			thread = await imageboard.site.getThread(
				ThreadIdentifier(board, threadId),
				priority: RequestPriority.lowest,
			);
			isArchivedOnServer = thread.isArchived;
		} catch (_) {
			if (htmlContent == null) {
				return KurobaImportFailure('Thread not found online and no thread_data.html in ZIP.');
			}
			final htmlThread = parseKurobaThreadHtml(imageboard.key, board, threadId, htmlContent);
			if (htmlThread == null) {
				return KurobaImportFailure('Failed to parse any posts from thread_data.html');
			}
			thread = htmlThread;
			isArchivedOnServer = true;
		}
		final posts = thread.posts_;
		final opSubject = thread.title;
		final opAttachments = thread.attachments;

		// 6b. Verify extracted media files; retry extraction once if any are missing
		final expectedFilenames = <String>{};
		for (final post in posts) {
			for (final att in post.attachments_) {
				final name = Uri.tryParse(att.url)?.pathSegments.lastOrNull;
				if (name != null && name.isNotEmpty) expectedFilenames.add(name);
			}
		}
		if (expectedFilenames.isNotEmpty) {
			final missing = expectedFilenames.difference(mediaFiles);
			if (missing.isNotEmpty) {
				await extractFileToDisk(zipPath, threadDir.path);
				// Only delete stylesheet on retry; keep thread_data.html
				final retryCss = File('${threadDir.path}/tomorrow.css');
				if (retryCss.existsSync()) retryCss.deleteSync();
				mediaFiles = threadDir
						.listSync()
						.whereType<File>()
						.where((f) => f.uri.pathSegments.last != 'thread_data.html')
						.map((f) => f.uri.pathSegments.last)
						.toSet();
			}
		}
		final presentCount = expectedFilenames.isEmpty
				? mediaFiles.length
				: expectedFilenames.intersection(mediaFiles).length;
		final missingAfterRetry = expectedFilenames.isEmpty
				? 0
				: expectedFilenames.difference(mediaFiles).length;

		// 8. Persist thread so ThreadPage can display it without network
		await Persistence.setCachedThread(
			imageboard.key,
			board,
			threadId,
			thread,
		);

		// 9. Register the download record for the Downloads page listing
		final thumbnailUrl = opAttachments.isNotEmpty ? opAttachments.first.thumbnailUrl : null;
		await ThreadDownloadService.instance.registerImportedThread(
			imageboardKey: imageboard.key,
			board: board,
			threadId: threadId,
			title: opSubject,
			thumbnailUrl: thumbnailUrl,
			downloadedAt: DateTime.now(),
			totalFiles: mediaFiles.length,
			isArchivedOnServer: isArchivedOnServer,
		);

		final displayTitle = thread.title ?? '/$board/ #$threadId';
		final filesSummary = expectedFilenames.isEmpty
				? '${mediaFiles.length} files'
				: missingAfterRetry == 0
					? '${presentCount}/${expectedFilenames.length} files'
					: '${presentCount}/${expectedFilenames.length} files ($missingAfterRetry not in ZIP)';
		return KurobaImportSuccess(
			'Imported "$displayTitle" (${posts.length} posts, $filesSummary)',
		);
	} catch (e) {
		return KurobaImportFailure('Import failed: $e');
	}
}

/// Parses a KurobaEx-style HTML thread into a [Thread] object.
///
/// The [htmlContent] should be the inner contents of `thread_data.html`.
/// Returns `null` if parsing fails or no posts are found.
Thread? parseKurobaThreadHtml(
	String imageboardKey,
	String board,
	int threadId,
	String htmlContent,
) {
	final imageboard = ImageboardRegistry.instance.getImageboard(imageboardKey);
	if (imageboard == null) return null;

	String? imageUrl;
	if (imageboard.site is Site4Chan) {
		imageUrl = (imageboard.site as Site4Chan).imageUrl;
	}

	final document = parse(htmlContent);
	final postContainers = document.querySelectorAll('div.postContainer');
	if (postContainers.isEmpty) return null;

	final posts = <Post>[];
	DateTime? opTime;
	String? opSubject;
	List<Attachment> opAttachments = [];

	for (final container in postContainers) {
		final idAttr = container.attributes['id'] ?? '';
		if (!idAttr.startsWith('pc')) continue;
		final postId = int.tryParse(idAttr.substring(2));
		if (postId == null) continue;

		final isOp = container.classes.contains('opContainer');

		// Parse timestamp from "2023-07-15 06:04:45 No. 25512520"
		final dateTimeText = container.querySelector('span.dateTime')?.text.trim() ?? '';
		DateTime? postTime;
		if (dateTimeText.contains(' No. ')) {
			final datePart = dateTimeText.split(' No. ').first.trim();
			postTime = DateTime.tryParse(datePart);
		}
		postTime ??= DateTime.now();

		final nameText = container.querySelector('span.name')?.text.trim() ?? '';
		final subjectText = container.querySelector('span.subject')?.text.trim() ?? '';
		final commentHtml = container.querySelector('blockquote.postMessage')?.innerHtml ?? '';

		// Parse file attachments
		final attachments = <Attachment>[];
		for (final fileDiv in container.querySelectorAll('div.file')) {
			final fileLink = fileDiv.querySelector('div.fileText a');
			if (fileLink == null) continue;

			final cdnFilename = fileLink.attributes['href'] ?? '';
			if (cdnFilename.isEmpty) continue;

			final thumbnailSrc =
					fileDiv.querySelector('a.fileThumb img')?.attributes['src'] ?? '';

			// Link text: "1664577840710883.webm, 3.8 MB, 1024x576"
			final linkParts = fileLink.text.trim().split(', ');
			final originalFilename = linkParts.isNotEmpty ? linkParts[0] : cdnFilename;

			int? sizeBytes;
			int? width;
			int? height;
			if (linkParts.length >= 2) sizeBytes = _parseSize(linkParts[1]);
			if (linkParts.length >= 3) {
				final dims = linkParts[2].split('x');
				if (dims.length == 2) {
					width = int.tryParse(dims[0]);
					height = int.tryParse(dims[1]);
				}
			}

			final lastDot = cdnFilename.lastIndexOf('.');
			final cdnId = lastDot >= 0 ? cdnFilename.substring(0, lastDot) : cdnFilename;
			final cdnExt = lastDot >= 0 ? cdnFilename.substring(lastDot) : '';

			final String attUrl;
			final String thumbUrl;
			if (imageUrl != null) {
				attUrl = Uri.https(imageUrl, '/$board/$cdnFilename').toString();
				thumbUrl = thumbnailSrc.isNotEmpty
						? Uri.https(imageUrl, '/$board/$thumbnailSrc').toString()
						: Uri.https(imageUrl, '/$board/${cdnId}s.jpg').toString();
			} else {
				final baseUrl = imageboard.site.baseUrl;
				attUrl = 'https://$baseUrl/$board/$cdnFilename';
				thumbUrl = thumbnailSrc.isNotEmpty
						? 'https://$baseUrl/$board/$thumbnailSrc'
						: 'https://$baseUrl/$board/${cdnId}s.jpg';
			}

			attachments.add(Attachment(
				type: AttachmentType.fromFilename(cdnFilename),
				board: board,
				id: cdnId,
				ext: cdnExt,
				filename: originalFilename,
				url: attUrl,
				thumbnailUrl: thumbUrl,
				md5: '',
				width: width,
				height: height,
				threadId: threadId,
				sizeInBytes: sizeBytes,
			));
		}

		if (isOp) {
			opTime = postTime;
			opSubject = subjectText.isNotEmpty ? subjectText : null;
			opAttachments = List.from(attachments);
		}

		posts.add(Post(
			board: board,
			text: commentHtml,
			name: nameText,
			time: postTime,
			threadId: threadId,
			id: postId,
			spanFormat: imageboard.site is Site4Chan ? PostSpanFormat.chan4 : PostSpanFormat.stub,
			attachments_: attachments,
		));
	}

	if (posts.isEmpty) return null;

	opTime ??= DateTime.now();
	final imageCount = posts.fold<int>(0, (sum, p) => sum + p.attachments_.length);
	return Thread(
		posts_: posts,
		isArchived: true,
		replyCount: posts.length - 1,
		imageCount: imageCount,
		id: threadId,
		board: board,
		title: opSubject,
		isSticky: false,
		time: opTime,
		attachments: opAttachments,
	);
}

/// Parses a human-readable file size string (e.g. "3.8 MB") into bytes.
int? _parseSize(String sizeStr) {
	final parts = sizeStr.trim().split(' ');
	if (parts.length != 2) return null;
	final value = double.tryParse(parts[0]);
	if (value == null) return null;
	switch (parts[1].toUpperCase()) {
		case 'B':
			return value.round();
		case 'KB':
			return (value * 1024).round();
		case 'MB':
			return (value * 1024 * 1024).round();
		case 'GB':
			return (value * 1024 * 1024 * 1024).round();
		default:
			return null;
	}
}
