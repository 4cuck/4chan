// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'downloaded_thread.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class DownloadedThreadFields {
  static String getImageboardKey(DownloadedThread x) => x.imageboardKey;
  static void setImageboardKey(DownloadedThread x, String v) =>
      x.imageboardKey = v;
  static const int kImageboardKey = 0;
  static const imageboardKey = HiveFieldAdapter<DownloadedThread, String>(
    getter: getImageboardKey,
    setter: setImageboardKey,
    fieldNumber: kImageboardKey,
    fieldName: 'imageboardKey',
    merger: PrimitiveMerger(),
  );
  static String getBoard(DownloadedThread x) => x.board;
  static void setBoard(DownloadedThread x, String v) => x.board = v;
  static const int kBoard = 1;
  static const board = HiveFieldAdapter<DownloadedThread, String>(
    getter: getBoard,
    setter: setBoard,
    fieldNumber: kBoard,
    fieldName: 'board',
    merger: PrimitiveMerger(),
  );
  static int getThreadId(DownloadedThread x) => x.threadId;
  static void setThreadId(DownloadedThread x, int v) => x.threadId = v;
  static const int kThreadId = 2;
  static const threadId = HiveFieldAdapter<DownloadedThread, int>(
    getter: getThreadId,
    setter: setThreadId,
    fieldNumber: kThreadId,
    fieldName: 'threadId',
    merger: PrimitiveMerger(),
  );
  static String? getTitle(DownloadedThread x) => x.title;
  static void setTitle(DownloadedThread x, String? v) => x.title = v;
  static const int kTitle = 3;
  static const title = HiveFieldAdapter<DownloadedThread, String?>(
    getter: getTitle,
    setter: setTitle,
    fieldNumber: kTitle,
    fieldName: 'title',
    merger: PrimitiveMerger(),
  );
  static String? getThumbnailUrl(DownloadedThread x) => x.thumbnailUrl;
  static void setThumbnailUrl(DownloadedThread x, String? v) =>
      x.thumbnailUrl = v;
  static const int kThumbnailUrl = 4;
  static const thumbnailUrl = HiveFieldAdapter<DownloadedThread, String?>(
    getter: getThumbnailUrl,
    setter: setThumbnailUrl,
    fieldNumber: kThumbnailUrl,
    fieldName: 'thumbnailUrl',
    merger: PrimitiveMerger(),
  );
  static DateTime getDownloadedAt(DownloadedThread x) => x.downloadedAt;
  static void setDownloadedAt(DownloadedThread x, DateTime v) =>
      x.downloadedAt = v;
  static const int kDownloadedAt = 5;
  static const downloadedAt = HiveFieldAdapter<DownloadedThread, DateTime>(
    getter: getDownloadedAt,
    setter: setDownloadedAt,
    fieldNumber: kDownloadedAt,
    fieldName: 'downloadedAt',
    merger: PrimitiveMerger(),
  );
  static DownloadStatus getStatus(DownloadedThread x) => x.status;
  static void setStatus(DownloadedThread x, DownloadStatus v) => x.status = v;
  static const int kStatus = 6;
  static const status = HiveFieldAdapter<DownloadedThread, DownloadStatus>(
    getter: getStatus,
    setter: setStatus,
    fieldNumber: kStatus,
    fieldName: 'status',
    merger: PrimitiveMerger(),
  );
  static int getTotalFiles(DownloadedThread x) => x.totalFiles;
  static void setTotalFiles(DownloadedThread x, int v) => x.totalFiles = v;
  static const int kTotalFiles = 7;
  static const totalFiles = HiveFieldAdapter<DownloadedThread, int>(
    getter: getTotalFiles,
    setter: setTotalFiles,
    fieldNumber: kTotalFiles,
    fieldName: 'totalFiles',
    merger: PrimitiveMerger(),
  );
  static int getDownloadedFiles(DownloadedThread x) => x.downloadedFiles;
  static void setDownloadedFiles(DownloadedThread x, int v) =>
      x.downloadedFiles = v;
  static const int kDownloadedFiles = 8;
  static const downloadedFiles = HiveFieldAdapter<DownloadedThread, int>(
    getter: getDownloadedFiles,
    setter: setDownloadedFiles,
    fieldNumber: kDownloadedFiles,
    fieldName: 'downloadedFiles',
    merger: PrimitiveMerger(),
  );
  static DateTime? getLastUpdatedAt(DownloadedThread x) => x.lastUpdatedAt;
  static void setLastUpdatedAt(DownloadedThread x, DateTime? v) =>
      x.lastUpdatedAt = v;
  static const int kLastUpdatedAt = 9;
  static const lastUpdatedAt = HiveFieldAdapter<DownloadedThread, DateTime?>(
    getter: getLastUpdatedAt,
    setter: setLastUpdatedAt,
    fieldNumber: kLastUpdatedAt,
    fieldName: 'lastUpdatedAt',
    merger: PrimitiveMerger(),
  );
  static int getSyncedFiles(DownloadedThread x) => x.syncedFiles;
  static void setSyncedFiles(DownloadedThread x, int v) => x.syncedFiles = v;
  static const int kSyncedFiles = 10;
  static const syncedFiles = HiveFieldAdapter<DownloadedThread, int>(
    getter: getSyncedFiles,
    setter: setSyncedFiles,
    fieldNumber: kSyncedFiles,
    fieldName: 'syncedFiles',
    merger: PrimitiveMerger(),
  );
  static DateTime? getLastSyncedAt(DownloadedThread x) => x.lastSyncedAt;
  static void setLastSyncedAt(DownloadedThread x, DateTime? v) =>
      x.lastSyncedAt = v;
  static const int kLastSyncedAt = 11;
  static const lastSyncedAt = HiveFieldAdapter<DownloadedThread, DateTime?>(
    getter: getLastSyncedAt,
    setter: setLastSyncedAt,
    fieldNumber: kLastSyncedAt,
    fieldName: 'lastSyncedAt',
    merger: PrimitiveMerger(),
  );
  static String? getErrorMessage(DownloadedThread x) => x.errorMessage;
  static void setErrorMessage(DownloadedThread x, String? v) =>
      x.errorMessage = v;
  static const int kErrorMessage = 12;
  static const errorMessage = HiveFieldAdapter<DownloadedThread, String?>(
    getter: getErrorMessage,
    setter: setErrorMessage,
    fieldNumber: kErrorMessage,
    fieldName: 'errorMessage',
    merger: PrimitiveMerger(),
  );
  static String? getLocalThumbnailFilename(DownloadedThread x) =>
      x.localThumbnailFilename;
  static void setLocalThumbnailFilename(DownloadedThread x, String? v) =>
      x.localThumbnailFilename = v;
  static const int kLocalThumbnailFilename = 13;
  static const localThumbnailFilename =
      HiveFieldAdapter<DownloadedThread, String?>(
    getter: getLocalThumbnailFilename,
    setter: setLocalThumbnailFilename,
    fieldNumber: kLocalThumbnailFilename,
    fieldName: 'localThumbnailFilename',
    merger: PrimitiveMerger(),
  );
  static bool getIsArchivedOnServer(DownloadedThread x) => x.isArchivedOnServer;
  static void setIsArchivedOnServer(DownloadedThread x, bool v) =>
      x.isArchivedOnServer = v;
  static const int kIsArchivedOnServer = 14;
  static const isArchivedOnServer = HiveFieldAdapter<DownloadedThread, bool>(
    getter: getIsArchivedOnServer,
    setter: setIsArchivedOnServer,
    fieldNumber: kIsArchivedOnServer,
    fieldName: 'isArchivedOnServer',
    merger: PrimitiveMerger(),
  );
  static DateTime? getPendingDeletionAt(DownloadedThread x) =>
      x.pendingDeletionAt;
  static void setPendingDeletionAt(DownloadedThread x, DateTime? v) =>
      x.pendingDeletionAt = v;
  static const int kPendingDeletionAt = 15;
  static const pendingDeletionAt =
      HiveFieldAdapter<DownloadedThread, DateTime?>(
    getter: getPendingDeletionAt,
    setter: setPendingDeletionAt,
    fieldNumber: kPendingDeletionAt,
    fieldName: 'pendingDeletionAt',
    merger: PrimitiveMerger(),
  );
}

class DownloadedThreadAdapter extends TypeAdapter<DownloadedThread> {
  const DownloadedThreadAdapter();

  static const int kTypeId = 52;

  @override
  final int typeId = kTypeId;

  @override
  final Map<int, ReadOnlyHiveFieldAdapter<DownloadedThread, dynamic>> fields =
      const {
    0: DownloadedThreadFields.imageboardKey,
    1: DownloadedThreadFields.board,
    2: DownloadedThreadFields.threadId,
    3: DownloadedThreadFields.title,
    4: DownloadedThreadFields.thumbnailUrl,
    5: DownloadedThreadFields.downloadedAt,
    6: DownloadedThreadFields.status,
    7: DownloadedThreadFields.totalFiles,
    8: DownloadedThreadFields.downloadedFiles,
    9: DownloadedThreadFields.lastUpdatedAt,
    10: DownloadedThreadFields.syncedFiles,
    11: DownloadedThreadFields.lastSyncedAt,
    12: DownloadedThreadFields.errorMessage,
    13: DownloadedThreadFields.localThumbnailFilename,
    14: DownloadedThreadFields.isArchivedOnServer,
    15: DownloadedThreadFields.pendingDeletionAt
  };

  @override
  DownloadedThread read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final List<dynamic> fields = List.filled(16, null);
    for (int i = 0; i < numOfFields; i++) {
      final int fieldId = reader.readByte();
      final dynamic value = reader.read();
      if (fieldId < fields.length) {
        fields[fieldId] = value;
      }
    }
    return DownloadedThread(
      imageboardKey: fields[0] as String,
      board: fields[1] as String,
      threadId: fields[2] as int,
      title: fields[3] as String?,
      thumbnailUrl: fields[4] as String?,
      downloadedAt: fields[5] as DateTime,
      status: fields[6] as DownloadStatus,
      totalFiles: fields[7] as int,
      downloadedFiles: fields[8] as int,
      lastUpdatedAt: fields[9] as DateTime?,
      syncedFiles: fields[10] as int,
      lastSyncedAt: fields[11] as DateTime?,
      errorMessage: fields[12] as String?,
      localThumbnailFilename: fields[13] as String?,
      isArchivedOnServer: fields[14] as bool? ?? false,
      pendingDeletionAt: fields[15] as DateTime?,
    );
  }

  @override
  void write(BinaryWriter writer, DownloadedThread obj) {
    writer
      ..writeByte(16)
      ..writeByte(0)
      ..write(obj.imageboardKey)
      ..writeByte(1)
      ..write(obj.board)
      ..writeByte(2)
      ..write(obj.threadId)
      ..writeByte(3)
      ..write(obj.title)
      ..writeByte(4)
      ..write(obj.thumbnailUrl)
      ..writeByte(5)
      ..write(obj.downloadedAt)
      ..writeByte(6)
      ..write(obj.status)
      ..writeByte(7)
      ..write(obj.totalFiles)
      ..writeByte(8)
      ..write(obj.downloadedFiles)
      ..writeByte(9)
      ..write(obj.lastUpdatedAt)
      ..writeByte(10)
      ..write(obj.syncedFiles)
      ..writeByte(11)
      ..write(obj.lastSyncedAt)
      ..writeByte(12)
      ..write(obj.errorMessage)
      ..writeByte(13)
      ..write(obj.localThumbnailFilename)
      ..writeByte(14)
      ..write(obj.isArchivedOnServer)
      ..writeByte(15)
      ..write(obj.pendingDeletionAt);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DownloadedThreadAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class DownloadStatusAdapter extends TypeAdapter<DownloadStatus> {
  const DownloadStatusAdapter();

  static const int kTypeId = 51;

  @override
  final int typeId = kTypeId;

  @override
  final Map<int, ReadOnlyHiveFieldAdapter<DownloadStatus, dynamic>> fields =
      const {};

  @override
  DownloadStatus read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return DownloadStatus.pending;
      case 1:
        return DownloadStatus.downloading;
      case 2:
        return DownloadStatus.complete;
      case 3:
        return DownloadStatus.failed;
      case 4:
        return DownloadStatus.updating;
      case 5:
        return DownloadStatus.cancelled;
      default:
        return DownloadStatus.pending;
    }
  }

  @override
  void write(BinaryWriter writer, DownloadStatus obj) {
    switch (obj) {
      case DownloadStatus.pending:
        writer.writeByte(0);
        break;
      case DownloadStatus.downloading:
        writer.writeByte(1);
        break;
      case DownloadStatus.complete:
        writer.writeByte(2);
        break;
      case DownloadStatus.failed:
        writer.writeByte(3);
        break;
      case DownloadStatus.updating:
        writer.writeByte(4);
        break;
      case DownloadStatus.cancelled:
        writer.writeByte(5);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DownloadStatusAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
