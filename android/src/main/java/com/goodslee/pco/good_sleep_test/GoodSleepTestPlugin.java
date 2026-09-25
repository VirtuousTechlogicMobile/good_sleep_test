package com.goodslee.pco.good_sleep_test;

import android.Manifest;
import android.app.Activity;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.text.TextUtils;
import android.util.Log;

import androidx.annotation.NonNull;
import androidx.core.app.ActivityCompat;

import com.contec.cms50s.code.callback.BluetoothSearchCallback;
import com.contec.cms50s.code.callback.DeleteDataCallback;
import com.contec.cms50s.code.callback.GetDeviceBatteryCallback;
import com.contec.cms50s.code.callback.RealtimeCallback;
import com.contec.cms50s.code.connect.ContecSdk;
import com.contec.cms50s.code.tools.Utils;


import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.PluginRegistry;

/**
 * Contec CMS50S bridge — same channel names as the legacy Sleepcare MainActivity
 * so FlutterFlow Dart code can migrate with minimal changes.
 */
public class GoodSleepTestPlugin
        implements FlutterPlugin,
        ActivityAware,
        MethodChannel.MethodCallHandler,
        PluginRegistry.ActivityResultListener,
        PluginRegistry.RequestPermissionsResultListener {

    private static final String CHANNEL = "com.contectcms.bluetooth_cms5";
    private static final String STREAM = "getRealTimeDataEventChannel";
    private static final String TAG = "GoodSleepTestPlugin";
    private static final int REQUEST_ENABLE_BT = 1;
    private static final int REQUEST_BL = 21;
    private static final int REQUEST_ALL_PERMISSION = 0;

    private MethodChannel methodChannel;
    private EventChannel eventChannel;
    private EventChannel.EventSink eventSink;
    private Activity activity;
    private ActivityPluginBinding activityBinding;

    private BluetoothAdapter bluetoothAdapter = BluetoothAdapter.getDefaultAdapter();
    private ContecSdk sdk;
    private BluetoothDevice foundDevice;
    private String foundDeviceInfo;
    private boolean isConnected = false;
    private MethodChannel.Result pendingResult;
    private final Handler mainHandler = new Handler(Looper.getMainLooper());

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        methodChannel = new MethodChannel(binding.getBinaryMessenger(), CHANNEL);
        methodChannel.setMethodCallHandler(this);
        eventChannel = new EventChannel(binding.getBinaryMessenger(), STREAM);
        eventChannel.setStreamHandler(new EventChannel.StreamHandler() {
            @Override
            public void onListen(Object args, EventChannel.EventSink events) {
                eventSink = events;
            }

            @Override
            public void onCancel(Object args) {
                eventSink = null;
            }
        });
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        if (methodChannel != null) {
            methodChannel.setMethodCallHandler(null);
            methodChannel = null;
        }
        if (eventChannel != null) {
            eventChannel.setStreamHandler(null);
            eventChannel = null;
        }
    }

    @Override
    public void onAttachedToActivity(@NonNull ActivityPluginBinding binding) {
        activity = binding.getActivity();
        activityBinding = binding;
        binding.addActivityResultListener(this);
        binding.addRequestPermissionsResultListener(this);
        sdk = new ContecSdk(activity.getApplicationContext());
    }

    @Override
    public void onDetachedFromActivityForConfigChanges() {
        detachActivity();
    }

    @Override
    public void onReattachedToActivityForConfigChanges(@NonNull ActivityPluginBinding binding) {
        onAttachedToActivity(binding);
    }

    @Override
    public void onDetachedFromActivity() {
        detachActivity();
    }

    private void detachActivity() {
        if (activityBinding != null) {
            activityBinding.removeActivityResultListener(this);
            activityBinding.removeRequestPermissionsResultListener(this);
            activityBinding = null;
        }
        activity = null;
    }

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        pendingResult = result;
        if (activity == null || sdk == null) {
            result.error("NO_ACTIVITY", "Plugin not attached to an Activity", null);
            return;
        }

        requestRuntimePermissions();

        switch (call.method) {
            case "startSearch":
                if (checkBluetoothPermission()) {
                    foundDevice = null;
                    foundDeviceInfo = null;
                    startSearch(result);
                } else {
                    result.success("permissions_required");
                }
                break;
            case "stopSearch":
                sdk.stopBluetoothSearch();
                success(result, "stopSearchExecuted");
                break;
            case "connectDevice":
                connectDevice(call, result);
                break;
            case "disconnectDevice":
                sdk.disconnect();
                isConnected = false;
                success(result, "Disconnect Device");
                break;
            case "isConnected":
                success(result, isConnected ? "Connected" : "not connected Connected");
                break;
            case "getBattery":
                sdk.getDeviceBattery(new GetDeviceBatteryCallback() {
                    @Override
                    public void onFail(int errorCode) {
                        success(result, "Get Battery Failed");
                    }

                    @Override
                    public void onSuccess(int battery) {
                        success(result, battery);
                    }
                });
                break;
            case "deleteData":
                sdk.deleteData(new DeleteDataCallback() {
                    @Override
                    public void onSuccess(int status) {
                        success(result, "Data Deleted Successfully " + status);
                    }

                    @Override
                    public void onFail(int errorCode) {
                        success(result, "Delete Data Failed");
                    }
                });
                break;
            case "startRealtimeData":
                success(result, "ok");
                startRealtime();
                break;
            case "stopRealtimeData":
                sdk.stopRealtime();
                success(result, "Realtime Recording Stopped");
                break;
            default:
                result.notImplemented();
        }
    }

    private void startSearch(MethodChannel.Result result) {
        sdk.startBluetoothSearch(new BluetoothSearchCallback() {
            @Override
            public void onDeviceFound(final BluetoothDevice device, int rssi, final byte[] record) {
                mainHandler.post(() -> {
                    String name = device.getName();
                    Log.e(TAG, "search device = " + name);
                    if (methodChannel != null && name != null) {
                        methodChannel.invokeMethod("DEVICE_NAME", name);
                    }
                    if (name != null && name.contains("SpO2")) {
                        foundDevice = device;
                        foundDeviceInfo = name;
                        sdk.stopBluetoothSearch();
                    }
                    Log.e(TAG, "BYTE = " + Utils.bytesToHexString(record));
                });
            }

            @Override
            public void onSearchError(int errorCode) {
                if (errorCode == ContecSdk.NO_BLUETOOTH) {
                    success(result, "this no bluetooth");
                } else if (errorCode == ContecSdk.BLUETOOTH_CLOSE) {
                    success(result, "bluetooth not enable");
                }
            }

            @Override
            public void onSearchComplete() {
                mainHandler.post(() -> {
                    if (foundDevice != null) {
                        success(result, "search complete,found device:" + foundDeviceInfo);
                    } else {
                        success(result, "search complete,no device.");
                    }
                });
            }
        }, 20000);
    }

    private void connectDevice(MethodCall call, MethodChannel.Result result) {
        BluetoothDevice target = foundDevice;
        // Prefer device found during scan; optional future: resolve by name from args.
        Object selected = call.argument("selectedDevice");
        if (target == null) {
            success(result, "this is not 50s device " + foundDeviceInfo + " " + foundDevice);
            return;
        }
        if (TextUtils.isEmpty(target.getName()) || !target.getName().contains("SpO2")) {
            success(result, "this is not 50s device " + foundDeviceInfo + " " + foundDevice);
            return;
        }
        Log.e(TAG, "connect selected=" + selected + " device=" + target.getName());
        sdk.connect(target, status -> {
            Log.e(TAG, "connectStatus = " + status);
            if (status == ContecSdk.NOTIFY_SUCCESS) {
                isConnected = true;
            }
            if (status == ContecSdk.STATE_DISCONNECTED
                    || status == ContecSdk.STATE_ABNORMAL_DISCONNECTED
                    || status == ContecSdk.STATE_CANCEL_CONNECT) {
                if (methodChannel != null && status == ContecSdk.STATE_ABNORMAL_DISCONNECTED) {
                    mainHandler.post(() -> methodChannel.invokeMethod("ERROR", "disconnect_dialog"));
                }
                isConnected = false;
            }
        });
        success(result, "Device Connected Successfully");
    }

    private void startRealtime() {
        new Thread(() -> sdk.startRealtime(new RealtimeCallback() {
            @Override
            public void onFail(int errorCode) {
            }

            @Override
            public void onRealtimeWaveData(int signal, int prSound, final int waveData, int barData, int fingerOut) {
                mainHandler.post(() -> {
                    if (eventSink != null) {
                        eventSink.success("waveData," + waveData);
                    }
                });
            }

            @Override
            public void onSpo2Data(int piError, final int spo2, final int pr, int pi) {
                mainHandler.post(() -> {
                    if (eventSink != null) {
                        eventSink.success("spo2Data," + spo2 + "," + pr);
                    }
                });
            }

            @Override
            public void onRealtimeEnd() {
                Log.e(TAG, "real time end");
            }
        })).start();
    }

    private void requestRuntimePermissions() {
        if (activity == null) return;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            ActivityCompat.requestPermissions(
                    activity,
                    new String[]{
                            Manifest.permission.ACCESS_COARSE_LOCATION,
                            Manifest.permission.ACCESS_FINE_LOCATION,
                            Manifest.permission.BLUETOOTH_CONNECT,
                            Manifest.permission.BLUETOOTH_SCAN
                    },
                    REQUEST_ALL_PERMISSION);
        }
    }

    private boolean checkBluetoothPermission() {
        if (bluetoothAdapter == null || activity == null) return false;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            if (ActivityCompat.checkSelfPermission(activity, Manifest.permission.BLUETOOTH_CONNECT)
                    != PackageManager.PERMISSION_GRANTED) {
                ActivityCompat.requestPermissions(
                        activity,
                        new String[]{Manifest.permission.BLUETOOTH_CONNECT},
                        REQUEST_BL);
                return false;
            }
        }
        if (!bluetoothAdapter.isEnabled()) {
            Intent enableBtIntent = new Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE);
            activity.startActivityForResult(enableBtIntent, REQUEST_ENABLE_BT);
            return false;
        }
        return true;
    }

    @Override
    public boolean onActivityResult(int requestCode, int resultCode, Intent data) {
        if (requestCode == REQUEST_ENABLE_BT && resultCode == Activity.RESULT_OK && pendingResult != null) {
            foundDevice = null;
            startSearch(pendingResult);
            return true;
        }
        return false;
    }

    @Override
    public boolean onRequestPermissionsResult(int requestCode, @NonNull String[] permissions, @NonNull int[] grantResults) {
        if (pendingResult == null) return false;
        if (requestCode == REQUEST_ALL_PERMISSION || requestCode == REQUEST_BL) {
            if (checkBluetoothPermission()) {
                foundDevice = null;
                startSearch(pendingResult);
            }
            return true;
        }
        return false;
    }

    private void success(MethodChannel.Result result, Object data) {
        try {
            result.success(data);
        } catch (Exception e) {
            Log.e(TAG, "result already submitted: " + e);
        }
    }
}
