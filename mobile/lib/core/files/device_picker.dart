import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

/// Telefonda çekilen ya da seçilen dosya. [size] seçici bildirmediyse null
/// (çağıran dosyadan okur).
typedef PickedDeviceFile = ({String path, String name, int? size});

/// Kamera/galeri ve dosya seçici. Vazgeçilirse null; izin reddi ve seçici
/// hataları FIRLATILIR (PlatformException) -- çağıran
/// `describeDeviceError` ile kullanıcıya anlatır. Testler sahtesini verir.
abstract interface class DevicePicker {
  Future<PickedDeviceFile?> pickImage(ImageSource source);
  Future<PickedDeviceFile?> pickFile();
}

class PluginDevicePicker implements DevicePicker {
  const PluginDevicePicker();

  @override
  Future<PickedDeviceFile?> pickImage(ImageSource source) async {
    final picked = await ImagePicker().pickImage(source: source, imageQuality: 85);
    return picked == null ? null : (path: picked.path, name: picked.name, size: null);
  }

  @override
  Future<PickedDeviceFile?> pickFile() async {
    final result = await FilePicker.platform.pickFiles(withData: false);
    final picked = result?.files.single;
    final path = picked?.path;
    if (picked == null || path == null) return null;
    return (path: path, name: picked.name, size: picked.size);
  }
}

final devicePickerProvider = Provider<DevicePicker>((ref) => const PluginDevicePicker());
