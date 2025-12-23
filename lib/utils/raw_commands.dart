import 'dart:typed_data';

class RawCommands {
  
  // RESET Printer (ESC @)
  static List<int> reset() => [0x1B, 0x40];

  // FEED Lines (ESC d n)
  static List<int> feed(int lines) => [0x1B, 0x64, lines];

  // CUT Paper (GS V 66 0)
  static List<int> cut() => [0x1D, 0x56, 66, 0];

  /**
   * PROTOCOL: GS v 0 (Raster Bit Image)
   * This is the standard for most modern thermal printers.
   * Bytes: 0x1D 0x76 0x30 0x00 xL xH yL yH [data]
   * * xL, xH = width in bytes (width / 8)
   * yL, yH = height in dots
   */
  static List<int> command_GS_v_0(List<int> imageBytes, int width, int height) {
    List<int> cmd = [];
    cmd.addAll([0x1D, 0x76, 0x30, 0x00]); // Header
    
    // Calculate dimensions
    int bytesWidth = (width + 7) ~/ 8;
    cmd.add(bytesWidth % 256); // xL
    cmd.add(bytesWidth ~/ 256); // xH
    cmd.add(height % 256);      // yL
    cmd.add(height ~/ 256);     // yH
    
    cmd.addAll(imageBytes);
    return cmd;
  }

  /**
   * PROTOCOL: ESC * 33 (Double Density Bit Image)
   * Compatible with older Epson and some Star printers
   * Bytes: 0x1B 0x2A 33 nL nH [data]
   */
  static List<int> command_ESC_Star_33(List<int> imageColumnBytes, int width) {
    List<int> cmd = [];
    cmd.addAll([0x1B, 0x2A, 33]);
    
    cmd.add(width % 256); // nL
    cmd.add(width ~/ 256); // nH
    
    cmd.addAll(imageColumnBytes);
    return cmd;
  }
}