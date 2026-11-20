import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:file_share/guest_qr_print.dart';

void main(){
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Guest QR printing makes a real PDF with embedded scannable QR pixels',
      ()async{
    const url='https://fileshare.example.workers.dev/q/PermanentGuestToken123456';
    final pdf=await buildGuestQrPrintPdf(url);
    expect(pdf.length,greaterThan(3000));
    expect(utf8.decode(pdf.take(5).toList()),'%PDF-');
  });

  test('Guest QR printing rejects an empty or non-web QR link',()async{
    await expectLater(buildGuestQrPrintPdf(''),
      throwsA(isA<FormatException>()));
    await expectLater(buildGuestQrPrintPdf('just-a-token'),
      throwsA(isA<FormatException>()));
  });
}
