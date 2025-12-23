import 'dart:typed_data';

class RawCommands {
  
  // --- BASIC COMMANDS ---

  // RESET Printer (ESC @)
  // Clears the buffer and resets settings to default. 
  // Useful to call before starting a new print job.
  static List<int> reset() => [0x1B, 0x40];

  // FEED Lines (ESC d n)
  // Feeds 'n' lines. Max 255.
  static List<int> feed(int lines) => [0x1B, 0x64, lines];

  // CUT Paper (GS V 66 0)
  // Standard partial cut. Note: Not all mobile printers support cutting.
  static List<int> cut() => [0x1D, 0x56, 66, 0];

  // ALIGNMENT (ESC a n)
  // 0: Left, 1: Center, 2: Right
  static List<int> setAlignment(int align) {
    // Clamp value between 0 and 2
    int safeAlign = align.clamp(0, 2); 
    return [0x1B, 0x61, safeAlign];
  }

  // --- IMAGE PROTOCOLS ---

  /**
   * PROTOCOL: GS v 0 (Raster Bit Image)
   * This is the standard for most modern thermal printers (Epson, Sunmi, XPrinter).
   * It prints row-by-row (Raster).
   * * Header: 0x1D 0x76 0x30 0x00 xL xH yL yH [data]
   * - xL, xH = width in bytes (width / 8)
   * - yL, yH = height in dots
   */
  static List<int> command_GS_v_0(List<int> imageBytes, int width, int height) {
    List<int> cmd = [];
    cmd.addAll([0x1D, 0x76, 0x30, 0x00]); // Header for "Normal" mode
    
    // Calculate width in bytes (8 pixels per byte)
    int bytesWidth = (width + 7) ~/ 8;
    
    // Low Byte / High Byte calculations
    cmd.add(bytesWidth % 256); // xL
    cmd.add(bytesWidth ~/ 256); // xH
    cmd.add(height % 256);      // yL
    cmd.add(height ~/ 256);     // yH
    
    cmd.addAll(imageBytes);
    return cmd;
  }

  /**
   * PROTOCOL: ESC * 33 (Double Density Bit Image)
   * Compatible with older Epson, Star, and some legacy Bluetooth printers 
   * that do not support GS v 0.
   * This prints column-by-column (Column Format).
   * * Header: 0x1B 0x2A 33 nL nH [data]
   * - 33 = 24-dot double-density mode
   * - nL, nH = number of dots in horizontal direction
   */
  static List<int> command_ESC_Star_33(List<int> imageColumnBytes, int width) {
    List<int> cmd = [];
    cmd.addAll([0x1B, 0x2A, 33]); // Select bit image mode (24-pin double density)
    
    cmd.add(width % 256); // nL
    cmd.add(width ~/ 256); // nH
    
    cmd.addAll(imageColumnBytes);
    
    // Usually required to return to normal line spacing after ESC * graphics
    cmd.addAll([0x1B, 0x33, 30]); // Set line spacing to ~30 dots
    
    return cmd;
  }
}