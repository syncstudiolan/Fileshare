import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Shared File Share directory, deployed ONCE by the app publisher.
/// A user never needs to enter their Worker address on a second device.
/// The directory does not store passwords, Cloudflare tokens, or files.
/// The personal Worker validates the password; the directory only returns
/// that Worker's signed session on successful authentication.
class DirectoryLogin {
  const DirectoryLogin({
    required this.email, required this.workerUrl,
    required this.session, required this.expiresAt,
  });
  final String email, workerUrl, session;
  final int expiresAt;
}

class AccountDirectory {
  AccountDirectory._();
  static final AccountDirectory instance=AccountDirectory._();

  /// Set only in the official app build configuration after directory
  /// deployment. Never invent a cloud URL or use the user's personal Worker.
  static const String _configuredUrl=
    String.fromEnvironment('FILE_SHARE_DIRECTORY_URL',
      defaultValue:'https://fileshare-directory.modeltech0.workers.dev');

  Uri? get _host {
    if(_configuredUrl.isEmpty)return null;
    final url=Uri.tryParse(_configuredUrl);
    if(url==null||url.scheme!='https'||url.userInfo.isNotEmpty||
       url.hasPort||url.query.isNotEmpty||url.fragment.isNotEmpty||
       (url.path.isNotEmpty&&url.path!='/'))return null;
    return url;
  }
  bool get enabled=>_host!=null;

  Future<Map<String,dynamic>> _post(
      String path,Map<String,dynamic> values)async{
    final origin=_host;
    if(origin==null)throw StateError(
      'Email-only discovery is not active until the File Share directory is configured.');
    final client=http.Client();
    try {
      final response=await client.post(origin.resolve(path),headers:{
        'content-type':'application/json','accept':'application/json',
      },body:jsonEncode(values)).timeout(const Duration(seconds:28));
      dynamic payload;
      try{payload=jsonDecode(response.body);}
      catch(_){throw const FormatException('Unexpected directory response');}
      if(payload is! Map<String,dynamic>){
        throw const FormatException('Unexpected directory response');
      }
      if(response.statusCode<200||response.statusCode>=300||
         payload['ok']!=true){
        throw StateError(payload['error']?.toString()??
          'Directory request failed');
      }
      return payload;
    }on TimeoutException {
      throw StateError('Directory is unreachable. Check your internet connection.');
    }finally{client.close();}
  }

  /// The signed session proves the user already logged in on their own Worker.
  /// This binds the first account to its personal Worker. It does not verify mailbox ownership.
  Future<void> linkAccount({
    required String email,
    required String workerUrl,
    required String personalSession,
  })async{
    await _post('/v1/directory/claim',{
      'email':email.trim().toLowerCase(),
      'workerUrl':workerUrl,
      'personalSession':personalSession,
    });
  }

  /// The password travels only in an encrypted HTTPS request. It is NOT
  /// saved in central D1 or local preferences. On success, the directory
  /// proxies login to the user's private Worker.
  Future<DirectoryLogin> signIn(String email,String password)async{
    final response=await _post('/v1/directory/login',{
      'email':email.trim().toLowerCase(),
      'password':password,
    });
    final worker=response['workerUrl'],token=response['session'];
    final account=response['email'],expires=response['expiresAt'];
    if(worker is! String || token is! String ||
       account is! String || expires is! num ||
       expires.toInt()<=DateTime.now().millisecondsSinceEpoch){
      throw const FormatException('Directory sent an invalid cloud session');
    }
    return DirectoryLogin(
      workerUrl:worker,session:token,email:account,expiresAt:expires.toInt());
  }

  @visibleForTesting
  static String validateDirectoryUrl(String raw){
    final uri=Uri.tryParse(raw);
    if(uri==null||uri.scheme!='https'||uri.hasPort||
       uri.userInfo.isNotEmpty||uri.query.isNotEmpty||
       uri.fragment.isNotEmpty||!uri.host.contains('.')){
      throw const FormatException('HTTPS directory address required');
    }
    return uri.origin;
  }
}
