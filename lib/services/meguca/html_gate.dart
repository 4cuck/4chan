import 'dart:convert';

import 'package:chan/services/cloudflare.dart';
import 'package:chan/services/persistence.dart';
import 'package:chan/sites/imageboard_site.dart';
import 'package:dio/dio.dart';

/// Meguca HTML gate HttpOnly cookies (7-day lifetime after one successful proof).
/// See `/root/meguca/server/altcha_html_gate.go` and related gate cookie files.
const megucaHtmlGateCookieByKind = {
  'altcha': 'meguca_altcha_html',
  'hcaptcha': 'meguca_hcaptcha_html',
  'turnstile': 'meguca_turnstile_html',
  'cap': 'meguca_cap_html',
  'twister': 'meguca_twister_html',
  'gocaptcha': 'meguca_gocaptcha_html',
};

/// Returns true when the response is Meguca's unified HTML gate page (HTTP 403).
bool megucaResponseIsHtmlGate(Response<dynamic> response) {
  if (response.statusCode != 403) {
    return false;
  }
  final html = response.html;
  if (html == null) {
    return false;
  }
  return html.contains('id="captcha-html-gates-cfg"') || html.contains('id="gate-root"');
}

Map<String, dynamic>? megucaParseHtmlGateConfig(String html) {
  final match = RegExp(
    r'<script type="application/json" id="captcha-html-gates-cfg">([^<]+)</script>',
  ).firstMatch(html);
  if (match == null) {
    return null;
  }
  try {
    final parsed = jsonDecode(match.group(1)!);
    if (parsed is Map) {
      return parsed.cast<String, dynamic>();
    }
  } catch (_) {}
  return null;
}

bool megucaHtmlGatePageHtml(String html) {
  return html.contains('id="captcha-html-gates-cfg"') || html.contains('id="gate-root"');
}

/// True when every *active* HTML gate kind has its HttpOnly cookie in [cookieNames].
bool megucaHtmlGateCookiesSatisfied(
  Set<String> cookieNames,
  Map<String, dynamic> gateCfg,
) {
  for (final entry in megucaHtmlGateCookieByKind.entries) {
    if (gateCfg[entry.key] == true && !cookieNames.contains(entry.value)) {
      return false;
    }
  }
  return true;
}

Future<bool> megucaHtmlGateCookiesSatisfiedForSite(
  ImageboardSite site,
  Uri origin,
  Map<String, dynamic> gateCfg,
) async {
  final cookies = await Persistence.currentCookies.loadForRequest(origin);
  return megucaHtmlGateCookiesSatisfied(cookies.map((c) => c.name).toSet(), gateCfg);
}

/// Opens the gate page in a WebView. Meguca's bundled gate script solves captchas
/// and POSTs to `/api/captcha/html-gates`, which sets HttpOnly cookies once.
///
/// This is the ONLY path that ever opens a webview for awoo.cf. After it returns
/// the gate cookies live in [Persistence.currentCookies] for ~7 days and all
/// subsequent HTTP requests go through Dio.
Future<void> solveMegucaHtmlGate(ImageboardSite site, Uri gatePage, {CancelToken? cancelToken}) async {
  Map<String, dynamic>? gateCfg;
  await useCloudflareClearedWebview<void>(
    handler: (controller, url) async {
      for (var i = 0; i < 240; i++) {
        if (cancelToken?.isCancelled ?? false) {
          throw DioError(requestOptions: RequestOptions(path: gatePage.path), type: DioErrorType.cancel);
        }
        final webUri = await controller.getUrl();
        final currentUrl = url ?? (webUri != null ? Uri.parse(webUri.toString()) : null);
        if (currentUrl != null) {
          await Persistence.saveCookiesFromWebView(currentUrl);
        }
        final html = await controller.getHtml() ?? '';
        gateCfg ??= megucaParseHtmlGateConfig(html);
        if (!megucaHtmlGatePageHtml(html)) {
          return;
        }
        if (gateCfg != null &&
            currentUrl != null &&
            await megucaHtmlGateCookiesSatisfiedForSite(site, currentUrl, gateCfg!)) {
          return;
        }
        await Future.delayed(const Duration(milliseconds: 500));
        final nextWebUri = await controller.getUrl();
        url = nextWebUri != null ? Uri.parse(nextWebUri.toString()) : null;
      }
      throw Exception('Timed out waiting for awoo.cf HTML gate completion');
    },
    uri: gatePage,
    priority: RequestPriority.interactive,
    gatewayName: 'awoo.cf HTML gate',
    site: site,
    userAgent: site.userAgent,
    skipHeadless: true,
    cancelToken: cancelToken,
  );
  if (gateCfg != null) {
    await Persistence.saveCookiesFromWebView(gatePage);
  }
}

Future<Map<String, dynamic>> fetchMegucaPublicConfig(ImageboardSite site, {CancelToken? cancelToken}) async {
  final response = await site.client.getUri<Map>(
    Uri.https(site.baseUrl, '/json/config'),
    options: Options(responseType: ResponseType.json, extra: {kPriority: RequestPriority.functional}),
    cancelToken: cancelToken,
  );
  final data = response.data;
  if (data is Map) {
    return data.cast<String, dynamic>();
  }
  return {};
}
