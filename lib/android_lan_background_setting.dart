import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Controls the already-running Android connectedDevice service and its
/// persisted BOOT_COMPLETED restarter. The user can turn it off at any time.
class AndroidLanBackgroundSetting extends StatefulWidget {
  const AndroidLanBackgroundSetting({super.key});
  @override State<AndroidLanBackgroundSetting> createState()=>
    _AndroidLanBackgroundSettingState();
}
class _AndroidLanBackgroundSettingState
    extends State<AndroidLanBackgroundSetting>{
  static const _native=MethodChannel('file_share.native');
  bool _enabled=true,_busy=true;
  @override void initState(){super.initState();_restore();}
  Future<void> _restore()async{
    try{
      final enabled=await _native.invokeMethod<bool>('getLanBootReceiver');
      if(mounted)setState((){
        _enabled=enabled??true;
        _busy=false;
      });
    }catch(_){
      if(mounted)setState(()=>_busy=false);
    }
  }
  Future<void> _set(bool enabled)async{
    if(!Platform.isAndroid)return;
    setState(()=>_busy=true);
    try{
      await _native.invokeMethod<bool>('setLanBootReceiver',
        {'enabled':enabled});
      await SharedPreferencesAsync()
        .setBool('android_receive_background',enabled);
      if(mounted)setState(()=>_enabled=enabled);
    }catch(e){
      if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content:Text('Background receiving could not be changed: $e')));
    }finally{
      if(mounted)setState(()=>_busy=false);
    }
  }
  @override Widget build(BuildContext context)=>Column(children:[
    SwitchListTile.adaptive(
      secondary:const Icon(Icons.wifi_rounded),
      title:const Text('Receive files in background'),
      subtitle:Text(_enabled
        ?'Enabled · Keep LAN receiving with a visible notification'
        :'Disabled · Receive while File Share is open'),
      value:_enabled,onChanged:_busy?null:_set),
    const ListTile(
      leading:Icon(Icons.restart_alt_rounded),
      title:Text('Restart after phone reboot'),
      subtitle:Text('Uses Android BOOT_COMPLETED when background '
        'receiving is enabled. Your phone may restrict auto-start.')),
    const ListTile(
      leading:Icon(Icons.notifications_active_outlined),
      title:Text('File received notifications'),
      subtitle:Text('Allow notifications and background activity in Android settings.')),
    const Padding(padding:EdgeInsets.all(9),
      child:Text('Android force-stop, OEM battery optimization and '
        'Wi-Fi disconnection can prevent background receiving.')),
  ]);
}
