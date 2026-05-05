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
	Future<CopyPartySyncResult> putFile({
		required File file,
		required String remoteRelativePath,
		required String serverUrl,
		required String password,
	}) async {
		final base = serverUrl.endsWith('/') ? serverUrl.substring(0, serverUrl.length - 1) : serverUrl;
		final cleanPath = remoteRelativePath.startsWith('/') ? remoteRelativePath.substring(1) : remoteRelativePath;
		final url = '$base/$cleanPath';
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

	/// HTTP DELETE a remote folder on CopyParty (best-effort, ignores 404).
	Future<CopyPartySyncResult> deleteFolder({
		required String remoteFolderPath,
		required String serverUrl,
		required String password,
	}) async {
		final base = serverUrl.endsWith('/') ? serverUrl.substring(0, serverUrl.length - 1) : serverUrl;
		final cleanPath = remoteFolderPath.startsWith('/') ? remoteFolderPath.substring(1) : remoteFolderPath;
		final cleanNoSlash = cleanPath.endsWith('/') ? cleanPath.substring(0, cleanPath.length - 1) : cleanPath;
		final url = '$base/$cleanNoSlash';
		final parsedUrl = Uri.tryParse(url);
		if (parsedUrl == null || (!parsedUrl.isScheme('http') && !parsedUrl.isScheme('https'))) {
			print('[CopyParty] deleteFolder: invalid URL — url=$url');
			return CopyPartySyncResult.serverError;
		}
		print('[CopyParty] deleteFolder: DELETE $url');
		try {
			final response = await _dio.delete(
				url,
				options: Options(
					headers: {
						if (password.isNotEmpty) 'Pw': password,
					},
				),
			);
			print('[CopyParty] deleteFolder: response ${response.statusCode}');
			if (response.statusCode == 401 || response.statusCode == 403) return CopyPartySyncResult.authFailed;
			if (response.statusCode == 404) return CopyPartySyncResult.ok;
			if (response.statusCode != null && response.statusCode! >= 200 && response.statusCode! < 300) return CopyPartySyncResult.ok;
			return CopyPartySyncResult.serverError;
		} on DioError catch (e) {
			print('[CopyParty] deleteFolder: DioError status=${e.response?.statusCode}');
			if (e.response?.statusCode == 404) return CopyPartySyncResult.ok;
			if (e.response?.statusCode == 401 || e.response?.statusCode == 403) return CopyPartySyncResult.authFailed;
			if (e.response != null) return CopyPartySyncResult.serverError;
			return CopyPartySyncResult.networkError;
		}
	}
}
