import 'package:chan/services/persistence.dart';
import 'package:chan/services/util.dart';
import 'package:chan/sites/imageboard_site.dart';
import 'package:chan/sites/meguca.dart';
import 'package:dio/dio.dart';

/// Meguca's anti-abuse middleware (websockets/post_creation.go ::
/// validateAntiAbuseContext) returns a fake "range ban" 501 when any of
/// `clientTime`, `cssFingerprint`, or `perfHash` are missing. We send
/// stable, non-trivial values so the gate passes; the server hashes
/// these for shadow-ban tracking but a moderator could always add a
/// whitelist rule keyed on the same value if Chance traffic needs
/// special handling.
const String _kMegucaCssFingerprint = 'chanawoo';

/// Image allocation tokens from `/api/upload` are always 86 chars.
const int _kMegucaImageTokenLength = 86;

/// Returned by [megucaAuthenticatePostingCaptcha] so the caller can decide
/// whether to retry. Always thrown as an [AdditionalCaptchaRequiredException]
/// by the submit path when the server responds with `400 invalid input: captcha`.
class MegucaCaptchaRequiredException implements Exception {
  const MegucaCaptchaRequiredException();
}

/// Upload a file to Meguca's `/api/upload` endpoint and return the allocation
/// token. The token is bound to the `captcha_session` cookie, which must
/// be the same jar used when submitting the post.
Future<String> megucaUploadImageViaHttp({
  required SiteMeguca site,
  required String path,
  String? filename,
  required CancelToken cancelToken,
}) async {
  final name = filename ?? path.split(RegExp(r'[/\\]')).last;
  Response<String> response;
  try {
    response = await site.client.postUri<String>(
      Uri.https(site.baseUrl, '/api/upload'),
      data: FormData.fromMap({
        'image': await MultipartFile.fromFile(path, filename: name),
      }),
      options: Options(
        responseType: ResponseType.plain,
        validateStatus: (s) => s != null && s < 500,
        headers: {
          'origin': 'https://${site.baseUrl}',
          'referer': 'https://${site.baseUrl}/',
        },
        extra: {kPriority: RequestPriority.interactive},
      ),
      cancelToken: cancelToken,
    );
  } on DioError catch (e) {
    final inner = e.response;
    if (inner != null) {
      response = Response<String>(
        requestOptions: inner.requestOptions,
        statusCode: inner.statusCode,
        headers: inner.headers,
        data: inner.data?.toString(),
      );
    } else {
      rethrow;
    }
  }

  final status = response.statusCode ?? 0;
  final body = response.data?.trim() ?? '';
  if (status == 200 && body.length == _kMegucaImageTokenLength) {
    return body;
  }
  final lower = body.toLowerCase();
  if (status == 403 && lower.contains('captcha')) {
    throw const MegucaCaptchaRequiredException();
  }
  if (status == 403 && (lower.contains('banned') || lower.contains('ban'))) {
    throw BannedException(body.isNotEmpty ? body : 'You are banned from uploading', null);
  }
  throw PostFailedException(
    body.isNotEmpty ? body : 'awoo.cf rejected the image upload (HTTP $status)',
  );
}

/// Submits a post via Meguca's HTTP create-reply/create-thread endpoints.
/// New-user IPs would normally be rejected with a "post once via WebSocket"
/// 403 — we bypass that by sending the signed Chance User-Agent (see
/// [megucaChanceUserAgent]); the server verifies the HMAC signature and
/// waives the wall when the secret matches.
///
/// Images are uploaded to `/api/upload` first so the allocation token is
/// created under the same `captcha_session` cookie as the post request.
/// Sending the raw file inline on create-reply used to store tokens with an
/// empty session and fail with "invalid image token".
///
/// On HTTP 400 with body `invalid input: captcha`, throws
/// [MegucaCaptchaRequiredException] so the caller can solve the hCaptcha
/// widget and retry. The successful response is a 303 redirect; the post
/// ID is read from the `addMine` Set-Cookie value or, failing that, parsed
/// out of the `Location` header.
Future<PostReceipt> megucaSubmitPostViaHttp({
  required SiteMeguca site,
  required DraftPost post,
  String? hCaptchaToken,
  required CancelToken cancelToken,
}) async {
  final password = makeRandomBase64String(64);
  final name = post.name ?? '';
  final isThread = post.threadId == null;
  final endpoint = Uri.https(site.baseUrl, isThread ? '/api/create-thread' : '/api/create-reply');

  final fields = <String, dynamic>{
    'board': post.board,
    'body': post.text,
    'name': name,
    if (post.options == 'sage') 'sage': 'on',
    if (isThread) 'subject': post.subject ?? '',
    if (!isThread) 'op': post.threadId.toString(),
    'clientTime': DateTime.now().millisecondsSinceEpoch.toString(),
    // Anti-abuse triad: Meguca rejects with a fake range-ban 501 when any
    // of these are missing. `perfHash` must be 6 base36 chars and not a
    // trivial pattern (see isValidPerfHash on the server).
    'cssFingerprint': _kMegucaCssFingerprint,
    'perfHash': _megucaPerfHash(),
    if (hCaptchaToken != null && hCaptchaToken.isNotEmpty)
      'hCaptchaResponse': hCaptchaToken,
    if (post.spoiler == true) 'spoiler': 'on',
  };
  if (post.file case String path) {
    final filename = post.overrideFilename ?? path.split(RegExp(r'[/\\]')).last;
    final imageToken = await megucaUploadImageViaHttp(
      site: site,
      path: path,
      filename: filename,
      cancelToken: cancelToken,
    );
    fields['imageToken'] = imageToken;
    fields['imageName'] = filename;
  }

  Response<String> response;
  try {
    response = await site.client.postUri<String>(
      endpoint,
      data: FormData.fromMap(fields),
      options: Options(
        responseType: ResponseType.plain,
        followRedirects: false,
        validateStatus: (s) => s != null && s < 500,
        headers: {
          'origin': 'https://${site.baseUrl}',
          'referer': 'https://${site.baseUrl}/${post.board}/${isThread ? '' : '${post.threadId}'}',
        },
        extra: {kPriority: RequestPriority.interactive},
      ),
      cancelToken: cancelToken,
    );
  } on DioError catch (e) {
    final inner = e.response;
    if (inner != null) {
      response = Response<String>(
        requestOptions: inner.requestOptions,
        statusCode: inner.statusCode,
        headers: inner.headers,
        data: inner.data?.toString(),
      );
    } else {
      rethrow;
    }
  }

  final status = response.statusCode ?? 0;
  final body = response.data?.trim() ?? '';

  if (status == 303 || status == 302 || status == 301 || status == 200) {
    final id = _extractPostId(response, isThread: isThread);
    if (id == null) {
      throw PostFailedException('awoo.cf accepted the post but did not return a post ID');
    }
    return PostReceipt(
      id: id,
      password: password,
      name: name,
      options: post.options ?? '',
      time: DateTime.now(),
      post: post,
    );
  }

  final lower = body.toLowerCase();
  if (status == 400 && lower.contains('captcha')) {
    throw const MegucaCaptchaRequiredException();
  }
  if (status == 403 && (lower.contains('banned') || lower.contains('ban'))) {
    throw BannedException(body.isNotEmpty ? body : 'You are banned from this board', null);
  }
  throw PostFailedException(body.isNotEmpty ? body : 'awoo.cf rejected the post (HTTP $status)');
}

/// Authenticate a solved hCaptcha so subsequent replies on the same board
/// skip the "captcha required" gate. Returns the token so callers can also
/// include it inline (the thread-creation endpoint validates inline).
Future<void> megucaAuthenticatePostingCaptcha({
  required SiteMeguca site,
  required String board,
  required String hCaptchaToken,
  required CancelToken cancelToken,
}) async {
  final response = await site.client.postUri<String>(
    Uri.https(site.baseUrl, '/api/captcha/$board'),
    data: FormData.fromMap({'h-captcha-response': hCaptchaToken}),
    options: Options(
      responseType: ResponseType.plain,
      validateStatus: (s) => s != null && s < 500,
      extra: {kPriority: RequestPriority.interactive},
    ),
    cancelToken: cancelToken,
  );
  if (response.statusCode != 200 || (response.data?.trim() ?? '') != 'OK') {
    throw PostFailedException(
      'Captcha authentication failed: HTTP ${response.statusCode} ${response.data}',
    );
  }
}

/// Returns a 6-character base36 string derived from the device timezone
/// offset. Matches the perfHash the old WS client sent (websockets/
/// post_creation.go :: isValidPerfHash) and dodges all of the trivial
/// patterns the server rejects (000000, abcdef, etc.).
String _megucaPerfHash() {
  final tz = DateTime.now().timeZoneOffset.inMinutes;
  var h = tz.abs() * 12345 + 67890;
  h = (((h >> 16) ^ h) * 0x45d9f3b).abs();
  var hash = h.toRadixString(36).padLeft(6, '0');
  if (hash.length > 6) {
    hash = hash.substring(0, 6);
  }
  const trivial = {
    '000000', '111111', '222222', '333333', '444444',
    '555555', '666666', '777777', '888888', '999999',
    'aaaaaa', 'bbbbbb', 'cccccc', 'zzzzzz',
    '123456', 'abcdef', 'fedcba', '654321',
  };
  if (trivial.contains(hash)) {
    // Tweak the hash to avoid colliding with a banned pattern. The
    // server's trivial-pattern list is small enough that the simple
    // perturbation below will always land on a valid value.
    hash = 'p${hash.substring(0, 5)}';
  }
  return hash;
}

int? _extractPostId(Response<String> response, {required bool isThread}) {
  for (final raw in response.headers.map['set-cookie'] ?? const <String>[]) {
    final trimmed = raw.trimLeft();
    if (!trimmed.startsWith('addMine=')) continue;
    final eq = trimmed.indexOf('=');
    final semi = trimmed.indexOf(';', eq + 1);
    final value = semi < 0 ? trimmed.substring(eq + 1) : trimmed.substring(eq + 1, semi);
    final parsed = int.tryParse(value.trim());
    if (parsed != null) return parsed;
  }
  final location = response.headers.value('location') ?? response.headers.value('Location');
  if (location != null) {
    final match = RegExp(r'/([^/]+)/(\d+)(?:\?|#|$)').firstMatch(location);
    if (match != null) {
      final id = int.tryParse(match.group(2)!);
      if (id != null) return id;
    }
  }
  return null;
}
