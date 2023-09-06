import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:firebase_performance/firebase_performance.dart';

/// [Dio] client interceptor that hooks into request/response process
/// and calls Firebase Metric API in between. The request key is calculated
/// based upon [extra] field hash code which appears to be the same across
/// [onRequest], [onResponse] and [onError] calls.
///
/// Additionally there is no good API of obtaining content length from interceptor
/// API so we're "approximating" the byte length based on headers & request data.
/// If you're not fine with this, you can provide your own implementation in the constructor
///
/// This interceptor might be counting parsing time into elapsed API call duration.
/// I am not fully aware of [Dio] internal architecture.
class DioFirebasePerformanceInterceptor extends Interceptor {
  DioFirebasePerformanceInterceptor({
    this.requestContentLengthMethod = defaultRequestContentLength,
    this.responseContentLengthMethod = defaultResponseContentLength,
    this.keyMethod = defaultRequestKey,
  });

  /// key: requestKey, value: ongoing metric
  final _map = <Object?, HttpMetric>{};
  final RequestContentLengthMethod requestContentLengthMethod;
  final ResponseContentLengthMethod responseContentLengthMethod;
  final RequestKeyMethod keyMethod;
  static const extraKey = '_firebase_performance_key';
  final _random = Random();
  static const _maxKeyValue = 1<<32;

  @override
  void onRequest(
      RequestOptions options, RequestInterceptorHandler handler) async {
    try {
      final metric = FirebasePerformance.instance.newHttpMetric(
          options.uri.normalized(), options.method.asHttpMethod()!);

      options.extra[extraKey] = _random.nextInt(_maxKeyValue);
      final requestKey = keyMethod(options);
      _map[requestKey] = metric;
      final requestContentLength = requestContentLengthMethod(options);
      metric.start();
      if (requestContentLength != null)
        metric.requestPayloadSize = requestContentLength;
    } catch (_) {}
    return super.onRequest(options, handler);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) async {
    try {
      final requestKey = keyMethod(response.requestOptions);
      final metric = _map[requestKey];
      metric!.setResponse(response, responseContentLengthMethod);
      metric.stop();
      _map.remove(requestKey);
    } catch (_) {}
    return super.onResponse(response, handler);
  }

  @override
  Future onError(DioException err, ErrorInterceptorHandler handler) async {
    try {
      final requestKey = keyMethod(err.requestOptions);
      final metric = _map[requestKey];
      metric!.setResponse(err.response, responseContentLengthMethod);
      metric.stop();
      _map.remove(requestKey);
    } catch (_) {}
    return super.onError(err, handler);
  }

  static int? defaultRequestKey(RequestOptions options) {
    return options.extra[extraKey];
  }
}

typedef RequestContentLengthMethod = int? Function(RequestOptions options);

int? defaultRequestContentLength(RequestOptions options) {
  if (options.data is String || options.data is Map || options.data is List) {
    try {
      return jsonEncode(options.headers).length +
          (options.data == null ? 0 : jsonEncode(options.data).length);
    } catch (_) {}
  }
  return null;
}

typedef ResponseContentLengthMethod = int? Function(Response options);

int? defaultResponseContentLength(Response response) {
  if (response.data is String ||
      response.data is Map ||
      response.data is List) {
    try {
      return jsonEncode(response.data).length +
          jsonEncode(response.headers).length;
    } catch (_) {}
  }
  return null;
}

typedef RequestKeyMethod = Object? Function(RequestOptions options);

extension _ResponseHttpMetric on HttpMetric {
  void setResponse(Response? value,
      ResponseContentLengthMethod responseContentLengthMethod) {
    if (value == null) {
      return;
    }
    final responseContentLength = responseContentLengthMethod(value);
    if (responseContentLength != null)
      responsePayloadSize = responseContentLength;
    final contentType = value.headers.value.call(Headers.contentTypeHeader);
    if (contentType != null) responseContentType = contentType;
    if (value.statusCode != null) httpResponseCode = value.statusCode;
  }
}

extension _UriHttpMethod on Uri {
  String normalized() {
    return "$scheme://$host$path";
  }
}

extension _StringHttpMethod on String {
  HttpMethod? asHttpMethod() {
    switch (toUpperCase()) {
      case "POST":
        return HttpMethod.Post;
      case "GET":
        return HttpMethod.Get;
      case "DELETE":
        return HttpMethod.Delete;
      case "PUT":
        return HttpMethod.Put;
      case "PATCH":
        return HttpMethod.Patch;
      case "OPTIONS":
        return HttpMethod.Options;
      default:
        return null;
    }
  }
}
