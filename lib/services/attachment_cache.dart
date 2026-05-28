import 'dart:async';

import 'package:chan/models/attachment.dart';
import 'package:chan/services/media.dart';
import 'package:chan/services/streaming_mp4.dart';
import 'package:chan/services/thread_downloader.dart';
import 'package:extended_image_library/extended_image_library.dart';

class AttachmentCache {
	static final _streamController = StreamController<(Attachment, Object)>.broadcast();
	static Stream<(Attachment, Object)> get stream => _streamController.stream;
	static onCached(Attachment attachment, Object source) {
		_streamController.add((attachment, source));
	}
	static Future<File?> optimisticallyFindFile(Attachment attachment) async {
		if (attachment.type == AttachmentType.pdf || attachment.type == AttachmentType.url) {
			// Not cacheable
			return null;
		}

		// Check permanent downloads first
		final downloadedFile = ThreadDownloadService.instance.findDownloadedFile(attachment);
		if (downloadedFile != null && await downloadedFile.exists()) {
			return downloadedFile;
		}

		if (attachment.type == AttachmentType.image) {
			return await getCachedImageFile(attachment.url);
		}
		if (attachment.type == AttachmentType.webm) {
			final conversion = MediaConversion.toMp4(Uri.parse(attachment.url));
			final file = conversion.getDestination();
			if (await file.exists()) {
				return file;
			}
			// Fall through in case WEBM is directly playing
		}
		final file = VideoServer.instance.optimisticallyGetFile(Uri.parse(attachment.url));
		if (file != null && await file.exists()) {
			return file;
		}
		// Check if the media has been cached after a prior CopyParty fetch
		// (cached under the CopyParty URL key rather than the original CDN URL key).
		final copypartyUri = await ThreadDownloadService.instance.copypartySourceUri(attachment);
		if (copypartyUri != null) {
			if (attachment.type == AttachmentType.image) {
				final cpCached = await getCachedImageFile(copypartyUri.toString());
				if (cpCached != null) return cpCached;
			}
			final cpFile = VideoServer.instance.optimisticallyGetFile(copypartyUri);
			if (cpFile != null && await cpFile.exists()) return cpFile;
		}
		return null;
	}
}
