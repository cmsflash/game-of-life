import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:game_of_life/features/auth/data/profile_avatar.dart';

void main() {
  test('picker requests compressed dimensions and accepts PNG bytes', () async {
    final file = _FakeAvatarFile(
      bytes: Uint8List.fromList(const [
        0x89,
        0x50,
        0x4e,
        0x47,
        0x0d,
        0x0a,
        0x1a,
        0x0a,
      ]),
    );
    final gateway = _FakeAvatarGateway(file);

    final upload = await DeviceProfileAvatarPicker(gateway: gateway).pick();

    expect(gateway.maxWidth, 1024);
    expect(gateway.maxHeight, 1024);
    expect(gateway.imageQuality, 85);
    expect(upload?.contentType, 'image/png');
    expect(upload?.filename, 'profile.png');
    expect(file.readCalls, 1);
  });

  test('oversized selection is rejected before reading its contents', () async {
    final file = _FakeAvatarFile(
      bytes: Uint8List(0),
      reportedLength: maxProfileAvatarBytes + 1,
    );

    await expectLater(
      DeviceProfileAvatarPicker(gateway: _FakeAvatarGateway(file)).pick(),
      throwsA(
        isA<ProfileAvatarPickException>().having(
          (error) => error.message,
          'message',
          contains('smaller than 3 MB'),
        ),
      ),
    );

    expect(file.readCalls, 0);
  });

  test('byte length is checked again after reading', () async {
    final file = _FakeAvatarFile(
      bytes: Uint8List(maxProfileAvatarBytes + 1),
      reportedLength: 100,
    );

    await expectLater(
      DeviceProfileAvatarPicker(gateway: _FakeAvatarGateway(file)).pick(),
      throwsA(isA<ProfileAvatarPickException>()),
    );

    expect(file.readCalls, 1);
  });
}

class _FakeAvatarGateway implements ProfileAvatarImageGateway {
  _FakeAvatarGateway(this.file);

  final ProfileAvatarFile? file;
  double? maxWidth;
  double? maxHeight;
  int? imageQuality;

  @override
  Future<ProfileAvatarFile?> pick({
    required double maxWidth,
    required double maxHeight,
    required int imageQuality,
  }) async {
    this.maxWidth = maxWidth;
    this.maxHeight = maxHeight;
    this.imageQuality = imageQuality;
    return file;
  }
}

class _FakeAvatarFile implements ProfileAvatarFile {
  _FakeAvatarFile({required this.bytes, int? reportedLength})
    : reportedLength = reportedLength ?? bytes.length;

  final Uint8List bytes;
  final int reportedLength;
  var readCalls = 0;

  @override
  Future<int> length() async => reportedLength;

  @override
  Future<Uint8List> readAsBytes() async {
    readCalls++;
    return bytes;
  }
}
