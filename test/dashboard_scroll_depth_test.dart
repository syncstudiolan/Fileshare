import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:file_share/main.dart' show FileShareScrollDepth;

void main(){
  testWidgets('scroll depth uses compositor transforms without rebuilding cards',
    (tester)async{
    tester.view.physicalSize=const Size(430,850);
    tester.view.devicePixelRatio=1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller=ScrollController();
    addTearDown(controller.dispose);
    var cardBuilds=0;
    await tester.pumpWidget(MaterialApp(home:Scaffold(body:
      ListView.builder(controller:controller,itemCount:18,
        itemBuilder:(context,index)=>FileShareScrollDepth(
          key:ValueKey('depth-$index'),position:controller,
          child:Builder(builder:(_){
            cardBuilds++;
            return SizedBox(height:130,
              child:Text('Transfer card $index'));
          }))))));
    final before=cardBuilds;
    expect(find.byType(FileShareScrollDepth),findsWidgets);
    await tester.drag(find.byType(ListView),const Offset(0,-300));
    await tester.pump();
    expect(controller.offset,greaterThan(0));
    expect(cardBuilds,greaterThanOrEqualTo(before));
    // The scroll effect is a real perspective Transform, not an entrance
    // animation replayed on new cards.
    final transforms=tester.widgetList<Transform>(find.byType(Transform));
    expect(transforms.any((t)=>t.transform.entry(3,2)!=0),isTrue);
  });

  testWidgets('reduced motion disables scroll 3D transformations',
    (tester)async{
    final controller=ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(home:MediaQuery(
      data:const MediaQueryData(disableAnimations:true),
      child:Scaffold(body:ListView(
        controller:controller,children:[
          FileShareScrollDepth(position:controller,
            child:const SizedBox(height:100,child:Text('Card'))),
        ])))));
    expect(find.text('Card'),findsOneWidget);
    expect(find.descendant(
      of:find.byType(FileShareScrollDepth),
      matching:find.byType(AnimatedBuilder)),findsNothing);
  });
}
