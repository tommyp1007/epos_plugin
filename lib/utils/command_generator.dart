import 'package:image/image.dart' as img;
import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';

class CommandGenerator {
  
  // Strategy 1: Standard ESC/POS (GS v 0) - Raster Bit Image
  // Best for modern printers (Sunmi, Epson TM-T series, XPrinter, etc.)
  Future<List<int>> getGraphics_GS_v_0(img.Image src, {bool is80mm = false}) async {
    final profile = await CapabilityProfile.load();
    // Dynamic Paper Size: Critical for Tablet (80mm) vs Phone (58mm) usage
    final generator = Generator(is80mm ? PaperSize.mm80 : PaperSize.mm58, profile);
    
    // esc_pos_utils uses GS v 0 by default for imageRaster
    // PosAlign.center ensures it looks good on both wide and narrow papers
    return generator.imageRaster(src, align: PosAlign.center);
  }

  // Strategy 2: ESC * 33 (Bit image mode / Legacy)
  // Use this if Strategy 1 prints garbage characters on older generic printers
  Future<List<int>> getGraphics_ESC_Star(img.Image src, {bool is80mm = false}) async {
    final profile = await CapabilityProfile.load();
    final generator = Generator(is80mm ? PaperSize.mm80 : PaperSize.mm58, profile);
    
    // The library's .image() method is a high-level wrapper. 
    // While it often prefers Raster, it is the standard fallback for "print an image".
    return generator.image(src, align: PosAlign.center); 
  }

  // Strategy 3: Text Printing
  Future<List<int>> getText(String text, {bool is80mm = false}) async {
    final profile = await CapabilityProfile.load();
    final generator = Generator(is80mm ? PaperSize.mm80 : PaperSize.mm58, profile);
    
    List<int> bytes = [];
    // Always good practice to reset before printing text to clear weird styles
    bytes += generator.reset(); 
    bytes += generator.text(
      text, 
      styles: const PosStyles(
        align: PosAlign.left, 
        height: PosTextSize.size1, 
        width: PosTextSize.size1
      )
    );
    // Feed paper slightly so text isn't stuck under the cutter
    bytes += generator.feed(1); 
    
    return bytes;
  }
}