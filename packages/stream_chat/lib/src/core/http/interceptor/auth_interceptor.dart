import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:stream_chat/src/core/api/responses.dart';
import 'package:stream_chat/src/core/error/error.dart';
import 'package:stream_chat/src/core/http/stream_chat_dio_error.dart';
import 'package:stream_chat/src/core/http/stream_http_client.dart';
import 'package:stream_chat/src/core/http/token.dart';
import 'package:stream_chat/src/core/http/token_manager.dart';

/// Authentication interceptor that refreshes the token if
/// an auth error is received
class AuthInterceptor extends QueuedInterceptor {
  /// Initialize a new auth interceptor
  AuthInterceptor(this._client, this._tokenManager);

  final StreamHttpClient _client;

  /// The token manager used in the client
  final TokenManager _tokenManager;

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    late Token token;
    try {
      token = await _tokenManager.loadToken();
    } catch (_) {
      final error = StreamChatNetworkError(ChatErrorCode.undefinedToken);
      final dioError = StreamChatDioError(
        error: error,
        requestOptions: options,
      );
      return handler.reject(dioError, true);
    }
    final params = {'user_id': token.userId};
    final headers = {
      'Authorization': token.rawValue,
      'stream-auth-type': token.authType.name,
    };
    options
      ..queryParameters.addAll(params)
      ..headers.addAll(headers);
    return handler.next(options);
  }

  @override
  void onError(
    DioException exception,
    ErrorInterceptorHandler handler,
  ) async {
    Map<String, dynamic>? data;

    /// If JWT is expired, we are getting a string as response data.
    /// The reason is the `content-type` of the header is `text/plain` instead of `application/json`.
    /// `data` in this case is a string like this:
    /// `"{"code": 40, "message": "QueryChannels failed with error: \"JWAuth error: token is expired (exp)\"", "StatusCode": 401, "duration":`
    if (exception.response?.data is String) {
      try {
        data = jsonDecode(exception.response?.data);
      } catch (_) {
        data = null;
      }
    } else {
      data = exception.response?.data;
    }

    /// No need to check if `data is! Map<String, dynamic>` anymore.
    if (data == null) {
      return handler.next(exception);
    }

    final error = ErrorResponse.fromJson(data);
    if (error.code == ChatErrorCode.tokenExpired.code) {
      if (_tokenManager.isStatic) return handler.next(exception);
      await _tokenManager.loadToken(refresh: true);
      try {
        final options = exception.requestOptions;
        final response = await _client.fetch(options);
        return handler.resolve(response);
      } on DioException catch (exception) {
        return handler.next(exception);
      }
    }
    return handler.next(exception);
  }
}
