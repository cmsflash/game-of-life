import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';

const maxProfileAvatarBytes = 3 * 1024 * 1024;

class AvatarDocument {
  const AvatarDocument({required this.url, required this.version});

  final String? url;
  final int version;

  factory AvatarDocument.fromJson(Map<String, dynamic> json) => AvatarDocument(
    url: json['avatarUrl'] as String?,
    version: (json['avatarVersion'] as num?)?.round() ?? 0,
  );
}

class ProfileAvatarUpload {
  const ProfileAvatarUpload({
    required this.bytes,
    required this.filename,
    required this.contentType,
  });

  final Uint8List bytes;
  final String filename;
  final String contentType;
}

class ProfileAvatarPickException implements Exception {
  const ProfileAvatarPickException(this.message);

  final String message;

  @override
  String toString() => message;
}

abstract interface class ProfileAvatarPicker {
  Future<ProfileAvatarUpload?> pick();
}

abstract interface class ProfileAvatarFile {
  Future<int> length();
  Future<Uint8List> readAsBytes();
}

abstract interface class ProfileAvatarImageGateway {
  Future<ProfileAvatarFile?> pick({
    required double maxWidth,
    required double maxHeight,
    required int imageQuality,
  });
}

class ImagePickerProfileAvatarGateway implements ProfileAvatarImageGateway {
  ImagePickerProfileAvatarGateway({ImagePicker? picker})
    : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  @override
  Future<ProfileAvatarFile?> pick({
    required double maxWidth,
    required double maxHeight,
    required int imageQuality,
  }) async {
    final image = await _picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      imageQuality: imageQuality,
      requestFullMetadata: false,
    );
    return image == null ? null : _XFileProfileAvatarFile(image);
  }
}

class DeviceProfileAvatarPicker implements ProfileAvatarPicker {
  DeviceProfileAvatarPicker({ProfileAvatarImageGateway? gateway})
    : _gateway = gateway ?? ImagePickerProfileAvatarGateway();

  final ProfileAvatarImageGateway _gateway;

  @override
  Future<ProfileAvatarUpload?> pick() async {
    final image = await _gateway.pick(
      maxWidth: 1024,
      maxHeight: 1024,
      imageQuality: 85,
    );
    if (image == null) return null;
    if (await image.length() > maxProfileAvatarBytes) {
      throw const ProfileAvatarPickException(
        'Choose a JPEG, PNG, or WebP image smaller than 3 MB.',
      );
    }
    final bytes = await image.readAsBytes();
    if (bytes.isEmpty) {
      throw const ProfileAvatarPickException(
        'That image is empty. Choose a different picture.',
      );
    }
    if (bytes.length > maxProfileAvatarBytes) {
      throw const ProfileAvatarPickException(
        'Choose a JPEG, PNG, or WebP image smaller than 3 MB.',
      );
    }
    final format = _imageFormat(bytes);
    if (format == null) {
      throw const ProfileAvatarPickException(
        'Choose a JPEG, PNG, or WebP image.',
      );
    }
    return ProfileAvatarUpload(
      bytes: bytes,
      filename: 'profile.${format.extension}',
      contentType: format.contentType,
    );
  }
}

class _XFileProfileAvatarFile implements ProfileAvatarFile {
  const _XFileProfileAvatarFile(this.file);

  final XFile file;

  @override
  Future<int> length() => file.length();

  @override
  Future<Uint8List> readAsBytes() => file.readAsBytes();
}

_ProfileImageFormat? _imageFormat(Uint8List bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xff &&
      bytes[1] == 0xd8 &&
      bytes[2] == 0xff) {
    return const _ProfileImageFormat('jpg', 'image/jpeg');
  }
  const png = <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  if (bytes.length >= png.length && _matches(bytes, 0, png)) {
    return const _ProfileImageFormat('png', 'image/png');
  }
  const riff = <int>[0x52, 0x49, 0x46, 0x46];
  const webp = <int>[0x57, 0x45, 0x42, 0x50];
  if (bytes.length >= 12 &&
      _matches(bytes, 0, riff) &&
      _matches(bytes, 8, webp)) {
    return const _ProfileImageFormat('webp', 'image/webp');
  }
  return null;
}

bool _matches(Uint8List bytes, int offset, List<int> signature) {
  for (var index = 0; index < signature.length; index++) {
    if (bytes[offset + index] != signature[index]) return false;
  }
  return true;
}

class _ProfileImageFormat {
  const _ProfileImageFormat(this.extension, this.contentType);

  final String extension;
  final String contentType;
}
