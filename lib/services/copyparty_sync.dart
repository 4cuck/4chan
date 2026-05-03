import 'dart:io';

import 'package:dio/dio.dart';

enum CopyPartySyncResult { ok, authFailed, serverError, networkError }

class CopyPartySyncService {
	static late final CopyPartySyncService instance;

	static void initializeStatic() {
		instance = CopyPartySyncService._();
	}

	CopyPartySyncService._();

	final _dio = Dio();

	/// HTTP PUT a single file to CopyParty.
	///
	/// [remoteRelativePath] e.g. `/chan/4chan/gif/25512520/abc.jpg`
	/// Uses the `Pw:` custom header — never a ?pw= query param.
	Future<CopyPartySyncResult> putFile({
		required File file,
		required String remoteRelativePath,
		required String serverUrl,
		required String password,
	}) async {
		final base = serverUrl.endsWith('/') ? serverUrl.substring(0, serverUrl.length - 1) : serverUrl;
		// Ensure exactly one '/' between base and relative path regardless of caller
		final cleanPath = remoteRelativePath.startsWith('/') ? remoteRelativePath.substring(1) : remoteRelativePath;
		final url = '$base/$cleanPath';
		// Validate URL scheme before any network operation
		final parsedUrl = Uri.tryParse(url);
		if (parsedUrl == null || (!parsedUrl.isScheme('http') && !parsedUrl.isScheme('https'))) {
			print('[CopyParty] putFile: invalid URL scheme — url=$url');
			return CopyPartySyncResult.serverError;
		}
		print('[CopyParty] putFile: PUT $url (password=${password.isNotEmpty ? 'set' : 'empty'}, fileSize=${file.lengthSync()})');
		try {
			final response = await _dio.put(
				url,
				data: file.openRead(),
				options: Options(
					headers: {
						if (password.isNotEmpty) 'Pw': password,
						'Content-Type': 'application/octet-stream',
						'Content-Length': '${file.lengthSync()}',
					},
					receiveTimeout: 1800000,
					sendTimeout: 1800000,
				),
			);
			print('[CopyParty] putFile: response ${response.statusCode} for $url');
			if (response.statusCode == 401 || response.statusCode == 403) {
				return CopyPartySyncResult.authFailed;
			}
			if (response.statusCode != null &&
			    response.statusCode! >= 200 &&
			    response.statusCode! < 300) {
				return CopyPartySyncResult.ok;
			}
			return CopyPartySyncResult.serverError;
		} on DioError catch (e) {
			print('[CopyParty] putFile: DioError type=${e.type} status=${e.response?.statusCode} message=${e.message} error=${e.error}');
			if (e.response?.statusCode == 401 || e.response?.statusCode == 403) {
				return CopyPartySyncResult.authFailed;
			}
			if (e.response != null) {
				return CopyPartySyncResult.serverError;
			}
			return CopyPartySyncResult.networkError;
		}
	}
}
