/*
 * PhoneGap is available under *either* the terms of the modified BSD license *or* the
 * MIT License (2008). See http://opensource.org/licenses/alphabetical for full text.
 *
 * Copyright 2011 Matt Kane. All rights reserved.
 * Copyright (c) 2011, IBM Corporation
 */

#import <AVFoundation/AVFoundation.h>
#import <AssetsLibrary/AssetsLibrary.h>
#import <Cordova/CDVPlugin.h>


//------------------------------------------------------------------------------
// Delegate to handle orientation functions
//------------------------------------------------------------------------------
@protocol CDVBarcodeScannerOrientationDelegate <NSObject>

- (NSUInteger)supportedInterfaceOrientations;
- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)interfaceOrientation;
- (BOOL)shouldAutorotate;

@end

//------------------------------------------------------------------------------
// Adds a shutter button to the UI, and changes the scan from continuous to
// only performing a scan when you click the shutter button.  For testing.
//------------------------------------------------------------------------------
#define USE_SHUTTER 0

//------------------------------------------------------------------------------
@class CDVbcsProcessor;
@class CDVbcsViewController;

//------------------------------------------------------------------------------
// plugin class
//------------------------------------------------------------------------------
@interface CDVBarcodeScanner : CDVPlugin {}
- (NSString*)isScanNotPossible;
- (void)scan:(CDVInvokedUrlCommand*)command;
- (void)encode:(CDVInvokedUrlCommand*)command;
- (void)returnImage:(NSString*)filePath format:(NSString*)format callback:(NSString*)callback;
- (void)returnSuccess:(NSString*)scannedText format:(NSString*)format cancelled:(BOOL)cancelled flipped:(BOOL)flipped callback:(NSString*)callback;
- (void)returnError:(NSString*)message callback:(NSString*)callback;
@end

//------------------------------------------------------------------------------
// class that does the grunt work
//------------------------------------------------------------------------------
@interface CDVbcsProcessor : NSObject <AVCaptureMetadataOutputObjectsDelegate> {}
@property (nonatomic, retain) CDVBarcodeScanner*          plugin;
@property (nonatomic, retain) NSString*                   callback;
@property (nonatomic, retain) UIViewController*           parentViewController;
@property (nonatomic, retain) CDVbcsViewController*       viewController;
@property (nonatomic, retain) AVCaptureSession*           captureSession;
@property (nonatomic, retain) AVCaptureVideoPreviewLayer* previewLayer;
@property (nonatomic, retain) NSString*                   alternateXib;
@property (nonatomic, retain) NSMutableArray*             results;
@property (nonatomic, retain) NSString*                   formats;
@property (nonatomic)         BOOL                        is1D;
@property (nonatomic)         BOOL                        is2D;
@property (nonatomic)         BOOL                        capturing;
@property (nonatomic)         BOOL                        isFrontCamera;
@property (nonatomic)         BOOL                        isShowFlipCameraButton;
@property (nonatomic)         BOOL                        isShowTorchButton;
@property (nonatomic)         BOOL                        isFlipped;
@property (nonatomic)         BOOL                        isTransitionAnimated;
@property (nonatomic)         BOOL                        isSuccessBeepEnabled;
@property (nonatomic)         NSString*                   statusMessage;


- (id)initWithPlugin:(CDVBarcodeScanner*)plugin callback:(NSString*)callback parentViewController:(UIViewController*)parentViewController alterateOverlayXib:(NSString *)alternateXib;
- (void)scanBarcode;
- (void)barcodeScanSucceeded:(NSString*)text format:(NSString*)format;
- (void)barcodeScanFailed:(NSString*)message;
- (void)barcodeScanCancelled;
- (void)openDialog;
- (NSString*)setUpCaptureSession;
- (void)captureOutput:(AVCaptureOutput*)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection*)connection;
@end

//------------------------------------------------------------------------------
// Qr encoder processor
//------------------------------------------------------------------------------
@interface CDVqrProcessor: NSObject
@property (nonatomic, retain) CDVBarcodeScanner*          plugin;
@property (nonatomic, retain) NSString*                   callback;
@property (nonatomic, retain) NSString*                   stringToEncode;
@property                     NSInteger                   size;

- (id)initWithPlugin:(CDVBarcodeScanner*)plugin callback:(NSString*)callback stringToEncode:(NSString*)stringToEncode;
- (void)generateImage;
@end

//------------------------------------------------------------------------------
// view controller for the ui
//------------------------------------------------------------------------------
@interface CDVbcsViewController : UIViewController <CDVBarcodeScannerOrientationDelegate> {}
@property (nonatomic, retain) CDVbcsProcessor*  processor;
@property (nonatomic, retain) NSString*        alternateXib;
@property (nonatomic)         BOOL             shutterPressed;
@property (nonatomic, retain) IBOutlet UIView* overlayView;
@property (nonatomic, retain) UIToolbar * toolbar;
@property (nonatomic, retain) UIView * reticleView;
@property (nonatomic, retain) UIImageView * buttonTorch;
@property (nonatomic, retain) UIView * lineView;
@property (nonatomic, strong) CADisplayLink * scanLineRefresh;
@property (nonatomic)         int scanLineStep;
// unsafe_unretained is equivalent to assign - used to prevent retain cycles in the property below
@property (nonatomic, unsafe_unretained) id orientationDelegate;

- (id)initWithProcessor:(CDVbcsProcessor*)processor alternateOverlay:(NSString *)alternateXib;
- (void)startCapturing;
- (UIView*)buildOverlayView;
- (UIImage*)buildReticleImage;
- (UIImage*)buildLineImage;
- (void)shutterButtonPressed;
- (IBAction)cancelButtonPressed:(id)sender;
- (IBAction)flipCameraButtonPressed:(id)sender;
- (IBAction)torchButtonPressed:(id)sender;
- (IBAction)startRefresh:(id)sender;

@end

//------------------------------------------------------------------------------
// plugin class
//------------------------------------------------------------------------------
@implementation CDVBarcodeScanner

//--------------------------------------------------------------------------
- (NSString*)isScanNotPossible {
    NSString* result = nil;

    Class aClass = NSClassFromString(@"AVCaptureSession");
    if (aClass == nil) {
        return @"AVFoundation Framework not available";
    }

    return result;
}

-(BOOL)notHasPermission
{
    AVAuthorizationStatus authStatus = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    return (authStatus == AVAuthorizationStatusDenied ||
            authStatus == AVAuthorizationStatusRestricted);
}

-(BOOL)isUsageDescriptionSet
{
  NSDictionary * plist = [[NSBundle mainBundle] infoDictionary];
  if ([plist objectForKey:@"NSCameraUsageDescription" ]) {
    return YES;
  }
  return NO;
}



//--------------------------------------------------------------------------
- (void)scan:(CDVInvokedUrlCommand*)command {
    CDVbcsProcessor* processor;
    NSString*       callback;
    NSString*       capabilityError;

    callback = command.callbackId;

    NSDictionary* options;
    if (command.arguments.count == 0) {
      options = [NSDictionary dictionary];
    } else {
      options = command.arguments[0];
    }

    BOOL preferFrontCamera = [options[@"preferFrontCamera"] boolValue];
    BOOL showFlipCameraButton = [options[@"showFlipCameraButton"] boolValue];
    BOOL showTorchButton = [options[@"showTorchButton"] boolValue];
    BOOL disableAnimations = [options[@"disableAnimations"] boolValue];
    BOOL disableSuccessBeep = [options[@"disableSuccessBeep"] boolValue];

    // We allow the user to define an alternate xib file for loading the overlay.
    NSString *overlayXib = options[@"overlayXib"];

    capabilityError = [self isScanNotPossible];
    if (capabilityError) {
        [self returnError:capabilityError callback:callback];
        return;
    } else if ([self notHasPermission]) {
        NSString * error = NSLocalizedString(@"Access to the camera has been prohibited; please enable it in the Settings app to continue.",nil);
        [self returnError:error callback:callback];
        return;
    } else if (![self isUsageDescriptionSet]) {
      NSString * error = NSLocalizedString(@"NSCameraUsageDescription is not set in the info.plist", nil);
      [self returnError:error callback:callback];
      return;
    }

    processor = [[CDVbcsProcessor alloc]
                initWithPlugin:self
                      callback:callback
          parentViewController:self.viewController
            alterateOverlayXib:overlayXib
            ];
    // queue [processor scanBarcode] to run on the event loop

    if (preferFrontCamera) {
      processor.isFrontCamera = true;
    }

    if (showFlipCameraButton) {
      processor.isShowFlipCameraButton = true;
    }

    if (showTorchButton) {
      processor.isShowTorchButton = true;
    }

    processor.isSuccessBeepEnabled = !disableSuccessBeep;

    processor.isTransitionAnimated = !disableAnimations;

    processor.formats = options[@"formats"];
    
    processor.statusMessage = options[@"prompt"];

    [processor performSelector:@selector(scanBarcode) withObject:nil afterDelay:0];
}

//--------------------------------------------------------------------------
- (void)encode:(CDVInvokedUrlCommand*)command {
    if([command.arguments count] < 1)
        [self returnError:@"Too few arguments!" callback:command.callbackId];

    CDVqrProcessor* processor;
    NSString*       callback;
    callback = command.callbackId;

    processor = [[CDVqrProcessor alloc]
                 initWithPlugin:self
                 callback:callback
                 stringToEncode: command.arguments[0][@"data"]
                 ];
    // queue [processor generateImage] to run on the event loop
    [processor performSelector:@selector(generateImage) withObject:nil afterDelay:0];
}

- (void)returnImage:(NSString*)filePath format:(NSString*)format callback:(NSString*)callback{
    NSMutableDictionary* resultDict = [[NSMutableDictionary alloc] init];
    resultDict[@"format"] = format;
    resultDict[@"file"] = filePath;

    CDVPluginResult* result = [CDVPluginResult
                               resultWithStatus: CDVCommandStatus_OK
                               messageAsDictionary:resultDict
                               ];

    [[self commandDelegate] sendPluginResult:result callbackId:callback];
}

//--------------------------------------------------------------------------
- (void)returnSuccess:(NSString*)scannedText format:(NSString*)format cancelled:(BOOL)cancelled flipped:(BOOL)flipped callback:(NSString*)callback{
    NSNumber* cancelledNumber = @(cancelled ? 1 : 0);

    NSMutableDictionary* resultDict = [NSMutableDictionary new];
    resultDict[@"text"] = scannedText;
    resultDict[@"format"] = format;
    resultDict[@"cancelled"] = cancelledNumber;

    CDVPluginResult* result = [CDVPluginResult
                               resultWithStatus: CDVCommandStatus_OK
                               messageAsDictionary: resultDict
                               ];
    [self.commandDelegate sendPluginResult:result callbackId:callback];
}

//--------------------------------------------------------------------------
- (void)returnError:(NSString*)message callback:(NSString*)callback {
    CDVPluginResult* result = [CDVPluginResult
                               resultWithStatus: CDVCommandStatus_ERROR
                               messageAsString: message
                               ];

    [self.commandDelegate sendPluginResult:result callbackId:callback];
}

@end

//------------------------------------------------------------------------------
// class that does the grunt work
//------------------------------------------------------------------------------
@implementation CDVbcsProcessor

@synthesize plugin               = _plugin;
@synthesize callback             = _callback;
@synthesize parentViewController = _parentViewController;
@synthesize viewController       = _viewController;
@synthesize captureSession       = _captureSession;
@synthesize previewLayer         = _previewLayer;
@synthesize alternateXib         = _alternateXib;
@synthesize is1D                 = _is1D;
@synthesize is2D                 = _is2D;
@synthesize capturing            = _capturing;
@synthesize results              = _results;

SystemSoundID _soundFileObject;

//--------------------------------------------------------------------------
- (id)initWithPlugin:(CDVBarcodeScanner*)plugin
            callback:(NSString*)callback
parentViewController:(UIViewController*)parentViewController
  alterateOverlayXib:(NSString *)alternateXib {
    self = [super init];
    if (!self) return self;

    self.plugin               = plugin;
    self.callback             = callback;
    self.parentViewController = parentViewController;
    self.alternateXib         = alternateXib;

    self.is1D      = YES;
    self.is2D      = YES;
    self.capturing = NO;
    self.results = [NSMutableArray new];

    CFURLRef soundFileURLRef  = CFBundleCopyResourceURL(CFBundleGetMainBundle(), CFSTR("CDVBarcodeScanner.bundle/beep"), CFSTR ("caf"), NULL);
    AudioServicesCreateSystemSoundID(soundFileURLRef, &_soundFileObject);

    return self;
}

//--------------------------------------------------------------------------
- (void)dealloc {
    self.plugin = nil;
    self.callback = nil;
    self.parentViewController = nil;
    self.viewController = nil;
    self.captureSession = nil;
    self.previewLayer = nil;
    self.alternateXib = nil;
    self.results = nil;

    self.capturing = NO;

    AudioServicesRemoveSystemSoundCompletion(_soundFileObject);
    AudioServicesDisposeSystemSoundID(_soundFileObject);
}

//--------------------------------------------------------------------------
- (void)scanBarcode {

//    self.captureSession = nil;
//    self.previewLayer = nil;
    NSString* errorMessage = [self setUpCaptureSession];
    if (errorMessage) {
        [self barcodeScanFailed:errorMessage];
        return;
    }

    self.viewController = [[CDVbcsViewController alloc] initWithProcessor: self alternateOverlay:self.alternateXib];
    // here we set the orientation delegate to the MainViewController of the app (orientation controlled in the Project Settings)
    self.viewController.orientationDelegate = self.plugin.viewController;

    // delayed [self openDialog];
    [self performSelector:@selector(openDialog) withObject:nil afterDelay:1];
}

//--------------------------------------------------------------------------
- (void)openDialog {
    [self.parentViewController
     presentViewController:self.viewController
     animated:self.isTransitionAnimated completion:nil
     ];
}

//--------------------------------------------------------------------------
// 扫码结束时调用
- (void)barcodeScanDone:(void (^)(void))callbackBlock {
    self.capturing = NO;
    [self.captureSession stopRunning];
    [self.parentViewController dismissViewControllerAnimated:self.isTransitionAnimated completion:callbackBlock];

    // 释放扫码线刷新
    [self.viewController.scanLineRefresh invalidate];
    self.viewController.scanLineRefresh = nil;
    
    // viewcontroller holding onto a reference to us, release them so they will release us
    // will release us
    self.viewController = nil;
    
}

//--------------------------------------------------------------------------
- (BOOL)checkResult:(NSString *)result {
    [self.results addObject:result];

    NSInteger treshold = 7;

    if (self.results.count > treshold) {
        [self.results removeObjectAtIndex:0];
    }

    if (self.results.count < treshold)
    {
        return NO;
    }

    BOOL allEqual = YES;
    NSString *compareString = self.results[0];

    for (NSString *aResult in self.results)
    {
        if (![compareString isEqualToString:aResult])
        {
            allEqual = NO;
            //NSLog(@"Did not fit: %@",self.results);
            break;
        }
    }

    return allEqual;
}

//--------------------------------------------------------------------------
- (void)barcodeScanSucceeded:(NSString*)text format:(NSString*)format {
    dispatch_sync(dispatch_get_main_queue(), ^{
        if (self.isSuccessBeepEnabled) {
            AudioServicesPlaySystemSound(_soundFileObject);
        }
        [self barcodeScanDone:^{
            [self.plugin returnSuccess:text format:format cancelled:FALSE flipped:FALSE callback:self.callback];
        }];
    });
}

//--------------------------------------------------------------------------
- (void)barcodeScanFailed:(NSString*)message {
    dispatch_sync(dispatch_get_main_queue(), ^{
        [self barcodeScanDone:^{
            [self.plugin returnError:message callback:self.callback];
        }];
    });
}

//--------------------------------------------------------------------------
// 事件定义
//--------------------------------------------------------------------------
// 取消扫码
- (void)barcodeScanCancelled {
    [self barcodeScanDone:^{
        [self.plugin returnSuccess:@"" format:@"" cancelled:TRUE flipped:self.isFlipped callback:self.callback];
    }];
    if (self.isFlipped) {
        self.isFlipped = NO;
    }
}
// 切换前后摄像头
- (void)flipCamera {
    self.isFlipped = YES;
    self.isFrontCamera = !self.isFrontCamera;
    [self barcodeScanDone:^{
        if (self.isFlipped) {
            self.isFlipped = NO;
        }
    [self performSelector:@selector(scanBarcode) withObject:nil afterDelay:0.1];
    }];
}
// 开关电筒
- (void)toggleTorch {
  AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
  [device lockForConfiguration:nil];
  if (device.flashActive) {
    UIImage* tourchImg = [UIImage imageNamed:@"CDVBarcodeScanner.bundle/torch_off"];
    self.viewController.buttonTorch.image = tourchImg;
    [device setTorchMode:AVCaptureTorchModeOff];
    [device setFlashMode:AVCaptureFlashModeOff];
  } else {
    UIImage* tourchImg = [UIImage imageNamed:@"CDVBarcodeScanner.bundle/torch_on"];
    self.viewController.buttonTorch.image = tourchImg;
    [device setTorchModeOnWithLevel:AVCaptureMaxAvailableTorchLevel error:nil];
    [device setFlashMode:AVCaptureFlashModeOn];
  }
  [device unlockForConfiguration];
}

// 绘制刷新定时器
- (void)scanLineRefresh {
    UIView* scanLine = self.viewController.lineView;
    CGRect bounds = self.viewController.reticleView.frame;
    double scale = 3.57142857;
    int step = self.viewController.scanLineStep ++;
    if(step > (bounds.size.height - bounds.size.height / scale)){
        step = self.viewController.scanLineStep = 0;
    }
    
    scanLine.transform = CGAffineTransformMakeTranslation(0, +step);
    
}

//--------------------------------------------------------------------------
- (NSString*)setUpCaptureSession {
    NSError* error = nil;

    AVCaptureSession* captureSession = [[AVCaptureSession alloc] init];
    self.captureSession = captureSession;

       AVCaptureDevice* __block device = nil;
    if (self.isFrontCamera) {

        NSArray* devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
        [devices enumerateObjectsUsingBlock:^(AVCaptureDevice *obj, NSUInteger idx, BOOL *stop) {
            if (obj.position == AVCaptureDevicePositionFront) {
                device = obj;
            }
        }];
    } else {
        device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
        if (!device) return @"unable to obtain video capture device";

    }

    // set focus params if available to improve focusing
    [device lockForConfiguration:&error];
    if (error == nil) {
        if([device isFocusModeSupported:AVCaptureFocusModeContinuousAutoFocus]) {
            [device setFocusMode:AVCaptureFocusModeContinuousAutoFocus];
        }
        if([device isAutoFocusRangeRestrictionSupported]) {
            [device setAutoFocusRangeRestriction:AVCaptureAutoFocusRangeRestrictionNear];
        }
    }
    [device unlockForConfiguration];

    AVCaptureDeviceInput* input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
    if (!input) return @"unable to obtain video capture device input";

    AVCaptureMetadataOutput* output = [[AVCaptureMetadataOutput alloc] init];
    if (!output) return @"unable to obtain video capture output";

    [output setMetadataObjectsDelegate:self queue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0)];

    if ([captureSession canSetSessionPreset:AVCaptureSessionPresetHigh]) {
      captureSession.sessionPreset = AVCaptureSessionPresetHigh;
    } else if ([captureSession canSetSessionPreset:AVCaptureSessionPresetMedium]) {
      captureSession.sessionPreset = AVCaptureSessionPresetMedium;
    } else {
      return @"unable to preset high nor medium quality video capture";
    }

    if ([captureSession canAddInput:input]) {
        [captureSession addInput:input];
    }
    else {
        return @"unable to add video capture device input to session";
    }

    if ([captureSession canAddOutput:output]) {
        [captureSession addOutput:output];
    }
    else {
        return @"unable to add video capture output to session";
    }

    [output setMetadataObjectTypes:[self formatObjectTypes]];

    // setup capture preview layer
    self.previewLayer = [AVCaptureVideoPreviewLayer layerWithSession:captureSession];
    self.previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;

    // run on next event loop pass [captureSession startRunning]
    [captureSession performSelector:@selector(startRunning) withObject:nil afterDelay:0];

    return nil;
}

//--------------------------------------------------------------------------
// this method gets sent the captured frames
//--------------------------------------------------------------------------
- (void)captureOutput:(AVCaptureOutput*)captureOutput didOutputMetadataObjects:(NSArray *)metadataObjects fromConnection:(AVCaptureConnection*)connection {

    if (!self.capturing) return;

#if USE_SHUTTER
    if (!self.viewController.shutterPressed) return;
    self.viewController.shutterPressed = NO;

    UIView* flashView = [[UIView alloc] initWithFrame:self.viewController.view.frame];
    [flashView setBackgroundColor:[UIColor whiteColor]];
    [self.viewController.view.window addSubview:flashView];

    [UIView
     animateWithDuration:.4f
     animations:^{
         [flashView setAlpha:0.f];
     }
     completion:^(BOOL finished){
         [flashView removeFromSuperview];
     }
     ];
#endif


    try {
        // This will bring in multiple entities if there are multiple 2D codes in frame.
        for (AVMetadataObject *metaData in metadataObjects) {
            AVMetadataMachineReadableCodeObject* code = (AVMetadataMachineReadableCodeObject*)[self.previewLayer transformedMetadataObjectForMetadataObject:(AVMetadataMachineReadableCodeObject*)metaData];

            if ([self checkResult:code.stringValue]) {
                [self barcodeScanSucceeded:code.stringValue format:[self formatStringFromMetadata:code]];
            }
        }
    }
    catch (...) {
        //            NSLog(@"decoding: unknown exception");
        //            [self barcodeScanFailed:@"unknown exception decoding barcode"];
    }

    //        NSTimeInterval timeElapsed  = [NSDate timeIntervalSinceReferenceDate] - timeStart;
    //        NSLog(@"decoding completed in %dms", (int) (timeElapsed * 1000));

}

//--------------------------------------------------------------------------
// convert metadata object information to barcode format string
//--------------------------------------------------------------------------
- (NSString*)formatStringFromMetadata:(AVMetadataMachineReadableCodeObject*)format {
    if (format.type == AVMetadataObjectTypeQRCode)          return @"QR_CODE";
    if (format.type == AVMetadataObjectTypeAztecCode)       return @"AZTEC";
    if (format.type == AVMetadataObjectTypeDataMatrixCode)  return @"DATA_MATRIX";
    if (format.type == AVMetadataObjectTypeUPCECode)        return @"UPC_E";
    // According to Apple documentation, UPC_A is EAN13 with a leading 0.
    if (format.type == AVMetadataObjectTypeEAN13Code && [format.stringValue characterAtIndex:0] == '0') return @"UPC_A";
    if (format.type == AVMetadataObjectTypeEAN8Code)        return @"EAN_8";
    if (format.type == AVMetadataObjectTypeEAN13Code)       return @"EAN_13";
    if (format.type == AVMetadataObjectTypeCode128Code)     return @"CODE_128";
    if (format.type == AVMetadataObjectTypeCode93Code)      return @"CODE_93";
    if (format.type == AVMetadataObjectTypeCode39Code)      return @"CODE_39";
    if (format.type == AVMetadataObjectTypeInterleaved2of5Code) return @"ITF";
    if (format.type == AVMetadataObjectTypeITF14Code)          return @"ITF_14";

    if (format.type == AVMetadataObjectTypePDF417Code)      return @"PDF_417";
    return @"???";
}

//--------------------------------------------------------------------------
// convert string formats to metadata objects
//--------------------------------------------------------------------------
- (NSArray*) formatObjectTypes {
    NSArray *supportedFormats = nil;
    if (self.formats != nil) {
        supportedFormats = [self.formats componentsSeparatedByString:@","];
    }

    NSMutableArray * formatObjectTypes = [NSMutableArray array];

    if (self.formats == nil || [supportedFormats containsObject:@"QR_CODE"]) [formatObjectTypes addObject:AVMetadataObjectTypeQRCode];
    if (self.formats == nil || [supportedFormats containsObject:@"AZTEC"]) [formatObjectTypes addObject:AVMetadataObjectTypeAztecCode];
    if (self.formats == nil || [supportedFormats containsObject:@"DATA_MATRIX"]) [formatObjectTypes addObject:AVMetadataObjectTypeDataMatrixCode];
    if (self.formats == nil || [supportedFormats containsObject:@"UPC_E"]) [formatObjectTypes addObject:AVMetadataObjectTypeUPCECode];
    if (self.formats == nil || [supportedFormats containsObject:@"EAN_8"]) [formatObjectTypes addObject:AVMetadataObjectTypeEAN8Code];
    if (self.formats == nil || [supportedFormats containsObject:@"EAN_13"]) [formatObjectTypes addObject:AVMetadataObjectTypeEAN13Code];
    if (self.formats == nil || [supportedFormats containsObject:@"CODE_128"]) [formatObjectTypes addObject:AVMetadataObjectTypeCode128Code];
    if (self.formats == nil || [supportedFormats containsObject:@"CODE_93"]) [formatObjectTypes addObject:AVMetadataObjectTypeCode93Code];
    if (self.formats == nil || [supportedFormats containsObject:@"CODE_39"]) [formatObjectTypes addObject:AVMetadataObjectTypeCode39Code];
    if (self.formats == nil || [supportedFormats containsObject:@"ITF"]) [formatObjectTypes addObject:AVMetadataObjectTypeInterleaved2of5Code];
    if (self.formats == nil || [supportedFormats containsObject:@"ITF_14"]) [formatObjectTypes addObject:AVMetadataObjectTypeITF14Code];
    if (self.formats == nil || [supportedFormats containsObject:@"PDF_417"]) [formatObjectTypes addObject:AVMetadataObjectTypePDF417Code];

    return formatObjectTypes;
}

@end

//------------------------------------------------------------------------------
// qr encoder processor
//------------------------------------------------------------------------------
@implementation CDVqrProcessor
@synthesize plugin               = _plugin;
@synthesize callback             = _callback;
@synthesize stringToEncode       = _stringToEncode;
@synthesize size                 = _size;

- (id)initWithPlugin:(CDVBarcodeScanner*)plugin callback:(NSString*)callback stringToEncode:(NSString*)stringToEncode{
    self = [super init];
    if (!self) return self;

    self.plugin          = plugin;
    self.callback        = callback;
    self.stringToEncode  = stringToEncode;
    self.size            = 300;

    return self;
}

//--------------------------------------------------------------------------
- (void)dealloc {
    self.plugin = nil;
    self.callback = nil;
    self.stringToEncode = nil;
}
//--------------------------------------------------------------------------
- (void)generateImage{
    /* setup qr filter */
    CIFilter *filter = [CIFilter filterWithName:@"CIQRCodeGenerator"];
    [filter setDefaults];

    /* set filter's input message
     * the encoding string has to be convert to a UTF-8 encoded NSData object */
    [filter setValue:[self.stringToEncode dataUsingEncoding:NSUTF8StringEncoding]
              forKey:@"inputMessage"];

    /* on ios >= 7.0  set low image error correction level */
    if (floor(NSFoundationVersionNumber) >= NSFoundationVersionNumber_iOS_7_0)
        [filter setValue:@"L" forKey:@"inputCorrectionLevel"];

    /* prepare cgImage */
    CIImage *outputImage = [filter outputImage];
    CIContext *context = [CIContext contextWithOptions:nil];
    CGImageRef cgImage = [context createCGImage:outputImage
                                       fromRect:[outputImage extent]];

    /* returned qr code image */
    UIImage *qrImage = [UIImage imageWithCGImage:cgImage
                                           scale:1.
                                     orientation:UIImageOrientationUp];
    /* resize generated image */
    CGFloat width = _size;
    CGFloat height = _size;

    UIGraphicsBeginImageContext(CGSizeMake(width, height));

    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSetInterpolationQuality(ctx, kCGInterpolationNone);
    [qrImage drawInRect:CGRectMake(0, 0, width, height)];
    qrImage = UIGraphicsGetImageFromCurrentImageContext();

    /* clean up */
    UIGraphicsEndImageContext();
    CGImageRelease(cgImage);

    /* save image to file */
    NSString* fileName = [[[NSProcessInfo processInfo] globallyUniqueString] stringByAppendingString:@".jpg"];
    NSString* filePath = [NSTemporaryDirectory() stringByAppendingPathComponent:fileName];
    [UIImageJPEGRepresentation(qrImage, 1.0) writeToFile:filePath atomically:YES];

    /* return file path back to cordova */
    [self.plugin returnImage:filePath format:@"QR_CODE" callback: self.callback];
}
@end

//------------------------------------------------------------------------------
// view controller for the ui
//------------------------------------------------------------------------------
@implementation CDVbcsViewController
@synthesize processor      = _processor;
@synthesize shutterPressed = _shutterPressed;
@synthesize alternateXib   = _alternateXib;
@synthesize overlayView    = _overlayView;

//--------------------------------------------------------------------------
- (id)initWithProcessor:(CDVbcsProcessor*)processor alternateOverlay:(NSString *)alternateXib {
    self = [super init];
    if (!self) return self;

    self.processor = processor;
    self.shutterPressed = NO;
    self.alternateXib = alternateXib;
    self.overlayView = nil;
    return self;
}

//--------------------------------------------------------------------------
- (void)dealloc {
    self.view = nil;
    self.processor = nil;
    self.shutterPressed = NO;
    self.alternateXib = nil;
    self.overlayView = nil;
}

//--------------------------------------------------------------------------
- (void)loadView {
    self.view = [[UIView alloc] initWithFrame: self.processor.parentViewController.view.frame];
}

//--------------------------------------------------------------------------
- (void)viewWillAppear:(BOOL)animated {

    // set video orientation to what the camera sees
    self.processor.previewLayer.connection.videoOrientation = (AVCaptureVideoOrientation) [[UIApplication sharedApplication] statusBarOrientation];

    // this fixes the bug when the statusbar is landscape, and the preview layer
    // starts up in portrait (not filling the whole view)
    self.processor.previewLayer.frame = self.view.bounds;
}

//--------------------------------------------------------------------------
- (void)viewDidAppear:(BOOL)animated {
    self.scanLineStep = 0;
    self.scanLineRefresh = [CADisplayLink displayLinkWithTarget:self selector:@selector(startRefresh:)];
    // 每隔1帧调用一次
    self.scanLineRefresh.frameInterval = 1;
    [self.scanLineRefresh addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
    // setup capture preview layer
    AVCaptureVideoPreviewLayer* previewLayer = self.processor.previewLayer;
    previewLayer.frame = self.view.bounds;
    previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;

    if ([previewLayer.connection isVideoOrientationSupported]) {
        [previewLayer.connection setVideoOrientation:[[UIApplication sharedApplication] statusBarOrientation]];
    }

    [self.view.layer insertSublayer:previewLayer below:[[self.view.layer sublayers] objectAtIndex:0]];

    [self.view addSubview:[self buildOverlayView]];
    [self startCapturing];

    [super viewDidAppear:animated];
}

//--------------------------------------------------------------------------
- (void)startCapturing {
    self.processor.capturing = YES;
}

//--------------------------------------------------------------------------
- (IBAction)shutterButtonPressed {
    self.shutterPressed = YES;
}

//--------------------------------------------------------------------------
- (IBAction)cancelButtonPressed:(id)sender {
    [self.processor performSelector:@selector(barcodeScanCancelled) withObject:nil afterDelay:0];
}

- (IBAction)flipCameraButtonPressed:(id)sender
{
    [self.processor performSelector:@selector(flipCamera) withObject:nil afterDelay:0];
}

- (IBAction)torchButtonPressed:(id)sender
{
  [self.processor performSelector:@selector(toggleTorch) withObject:nil afterDelay:0];
}

- (IBAction)startRefresh:(id)sender
{
    [self.processor performSelector:@selector(scanLineRefresh) withObject:nil afterDelay:0];
}

//--------------------------------------------------------------------------
// 从xlib中加载视图
- (UIView *)buildOverlayViewFromXib
{
    [[NSBundle mainBundle] loadNibNamed:self.alternateXib owner:self options:NULL];

    if ( self.overlayView == nil )
    {
        NSLog(@"%@", @"An error occurred loading the overlay xib.  It appears that the overlayView outlet is not set.");
        return nil;
    }

	self.overlayView.autoresizesSubviews = YES;
    self.overlayView.autoresizingMask    = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.overlayView.opaque              = NO;

	CGRect bounds = self.view.bounds;
    bounds = CGRectMake(0, 0, bounds.size.width, bounds.size.height);

	[self.overlayView setFrame:bounds];

    return self.overlayView;
}

//--------------------------------------------------------------------------
//按钮布局
- (UIView*)buildOverlayView {
    if ( nil != self.alternateXib )
    {
        return [self buildOverlayViewFromXib];
    }
    CGRect bounds = self.view.frame;
    bounds = CGRectMake(0, 0, bounds.size.width, bounds.size.height);

    UIView* overlayView = [[UIView alloc] initWithFrame:bounds];
    overlayView.autoresizesSubviews = YES;
    overlayView.autoresizingMask    = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlayView.opaque              = NO;
    
    // 绘制蒙版
    UIImage* maskImage = [self buildMaskImage];
    UIView* maskView = [[UIImageView alloc] initWithImage:maskImage];
    maskView.opaque = NO;
    maskView.contentMode = UIViewContentModeScaleAspectFill;
    maskView.autoresizingMask = 0;
    [overlayView addSubview: maskView];
    
    // 取消按钮
    UIImage* cancelImg = [UIImage imageNamed:@"CDVBarcodeScanner.bundle/cancel"];
    UIImageView* buttonCancel = [[UIImageView alloc] initWithImage:cancelImg];
    // 设置按钮的大小
    buttonCancel.frame = CGRectMake(bounds.size.width/2 - 21 - 60, bounds.size.height - (36 + 80), 42, 42);
    // 注册点击事件
    [buttonCancel setUserInteractionEnabled:YES];
    [buttonCancel addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(cancelButtonPressed:)]];
    // 将按钮添加到rootView控件中
    [overlayView addSubview:buttonCancel];
    
    // 电筒按钮
    UIImage* tourchImg = [UIImage imageNamed:@"CDVBarcodeScanner.bundle/torch_off"];
    self.buttonTorch = [[UIImageView alloc] initWithImage:tourchImg];
    // 设置按钮的大小
    self.buttonTorch.frame = CGRectMake(bounds.size.width/2 - 21 + 60, bounds.size.height - (36 + 80), 42, 42);
    // 注册点击事件
    [self.buttonTorch setUserInteractionEnabled:YES];
    [self.buttonTorch addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(torchButtonPressed:)]];
    // 将按钮添加到rootView控件中
    [overlayView addSubview:self.buttonTorch];
    
    // 扫码消息文本
    UITextField * textField = [[UITextField alloc]initWithFrame:CGRectMake(0, 50, bounds.size.width, 50)];
    textField.textColor = [UIColor whiteColor];
    textField.textAlignment = NSTextAlignmentCenter;
    textField.text = self.processor.statusMessage;
    textField.enabled = NO;
    [overlayView addSubview:textField];

    // 绘制扫码框
    UIImage* reticleImage = [self buildReticleImage];
    self.reticleView = [[UIImageView alloc] initWithImage:reticleImage];

    self.reticleView.opaque           = NO;
    self.reticleView.contentMode      = UIViewContentModeScaleAspectFit;
    self.reticleView.autoresizingMask = 0;
    [overlayView addSubview: self.reticleView];
    
    // 绘制扫码线
    double offsetWidth = bounds.size.width / 9.375;
    double offsetHeight = bounds.size.height / 22.233333;
    UIImage* lineImage = [UIImage imageNamed:@"CDVBarcodeScanner.bundle/line"];;
    self.lineView = [[UIImageView alloc] initWithImage:lineImage];
    self.lineView.frame = CGRectMake(bounds.size.width / 4 -  offsetWidth, bounds.size.height / 4 + offsetHeight, bounds.size.width / 2 + offsetWidth * 2, 4);
    self.lineView.opaque           = NO;
    self.lineView.contentMode      = UIViewContentModeScaleAspectFit;
    self.lineView.autoresizingMask = 0;
    [overlayView addSubview: self.lineView];
    
    
    [self resizeElements];
    return overlayView;
}
//--------------------------------------------------------------------------

#define RETICLE_SIZE    500.0f
#define RETICLE_WIDTH    4.0f
#define RETICLE_OFFSET   60.0f
#define RETICLE_ALPHA     0.4f

//--------------------------------------------------------------------------
// 绘制蒙版
//--------------------------------------------------------------------------
- (UIImage*)buildMaskImage {
    UIImage* result;
    CGRect bounds = self.view.bounds;
    UIGraphicsBeginImageContext(CGSizeMake(bounds.size.width, bounds.size.height));
    CGContextRef context = UIGraphicsGetCurrentContext();
    
    UIColor* color = [UIColor colorWithRed:0.0 green:0.0 blue:0.0 alpha:0.4f];
    CGContextSetLineWidth(context, 0);
    CGContextSetFillColorWithColor(context, color.CGColor);
    
    double scaleWidth = 8.5227277;
    double scaleHeight = 3.51052632;
    double offsetWidth = bounds.size.width / scaleWidth;
    double offsetHeight = bounds.size.height / scaleHeight;
    
    CGContextAddRect(context, CGRectMake(0 ,0 , bounds.size.width, offsetHeight));
    CGContextAddRect(context, CGRectMake(0 ,bounds.size.height - offsetHeight , bounds.size.width, offsetHeight));
    CGContextAddRect(context, CGRectMake(0 ,0 , offsetWidth, bounds.size.height));
    CGContextAddRect(context, CGRectMake(bounds.size.width - offsetWidth ,0 , offsetWidth, bounds.size.height));
    CGContextDrawPath(context, kCGPathFillStroke);
    result = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return result;
}

//-------------------------------------------------------------------------
// builds the green box and red line
//-------------------------------------------------------------------------
- (UIImage*)buildReticleImage {
    UIImage* result;
    UIGraphicsBeginImageContext(CGSizeMake(RETICLE_SIZE, RETICLE_SIZE));
    CGContextRef context = UIGraphicsGetCurrentContext();
   
    // 绘制扫描线
    if (self.processor.is1D) {
    }

    // 绘制扫描框
    if (self.processor.is2D) {
        UIColor* color = [UIColor colorWithRed:53/255.0 green:182/255.0 blue:151/255.0 alpha:1];
        
        CGContextSetStrokeColorWithColor(context, color.CGColor);
        CGContextSetLineWidth(context, RETICLE_WIDTH);
        // 左上
        CGPoint lth[2] = {CGPointMake(RETICLE_OFFSET, RETICLE_OFFSET + 1), CGPointMake(RETICLE_OFFSET + 30, RETICLE_OFFSET + 1)};
        CGContextAddLines(context, lth, 2);
        CGPoint ltv[2] = {CGPointMake(RETICLE_OFFSET + 1, RETICLE_OFFSET), CGPointMake(RETICLE_OFFSET + 1, RETICLE_OFFSET + 30)};
        CGContextAddLines(context, ltv, 2);
        // 左下
        CGPoint lbh[2] = {CGPointMake(RETICLE_OFFSET, RETICLE_SIZE - RETICLE_OFFSET - 1), CGPointMake(RETICLE_OFFSET + 30, RETICLE_SIZE - RETICLE_OFFSET - 1)};
        CGContextAddLines(context, lbh, 2);
        CGPoint lbv[2] = {CGPointMake(RETICLE_OFFSET + 1, RETICLE_SIZE - RETICLE_OFFSET), CGPointMake(RETICLE_OFFSET + 1, RETICLE_SIZE - RETICLE_OFFSET - 30)};
        CGContextAddLines(context, lbv, 2);
        // 右上
        CGPoint rth[2] = {CGPointMake(RETICLE_SIZE - RETICLE_OFFSET, RETICLE_OFFSET + 1), CGPointMake(RETICLE_SIZE - RETICLE_OFFSET - 30, RETICLE_OFFSET + 1)};
        CGContextAddLines(context, rth, 2);
        CGPoint rtv[2] = {CGPointMake(RETICLE_SIZE - RETICLE_OFFSET - 1, RETICLE_OFFSET), CGPointMake(RETICLE_SIZE - RETICLE_OFFSET - 1, RETICLE_OFFSET + 30)};
        CGContextAddLines(context, rtv, 2);
        // 右下
        CGPoint rbh[2] = {CGPointMake(RETICLE_SIZE - RETICLE_OFFSET, RETICLE_SIZE - RETICLE_OFFSET - 1), CGPointMake(RETICLE_SIZE - RETICLE_OFFSET - 30, RETICLE_SIZE - RETICLE_OFFSET - 1)};
        CGContextAddLines(context, rbh, 2);
        CGPoint rbv[2] = {CGPointMake(RETICLE_SIZE - RETICLE_OFFSET - 1, RETICLE_SIZE - RETICLE_OFFSET), CGPointMake(RETICLE_SIZE - RETICLE_OFFSET - 1, RETICLE_SIZE - RETICLE_OFFSET - 30)};
        CGContextAddLines(context, rbv, 2);
        
        CGContextStrokePath(context);
        
    }

    result = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return result;
}

//-------------------------------------------------------------------------
// 绘制扫码线
- (UIImage*)buildLineImage {
    UIImage* result;
    UIGraphicsBeginImageContext(CGSizeMake(RETICLE_SIZE, RETICLE_SIZE));
    CGContextRef context = UIGraphicsGetCurrentContext();
    
    UIColor* color = [UIColor colorWithRed:53/255.0 green:182/255.0 blue:151/255.0 alpha:RETICLE_ALPHA];
    CGContextSetStrokeColorWithColor(context, color.CGColor);
    CGContextSetLineWidth(context, RETICLE_WIDTH);
    CGPoint scanLine[2] = {CGPointMake(RETICLE_OFFSET + 20, RETICLE_OFFSET + 5), CGPointMake(RETICLE_SIZE - RETICLE_OFFSET - 20, RETICLE_OFFSET + 5)};
    CGContextAddLines(context, scanLine, 2);
    CGContextStrokePath(context);
    
    result = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return result;
}

#pragma mark CDVBarcodeScannerOrientationDelegate

- (BOOL)shouldAutorotate
{
    return YES;
}

- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation
{
    return [[UIApplication sharedApplication] statusBarOrientation];
}

- (NSUInteger)supportedInterfaceOrientations
{
    return UIInterfaceOrientationMaskAll;
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)interfaceOrientation
{
    if ((self.orientationDelegate != nil) && [self.orientationDelegate respondsToSelector:@selector(shouldAutorotateToInterfaceOrientation:)]) {
        return [self.orientationDelegate shouldAutorotateToInterfaceOrientation:interfaceOrientation];
    }

    return YES;
}

- (void) willAnimateRotationToInterfaceOrientation:(UIInterfaceOrientation)orientation duration:(NSTimeInterval)duration
{
    [UIView setAnimationsEnabled:NO];
    AVCaptureVideoPreviewLayer* previewLayer = self.processor.previewLayer;
    previewLayer.frame = self.view.bounds;

    if (orientation == UIInterfaceOrientationLandscapeLeft) {
        [previewLayer setOrientation:AVCaptureVideoOrientationLandscapeLeft];
    } else if (orientation == UIInterfaceOrientationLandscapeRight) {
        [previewLayer setOrientation:AVCaptureVideoOrientationLandscapeRight];
    } else if (orientation == UIInterfaceOrientationPortrait) {
        [previewLayer setOrientation:AVCaptureVideoOrientationPortrait];
    } else if (orientation == UIInterfaceOrientationPortraitUpsideDown) {
        [previewLayer setOrientation:AVCaptureVideoOrientationPortraitUpsideDown];
    }

    previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;

    [self resizeElements];
    [UIView setAnimationsEnabled:YES];
}

//----------------------------------------------------------------------------------
// 根据屏幕横放竖放重新绘制扫码框
//----------------------------------------------------------------------------------
-(void) resizeElements {
    CGRect bounds = self.view.bounds;
    if (@available(iOS 11.0, *)) {
        bounds = CGRectMake(bounds.origin.x, bounds.origin.y, bounds.size.width, self.view.safeAreaLayoutGuide.layoutFrame.size.height+self.view.safeAreaLayoutGuide.layoutFrame.origin.y);
    }

    [self.toolbar sizeToFit];
    CGFloat toolbarHeight  = [self.toolbar frame].size.height;
    CGFloat rootViewHeight = CGRectGetHeight(bounds);
    CGFloat rootViewWidth  = CGRectGetWidth(bounds);
    CGRect  rectArea       = CGRectMake(0, rootViewHeight - toolbarHeight, rootViewWidth, toolbarHeight);
    [self.toolbar setFrame:rectArea];

    CGFloat minAxis = MIN(rootViewHeight, rootViewWidth);

    rectArea = CGRectMake(
                          (CGFloat) (0.5 * (rootViewWidth  - minAxis)),
                          (CGFloat) (0.5 * (rootViewHeight - minAxis)),
                          minAxis,
                          minAxis
                          );

    [self.reticleView setFrame:rectArea];
    self.reticleView.center = CGPointMake(self.view.center.x, self.view.center.y-self.toolbar.frame.size.height/2);
}

@end
