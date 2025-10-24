import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

class MediaDownloader {
  MediaDownloader(this._dio);

  final Dio _dio;

  /// Returns absolute URL if [url] is relative.
  static String toAbsoluteUrl(String baseUrl, String url) {
    if (url.startsWith('http://') || url.startsWith('https://')) return url;
    if (baseUrl.endsWith('/') && url.startsWith('/')) {
      return baseUrl + url.substring(1);
    }
    if (!baseUrl.endsWith('/') && !url.startsWith('/')) {
      return '$baseUrl/$url';
    }
    return baseUrl + url;
  }

  /// Downloads a file and returns local file path.
  Future<String> downloadToCache(String absoluteUrl, {String? filename}) async {
    final dir = await getApplicationSupportDirectory();
    final mediaDir = Directory('${dir.path}/media');
    if (!await mediaDir.exists()) {
      await mediaDir.create(recursive: true);
    }

    final name = filename ??
        absoluteUrl.split('?').first.split('/').last; // crude but OK
    final savePath = '${mediaDir.path}/$name';

    // If file already exists, skip download
    final f = File(savePath);
    if (await f.exists() && (await f.length()) > 0) {
      return savePath;
    }

    await _dio.download(absoluteUrl, savePath);
    return savePath;
  }
}
