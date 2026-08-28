import 'dart:async';

import 'package:chan/models/attachment.dart';
import 'package:chan/models/board.dart';
import 'package:chan/models/post.dart';
import 'package:chan/models/thread.dart';
import 'package:chan/services/meguca/html_gate.dart';
import 'package:chan/services/meguca/posting.dart';
import 'package:chan/services/meguca/user_agent.dart';
import 'package:chan/services/persistence.dart';
import 'package:chan/services/settings.dart';
import 'package:chan/sites/helpers/http_304.dart';
import 'package:chan/sites/imageboard_site.dart';
import 'package:chan/sites/util.dart';
import 'package:chan/util.dart';
import 'package:chan/widgets/post_spans.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart';

class SiteMeguca extends ImageboardSite with Http304CachingThreadMixin, Http304CachingCatalogMixin {
  SiteMeguca({
    required this.baseUrl,
    required this.name,
    String? imageUrl,
    this.defaultUsername = 'Anonymous',
    required super.overrideUserAgent,
    required super.addIntrospectedHeaders,
    required super.archives,
    required super.imageHeaders,
    required super.videoHeaders,
    required super.preferHttp3WithoutAltSvc,
    this.worksafeBoards = const {'c'},
  }) : _imageUrlOverride = imageUrl;

  @override
  final String baseUrl;
  final String? _imageUrlOverride;
  // Meguca serves attachments from the same host as the site itself. Host
  // matching (offline downloads, attachment-source detection) relies on
  // imageUrl being the media host, so default it to baseUrl when not provided.
  @override
  String? get imageUrl => _imageUrlOverride ?? baseUrl;
  @override
  final String name;
  @override
  final String defaultUsername;
  final Set<String> worksafeBoards;

  Map<int, String>? _extensions;

  String? _pendingPostCaptchaToken;

  static const megucaFileExtensions = {
    0: 'jpg',
    1: 'png',
    2: 'gif',
    3: 'webm',
    4: 'pdf',
    5: 'svg',
    6: 'mp4',
    7: 'mp3',
    8: 'ogg',
    9: 'zip',
    10: '7z',
    11: 'tar.gz',
    12: 'tar.xz',
    13: 'flac',
    14: '',
    15: 'txt',
    16: 'webp',
    17: 'rar',
    18: 'cbz',
    19: 'cbr',
    20: 'avif',
    21: 'swf',
  };

  @override
  String get siteType => 'meguca';

  @override
  String get siteData => baseUrl;

  @override
  bool get supportsPosting => true;

  @override
  String get userAgent => overrideUserAgent ?? megucaChanceUserAgent();

  @override
  Uri? get iconUrl => Uri.https(baseUrl, '/assets/favicons/default.ico');

  @override
  void initState() {
    super.initState();
    unawaited(_loadMegucaConfig());
  }

  Future<void> _loadMegucaConfig() async {
    try {
      await fetchMegucaPublicConfig(this);
      final extResponse = await client.getUri<Map>(
        Uri.https(baseUrl, '/json/extensions'),
        options: Options(responseType: ResponseType.json, extra: {kPriority: RequestPriority.functional}),
      );
      final raw = extResponse.data;
      if (raw is Map) {
        _extensions = raw.map((k, v) => MapEntry(int.parse(k.toString()), v.toString()));
      }
    } catch (e, st) {
      Future.error(e, st);
    }
  }

  String _extForFileType(int fileType) {
    return _extensions?[fileType] ?? megucaFileExtensions[fileType] ?? 'jpg';
  }

  static Map<int, ({String board, int threadId})> _parseMegucaLinks(dynamic ln, String defaultBoard) {
    if (ln is! List) {
      return const {};
    }
    final links = <int, ({String board, int threadId})>{};
    for (final raw in ln) {
      if (raw is! Map) {
        continue;
      }
      final postId = (raw['i'] as num?)?.toInt();
      final targetThreadId = (raw['o'] as num?)?.toInt();
      final linkBoard = raw['bd'] as String? ?? defaultBoard;
      if (postId != null && targetThreadId != null) {
        links[postId] = (board: linkBoard, threadId: targetThreadId);
      }
    }
    return links;
  }

  static PostQuoteLinkSpan _megucaQuoteLink({
    required String board,
    required int threadId,
    required int postId,
    required Map<int, ({String board, int threadId})> links,
  }) {
    final target = links[postId];
    if (target != null) {
      return PostQuoteLinkSpan(
        board: target.board,
        threadId: target.threadId,
        postId: postId,
      );
    }
    return PostQuoteLinkSpan(board: board, threadId: threadId, postId: postId);
  }

  static PostNodeSpan makeSpan(
    String board,
    int threadId,
    String htmlBody, {
    Map<int, ({String board, int threadId})> links = const {},
  }) {
    final body = parseFragment(htmlBody);
    int spoilerSpanId = 0;

    Iterable<PostSpan> visit(Iterable<dom.Node> nodes) sync* {
      var addLinebreakBefore = false;
      for (final node in nodes) {
        if (addLinebreakBefore) {
          yield const PostLineBreakSpan();
          addLinebreakBefore = false;
        }
        if (node is dom.Element) {
          if (node.localName == 'br') {
            addLinebreakBefore = true;
          } else if (node.localName == 'a' && node.classes.contains('post-link')) {
            final id = int.tryParse(node.attributes['data-id'] ?? '') ??
                int.tryParse(RegExp(r'#p(\d+)').firstMatch(node.attributes['href'] ?? '')?.group(1) ?? '');
            final href = node.attributes['href'] ?? '';
            if (id != null) {
              final fromLinks = links[id];
              if (fromLinks != null) {
                yield PostQuoteLinkSpan(
                  board: fromLinks.board,
                  threadId: fromLinks.threadId,
                  postId: id,
                );
              } else if (href.startsWith('/') && href.contains('/')) {
                final parts = href.split('/').where((s) => s.isNotEmpty).toList(growable: false);
                if (parts.length >= 2 && parts[0] != board) {
                  yield PostQuoteLinkSpan(
                    board: parts[0],
                    threadId: int.tryParse(parts[1]) ?? threadId,
                    postId: id,
                  );
                } else {
                  yield PostQuoteLinkSpan(board: board, threadId: threadId, postId: id);
                }
              } else {
                yield PostQuoteLinkSpan(board: board, threadId: threadId, postId: id);
              }
            } else {
              yield PostLinkSpan(href, name: node.text.nonEmptyOrNull);
            }
          } else if (node.localName == 'a') {
            yield PostLinkSpan(node.attributes['href'] ?? '', name: node.text.nonEmptyOrNull);
          } else if (node.localName == 'em') {
            yield PostQuoteSpan(PostNodeSpan(visit(node.nodes).toList(growable: false)));
          } else if (node.localName == 'b') {
            yield PostBoldSpan(PostNodeSpan(visit(node.nodes).toList(growable: false)));
          } else if (node.localName == 'i') {
            yield PostItalicSpan(PostNodeSpan(visit(node.nodes).toList(growable: false)));
          } else if (node.localName == 'span' && node.classes.contains('spoiler')) {
            yield PostSpoilerSpan(PostNodeSpan(visit(node.nodes).toList(growable: false)), spoilerSpanId++);
          } else if (node.localName == 'blockquote') {
            yield PostQuoteSpan(PostNodeSpan(visit(node.nodes).toList(growable: false)));
          } else {
            yield* visit(node.nodes);
          }
        } else if (node.text != null && node.text!.isNotEmpty) {
          yield* parsePlainMegucaText(
            node.text!,
            board: board,
            threadId: threadId,
            links: links,
          );
        }
      }
    }

    return PostNodeSpan(visit(body.nodes).toList(growable: false));
  }

  // Matches >>POSTID (with optional extra leading '>') and >>>/board/[POSTID]
  // anywhere inside a line, mirroring meguca/templates/body.go's linkRegexp
  // and referenceRegexp. The server only emits `<a class="post-link">` when
  // the referenced post is loaded in the same thread context, so cross-thread
  // and stale references arrive as raw text and we have to linkify them here.
  static final _quoteLinkPattern = RegExp(r'>>(>?)(\d+)\b');
  static final _crossBoardPattern = RegExp(r'>>>(>?)\/(\w+)\/(\d+)?');

  static Iterable<PostSpan> parsePlainMegucaText(
    String text, {
    required String board,
    required int threadId,
    Map<int, ({String board, int threadId})> links = const {},
  }) sync* {
    final lines = text.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      // A "greentext" line (starts with `>` but not `>>N` or `>>>/`). Real
      // post links use `>>` and we don't want to wrap those in a quote span.
      final isGreentext = line.startsWith('>') && !line.startsWith('>>');
      final spans = _linkifyLine(
        line,
        board: board,
        threadId: threadId,
        links: links,
      ).toList(growable: false);
      if (spans.isEmpty) {
        // empty line
      } else if (isGreentext) {
        yield PostQuoteSpan(PostNodeSpan(spans));
      } else {
        yield* spans;
      }
      if (i != lines.length - 1) {
        yield const PostLineBreakSpan();
      }
    }
  }

  static Iterable<PostSpan> _linkifyLine(
    String line, {
    required String board,
    required int threadId,
    Map<int, ({String board, int threadId})> links = const {},
  }) sync* {
    if (line.isEmpty) return;
    var cursor = 0;
    // Track the running list of segments. We scan for both link kinds and
    // emit whichever appears first at each position so >>>/board/123 doesn't
    // get eaten as `>>` + `>/board/123`.
    while (cursor < line.length) {
      final remainder = line.substring(cursor);
      final crossMatch = _crossBoardPattern.firstMatch(remainder);
      final quoteMatch = _quoteLinkPattern.firstMatch(remainder);

      int? nextStart;
      bool isCross = false;
      if (crossMatch != null && (quoteMatch == null || crossMatch.start <= quoteMatch.start)) {
        nextStart = crossMatch.start;
        isCross = true;
      } else if (quoteMatch != null) {
        nextStart = quoteMatch.start;
      }

      if (nextStart == null) {
        yield PostTextSpan(remainder);
        return;
      }

      if (nextStart > 0) {
        yield PostTextSpan(remainder.substring(0, nextStart));
      }

      if (isCross) {
        final m = crossMatch!;
        final boardName = m.group(2)!;
        final postId = int.tryParse(m.group(3) ?? '');
        if (postId != null) {
          yield PostQuoteLinkSpan(board: boardName, threadId: postId, postId: postId);
        } else {
          yield PostBoardLinkSpan(boardName);
        }
        cursor += m.end;
      } else {
        final m = quoteMatch!;
        final postId = int.parse(m.group(2)!);
        yield _megucaQuoteLink(
          board: board,
          threadId: threadId,
          postId: postId,
          links: links,
        );
        cursor += m.end;
      }
    }
  }

  Post parseMegucaPost(Map<String, dynamic> data, {required String board, required int threadId, required bool isOp}) {
    final id = (data['i'] as num).toInt();
    final time = DateTime.fromMillisecondsSinceEpoch(((data['t'] as num).toInt()) * 1000, isUtc: true).toLocal();
    final name = [data['n'], data['tr']].whereType<String>().where((s) => s.isNotEmpty).join('');
    final body = data['b'] as String? ?? '';
    final posterId = data['pid'] as String?;
    final links = _parseMegucaLinks(data['ln'], board);
    final post = Post(
      board: board,
      text: body,
      name: name.isEmpty ? defaultUsername : name,
      time: time,
      threadId: threadId,
      id: id,
      posterId: posterId,
      spanFormat: PostSpanFormat.jsChan,
      attachments_: _parseImage(data['im'], board, threadId, id),
    );
    post.setSpan(makeSpan(board, threadId, body, links: links));
    return post;
  }

  Post rebuildPostText(Post source, String text) {
    final post = Post(
      board: source.board,
      text: text,
      name: source.name,
      time: source.time,
      threadId: source.threadId,
      id: source.id,
      posterId: source.posterId,
      spanFormat: source.spanFormat,
      flag: source.flag,
      attachmentDeleted: source.attachmentDeleted,
      trip: source.trip,
      passSinceYear: source.passSinceYear,
      capcode: source.capcode,
      attachments_: source.attachments_,
      upvotes: source.upvotes,
      parentId: source.parentId,
      hasOmittedReplies: source.hasOmittedReplies,
      isDeleted: source.isDeleted,
      ipNumber: source.ipNumber,
      archiveName: source.archiveName,
      email: source.email,
    );
    post.setSpan(makeSpan(source.board, source.threadId, text));
    post.replyIds = List.of(source.replyIds);
    return post;
  }

  List<Attachment> _parseImage(dynamic im, String board, int threadId, int postId) {
    if (im is! Map) {
      return const [];
    }
    final sha1 = im['sha1'] as String?;
    if (sha1 == null || sha1.isEmpty) {
      return const [];
    }
    final fileType = (im['file_type'] as num?)?.toInt() ?? 0;
    final rawExt = _extForFileType(fileType);
    if (rawExt.isEmpty) {
      // NoFile (or an unknown type with no extension) - nothing to attach.
      return const [];
    }
    // Meguca stores `name` WITHOUT its extension and derives the real extension
    // from file_type. The rest of the app (modeled on 4chan) expects
    // Attachment.ext to include the leading dot and the filename to end with it,
    // so saving/downloading produces a valid "name.ext".
    final ext = '.$rawExt';
    final rawName = (im['name'] as String?)?.trim();
    final filename = (rawName != null && rawName.isNotEmpty) ? '$rawName$ext' : '$sha1$ext';
    final dims = im['dims'];
    int? width;
    int? height;
    if (dims is List && dims.length >= 2) {
      width = (dims[0] as num?)?.toInt();
      height = (dims[1] as num?)?.toInt();
    }
    final spoiler = im['spoiler'] == true;
    final type = AttachmentType.fromFilename('x$ext');
    return [
      Attachment(
        board: board,
        ext: ext,
        filename: filename,
        id: sha1,
        type: type,
        url: Uri.https(baseUrl, '/assets/images/src/$sha1$ext').toString(),
        thumbnailUrl: Uri.https(baseUrl, '/assets/images/thumb/$sha1.webp').toString(),
        width: width,
        height: height,
        spoiler: spoiler,
        md5: (im['md5'] as String?) ?? sha1,
        threadId: threadId,
        sizeInBytes: (im['size'] as num?)?.toInt(),
      ),
    ];
  }

  Thread _parseThreadMap(Map<String, dynamic> data, String board) {
    final threadId = (data['i'] as num).toInt();
    final op = parseMegucaPost(data, board: board, threadId: threadId, isOp: true);
    final replies = <Post>[];
    if (data['ps'] is List) {
      for (final raw in data['ps'] as List) {
        if (raw is Map) {
          replies.add(parseMegucaPost(Map<String, dynamic>.from(raw), board: board, threadId: threadId, isOp: false));
        }
      }
    }
    replies.sort((a, b) => a.id.compareTo(b.id));
    return Thread(
      board: board,
      id: threadId,
      isLocked: data['lk'] == true,
      isSticky: data['st'] == true,
      posts_: [op, ...replies],
      replyCount: (data['pc'] as num?)?.toInt() ?? replies.length,
      imageCount: (data['ic'] as num?)?.toInt() ?? replies.where((p) => p.attachments.isNotEmpty).length,
      title: data['su'] as String?,
      time: op.time,
      attachments: op.attachments_,
      lastUpdatedTime: DateTime.fromMillisecondsSinceEpoch((((data['ut'] as num?) ?? data['t'] as num).toInt()) * 1000, isUtc: true).toLocal(),
    );
  }

  @override
  Future<List<ImageboardBoard>> getBoards({required RequestPriority priority, CancelToken? cancelToken}) async {
    final response = await client.getUri<List>(
      Uri.https(baseUrl, '/json/board-list'),
      options: Options(responseType: ResponseType.json, extra: {kPriority: RequestPriority.functional}),
      cancelToken: cancelToken,
    );
    final list = response.data ?? const [];
    return [
      for (final raw in list)
        if (raw is Map)
          ImageboardBoard(
            name: raw['id'] as String,
            title: raw['title'] as String? ?? raw['id'] as String,
            isWorksafe: worksafeBoards.contains(raw['id']),
            webmAudioAllowed: true,
            // Meguca accepts a single attachment per post.
            filesPerPost: 1,
          ),
    ];
  }

  @override
  @protected
  RequestOptions getThreadRequest(ThreadIdentifier thread, {ThreadVariant? variant, bool liveRefresh = false}) {
    final lastN = Settings.instance.megucaThreadLastN;
    return RequestOptions(
      path: '/json/boards/${thread.board}/${thread.id}',
      baseUrl: 'https://$baseUrl',
      method: 'GET',
      responseType: ResponseType.json,
      queryParameters: {
        if (lastN > 0) 'last': lastN.toString(),
      },
      extra: {kPriority: RequestPriority.functional},
    );
  }

  @override
  @protected
  Future<Thread> makeThread(ThreadIdentifier thread, Response response, {ThreadVariant? variant, required RequestPriority priority, CancelToken? cancelToken}) async {
    final data = Map<String, dynamic>.from(response.data as Map);
    return _parseThreadMap(data, thread.board);
  }

  @override
  @protected
  RequestOptions getCatalogRequest(String board, {CatalogVariant? variant}) {
    return RequestOptions(
      path: '/json/boards/$board/catalog',
      baseUrl: 'https://$baseUrl',
      method: 'GET',
      responseType: ResponseType.json,
      extra: {kPriority: RequestPriority.functional},
    );
  }

  @override
  @protected
  Future<List<Thread>> makeCatalog(String board, Response response, {CatalogVariant? variant, required RequestPriority priority, CancelToken? cancelToken}) async {
    final data = response.data as Map;
    final threads = data['ts'] as List? ?? const [];
    return [
      for (final raw in threads)
        if (raw is Map) _parseThreadMap(Map<String, dynamic>.from(raw), board),
    ];
  }

  @override
  bool decodeUrlPossible(Uri url) {
    if (url.host != baseUrl) {
      return false;
    }
    final segments = url.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty) {
      return false;
    }
    if (segments.length == 1) {
      return true;
    }
    if (segments.length == 2 && int.tryParse(segments[1]) != null) {
      return true;
    }
    if (segments.length == 2 && segments[1] == 'catalog') {
      return true;
    }
    if (segments[0] == 'all' && segments.length == 2 && int.tryParse(segments[1]) != null) {
      return true;
    }
    return false;
  }

  @override
  Future<BoardThreadOrPostIdentifier?> decodeUrl(Uri url, {CancelToken? cancelToken}) async {
    if (!decodeUrlPossible(url)) {
      return null;
    }
    final segments = url.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.length == 1) {
      return BoardThreadOrPostIdentifier(segments[0]);
    }
    if (segments.length == 2 && segments[1] == 'catalog') {
      return BoardThreadOrPostIdentifier(segments[0]);
    }
    if (segments[0] == 'all' && segments.length == 2) {
      final threadId = int.tryParse(segments[1]);
      if (threadId != null) {
        return BoardThreadOrPostIdentifier('all', threadId, ['', 'p'].tryMapOnce(url.fragment.extractPrefixedInt));
      }
    }
    if (segments.length == 2) {
      final threadId = int.tryParse(segments[1]);
      if (threadId != null) {
        return BoardThreadOrPostIdentifier(segments[0], threadId, ['', 'p'].tryMapOnce(url.fragment.extractPrefixedInt));
      }
    }
    return null;
  }

  @override
  String getWebUrlImpl(String board, [int? threadId, int? postId]) {
    if (postId != null && threadId != null) {
      // Meguca links to posts with a `#pN` fragment (see client/posts/render/etc.ts),
      // which is also what decodeUrl parses. Emitting `?p=N` here silently dropped
      // the post id on the round-trip, so shared links didn't jump to the post.
      return 'https://$baseUrl/$board/$threadId#p$postId';
    }
    if (threadId != null) {
      return 'https://$baseUrl/$board/$threadId';
    }
    return 'https://$baseUrl/$board/';
  }

  @override
  Future<CaptchaRequest> getCaptchaRequest(String board, int? threadId, {CancelToken? cancelToken}) async {
    // Meguca decides per-post captcha server-side (spam score / recent solves).
    // We let `submitPost` handle the round-trip — see meguca client posting/model.ts.
    return const NoCaptchaRequest();
  }

  @override
  Future<PostReceipt> submitPost(DraftPost post, CaptchaSolution captchaSolution, CancelToken cancelToken) async {
    final captchaToken = switch (captchaSolution) {
      HCaptchaSolution(:final token) => token,
      _ => _pendingPostCaptchaToken,
    };
    try {
      final receipt = await megucaSubmitPostViaHttp(
        site: this,
        post: post,
        hCaptchaToken: captchaToken,
        cancelToken: cancelToken,
      );
      _pendingPostCaptchaToken = null;
      return receipt;
    } on MegucaCaptchaRequiredException {
      throw AdditionalCaptchaRequiredException(
        captchaRequest: MegucaCaptchaRequest(board: post.board),
        onSolved: (solution, tokenCancel) async {
          if (solution is! HCaptchaSolution) {
            return;
          }
          _pendingPostCaptchaToken = solution.token;
          // For replies the captcha is authenticated separately so the server
          // marks this session as "captcha solved". Thread creation validates
          // the same token inline, so this call is harmless either way.
          await megucaAuthenticatePostingCaptcha(
            site: this,
            board: post.board,
            hCaptchaToken: solution.token,
            cancelToken: tokenCancel,
          );
        },
      );
    }
  }

  @override
  bool get supportsWebPostingFallback => true;
}
