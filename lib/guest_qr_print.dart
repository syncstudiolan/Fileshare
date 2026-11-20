import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// Creates a real, scannable Guest QR graphic and lays it out on one A4 sheet.
/// Never prints only the token or link; all QR modules are rendered into PNG.
Future<Uint8List> buildGuestQrPrintPdf(String link) async {
  final uri=Uri.tryParse(link.trim());
  if(uri==null || !uri.hasScheme ||
      (uri.scheme!='https' && uri.scheme!='http') || uri.host.isEmpty){
    throw const FormatException('A valid Guest QR link is required for printing');
  }
  final qr=QrPainter(
    data:link,
    version:QrVersions.auto,
    errorCorrectionLevel:QrErrorCorrectLevel.M,
    color:Colors.black,
    emptyColor:Colors.white,
    gapless:true,
  );
  final imageData=await qr.toImageData(1100,format:ui.ImageByteFormat.png);
  if(imageData==null || imageData.lengthInBytes==0){
    throw StateError('Unable to render the Guest QR image');
  }
  final bytes=imageData.buffer.asUint8List(
    imageData.offsetInBytes,imageData.lengthInBytes);
  final document=pw.Document();
  document.addPage(pw.Page(
    pageFormat:PdfPageFormat.a4,
    margin:const pw.EdgeInsets.all(36),
    build:(_) => pw.Center(child:pw.Column(
      mainAxisSize:pw.MainAxisSize.min,
      crossAxisAlignment:pw.CrossAxisAlignment.center,
      children:[
        pw.Text('FILE SHARE',style:pw.TextStyle(
          fontSize:24,fontWeight:pw.FontWeight.bold)),
        pw.SizedBox(height:11),
        pw.Text('Scan to upload files securely',
          style:const pw.TextStyle(fontSize:13)),
        pw.SizedBox(height:26),
        pw.Container(
          padding:const pw.EdgeInsets.all(20),
          color:PdfColors.white,
          child:pw.Image(pw.MemoryImage(bytes),width:300,height:300),
        ),
        pw.SizedBox(height:20),
        pw.Text('Guest upload QR code',
          style:pw.TextStyle(fontSize:14,fontWeight:pw.FontWeight.bold)),
        pw.SizedBox(height:12),
        pw.Text(link,textAlign:pw.TextAlign.center,
          style:const pw.TextStyle(fontSize:9)),
        pw.SizedBox(height:20),
        pw.Text('Open the QR code using your phone camera.',
          style:const pw.TextStyle(fontSize:10)),
      ],
    )),
  ));
  return document.save();
}

/// Opens the platform printer/preview dialog; it does not write to Cloudflare
/// and cannot disable or regenerate the owner's persistent Guest QR.
Future<void> printGuestQr(String link) async {
  final pdf=await buildGuestQrPrintPdf(link);
  await Printing.layoutPdf(
    name:'File Share Guest Upload QR',
    onLayout:(format)async=>pdf,
  );
}
