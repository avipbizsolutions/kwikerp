import 'dart:convert';

import 'package:http/http.dart' as http;

class ApiException implements Exception {
  ApiException(this.status, this.message);
  final int status;
  final String message;
  @override
  String toString() => message;
}

/// Thin client for the KwikERP API.
class Api {
  Api(this.baseUrl, {this.token});
  final String baseUrl; // e.g. https://erp.kwikerp.cloud/api
  String? token;

  Uri _u(String path) => Uri.parse('${baseUrl.replaceAll(RegExp(r'/+$'), '')}$path');

  Map<String, String> get _headers => {
        'content-type': 'application/json',
        if (token != null) 'authorization': 'Bearer $token',
      };

  Future<dynamic> _decode(http.Response r) async {
    final body = r.body.isEmpty ? null : jsonDecode(r.body);
    if (r.statusCode >= 200 && r.statusCode < 300) return body;
    final msg = body is Map && body['message'] != null ? body['message'].toString() : 'Server error ${r.statusCode}';
    throw ApiException(r.statusCode, msg);
  }

  Future<Map<String, dynamic>> login({
    required String tenantCode,
    required String phone,
    required String pin,
    required String deviceId,
  }) async {
    final r = await http
        .post(_u('/auth/login'),
            headers: _headers,
            body: jsonEncode({'tenantCode': tenantCode, 'phone': phone, 'pin': pin, 'deviceId': deviceId}))
        .timeout(const Duration(seconds: 20));
    return Map<String, dynamic>.from(await _decode(r) as Map);
  }

  Future<Map<String, dynamic>> pull(int since) async {
    final r = await http.get(_u('/sync/pull?since=$since'), headers: _headers).timeout(const Duration(seconds: 60));
    return Map<String, dynamic>.from(await _decode(r) as Map);
  }

  Future<void> push(Map<String, List<Map<String, dynamic>>> rows) async {
    final r = await http
        .post(_u('/sync/push'), headers: _headers, body: jsonEncode(rows))
        .timeout(const Duration(seconds: 60));
    await _decode(r);
  }

  Future<Map<String, dynamic>> cancelBill(String id, {required String reason, String? approverPhone, String? approverPin}) async {
    final r = await http
        .post(_u('/bills/$id/cancel'),
            headers: _headers,
            body: jsonEncode({
              'reason': reason,
              if (approverPhone != null) 'approverPhone': approverPhone,
              if (approverPin != null) 'approverPin': approverPin,
            }))
        .timeout(const Duration(seconds: 20));
    return Map<String, dynamic>.from(await _decode(r) as Map);
  }

  /// Newest tablet app on the server: {versionCode, path}. No login needed.
  Future<Map<String, dynamic>> appVersion() async {
    final r = await http.get(_u('/download/pos/version'), headers: _headers).timeout(const Duration(seconds: 15));
    return Map<String, dynamic>.from(await _decode(r) as Map);
  }
}
