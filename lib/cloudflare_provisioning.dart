import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

/// One-time setup within the END USER'S Cloudflare account.
/// The Cloudflare API token is NEVER saved. Existing unknown Workers are
/// never overwritten. Only user action starts this provisioning transaction.
class CloudProvisioningResult {
  const CloudProvisioningResult(this.workerUrl,this.ownerSecret);
  final String workerUrl,ownerSecret;
}
class CloudflareProvisioner extends ChangeNotifier {
  CloudflareProvisioner({http.Client? client}):_client=client??http.Client();
  final http.Client _client;
  static const _secure=FlutterSecureStorage();
  String status='Ready to connect';
  bool busy=false;
  void _progress(String value){status=value;notifyListeners();}
  Uri _api(String path)=>Uri.parse('https://api.cloudflare.com/client/v4$path');

  static String _secret(){
    final rng=Random.secure();
    return base64UrlEncode(List<int>.generate(48,(_)=>rng.nextInt(256)))
      .replaceAll('=','');
  }
  Future<dynamic> _call(String token,String method,String path,[Object? body])async{
    final headers=<String,String>{
      'authorization':'Bearer $token','accept':'application/json',
      if(body!=null)'content-type':'application/json',
    };
    final uri=_api(path);
    late http.Response response;
    switch(method){
      case 'GET':
        response=await _client.get(uri,headers:headers)
          .timeout(const Duration(seconds:25));
        break;
      case 'POST':
        response=await _client.post(uri,headers:headers,body:jsonEncode(body))
          .timeout(const Duration(seconds:45));
        break;
      case 'PUT':
        response=await _client.put(uri,headers:headers,body:jsonEncode(body))
          .timeout(const Duration(seconds:45));
        break;
      default:
        throw ArgumentError('Unsupported Cloudflare operation');
    }
    dynamic data;
    try{data=jsonDecode(response.body);}catch(_){data=null;}
    if(response.statusCode<200||response.statusCode>=300||
       data is! Map||data['success']!=true){
      final errors=data is Map?data['errors']:null;
      final detail=errors is List&&errors.isNotEmpty?
        (errors.first is Map?errors.first['message']:errors.first):response.statusCode;
      throw StateError('Cloudflare $method $path: $detail');
    }
    return data['result'];
  }
  Future<bool> _exists(String token,String path)async{
    final response=await _client.get(_api(path),headers:{
      'authorization':'Bearer $token','accept':'application/json',
    }).timeout(const Duration(seconds:25));
    if(response.statusCode==404)return false;
    if(response.statusCode>=200&&response.statusCode<300)return true;
    throw StateError('Cannot check existing Cloudflare resource (HTTP ' + response.statusCode.toString() + ')');
  }
  Future<void> _upload(String token,String account,String worker,String code,
      String database,String bucket,String secret)async{
    final request=http.MultipartRequest('PUT',
      _api('/accounts/$account/workers/scripts/$worker'));
    request.headers['authorization']='Bearer $token';
    request.fields['metadata']=jsonEncode({
      'main_module':'main.js','compatibility_date':'2026-11-16',
      'bindings':[
        {'type':'d1','name':'DB','id':database},
        {'type':'r2_bucket','name':'FILES','bucket_name':bucket},
        {'type':'secret_text','name':'OWNER_TOKEN','text':secret},
      ]
    });
    request.files.add(http.MultipartFile.fromString('main.js',code,
      filename:'main.js',
      contentType:MediaType.parse('application/javascript+module')));
    final streamed=await _client.send(request).timeout(const Duration(minutes:2));
    final response=await http.Response.fromStream(streamed);
    dynamic result;
    try{result=jsonDecode(response.body);}catch(_){result=null;}
    if(response.statusCode<200||response.statusCode>=300||
       result is! Map||result['success']!=true){
      throw StateError('Worker upload refused: ' + (result is Map ? result['errors'].toString() : response.statusCode.toString()));
    }
  }

  Future<CloudProvisioningResult> provision(String accountId,String apiToken)async{
    if(busy)throw StateError('Setup already running');
    if(!RegExp(r'^[a-fA-F0-9]{32}$').hasMatch(accountId.trim())){
      throw const FormatException('Cloudflare Account ID must be 32 hex characters');
    }
    if(apiToken.trim().length<20){
      throw const FormatException('Enter your restricted Cloudflare API token');
    }
    busy=true;notifyListeners();
    final id=accountId.trim().toLowerCase(),token=apiToken.trim();
    final slug=id.substring(0,10);
    final worker='fileshare-personal-$slug';
    final databaseName='fileshare-personal-$slug';
    final bucket='fileshare-personal-$slug';
    final secretId='fileshare-bootstrap-$id';
    try{
      _progress('Verifying Cloudflare token');
      final verification=await _call(token,'GET','/user/tokens/verify');
      if(verification is! Map||verification['status']!='active'){
        throw StateError('Cloudflare token is inactive');
      }
      _progress('Finding your private database');
      final all=await _call(token,'GET','/accounts/$id/d1/database?per_page=100');
      final matching=all is List?all.whereType<Map>()
        .where((db)=>db['name']==databaseName).toList():<Map>[];
      dynamic dbId;
      if(matching.isNotEmpty){
        dbId=matching.first['uuid'];
      }else{
        _progress('Creating personal D1 database');
        final created=await _call(token,'POST','/accounts/$id/d1/database',
          {'name':databaseName});
        dbId=created is Map?created['uuid']:null;
      }
      if(dbId is! String||dbId.isEmpty){
        throw StateError('D1 database ID was not returned');
      }
      _progress('Checking your private R2 bucket');
      if(!await _exists(token,'/accounts/$id/r2/buckets/$bucket')){
        await _call(token,'POST','/accounts/$id/r2/buckets',{'name':bucket});
      }
      _progress('Configuring D1 schema and account tables');
      final sql=(await rootBundle.loadString('cloudflare/schema.sql'))
        .replaceFirst('PRAGMA foreign_keys = ON;', '');
      final schemaResult=await _call(token,'POST',
        '/accounts/$id/d1/database/$dbId/query',{'sql':sql});
      if(schemaResult is List && schemaResult.any(
        (entry)=>entry is Map && entry['success']==false)){
        throw StateError('D1 rejected one or more schema statements');
      }

      final domainData=await _call(token,'GET','/accounts/$id/workers/subdomain');
      final domain=domainData is Map?domainData['subdomain']:null;
      if(domain is! String||domain.isEmpty){
        throw StateError('Activate a workers.dev subdomain in your Cloudflare account');
      }
      final workerUrl='https://$worker.$domain.workers.dev';
      final exists=await _exists(token,'/accounts/$id/workers/scripts/$worker');
      String? bootstrap=await _secure.read(key:secretId);
      if(exists&&(bootstrap==null||bootstrap.isEmpty)){
        throw StateError('A Worker already exists but no matching setup key is saved. '
          'Do not overwrite it. Connect it manually using the owner secret.');
      }
      bootstrap??=_secret();
      // Persist before provisioning, so a retry after partial failure is safe.
      await _secure.write(key:secretId,value:bootstrap);
      _progress('Bundling your private QR guest page');
      var script=await rootBundle.loadString('cloudflare/worker.js');
      final guest=await rootBundle.loadString('cloudflare/public/guest.html');
      const placeholder="const GUEST_HTML = ''; // Embedded by first-time setup.";
      if(!script.contains(placeholder)){
        throw StateError('Bundled personal Worker template is incompatible');
      }
      script=script.replaceFirst(placeholder,'const GUEST_HTML = ' + jsonEncode(guest) + ';');
      _progress('Uploading Worker and encrypted owner secret');
      await _upload(token,id,worker,script,dbId,bucket,bootstrap);
      _progress('Enabling your workers.dev address');
      await _call(token,'POST','/accounts/$id/workers/scripts/$worker/subdomain',
        {'enabled':true,'previews_enabled':false});
      _progress('Scheduling midnight India-time cleanup');
      await _call(token,'PUT','/accounts/$id/workers/scripts/$worker/schedules',[
        {'cron':'30 18 * * *'},
        {'cron':'30 20 * * *'},
        {'cron':'30 22 * * *'},
      ]);
      _progress('Verifying your D1 and R2 read/write/delete');
      var verified=false;
      for(var attempt=0;attempt<4;attempt++){
        try{
          final response=await _client.post(
            Uri.parse('$workerUrl/v1/owner/self-test'),
            headers:{'authorization':'Bearer $bootstrap'},
          ).timeout(const Duration(seconds:16));
          if(response.statusCode==200){
            final result=jsonDecode(response.body);
            if(result is Map&&result['ok']==true&&result['d1']==true&&
               result['r2']==true){verified=true;break;}
          }
        }catch(_){/* Newly created workers.dev URL may need propagation. */}
        await Future<void>.delayed(Duration(seconds:attempt+1));
      }
      if(!verified){
        throw StateError('Worker deployed but storage verification was not confirmed. '
          'Retry setup; existing resources will be reused.');
      }
      _progress('Connected. Create your File Share account next.');
      return CloudProvisioningResult(workerUrl,bootstrap);
    }finally{busy=false;notifyListeners();}
  }
  @override void dispose(){_client.close();super.dispose();}
}
