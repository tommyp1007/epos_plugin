import 'package:image/image.dart' as img;
import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';

class CommandGenerator {
  
  // Strategy 1: Standard ESC/POS (GS v 0)
  Future<List<int>> getGraphics_GS_v_0(img.Image src) async {
    final profile = await CapabilityProfile.load();
    final generator = Generator(PaperSize.mm58, profile);
    // esc_pos_utils uses GS v 0 by default for imageRaster
    return generator.imageRaster(src, align: PosAlign.center);
  }

  // Strategy 2: ESC * 33 (Bit image mode for older Epson/Generic)
  Future<List<int>> getGraphics_ESC_Star(img.Image src) async {
    final profile = await CapabilityProfile.load();
    final generator = Generator(PaperSize.mm58, profile);
    // While the library defaults to GS v 0, you can manually implement ESC *
    // or use the generator.image() method which tries to adapt.
    // Real implementation requires manual bit manipulation here.
    return generator.image(src); 
  }

  // Strategy 3: Text Printing
  Future<List<int>> getText(String text) async {
    final profile = await CapabilityProfile.load();
    final generator = Generator(PaperSize.mm58, profile);
    return generator.text(text);
  }
}