import 'package:chan/models/attachment.dart';
import 'package:chan/models/post.dart';
import 'package:chan/models/thread.dart';
import 'package:chan/pages/attachments.dart' show SliverStaggeredGridDelegate;
import 'package:chan/pages/gallery.dart';
import 'package:chan/widgets/adaptive.dart';
import 'package:chan/services/imageboard.dart';
import 'package:chan/services/media.dart';
import 'package:chan/services/settings.dart';
import 'package:chan/services/thread_downloader.dart'
    show ThreadDownloadService;
import 'package:chan/util.dart';
import 'package:chan/widgets/attachment_thumbnail.dart';
import 'package:chan/widgets/attachment_viewer.dart'
    show AttachmentViewerController, CurvedRectTween;
import 'package:chan/widgets/context_menu.dart';
import 'package:chan/widgets/post_spans.dart';
import 'package:chan/widgets/refreshable_list.dart';
import 'package:chan/widgets/reply_box.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

class QuiltGalleryPage extends StatefulWidget {
  final List<TaggedAttachment> attachments;
  final Map<Attachment, Uri> overrideSources;
  final Map<Attachment, Uri> initialGoodSources;
  final PostSpanZoneData? zone;
  final Map<Attachment, ImageboardScoped<Thread>> threads;
  final Map<Attachment, ImageboardScoped<Post>> posts;
  final ValueChanged<ImageboardScoped<Thread>>? onThreadSelected;
  final ReplyBoxZone? replyBoxZone;
  final TaggedAttachment? initialAttachment;
  final bool allowContextMenu;
  final ValueChanged<TaggedAttachment>? onChange;
  final List<ContextMenuAction> Function(TaggedAttachment)?
      additionalContextMenuActionsBuilder;

  const QuiltGalleryPage({
    required this.attachments,
    this.overrideSources = const {},
    this.initialGoodSources = const {},
    this.zone,
    this.threads = const {},
    this.posts = const {},
    this.onThreadSelected,
    this.replyBoxZone,
    this.initialAttachment,
    this.allowContextMenu = true,
    this.onChange,
    this.additionalContextMenuActionsBuilder,
    super.key,
  });

  @override
  State<QuiltGalleryPage> createState() => _QuiltGalleryPageState();
}

class _QuiltGalleryPageState extends State<QuiltGalleryPage> {
  late final RefreshableListController<TaggedAttachment> _controller;
  late final ValueNotifier<int> _metadataVersionNotifier;
  TaggedAttachment? _currentAttachment;
  bool _scanning = false;
  bool _openingAttachment = false;

  @override
  void initState() {
    super.initState();
    _controller = RefreshableListController();
    _metadataVersionNotifier = ValueNotifier(0);
    _currentAttachment = widget.initialAttachment;
    if (widget.initialAttachment != null) {
      Future.delayed(const Duration(milliseconds: 250), () {
        if (mounted) {
          _controller.animateTo(
            (a) => a.attachment.id == widget.initialAttachment!.attachment.id,
          );
        }
      });
    }
    _preScanMetadata();
  }

  /// Pre-populate [AttachmentViewerController.mediaMetadataCache] for
  /// all video attachments using:
  ///  1. In-memory cache (instant, no I/O)
  ///  2. Hive disk cache (fast, persisted across sessions)
  ///  3. Full ffprobe scan for locally downloaded files (once, then persisted)
  Future<void> _preScanMetadata() async {
    if (_scanning) return;
    _scanning = true;
    final downloader = ThreadDownloadService.instance;
    bool anyUpdate = false;
    try {
      for (final tagged in widget.attachments) {
        if (!tagged.attachment.type.usesVideoPlayer) continue;
        final url = tagged.attachment.url;
        if (AttachmentViewerController.mediaMetadataCache.containsKey(url)) {
          continue;
        }
        try {
          // 1. Check in-memory MediaScan cache synchronously
          final localFile = downloader.findDownloadedFile(tagged.attachment);
          if (localFile != null) {
            final fromMemory = MediaScan.peekCachedFileScan(localFile.path);
            if (fromMemory != null) {
              AttachmentViewerController.mediaMetadataCache[url] = (
                duration: fromMemory.duration,
                hasAudio: fromMemory.hasAudio,
              );
              anyUpdate = true;
              continue;
            }
            // 2. Check Hive disk cache
            final fromDisk = await MediaScan.cachedFileScan(localFile.path);
            if (fromDisk != null) {
              AttachmentViewerController.mediaMetadataCache[url] = (
                duration: fromDisk.duration,
                hasAudio: fromDisk.hasAudio,
              );
              anyUpdate = true;
              continue;
            }
            // 3. Full ffprobe scan for the local file (result is persisted to Hive)
            final scan = await MediaScan.scan(localFile.uri);
            AttachmentViewerController.mediaMetadataCache[url] = (
              duration: scan.duration,
              hasAudio: scan.hasAudio,
            );
            anyUpdate = true;
          }
        } catch (_) {
          // Skip silently — badge just won't show duration for this attachment
        }
      }
      if (anyUpdate && mounted) _metadataVersionNotifier.value++;
    } finally {
      _scanning = false;
    }
  }

  Future<void> _openAttachment(TaggedAttachment attachment) async {
    if (_openingAttachment) return;
    _openingAttachment = true;
    setState(() => _currentAttachment = attachment);
    final result =
        await Navigator.of(context, rootNavigator: true).push<Attachment>(
      adaptivePageRoute(
        builder: (ctx) => GalleryPage(
          attachments: widget.attachments,
          overrideSources: widget.overrideSources,
          initialGoodSources: widget.initialGoodSources,
          zone: widget.zone,
          threads: widget.threads,
          posts: widget.posts,
          onThreadSelected: widget.onThreadSelected,
          replyBoxZone: widget.replyBoxZone,
          initialAttachment: attachment,
          allowContextMenu: widget.allowContextMenu,
          allowPop: true,
          heroOtherEndIsBoxFitCover: true,
          useHeroDestinationWidget: false,
          showScrollSheet: false,
          initiallyShowChrome: true,
          onChange: (tagged) {
            _currentAttachment = tagged;
          },
          additionalContextMenuActionsBuilder:
              widget.additionalContextMenuActionsBuilder,
        ),
      ),
    );
    _openingAttachment = false;
    if (!mounted) return;
    final target = result != null
        ? widget.attachments.tryFirstWhere((a) => a.attachment == result)
        : _currentAttachment;
    setState(() {
      if (target != null) _currentAttachment = target;
    });
    widget.onChange?.call(_currentAttachment!);
    // Refresh cells to pick up any metadata populated while the video was playing
    _metadataVersionNotifier.value++;
    if (target != null) {
      _controller.animateTo((a) => a.attachment.id == target.attachment.id);
    }
  }

  Widget _buildCell(BuildContext context, TaggedAttachment attachment) {
    return ValueListenableBuilder<int>(
      valueListenable: _metadataVersionNotifier,
      builder: (context, _, __) => _buildCellContent(context, attachment),
    );
  }

  Widget _buildCellContent(BuildContext context, TaggedAttachment attachment) {
    final meta = AttachmentViewerController
        .mediaMetadataCache[attachment.attachment.url];
    final isVideo = attachment.attachment.type.usesVideoPlayer;
    final attachExt =
        attachment.attachment.ext.toLowerCase().replaceAll('.', '');
    final isGif = attachExt == 'gif';
    final showBadge = isVideo || isGif || meta != null;
    final icon = attachment.attachment.icon;
    return GestureDetector(
      onTap: () => _openAttachment(attachment),
      child: Hero(
        tag: attachment,
        createRectTween: (a, b) =>
            CurvedRectTween(curve: Curves.ease, begin: a, end: b),
        child: Stack(
          fit: StackFit.expand,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: HSVColor.fromAHSV(
                        1,
                        attachment.attachment.id.hashCode.toDouble() % 360,
                        0.5,
                        0.2)
                    .toColor(),
              ),
            ),
            AttachmentThumbnail(
              attachment: attachment.attachment,
              fit: BoxFit.cover,
              mayObscure: true,
              site: attachment.imageboard.site,
              hero: null,
            ),
            // Play/media-type indicator — mirrors the centered play button in attachments.dart
            if (icon != null)
              Positioned.fill(
                child: IgnorePointer(
                  child: Center(
                    child: Icon(
                      icon,
                      color: Colors.white.withValues(alpha: 0.80),
                      size: 32,
                    ),
                  ),
                ),
              ),
            if (showBadge)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _CellBadge(
                  icon: icon,
                  ext: (isVideo || isGif)
                      ? attachment.attachment.ext
                          .toUpperCase()
                          .replaceAll('.', '')
                      : null,
                  duration: meta?.duration,
                  hasAudio: meta?.hasAudio,
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _metadataVersionNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final maxCrossAxisExtent =
        Settings.attachmentsPageMaxCrossAxisExtentSetting.watch(context);
    return Scaffold(
      backgroundColor: Colors.black,
      body: RefreshableList<TaggedAttachment>(
        filterableAdapter: null,
        id: '${widget.attachments.tryFirst?.attachment.id}_${widget.attachments.tryLast?.attachment.id}_${widget.attachments.length}_quilt',
        controller: _controller,
        listUpdater: (_) => throw UnimplementedError(),
        disableUpdates: true,
        initialList: widget.attachments,
        gridDelegate: SliverStaggeredGridDelegate(
          aspectRatios: widget.attachments.map((a) {
            final rawRatio =
                (a.attachment.width ?? 1) / (a.attachment.height ?? 1);
            return rawRatio.clamp(1 / 6, 6.0);
          }).toList(),
          maxCrossAxisExtent: maxCrossAxisExtent,
        ),
        itemBuilder: (context, attachment, options) =>
            _buildCell(context, attachment),
      ),
    );
  }
}

class _CellBadge extends StatelessWidget {
  final IconData? icon;
  final String? ext;
  final Duration? duration;
  final bool? hasAudio;

  const _CellBadge({this.icon, this.ext, this.duration, this.hasAudio});

  static String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final parts = <String>[
      if (ext != null) ext!,
      if (duration != null) _formatDuration(duration!),
    ];
    final text = parts.join('  ');
    final showAudio = hasAudio == true;
    if (icon == null && text.isEmpty && !showAudio) {
      return const SizedBox.shrink();
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      color: Colors.black54,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, color: Colors.white, size: 10),
            if (text.isNotEmpty) const SizedBox(width: 3),
          ],
          if (text.isNotEmpty)
            Text(
              text,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.w600),
            ),
          if (showAudio) ...[
            if (text.isNotEmpty) const SizedBox(width: 3),
            const Icon(CupertinoIcons.speaker_2_fill,
                color: Colors.white, size: 10),
          ],
        ],
      ),
    );
  }
}
