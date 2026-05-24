#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <Cocoa/Cocoa.h>
#include <sys/ioctl.h>
#include <signal.h>
#include <termios.h>

typedef NS_ENUM(NSInteger, ColorMap) {
  ColorMapGrayscale,
  ColorMapColor,
  ColorMapGreen,
  ColorMapAmber,
  ColorMapRainbow,
  ColorMapCyan,
  ColorMapRed,
  ColorMapPsychedelic,
  ColorMapInvertedGray,
  ColorMapMagenta,
  ColorMapSpectral
};

typedef NS_ENUM(NSInteger, MirrorMode) {
  MirrorModeNone,
  MirrorModeHorizontal,
  MirrorModeHorizontalSplit,
  MirrorModeVerticalSplit
};

static volatile int pixel_scale = 1;
static volatile ColorMap color_map = ColorMapGrayscale;
static volatile MirrorMode mirror_mode = MirrorModeHorizontal;
static volatile double contrast_factor = 1.15;
static volatile BOOL paused = NO;
static volatile int record_interval = 0;
static volatile BOOL should_capture_manual = NO;
static volatile BOOL show_help = NO;
struct termios orig_termios;

static inline void hsv_to_rgb(double h, double s, double v, int *r, int *g, int *b) {
  int i = (int)(h * 6);
  double f = h * 6 - i;
  double p = v * (1 - s);
  double q = v * (1 - f * s);
  double t = v * (1 - (1 - f) * s);
  double rv = 0, gv = 0, bv = 0;
  switch (i % 6) {
    case 0: rv = v; gv = t; bv = p; break;
    case 1: rv = q; gv = v; bv = p; break;
    case 2: rv = p; gv = v; bv = t; break;
    case 3: rv = p; gv = q; bv = v; break;
    case 4: rv = t; gv = p; bv = v; break;
    case 5: rv = v; gv = p; bv = q; break;
  }
  *r = (int)(rv * 255);
  *g = (int)(gv * 255);
  *b = (int)(bv * 255);
}

static inline void spectral_map(double val, int *r, int *g, int *b) {
  if (val < 0.25) {
    *r = 0;
    *g = (int)(val * 4.0 * 255);
    *b = 255;
  } else if (val < 0.5) {
    *r = 0;
    *g = 255;
    *b = (int)((1.0 - (val - 0.25) * 4.0) * 255);
  } else if (val < 0.75) {
    *r = (int)((val - 0.5) * 4.0 * 255);
    *g = 255;
    *b = 0;
  } else {
    *r = 255;
    *g = (int)((1.0 - (val - 0.75) * 4.0) * 255);
    *b = 0;
  }
}

static inline char *write_int(char *ptr, int val) {
  if (val >= 100) {
    *ptr++ = '0' + (val / 100);
    *ptr++ = '0' + ((val / 10) % 10);
    *ptr++ = '0' + (val % 10);
  } else if (val >= 10) {
    *ptr++ = '0' + (val / 10);
    *ptr++ = '0' + (val % 10);
  } else {
    *ptr++ = '0' + val;
  }
  return ptr;
}

void intHandler(int sig);

void disableRawMode() {
  tcsetattr(0, TCSAFLUSH, &orig_termios);
}

void enableRawMode() {
  tcgetattr(0, &orig_termios);
  atexit(disableRawMode);
  
  struct termios raw = orig_termios;
  raw.c_lflag &= ~(ECHO | ICANON);
  tcsetattr(0, TCSAFLUSH, &raw);
}

@interface CaptureDelegate : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@end

@implementation CaptureDelegate

- (void)captureOutput:(AVCaptureOutput *)output
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
           fromConnection:(AVCaptureConnection *)connection {
  @autoreleasepool {
    /*
     * RENDER LOOP OPTIMIZATION CRITERIA:
     * 1. Re-use a static C-string buffer ('frame_buffer') to bypass malloc/free overhead.
     * 2. Direct Pointer Arithmetic: Read raw 32-bit BGRA bytes directly from camera frame memory.
     * 3. Specialized Integers: Convert RGB color integers (0-255) directly into ASCII characters
     *    in the buffer, avoiding expensive Objective-C formatting strings (appendFormat:) or printf.
     * 4. Single System Call: Write the entire frame to stdout using a single 'fwrite' call,
     *    effectively minimizing kernel context switching and completely eliminating terminal flickering.
     */
    if (paused || show_help) return;

    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!imageBuffer) return;

    // Lock the base address of the pixel buffer
    CVPixelBufferLockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);

    size_t width = CVPixelBufferGetWidth(imageBuffer);
    size_t height = CVPixelBufferGetHeight(imageBuffer);

    // Get the pixel data
    unsigned char *baseAddress = (unsigned char *)CVPixelBufferGetBaseAddress(imageBuffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer);

    // Get terminal size
    struct winsize w;
    ioctl(0, TIOCGWINSZ, &w);
    int cols = w.ws_col;
    int rows = w.ws_row;

    if (cols <= 0) cols = 80;
    if (rows <= 0) rows = 24;

    static char *frame_buffer = NULL;
    static size_t frame_buffer_size = 0;

    size_t needed_size = cols * rows * 45 + 100;
    if (frame_buffer_size < needed_size) {
      frame_buffer = realloc(frame_buffer, needed_size);
      frame_buffer_size = needed_size;
    }

    char *ptr = frame_buffer;
    memcpy(ptr, "\033[0;0H", 6);
    ptr += 6;

    for (int y = 0; y < rows; y++) {
      /*
       * 1. COORDINATE QUANTIZATION (LOFI PIXEL BLOCKS):
       * By grouping terminal cells using pixel_scale (e.g. y / scale * scale),
       * we quantize the index grid to render blocks of pixels sharing the same color.
       */
      int quantized_y = (y / pixel_scale) * pixel_scale;
      int target_y = quantized_y;
      
      /*
       * 2. REFLECTION AXES / SYMMETRIC SPLITS:
       * For vertical reflection, mirror the bottom half of the terminal rows
       * using the top half of the camera rows (symmetrical split).
       */
      if (mirror_mode == MirrorModeVerticalSplit) {
        target_y = (quantized_y < rows / 2) ? quantized_y : (rows - 1 - quantized_y);
      }
      int src_y = target_y * (int)height / rows;
      if (src_y >= (int)height) src_y = (int)height - 1;

      unsigned char *rowAddress = baseAddress + (src_y * bytesPerRow);

      for (int x = 0; x < cols; x++) {
        int quantized_x = (x / pixel_scale) * pixel_scale;
        int target_x = quantized_x;
        
        /*
         * Standard Horizontal Mirroring flips the column indices.
         * Symmetrical Horizontal Split mirrors the left half onto the right half.
         */
        if (mirror_mode == MirrorModeHorizontal) {
          target_x = cols - 1 - quantized_x;
        } else if (mirror_mode == MirrorModeHorizontalSplit) {
          target_x = (quantized_x < cols / 2) ? quantized_x : (cols - 1 - quantized_x);
        } else if (mirror_mode == MirrorModeVerticalSplit) {
          target_x = cols - 1 - quantized_x;
        }

        int src_x = target_x * (int)width / cols;
        if (src_x >= (int)width) src_x = (int)width - 1;

        unsigned char *pixel = rowAddress + (src_x * 4);
        unsigned char b = pixel[0];
        unsigned char g = pixel[1];
        unsigned char r = pixel[2];

        /*
         * 3. LUMINANCE (BRIGHTNESS) MATH:
         * Standard NTSC weights are applied to match human eye sensitivity:
         * Y = 0.299*R + 0.587*G + 0.114*B.
         */
        double brightness = 0.299 * r + 0.587 * g + 0.114 * b;

        /*
         * 4. COLORMAP TRANSFORMATION:
         * Convert NTSC brightness or original RGB color into the destination colorspace.
         */
        int bg_r, bg_g, bg_b;
        if (color_map == ColorMapGrayscale) {
          bg_r = bg_g = bg_b = (int)brightness;
        } else if (color_map == ColorMapColor) {
          bg_r = r; bg_g = g; bg_b = b;
        } else if (color_map == ColorMapGreen) {
          bg_r = 0; bg_g = (int)brightness; bg_b = 0;
        } else if (color_map == ColorMapAmber) {
          bg_r = (int)brightness; bg_g = (int)(brightness * 0.6); bg_b = 0;
        } else if (color_map == ColorMapRainbow) {
          hsv_to_rgb(brightness / 255.0, 1.0, 1.0, &bg_r, &bg_g, &bg_b);
        } else if (color_map == ColorMapCyan) {
          bg_r = 0; bg_g = (int)(brightness * 0.75); bg_b = (int)brightness;
        } else if (color_map == ColorMapRed) {
          bg_r = (int)brightness; bg_g = 0; bg_b = 0;
        } else if (color_map == ColorMapPsychedelic) {
          bg_r = (r * 3) % 256; bg_g = (g * 5) % 256; bg_b = (b * 7) % 256;
        } else if (color_map == ColorMapInvertedGray) {
          bg_r = bg_g = bg_b = 255 - (int)brightness;
        } else if (color_map == ColorMapMagenta) {
          bg_r = (int)brightness; bg_g = 0; bg_b = (int)brightness;
        } else { // Spectral
          spectral_map(brightness / 255.0, &bg_r, &bg_g, &bg_b);
        }

        // Apply contrast for foreground character
        int fg_r = (int)fmin(255, bg_r * contrast_factor + 5);
        int fg_g = (int)fmin(255, bg_g * contrast_factor + 5);
        int fg_b = (int)fmin(255, bg_b * contrast_factor + 5);

        // Simple dithering pattern
        double fraction = (brightness / 255.0 * 23.0) - ((int)(brightness / 255.0 * 23.0));
        int chr_len = 3;
        int chr_type = 1; // 1 for ░, 2 for ▒, 0 for space
        if (fraction < 0.2) {
          chr_len = 1;
        } else if (fraction < 0.4) {
          chr_type = 1;
        } else if (fraction < 0.6) {
          chr_type = 2;
        } else if (fraction < 0.8) {
          int tmp_r = bg_r; bg_r = fg_r; fg_r = tmp_r;
          int tmp_g = bg_g; bg_g = fg_g; fg_g = tmp_g;
          int tmp_b = bg_b; bg_b = fg_b; fg_b = tmp_b;
          chr_type = 2;
        } else {
          int tmp_r = bg_r; bg_r = fg_r; fg_r = tmp_r;
          int tmp_g = bg_g; bg_g = fg_g; fg_g = tmp_g;
          int tmp_b = bg_b; bg_b = fg_b; fg_b = tmp_b;
          chr_type = 1;
        }

        // Format TrueColor escape sequences directly into the C buffer
        memcpy(ptr, "\033[48;2;", 7); ptr += 7;
        ptr = write_int(ptr, bg_r);
        *ptr++ = ';';
        ptr = write_int(ptr, bg_g);
        *ptr++ = ';';
        ptr = write_int(ptr, bg_b);
        memcpy(ptr, "m\033[38;2;", 8); ptr += 8;
        ptr = write_int(ptr, fg_r);
        *ptr++ = ';';
        ptr = write_int(ptr, fg_g);
        *ptr++ = ';';
        ptr = write_int(ptr, fg_b);
        *ptr++ = 'm';

        if (chr_len == 1) {
          *ptr++ = ' ';
        } else {
          *ptr++ = (char)0xe2;
          *ptr++ = (char)0x96;
          *ptr++ = (char)(chr_type == 1 ? 0x91 : 0x92);
        }
      }
      if (y < rows - 1) {
        *ptr++ = '\n';
      }
    }

    fwrite(frame_buffer, 1, ptr - frame_buffer, stdout);
    fflush(stdout);

    static double last_record_time = 0;
    double now = [[NSDate date] timeIntervalSince1970];
    if (record_interval > 0 && now - last_record_time >= record_interval) {
      last_record_time = now;
      NSData *bufferCopy = [NSData dataWithBytes:frame_buffer length:(ptr - frame_buffer)];
      dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        NSString *dirPath = @"capture";
        [[NSFileManager defaultManager] createDirectoryAtPath:dirPath
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        [formatter setDateFormat:@"yyyyMMdd_HHmmss_SSS"];
        NSString *timestamp = [formatter stringFromDate:[NSDate date]];
        NSString *filePath = [NSString stringWithFormat:@"%@/frame_%@.ansi", dirPath, timestamp];
        [bufferCopy writeToFile:filePath atomically:YES];
      });
    }

    if (should_capture_manual) {
      should_capture_manual = NO;
      NSData *bufferCopy = [NSData dataWithBytes:frame_buffer length:(ptr - frame_buffer)];
      dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        NSString *dirPath = @"capture";
        [[NSFileManager defaultManager] createDirectoryAtPath:dirPath
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        [formatter setDateFormat:@"yyyyMMdd_HHmmss_SSS"];
        NSString *timestamp = [formatter stringFromDate:[NSDate date]];
        NSString *filePath = [NSString stringWithFormat:@"%@/screenshot_%@.ansi", dirPath, timestamp];
        [bufferCopy writeToFile:filePath atomically:YES];
      });
    }

    CVPixelBufferUnlockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
  }
}

@end

void printHelpMenu() {
  printf("\033[0m\033[2J\033[0;0H");
  printf("term-cam live controls:\n");
  printf("=====================================================\n");
  printf("  h, ?          Toggle this help menu\n");
  printf("  q, Esc        Quit the application cleanly\n");
  printf("  Spacebar      Pause/unpause webcam stream\n");
  printf("  s             Save a manual screenshot to capture/\n");
  printf("  m             Cycle mirror modes (None -> Horiz -> HorizSplit -> VertSplit)\n");
  printf("  c             Cycle color maps (11 different themes!)\n");
  printf("  [ or ]        Adjust contrast factor (-/+)\n");
  printf("  + or =        Increase resolution (smaller cells)\n");
  printf("  -             Decrease resolution (larger cells)\n");
  printf("=====================================================\n");
  printf("Press any key to resume camera feed...\n");
  fflush(stdout);
}

void setupKeyboardListener() {
  static dispatch_source_t source = nil;
  dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
  source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, 0, 0, queue);

  dispatch_source_set_event_handler(source, ^{
    char c;
    if (read(0, &c, 1) > 0) {
      if (show_help) {
        if (c == 'q' || c == 'Q' || c == 27) {
          intHandler(0);
        } else {
          show_help = NO;
          printf("\033[2J");
          fflush(stdout);
        }
      } else {
        if (c == 'q' || c == 'Q' || c == 27) {
          intHandler(0);
        } else if (c == 'h' || c == 'H' || c == '?') {
          show_help = YES;
          printHelpMenu();
        } else if (c == 's' || c == 'S') {
          should_capture_manual = YES;
        } else if (c == 'm' || c == 'M') {
          mirror_mode = (mirror_mode + 1) % 4;
        } else if (c == 'c' || c == 'C') {
          color_map = (color_map + 1) % 11;
        } else if (c == ' ') {
          paused = !paused;
        } else if (c == '[') {
          contrast_factor = fmax(0.5, contrast_factor - 0.05);
        } else if (c == ']') {
          contrast_factor = fmin(3.0, contrast_factor + 0.05);
        } else if (c == '+' || c == '=') {
          if (pixel_scale > 1) {
            pixel_scale--;
          }
        } else if (c == '-') {
          if (pixel_scale < 20) {
            pixel_scale++;
          }
        }
      }
    }
  });

  dispatch_resume(source);
}

void intHandler(int sig) {
  printf("\033[0;0H"); // Move cursor to top left
  printf("\033[2J");   // Clear screen
  printf("\x1B[?25h");  // Re-enable cursor
  fflush(stdout);
  disableRawMode();
  exit(0);
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    if (argc > 1) {
      int val = atoi(argv[1]);
      if (val >= 0) {
        record_interval = val;
      } else {
        fprintf(stderr, "Usage: %s [record-interval-seconds (default: 0/off)]\n", argv[0]);
        return 1;
      }
    }

    enableRawMode();
    setupKeyboardListener();
    signal(SIGINT, intHandler);

    // Clear screen and hide cursor
    printf("\033[2J");
    printf("\x1B[?25l");
    fflush(stdout);

    AVCaptureSession *session = [[AVCaptureSession alloc] init];
    [session setSessionPreset:AVCaptureSessionPreset640x480];

    AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    if (!device) {
      fprintf(stderr, "Error: No video device found.\n");
      return 1;
    }

    NSError *error = nil;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
    if (!input) {
      fprintf(stderr, "Error: Could not open camera input: %s\n", [[error localizedDescription] UTF8String]);
      return 1;
    }
    [session addInput:input];

    AVCaptureVideoDataOutput *output = [[AVCaptureVideoDataOutput alloc] init];
    [output setVideoSettings:@{
      (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)
    }];

    CaptureDelegate *delegate = [[CaptureDelegate alloc] init];
    dispatch_queue_t queue = dispatch_queue_create("CameraQueue", DISPATCH_QUEUE_SERIAL);
    [output setSampleBufferDelegate:delegate queue:queue];
    [session addOutput:output];

    [session startRunning];

    // Run the main run loop so callbacks are processed
    [[NSRunLoop mainRunLoop] run];
  }
  return 0;
}
