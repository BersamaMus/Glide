import 'package:glide/services/places.dart';
import 'package:flutter_test/flutter_test.dart';

/// The names the camera chips give cameras and phones, from what their
/// pictures' metadata says.
void main() {
  test('a camera whose model names its maker is called by the model, in the maker\'s spelling', () {
    expect(cameraName('NIKON CORPORATION', 'NIKON D40'), 'Nikon D40');
    expect(cameraName('Canon', 'Canon EOS 5D Mark II'), 'Canon EOS 5D Mark II');
    expect(cameraName('OPPO', 'OPPO Find X9 Pro'), 'OPPO Find X9 Pro');
    expect(cameraName('EASTMAN KODAK COMPANY', 'KODAK EASYSHARE C613 ZOOM DIGITAL CAMERA'),
        'Kodak EASYSHARE C613 ZOOM DIGITAL CAMERA');
  });

  test('a model that does not is put after its maker, without the company\'s trappings', () {
    expect(cameraName('SONY', 'ILCE-7M3'), 'Sony ILCE-7M3');
    expect(cameraName('samsung', 'SM-S918B'), 'Samsung SM-S918B');
    expect(cameraName('OLYMPUS IMAGING CORP.', 'E-M10'), 'Olympus E-M10');
    expect(cameraName('FUJIFILM', 'X-T4'), 'Fujifilm X-T4');
    expect(cameraName('OPPO', 'CPH2581'), 'OPPO CPH2581');
  });

  test('phones known by their own names are called by them', () {
    expect(cameraName('Apple', 'iPhone 15 Pro'), 'iPhone 15 Pro');
    expect(cameraName('Google', 'Pixel 8 Pro'), 'Pixel 8 Pro');
    expect(cameraName('HMD Global', 'Nokia 7 plus'), 'Nokia 7 plus');
    expect(cameraName('Xiaomi', 'Redmi Note 12'), 'Redmi Note 12');
  });

  test('a model run into its maker\'s name is kept as it is', () {
    expect(cameraName('LG Electronics', 'LG-H870'), 'LG-H870');
    expect(cameraName('OM Digital Solutions', 'OM-1'), 'OM-1');
  });

  test('either alone will do; neither, and there is no camera to name', () {
    expect(cameraName('NIKON CORPORATION', null), 'Nikon');
    expect(cameraName(null, 'DSC-RX100'), 'DSC-RX100');
    expect(cameraName('  ', ''), isNull);
    expect(cameraName(null, null), isNull);
  });

  test('the same camera, however its maker and model were padded, is one name', () {
    expect(cameraName('NIKON CORPORATION ', ' NIKON  D40 '), 'Nikon D40');
    expect(cameraName('Nikon', 'NIKON D40'), cameraName('NIKON CORPORATION', 'NIKON D40'));
  });
}
