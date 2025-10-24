import 'package:dio/dio.dart';

class ScreenApi {
  final Dio _dio;
  ScreenApi(String baseOrigin)
      : _dio = Dio(BaseOptions(
          baseUrl: baseOrigin, // مثال: http://192.168.1.5:8000
          connectTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 20),
        ));

  Future<Map<String, dynamic>> getPlaylist({required String apiToken}) async {
    final r = await _dio.get(
      '/api/screen/v1/playlist',
      options: Options(headers: {'X-Screen-Token': apiToken}),
    );
    return Map<String, dynamic>.from(r.data);
  }
}
