import 'package:chan/models/thread.dart';
import 'package:hive/hive.dart';

part 'downloaded_thread.g.dart';

/// User preference for where a thread's files should be stored.
/// [null] on a [DownloadedThread] means "follow the global [copypartyAutoUpload] setting".
@HiveType(typeId: 54)
enum ThreadStoragePreference {
  /// Keep files on device only — never upload to Copyparty.
  @HiveField(0)
  localOnly,

  /// Upload to Copyparty and delete local copy after confirmation.
  @HiveField(1)
  remoteOnly,

  /// Upload to Copyparty but keep local copy as well.
  @HiveField(2)
  both,
}

@HiveType(typeId: 53)
enum ThreadStorageLocation {
  /// All files are stored on the local device.
  @HiveField(0)
  local,

  /// All files have been synced to Copyparty and deleted locally.
  @HiveField(1)
  remote,

  /// Partial sync — some files are local, some are on Copyparty.
  @HiveField(2)
  mixed,
}

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
  @HiveField(15)
  DateTime? pendingDeletionAt;
  @HiveField(16)
  ThreadStorageLocation? storageLocation;
  @HiveField(17)
  int? totalSizeBytes;
  @HiveField(18)
  ThreadStoragePreference? storagePreference;

  // Field 19: nullable per Hive evolution rule — null on old records = not locked.
  @HiveField(19)
  bool? _isLockedOnServer;
  /// Whether the thread was locked on the server at the time of last check.
  /// Old records (null) are treated as not locked.
  bool get isLockedOnServer => _isLockedOnServer ?? false;
  set isLockedOnServer(bool v) => _isLockedOnServer = v;
  /// Raw nullable value — null means the field has never been written (old record).
  /// Use [isLockedOnServer] for boolean comparisons.
  bool? get rawIsLockedOnServer => _isLockedOnServer;

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
    this.pendingDeletionAt,
    this.storageLocation = ThreadStorageLocation.local,
    this.totalSizeBytes,
    this.storagePreference,
    bool? isLockedOnServer,
  }) : _isLockedOnServer = isLockedOnServer;

  /// Returns the effective storage location, inferring from [syncedFiles] for
  /// records created before field 16 was added (they default to [local]).
  ThreadStorageLocation get effectiveStorageLocation {
    final loc = storageLocation ?? ThreadStorageLocation.local;
    if (loc == ThreadStorageLocation.local && syncedFiles > 0) {
      if (syncedFiles >= totalFiles && totalFiles > 0) {
        return ThreadStorageLocation.remote;
      }
      return ThreadStorageLocation.mixed;
    }
    return loc;
  }

  String get boxKey => '${imageboardKey}_${board}_$threadId';
  ThreadIdentifier get identifier => ThreadIdentifier(board, threadId);
}
