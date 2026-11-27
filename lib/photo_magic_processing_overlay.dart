import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Lightweight GPU-painted visual feedback; does not process image pixels.
class PhotoMagicProcessingOverlay extends StatefulWidget {
  const PhotoMagicProcessingOverlay({super.key,required this.label});
  final String label;

  @override
  State<PhotoMagicProcessingOverlay> createState() =>
      _PhotoMagicProcessingOverlayState();
}

class _PhotoMagicProcessingOverlayState extends State<PhotoMagicProcessingOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller=AnimationController(
    vsync:this,duration:const Duration(milliseconds:2200))..repeat();

  @override
  void dispose(){
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context)=>IgnorePointer(
    child:AnimatedBuilder(
      animation:_controller,
      builder:(context,child)=>Stack(fit:StackFit.expand,children:[
        CustomPaint(painter:_MagicPainter(_controller.value)),
        Align(alignment:Alignment.bottomCenter,
          child:Padding(padding:const EdgeInsets.fromLTRB(12,0,12,12),
            child:DecoratedBox(
              decoration:BoxDecoration(
                color:const Color(0xE8231C40),
                borderRadius:BorderRadius.circular(24),
                border:Border.all(color:const Color(0xAAE4D4FF))),
              child:Padding(
                padding:const EdgeInsets.symmetric(horizontal:14,vertical:9),
                child:Row(mainAxisSize:MainAxisSize.min,children:[
                  const Icon(Icons.auto_awesome,color:Color(0xFFE4D0FF),size:17),
                  const SizedBox(width:8),
                  Flexible(child:Text(widget.label,
                    maxLines:1,overflow:TextOverflow.ellipsis,
                    style:const TextStyle(color:Colors.white,
                      fontWeight:FontWeight.w600,fontSize:12))),
                  const SizedBox(width:10),
                  const SizedBox(width:12,height:12,
                    child:CircularProgressIndicator(strokeWidth:2,
                      color:Color(0xFFD1B5FF))),
                ]),
              ),
            )),
          ),
      ]),
    ),
  );
}

class _MagicPainter extends CustomPainter {
  const _MagicPainter(this.phase);
  final double phase;

  @override
  void paint(Canvas canvas,Size size){
    if(size.isEmpty)return;
    final sweepY=size.height*((phase*1.3)%1.0);
    final beam=Paint()..shader=LinearGradient(
      begin:Alignment.topCenter,end:Alignment.bottomCenter,
      colors:[Colors.transparent,
        const Color(0x443ECFDC),
        const Color(0x995DCEEF),
        const Color(0x666F4CF5),Colors.transparent],
      stops:const [0,.40,.50,.60,1],
    ).createShader(Rect.fromLTWH(0,sweepY-42,size.width,84));
    canvas.drawRect(Rect.fromLTWH(0,sweepY-42,size.width,84),beam);
    final shortest=math.min(size.width,size.height);
    for(var i=0;i<16;i++){
      final xFraction=((i*0.61803398875 + phase*(.10+(i%3)*.035))%1.0);
      final yFraction=((i*0.38196601125 + phase*(.20+(i%4)*.025))%1.0);
      final x=xFraction*size.width,y=yFraction*size.height;
      final twinkle=.3+.7*(.5+.5*math.sin(phase*math.pi*4+i*2.39));
      final radius=math.max(1.5,shortest*.009)*twinkle;
      final color=Color.lerp(const Color(0xFF75F6EF),
        const Color(0xFFF2D5FF),i.isEven ? .65 : .20)!;
      final paint=Paint()..color=color.withValues(alpha:twinkle*.83)
        ..strokeWidth=math.max(.75,radius*.28)
        ..strokeCap=StrokeCap.round;
      canvas.drawLine(Offset(x-radius*1.6,y),
        Offset(x+radius*1.6,y),paint);
      canvas.drawLine(Offset(x,y-radius*1.6),
        Offset(x,y+radius*1.6),paint);
      canvas.drawCircle(Offset(x,y),radius*.28,paint);
    }
  }
  @override bool shouldRepaint(covariant _MagicPainter previous)=>
    previous.phase!=phase;
}
