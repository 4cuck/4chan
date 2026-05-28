import 'package:chan/services/cloudflare.dart';
import 'package:chan/sites/imageboard_site.dart';
import 'package:dio/dio.dart';

Future<HCaptchaSolution> solveMegucaPostingCaptcha(
  ImageboardSite site,
  MegucaCaptchaRequest request, {
  CancelToken? cancelToken,
}) async {
  final uri = Uri.https(site.baseUrl, '/api/captcha/${request.board}');
  final token = await useCloudflareClearedWebview<String>(
    handler: (controller, url) async {
      for (var i = 0; i < 240; i++) {
        if (cancelToken?.isCancelled ?? false) {
          throw DioError(requestOptions: RequestOptions(path: uri.path), type: DioErrorType.cancel);
        }
        final payload = await controller.callAsyncJavaScript(functionBody: '''
          const ta = document.querySelector('[name="h-captcha-response"]');
          if (ta && ta.value) return ta.value;
          return null;
        ''');
        if (payload?.value case String s when s.isNotEmpty) {
          return s;
        }
        await Future.delayed(const Duration(milliseconds: 500));
      }
      throw Exception('Timed out waiting for hCaptcha on ${request.board}');
    },
    uri: uri,
    priority: RequestPriority.interactive,
    gatewayName: 'awoo.cf posting captcha',
    site: site,
    userAgent: site.userAgent,
    skipHeadless: true,
    cancelToken: cancelToken,
  );
  return HCaptchaSolution(token: token, acquiredAt: DateTime.now());
}
