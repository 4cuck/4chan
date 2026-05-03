import 'package:chan/models/thread.dart';
import 'package:hive/hive.dart';

part 'downloaded_thread.g.dart';

@HiveType(typeId: 51)
enum DownloadStatus {
	@HiveField(0)
	pending,
	@HiveField(1)
	downloading,
	@HiveField(2)
	complete,
	@HiveField(3)
	failed,
	@HiveField(4)
	updating,
	@HiveField(5)
	cancelled,
}

@HiveType(typeId: 52)
class DownloadedThread extends HiveObject {
	@HiveField(0)
	String imageboardKey;
	@HiveField(1)
	String board;
	@HiveField(2)
	int threadId;
	@HiveField(3)
	String? title;
	@HiveField(4)
	String? thumbnailUrl;
	@HiveField(5)
	DateTime downloadedAt;
	@HiveField(6)
	DownloadStatus status;
	@HiveField(7)
	int totalFiles;
	@HiveField(8)
	int downloadedFiles;
	@HiveField(9)
	DateTime? lastUpdatedAt;
	@HiveField(10)
	int syncedFiles;
	@HiveField(11)
	DateTime? lastSyncedAt;
	@HiveField(12)
	String? errorMessage;
	@HiveField(13)
	String? localThumbnailFilename;
	@HiveField(14)
	bool isArchivedOnServer;

	DownloadedThread({
		required this.imageboardKey,
		required this.board,
		required this.threadId,
		this.title,
		this.thumbnailUrl,
		required this.downloadedAt,
		required this.status,
		this.totalFiles = 0,
		this.downloadedFiles = 0,
		this.lastUpdatedAt,
		this.syncedFiles = 0,
		this.lastSyncedAt,
		this.errorMessage,
		this.localThumbnailFilename,
		this.isArchivedOnServer = false,
	});

	String get boxKey => '${imageboardKey}_${board}_$threadId';
	ThreadIdentifier get identifier => ThreadIdentifier(board, threadId);
}
