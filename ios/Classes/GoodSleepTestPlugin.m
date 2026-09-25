#import "GoodSleepTestPlugin.h"
#import "ContecBluetoothSDK.h"
#import <CoreBluetooth/CoreBluetooth.h>

@interface GoodSleepTestPlugin () <
    FlutterStreamHandler,
    CBCentralManagerDelegate,
    ContecBluetoothDelegate>
@property(nonatomic, strong) FlutterMethodChannel *methodChannel;
@property(nonatomic, strong) FlutterEventChannel *eventChannel;
@property(nonatomic, copy) FlutterEventSink eventSink;
@property(nonatomic, strong) ContecBluetoothSDK *c_SDK;
@property(nonatomic, strong) CBCentralManager *manager;
@property(nonatomic, strong) NSMutableArray<CBPeripheral *> *devices;
@property(nonatomic, strong) CBPeripheral *selectedPeripheral;
@property(nonatomic, strong) CBPeripheral *connectingPeripheral;
@property(nonatomic, copy) FlutterResult pendingResult;
@property(nonatomic, assign) BOOL isConnected;
@end

@implementation GoodSleepTestPlugin

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  GoodSleepTestPlugin *instance = [[GoodSleepTestPlugin alloc] init];
  instance.methodChannel = [FlutterMethodChannel
      methodChannelWithName:@"com.contectcms.bluetooth_cms5"
            binaryMessenger:[registrar messenger]];
  [registrar addMethodCallDelegate:instance channel:instance.methodChannel];

  instance.eventChannel = [FlutterEventChannel
      eventChannelWithName:@"getRealTimeDataEventChannel"
           binaryMessenger:[registrar messenger]];
  [instance.eventChannel setStreamHandler:instance];

  instance.c_SDK = [[ContecBluetoothSDK alloc] init];
  instance.c_SDK.delegate = instance;
  instance.devices = [NSMutableArray array];
}

- (FlutterError *)onListenWithArguments:(id)arguments
                              eventSink:(FlutterEventSink)events {
  self.eventSink = events;
  return nil;
}

- (FlutterError *)onCancelWithArguments:(id)arguments {
  self.eventSink = nil;
  return nil;
}

- (void)handleMethodCall:(FlutterMethodCall *)call
                  result:(FlutterResult)result {
  self.pendingResult = result;
  NSString *method = call.method;

  if ([method isEqualToString:@"startSearch"]) {
    self.devices = [NSMutableArray array];
    self.selectedPeripheral = nil;
    self.manager = [[CBCentralManager alloc] initWithDelegate:self queue:nil];
  } else if ([method isEqualToString:@"stopSearch"]) {
    [self.manager stopScan];
    result(@"stopSearchExecuted");
  } else if ([method isEqualToString:@"connectDevice"]) {
    [self connectSpO2Device:result];
  } else if ([method isEqualToString:@"disconnectDevice"]) {
    if (self.connectingPeripheral) {
      [self.manager cancelPeripheralConnection:self.connectingPeripheral];
    }
    self.isConnected = NO;
    result(@"Disconnect Device");
  } else if ([method isEqualToString:@"isConnected"]) {
    result(self.isConnected ? @"Connected" : @"not connected Connected");
  } else if ([method isEqualToString:@"startRealtimeData"]) {
    if (self.connectingPeripheral) {
      [self.c_SDK peripheral:self.connectingPeripheral
          startReceiveRealtimeDataWithType:SpO2RealTimeDatatype_Value |
                                           SpO2RealTimeDatatype_Wave];
    }
    result(@"Okk");
  } else if ([method isEqualToString:@"stopRealtimeData"]) {
    if (self.connectingPeripheral) {
      [self.c_SDK endReceiveRealtimeDataWithPeripheral:self.connectingPeripheral];
    }
    result(@"Realtime Recording Stopped");
  } else if ([method isEqualToString:@"getBattery"]) {
    result(@"0");
  } else if ([method isEqualToString:@"deleteData"]) {
    if (self.connectingPeripheral) {
      [self.c_SDK peripheral:self.connectingPeripheral
                  deleteData:DeleteParameter_SpO2];
    }
    result(@"Data Deleted Successfully");
  } else {
    result(FlutterMethodNotImplemented);
  }
}

- (void)connectSpO2Device:(FlutterResult)result {
  for (CBPeripheral *peri in self.devices) {
    if ([peri.name hasPrefix:@"SpO2"]) {
      self.selectedPeripheral = peri;
      break;
    }
  }
  if (self.selectedPeripheral == nil ||
      ![self.selectedPeripheral.name hasPrefix:@"SpO2"]) {
    result(@"No SpO2 Device");
    return;
  }
  self.connectingPeripheral = self.selectedPeripheral;
  [self.manager connectPeripheral:self.selectedPeripheral options:nil];
  [self.manager stopScan];
  result(@"Device Connected");
}

#pragma mark - CBCentralManagerDelegate

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
  if (central.state == CBManagerStatePoweredOn) {
    [self.manager scanForPeripheralsWithServices:nil options:nil];
  } else if (self.pendingResult) {
    self.pendingResult(@"Bluetooth Not Supported");
    self.pendingResult = nil;
  }
}

- (void)centralManager:(CBCentralManager *)central
    didDiscoverPeripheral:(CBPeripheral *)peripheral
        advertisementData:(NSDictionary *)advertisementData
                     RSSI:(NSNumber *)RSSI {
  if (peripheral.name == nil) return;
  if (![self.devices containsObject:peripheral]) {
    [self.devices addObject:peripheral];
    [self.methodChannel invokeMethod:@"DEVICE_NAME" arguments:peripheral.name];
    if ([peripheral.name hasPrefix:@"SpO2"]) {
      self.selectedPeripheral = peripheral;
      [self.manager stopScan];
      if (self.pendingResult) {
        self.pendingResult([NSString
            stringWithFormat:@"search complete,found device:%@",
                             peripheral.name]);
        self.pendingResult = nil;
      }
    }
  }
}

- (void)centralManager:(CBCentralManager *)central
    didConnectPeripheral:(CBPeripheral *)peripheral {
  self.isConnected = YES;
  self.connectingPeripheral = peripheral;
}

- (void)centralManager:(CBCentralManager *)central
    didDisconnectPeripheral:(CBPeripheral *)peripheral
                      error:(NSError *)error {
  self.isConnected = NO;
  [self.methodChannel invokeMethod:@"ERROR" arguments:@"disconnect_dialog"];
}

#pragma mark - ContecBluetoothDelegate (required)

- (void)contec_getDeviceData:(NSDictionary *)dicDeviceData {
}

- (void)contec_getOperateResult:(NSDictionary *)dicOperateResult {
}

- (void)contec_getError:(NSDictionary *)dicError {
  [self.methodChannel invokeMethod:@"CONNECT-ERROR"
                         arguments:[dicError description]];
}

#pragma mark - ContecBluetoothDelegate (realtime)

- (void)contec_receivedRealtimeValueData:(NSDictionary *)valueDic {
  if (!self.eventSink) return;
  NSString *oxyData = valueDic[@"oxygen"];
  NSString *pulseData = valueDic[@"pulse"];
  self.eventSink(
      [NSString stringWithFormat:@"spo2Data,%@,%@", oxyData, pulseData]);
}

- (void)contec_receivedRealtimeWaveData:(NSDictionary *)waveDic {
  if (!self.eventSink) return;
  NSString *waveData = waveDic[@"pulseWave"];
  self.eventSink([NSString stringWithFormat:@"waveData,%@", waveData]);
}

@end
