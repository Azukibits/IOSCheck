#import <AppKit/AppKit.h>

static NSColor* HexColor(unsigned int hex, CGFloat alpha) {
    return [NSColor colorWithCalibratedRed:((hex >> 16) & 0xff) / 255.0
                                     green:((hex >> 8) & 0xff) / 255.0
                                      blue:(hex & 0xff) / 255.0
                                     alpha:alpha];
}

static NSImage* DrawIcon(CGFloat size) {
    NSBitmapImageRep* bitmap = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL
                      pixelsWide:(NSInteger)size
                      pixelsHigh:(NSInteger)size
                   bitsPerSample:8
                 samplesPerPixel:4
                        hasAlpha:YES
                        isPlanar:NO
                  colorSpaceName:NSCalibratedRGBColorSpace
                     bytesPerRow:0
                    bitsPerPixel:0];
    NSGraphicsContext* context = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:context];

    NSRect bounds = NSMakeRect(0, 0, size, size);
    NSBezierPath* outer = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(bounds, size * 0.03, size * 0.03)
                                                          xRadius:size * 0.23
                                                          yRadius:size * 0.23];
    NSGradient* shell = [[NSGradient alloc] initWithColors:@[
        HexColor(0x15304d, 1.0),
        HexColor(0x0f6d8c, 1.0),
        HexColor(0x82d9c9, 1.0)
    ]];
    [shell drawInBezierPath:outer angle:-55];

    [NSGraphicsContext saveGraphicsState];
    [outer addClip];

    [HexColor(0xdff9f5, 0.22) setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(size * 0.12, size * 0.56, size * 0.76, size * 0.38)] fill];

    NSBezierPath* card = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(size * 0.18, size * 0.21, size * 0.64, size * 0.58)
                                                         xRadius:size * 0.12
                                                         yRadius:size * 0.12];
    [HexColor(0xf7fbff, 1.0) setFill];
    [card fill];

    NSBezierPath* band = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(size * 0.18, size * 0.54, size * 0.64, size * 0.14)
                                                         xRadius:size * 0.07
                                                         yRadius:size * 0.07];
    [HexColor(0x15a7c7, 1.0) setFill];
    [band fill];

    NSGradient* body = [[NSGradient alloc] initWithColors:@[
        HexColor(0xffffff, 1.0),
        HexColor(0xddeff6, 1.0)
    ]];
    NSBezierPath* bodyRect = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(size * 0.18, size * 0.21, size * 0.64, size * 0.37)
                                                              xRadius:size * 0.1
                                                              yRadius:size * 0.1];
    [body drawInBezierPath:bodyRect angle:-90];

    [HexColor(0x17324c, 1.0) setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(size * 0.28, size * 0.34, size * 0.14, size * 0.14)] fill];

    [HexColor(0x284f69, 0.9) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(size * 0.47, size * 0.41, size * 0.22, size * 0.05)
                                     xRadius:size * 0.02
                                     yRadius:size * 0.02] fill];

    [HexColor(0x6a879d, 0.95) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(size * 0.47, size * 0.31, size * 0.16, size * 0.05)
                                     xRadius:size * 0.02
                                     yRadius:size * 0.02] fill];

    NSBezierPath* switchRing = [NSBezierPath bezierPath];
    switchRing.lineWidth = size * 0.08;
    [switchRing appendBezierPathWithArcWithCenter:NSMakePoint(size * 0.72, size * 0.27)
                                           radius:size * 0.12
                                       startAngle:210
                                         endAngle:30
                                        clockwise:NO];
    [HexColor(0xff8f3a, 1.0) setStroke];
    [switchRing stroke];

    NSBezierPath* arrow = [NSBezierPath bezierPath];
    [arrow moveToPoint:NSMakePoint(size * 0.83, size * 0.37)];
    [arrow lineToPoint:NSMakePoint(size * 0.88, size * 0.28)];
    [arrow lineToPoint:NSMakePoint(size * 0.78, size * 0.29)];
    [arrow closePath];
    [HexColor(0xff8f3a, 1.0) setFill];
    [arrow fill];

    NSBezierPath* shield = [NSBezierPath bezierPath];
    [shield moveToPoint:NSMakePoint(size * 0.2, size * 0.78)];
    [shield lineToPoint:NSMakePoint(size * 0.31, size * 0.73)];
    [shield curveToPoint:NSMakePoint(size * 0.26, size * 0.58)
            controlPoint1:NSMakePoint(size * 0.31, size * 0.67)
            controlPoint2:NSMakePoint(size * 0.31, size * 0.61)];
    [shield curveToPoint:NSMakePoint(size * 0.15, size * 0.73)
            controlPoint1:NSMakePoint(size * 0.21, size * 0.61)
            controlPoint2:NSMakePoint(size * 0.15, size * 0.67)];
    [shield closePath];
    [HexColor(0x1b445f, 0.92) setFill];
    [shield fill];

    NSBezierPath* check = [NSBezierPath bezierPath];
    check.lineWidth = size * 0.03;
    check.lineCapStyle = NSLineCapStyleRound;
    [check moveToPoint:NSMakePoint(size * 0.18, size * 0.69)];
    [check lineToPoint:NSMakePoint(size * 0.22, size * 0.65)];
    [check lineToPoint:NSMakePoint(size * 0.28, size * 0.75)];
    [HexColor(0x8ef0d4, 1.0) setStroke];
    [check stroke];

    [NSGraphicsContext restoreGraphicsState];

    outer.lineWidth = size * 0.012;
    [HexColor(0xffffff, 0.18) setStroke];
    [outer stroke];

    [NSGraphicsContext restoreGraphicsState];

    NSImage* image = [[NSImage alloc] initWithSize:NSMakeSize(size, size)];
    [image addRepresentation:bitmap];
    return image;
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSString* cwd = [[NSFileManager defaultManager] currentDirectoryPath];
        NSString* iconset = [cwd stringByAppendingPathComponent:@"assets/AppIcon.iconset"];
        NSString* tiffPath = [cwd stringByAppendingPathComponent:@"assets/AppIcon.tiff"];
        [[NSFileManager defaultManager] removeItemAtPath:iconset error:nil];
        [[NSFileManager defaultManager] createDirectoryAtPath:iconset withIntermediateDirectories:YES attributes:nil error:nil];

        NSArray<NSArray*>* specs = @[
            @[ @"icon_16x16.png", @16 ],
            @[ @"icon_16x16@2x.png", @32 ],
            @[ @"icon_32x32.png", @32 ],
            @[ @"icon_32x32@2x.png", @64 ],
            @[ @"icon_128x128.png", @128 ],
            @[ @"icon_128x128@2x.png", @256 ],
            @[ @"icon_256x256.png", @256 ],
            @[ @"icon_256x256@2x.png", @512 ],
            @[ @"icon_512x512.png", @512 ],
            @[ @"icon_512x512@2x.png", @1024 ],
        ];

        for (NSArray* spec in specs) {
            NSString* name = spec[0];
            CGFloat size = [spec[1] doubleValue];
            NSImage* image = DrawIcon(size);
            NSData* tiff = [image TIFFRepresentation];
            NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithData:tiff];
            NSData* png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
            NSString* path = [iconset stringByAppendingPathComponent:name];
            if (png == nil) {
                NSLog(@"Failed to create PNG for %@", name);
                return 1;
            }
            if (![png writeToFile:path atomically:NO]) {
                NSLog(@"Failed to write %@", path);
                return 1;
            }
        }

        NSImage* master = DrawIcon(1024);
        NSData* masterTiff = [master TIFFRepresentation];
        if (![masterTiff writeToFile:tiffPath atomically:NO]) {
            NSLog(@"Failed to write %@", tiffPath);
            return 1;
        }
    }

    return 0;
}
