// MIT License
//
// Copyright (c) 2026 M. Stegen / Stegen Electronics
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:nsd/nsd.dart';
import 'dart:async';  // For TimeoutException and Timer
import 'package:shared_preferences/shared_preferences.dart';  // Added for persistent storage
import 'package:uuid/uuid.dart';  // Added for UUID generation
import 'package:package_info_plus/package_info_plus.dart';  // Added for app version info
import 'package:network_info_plus/network_info_plus.dart';  // Added for subnet scanning
import 'mqtt_service.dart';  // Added for MQTT support
import 'utils/logger.dart';  // Added for debug logging

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SmartEVSE Control',
      theme: ThemeData(
        brightness: Brightness.dark,  // Enables dark mode: black background, white text
        primarySwatch: Colors.blue,
      ),
      home: const EVSEControlScreen(),
    );
  }
}

class EVSEControlScreen extends StatefulWidget {
  const EVSEControlScreen({super.key});

  @override
  EVSEControlScreenState createState() => EVSEControlScreenState();  // Made state class public
}

class EVSEControlScreenState extends State<EVSEControlScreen> with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  static const Color boxBackgroundColor = Colors.white12;  // Define const color for all boxes
  static const int maxDevices = 8;

  // DEV MODE: Set to true to skip pairing and show main screen with mock data
  static const bool _devMode = false;//true;

  String? _selectedSerial;  // Nullable
  String _selectedIp = '';
  String status = 'Unknown';
  String _currentMode = '';
  int _loadbl = 0;
  int _currentMinA = 6;
  int _currentMaxA = 32;
  double _overrideCurrentA = 6.0;  // Set initial to min to avoid slider error
  bool isLoading = false;
  Timer? _timer;
  bool _evMeterEnabled = false;
  bool _mainsMeterEnabled = false;
  double _powerKW = 0.0;  // Power in kW (converted from W in API)
  double _chargedKWh = 0.0;
  double _l1A = 0.0;
  double _l2A = 0.0;
  double _l3A = 0.0;
  int _stateId = 0;
  int _nrofphases = 0;
  late AnimationController _animationController;
  bool _shouldFade = false;
  Color? _iconColor;
  bool _isConnected = false;
  String _error = 'None';
  double _chargeCurrentA = 0.0;
  int _solarStopTimer = 0;  // New variable for solar_stop_timer
  String? _appUUID;  // Added for unique AppUUID
  List<Map<String, String>> _storedDevices = [];  // List of stored devices {serial: ip}
  String _appVersion = '';  // App version from package info
  String _smartEVSEVersion = '-';  // SmartEVSE software version (placeholder)

  // MQTT state variables
  final MqttService _mqttService = MqttService();
  bool _mqttConnected = false;
  bool _usingMqtt = false;  // True when currently using MQTT fallback
  Timer? _mqttDataTimer;  // Timer for MQTT data timeout
  static const int _mqttDataTimeoutSeconds = 30;  // Timeout duration
  String? _connectionError;  // Error message to display

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
      lowerBound: 0.1,
    )..repeat(reverse: true);
    _initMqttCallbacks();  // Initialize MQTT callbacks first
    _initializeApp();  // Load UUID then stored devices
  }

  /// Initialize app - load UUID first, then stored devices
  Future<void> _initializeApp() async {
    await _loadAppVersion();  // Load app version info
    await _loadAppUUID();  // Wait for AppUUID to be loaded
    
    // DEV MODE: Skip pairing, show main screen with mock data
    if (_devMode) {
      _initDevMode();
      return;
    }
    
    await _loadStoredDevices();  // Then load stored devices (may connect MQTT)
  }

  /// Initialize dev mode with mock data for UI testing
  void _initDevMode() {
    setState(() {
      // Mock device
      _selectedSerial = '12345';
      _selectedIp = '192.168.1.100';  // Fake IP
      _storedDevices = [{'serial': '12345', 'ip': '192.168.1.100', 'customName': 'Test Device'}];
      
      // Slider settings (the main thing to test)
      _currentMinA = 6;
      _currentMaxA = 32;
      _overrideCurrentA = 16.0;  // Start in middle of range
      
      // Mock status data
      status = 'Connected';
      _currentMode = 'normal';
      _loadbl = 0;  // Show slider (loadbl < 2)
      _stateId = 1;
      _isConnected = true;
      _error = 'None';
      _nrofphases = 3;
      _chargeCurrentA = 16.0;
      _iconColor = Colors.green;
      
      // Mock meter data
      _evMeterEnabled = true;
      _mainsMeterEnabled = true;
      _powerKW = 11.0;
      _chargedKWh = 5.2;
      _l1A = 16.0;
      _l2A = 16.0;
      _l3A = 16.0;
      
      // Version info
      _smartEVSEVersion = 'DEV-MODE';
    });
  }

  /// Load app version from package info
  Future<void> _loadAppVersion() async {
    final packageInfo = await PackageInfo.fromPlatform();
    setState(() {
      _appVersion = packageInfo.version;
    });
  }

  /// Initialize MQTT service callbacks
  void _initMqttCallbacks() {
    _mqttService.onConnectionChanged = (connected) {
      Logger.debug('App', 'MQTT connection changed: $connected');
      setState(() {
        _mqttConnected = connected;
      });
    };

    _mqttService.onDataReceived = (data) {
      Logger.debug('App', 'MQTT data received: $data');
      // Reset MQTT data timeout timer
      _resetMqttDataTimer();
      // Clear any connection error
      if (_connectionError != null) {
        setState(() {
          _connectionError = null;
        });
      }
      // Update UI state from MQTT data (only if we're using MQTT)
      if (_usingMqtt) {
        _updateStateFromMqttData(data);
      }
    };
  }

  /// Reset the MQTT data timeout timer
  void _resetMqttDataTimer() {
    _mqttDataTimer?.cancel();
    if (_usingMqtt && _mqttConnected) {
      _mqttDataTimer = Timer(Duration(seconds: _mqttDataTimeoutSeconds), _onMqttDataTimeout);
    }
  }

  /// Called when MQTT data timeout expires
  Future<void> _onMqttDataTimeout() async {
    Logger.warning('App', 'MQTT data timeout - no data received for $_mqttDataTimeoutSeconds seconds');
    
    // Try to fall back to HTTP
    setState(() {
      _usingMqtt = false;  // Temporarily disable MQTT mode to try HTTP
    });
    
    bool httpSuccess = false;
    if (_selectedIp.isNotEmpty) {
      try {
        final url = Uri.parse('http://$_selectedIp/settings');
        final response = await http.get(url).timeout(const Duration(seconds: 5));
        if (response.statusCode == 200) {
          httpSuccess = true;
          Logger.debug('App', 'HTTP fallback successful after MQTT timeout');
          // HTTP will handle the data update via _fetchStatus
          _fetchStatus();
        }
      } catch (e) {
        Logger.error('App', 'HTTP fallback failed: $e');
      }
    }
    
    if (!httpSuccess) {
      // Both MQTT and HTTP failed
      setState(() {
        _usingMqtt = true;  // Go back to MQTT mode
        _connectionError = 'Connection lost - no data received';
      });
      // Restart the timer to keep trying
      _resetMqttDataTimer();
    }
  }

  /// Update UI state from received MQTT data
  void _updateStateFromMqttData(Map<String, dynamic> data) {
    setState(() {
      if (data.containsKey('charge_current')) {
        _chargeCurrentA = data['charge_current'];
      }
      if (data.containsKey('override_current')) {
        _overrideCurrentA = data['override_current'];
        if (_overrideCurrentA == 0) {
          _overrideCurrentA = _currentMinA.toDouble();
        }
      }
      if (data.containsKey('mode')) {
        _currentMode = data['mode'];
      }
      if (data.containsKey('nrofphases')) {
        _nrofphases = data['nrofphases'];
      }
      if (data.containsKey('state_id')) {
        _stateId = data['state_id'];
        _shouldFade = (_stateId == 2);
        _isConnected = _stateId >= 1;
      }
      if (data.containsKey('state')) {
        status = data['state'];
      }
      if (data.containsKey('l1')) {
        _l1A = data['l1'];
        _mainsMeterEnabled = true;  // Enable mains meter when L1 data received
      }
      if (data.containsKey('l2')) {
        _l2A = data['l2'];
      }
      if (data.containsKey('l3')) {
        _l3A = data['l3'];
      }
      if (data.containsKey('power')) {
        _powerKW = data['power'];
      }
      if (data.containsKey('charged_kwh')) {
        _chargedKWh = data['charged_kwh'];
        _evMeterEnabled = true;  // Enable EV meter when charged_kwh data received
      }
      if (data.containsKey('error')) {
        _error = data['error'];
      }
      if (data.containsKey('loadbl')) {
        _loadbl = data['loadbl'];
      }
      if (data.containsKey('solar_stop_timer')) {
        _solarStopTimer = data['solar_stop_timer'];
      }
      if (data.containsKey('version')) {
        _smartEVSEVersion = data['version'];
      }
      if (data.containsKey('max_current')) {
        _currentMaxA = data['max_current'];
      }

      // Update icon color based on state
      _iconColor = Colors.white;
      if (_error != 'None' && _error != 'No Power Available') {
        _iconColor = Colors.red;
      } else if (_isConnected) {
        if (_currentMode == 'solar') {
          _iconColor = Colors.yellow;
        } else {
          _iconColor = Colors.green;
        }
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _animationController.dispose();
    _timer?.cancel();
    _mqttDataTimer?.cancel();  // Cancel MQTT data timeout timer
    _mqttService.disconnect();  // Disconnect MQTT on dispose
    super.dispose();
  }

  Future<void> _loadAppUUID() async {
    final prefs = await SharedPreferences.getInstance();
    _appUUID = prefs.getString('app_uuid');
    if (_appUUID == null || _appUUID!.isEmpty) {
      var uuid = const Uuid();
      _appUUID = uuid.v4();
      await prefs.setString('app_uuid', _appUUID!);
    }
//    print('App UUID: $_appUUID');  // Debug print to view the UUID in console
  }

  Future<void> _setActiveEVSE(String? serial, String ip) async {
    final prefs = await SharedPreferences.getInstance();
    if (serial != null) {
      await prefs.setString('active_serial', serial);
    } else {
      await prefs.remove('active_serial');
    }

    // Disconnect from previous MQTT if switching devices
    _mqttService.disconnect();
    setState(() {
      _mqttConnected = false;
      _usingMqtt = false;
      // Reset meter flags when switching devices
      _evMeterEnabled = false;
      _mainsMeterEnabled = false;
      _connectionError = null;  // Clear any connection error
    });
    _mqttDataTimer?.cancel();  // Cancel MQTT data timeout timer

    setState(() {
      _selectedSerial = serial;
      _selectedIp = ip;
    });

    if (serial != null) {
      // Check if device is paired (has token) - if so, connect MQTT first
      final device = _findDeviceBySerial(serial);
      final hasMqttToken = device?['token']?.isNotEmpty ?? false;
      
      if (hasMqttToken) {
        // Connect to MQTT first for paired devices
        await _connectMqttIfPaired(serial);
        if (_mqttConnected) {
          setState(() {
            _usingMqtt = true;
          });
          _resetMqttDataTimer();
        }
      }
      
      _startTimer();
      // Only fetch via HTTP if MQTT is not connected
      if (!_mqttConnected) {
        _fetchStatus();
      }
    } else {
      _timer?.cancel();
    }
  }

  /// Connect to MQTT broker if the device is paired (has token)
  Future<void> _connectMqttIfPaired(String serial) async {
    // Skip if already connected via MQTT service
    if (_mqttService.isConnected) {
      Logger.debug('App', 'connectMqttIfPaired: Already connected, skipping');
      return;
    }

    if (_appUUID == null) {
      Logger.debug('App', 'connectMqttIfPaired: No appUUID, skipping');
      return;
    }

    final device = _findDeviceBySerial(serial);
    final token = device?['token'];
    if (token == null || token.isEmpty) {
      Logger.debug('App', 'connectMqttIfPaired: No token for serial $serial, skipping');
      return;
    }

    Logger.debug('App', 'connectMqttIfPaired: Connecting to MQTT for serial $serial...');
    // Connect to MQTT in background
    final connected = await _mqttService.connect(
      serial: serial,
      appUuid: _appUUID!,
      token: token,
    );

    Logger.debug('App', 'connectMqttIfPaired: Connection result: $connected');
    if (connected) {
      setState(() {
        _mqttConnected = true;
      });
    }
  }

  Future<void> _loadStoredDevices() async {
    final prefs = await SharedPreferences.getInstance();
    final storedJson = prefs.getString('stored_devices');
    if (storedJson != null) {
      final List<dynamic> decoded = json.decode(storedJson);
      setState(() {
        _storedDevices = decoded.map((item) => Map<String, String>.from(item)).toList();
      });
    }
    final activeSerial = prefs.getString('active_serial');
    final activeDevice = _findDeviceBySerial(activeSerial);
    if (activeDevice != null) {
      setState(() {
        _selectedSerial = activeSerial;
        _selectedIp = activeDevice['ip'] ?? '';
      });

      // Check if device is paired (has token) - if so, connect MQTT first
      final hasMqttToken = activeDevice['token']?.isNotEmpty ?? false;
      if (hasMqttToken) {
        Logger.debug('App', 'loadStoredDevices: Device is paired, connecting MQTT first');
        // Connect to MQTT first and wait for it
        await _connectMqttIfPaired(activeSerial!);
        // If MQTT connected, set usingMqtt to true and skip initial HTTP
        if (_mqttConnected) {
          Logger.debug('App', 'loadStoredDevices: MQTT connected, using MQTT mode');
          setState(() {
            _usingMqtt = true;
          });
          _resetMqttDataTimer();  // Start MQTT data timeout timer
        }
      }

      _startTimer();
      // Only fetch via HTTP if MQTT is not connected
      if (!_mqttConnected) {
        _fetchStatus();
      }
    } else if (_storedDevices.isNotEmpty) {
      setState(() {
        _selectedSerial = _storedDevices.first['serial'];
        _selectedIp = _storedDevices.first['ip']!;
      });
      _setActiveEVSE(_selectedSerial, _selectedIp);
      if (_selectedIp.isNotEmpty) {
        _startTimer();
        _fetchStatus();
      }
    } else {
      setState(() {
        _selectedSerial = null;
        _selectedIp = '';
      });
    }
  }

  Future<void> _saveStoredDevices() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = json.encode(_storedDevices);
    await prefs.setString('stored_devices', jsonString);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      _startTimer();
      if (_selectedIp.isNotEmpty) {
        _fetchStatus();
      }
      // Reconnect MQTT if device is paired
      if (_selectedSerial != null && !_mqttConnected) {
        _connectMqttIfPaired(_selectedSerial!);
      }
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      _timer?.cancel();
      _timer = null;
      // Don't disconnect MQTT on pause - let it maintain connection for notifications
    }
  }

  void _startTimer() {
    _timer?.cancel();
    // Start timer if we have an IP or if device is paired (for MQTT)
    if (_selectedIp.isNotEmpty || _isMqttConnected()) {
      _timer = Timer.periodic(const Duration(seconds: 5), (timer) {
        // Only call _fetchStatus if not already using MQTT (MQTT updates via callbacks)
        if (!_usingMqtt || !_mqttConnected) {
          _fetchStatus();
        }
      });
    }
  }

  Future<void> _fetchStatus() async {
    if (_selectedIp.isEmpty && !_mqttConnected) {
      Logger.debug('App', 'fetchStatus: No IP and no MQTT, returning');
      return;
    }

    // If already using MQTT and it's connected, skip HTTP entirely
    if (_usingMqtt && _mqttConnected) {
      Logger.debug('App', 'fetchStatus: Already using MQTT, skipping HTTP');
      // MQTT data is already being updated via callbacks, nothing to do
      return;
    }

    // For paired devices, prefer MQTT over HTTP
    if (_isMqttConnected() && _mqttConnected) {
      Logger.debug('App', 'fetchStatus: Device is paired and MQTT connected, using MQTT');
      setState(() {
        _usingMqtt = true;
      });
      _resetMqttDataTimer();
      return;
    }

    setState(() => isLoading = true);

    bool httpSuccess = false;

    // Try HTTP if we have an IP (for unpaired devices or when MQTT is not connected)
    if (_selectedIp.isNotEmpty) {
      Logger.debug('App', 'fetchStatus: Trying HTTP to $_selectedIp...');
      try {
        final url = Uri.parse('http://$_selectedIp/settings');
        final response = await http.get(url).timeout(const Duration(seconds: 5));
        if (response.statusCode == 200) {
          httpSuccess = true;
          Logger.debug('App', 'fetchStatus: HTTP SUCCESS (status 200)');
          final data = json.decode(response.body);
          final chargeCurrent = (data['settings']?['charge_current'] ?? 0) / 10;
          _mqttDataTimer?.cancel();  // Cancel MQTT data timer when HTTP works
          setState(() {
            if (_usingMqtt) {
              Logger.debug('App', 'fetchStatus: Switching from MQTT to HTTP');
            }
            _usingMqtt = false;  // Successfully using HTTP
            _connectionError = null;  // Clear any connection error
            status = data['evse']?['state'] ?? 'Unknown';
            _smartEVSEVersion = data['version'] ?? '-';
            _chargeCurrentA = chargeCurrent;
            _currentMode = (data['mode'] ?? '').toLowerCase();
            _loadbl = data['evse']?['loadbl'] ?? 0;
            _currentMinA = data['settings']?['current_min'] ?? 6;
            _currentMaxA = data['settings']?['current_max'] ?? 32;
            _overrideCurrentA = (data['settings']?['override_current'] ?? 0) / 10;
            if (_overrideCurrentA == 0) {
              _overrideCurrentA = _currentMinA.toDouble();  // Default to min if no override
            }
            _evMeterEnabled = (data['ev_meter']?['description'] ?? 'Disabled') != 'Disabled';
            _mainsMeterEnabled = (data['settings']?['mains_meter'] ?? 'Disabled') != 'Disabled';
            _powerKW = (data['ev_meter']?['import_active_power'] as num? ?? 0).toDouble() / 1000.0;  // W to kW
            _chargedKWh = (data['ev_meter']?['charged_wh'] as num? ?? 0).toDouble() / 1000.0;  // Wh to kWh
            _l1A = (data['phase_currents']?['L1'] ?? 0) / 10.0;
            _l2A = (data['phase_currents']?['L2'] ?? 0) / 10.0;
            _l3A = (data['phase_currents']?['L3'] ?? 0) / 10.0;
            _stateId = data['evse']?['state_id'] ?? 0;
            _isConnected = data['evse']?['connected'] ?? false;
            _error = data['evse']?['error'] ?? 'None';
            _nrofphases = data['evse']?['nrofphases'] ?? 0;
            _solarStopTimer = data['evse']?['solar_stop_timer'] ?? 0;  // Fetch solar_stop_timer
            _shouldFade = (_stateId == 2);
            _iconColor = Colors.white;  // Default for unconnected
            if (_error != 'None') {
              _iconColor = Colors.red;
            } else if (_isConnected) {
              if (_currentMode == 'solar') {
                _iconColor = Colors.yellow;
              } else {
                _iconColor = Colors.green;
              }
            }
          });
        }
      } on TimeoutException {
        Logger.warning('App', 'fetchStatus: HTTP TIMEOUT');
      } catch (e) {
        Logger.error('App', 'fetchStatus: HTTP ERROR: $e');
      }
    }

    // Fallback to MQTT if HTTP failed and MQTT is connected
    if (!httpSuccess && _mqttConnected) {
      Logger.debug('App', 'fetchStatus: HTTP failed, using MQTT fallback (mqttConnected=$_mqttConnected)');
      setState(() {
        if (!_usingMqtt) {
          Logger.debug('App', 'fetchStatus: Switching from HTTP to MQTT');
        }
        _usingMqtt = true;  // Now using MQTT fallback
      });
      // MQTT data is already being updated via callbacks
      // Just indicate we're using MQTT mode
      _resetMqttDataTimer();  // Start MQTT data timeout timer
    } else if (!httpSuccess && !_mqttConnected) {
      Logger.debug('App', 'fetchStatus: HTTP failed and MQTT not connected');
      // Both HTTP and MQTT unavailable
      if (_isMqttConnected()) {
        // Device is paired but MQTT not connected, try to connect
        if (_selectedSerial != null) {
          _connectMqttIfPaired(_selectedSerial!);
        }
      }
      _showSnackBar('Connection unavailable—check network');
    }

    setState(() => isLoading = false);
  }

  Future<void> _setMode(String mode) async {
    // DEV MODE: Just update local state, no network calls
    if (_devMode) {
      setState(() {
        _currentMode = mode;
      });
      return;
    }

    if (_selectedIp.isEmpty && !_mqttConnected) {
      _showSnackBar('Select a device first!');
      return;
    }
    int modeValue = 0;
    if (mode == 'smart') modeValue = 3;
    if (mode == 'solar') modeValue = 2;
    if (mode == 'normal') modeValue = 1;
    if (mode == 'off') modeValue = 0;

    // If already using MQTT mode, skip HTTP and go directly to MQTT
    if (_usingMqtt && _mqttConnected) {
      Logger.debug('App', 'setMode: Using MQTT directly (usingMqtt=true)');
      final success = await _mqttService.setMode(modeValue);
      Logger.debug('App', 'setMode: MQTT publish result=$success');
      if (success) {
        setState(() {
          _currentMode = mode;
        });
      } else {
        _showSnackBar('Failed to set mode via MQTT');
      }
      return;
    }

    bool httpSuccess = false;

    // Try HTTP first if we have an IP
    if (_selectedIp.isNotEmpty) {
      try {
        final url = Uri.parse('http://$_selectedIp/settings?mode=$modeValue');
        final response = await http.post(
          url,
          body: '',
          headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        ).timeout(const Duration(seconds: 5));
        if (response.statusCode == 200) {
          httpSuccess = true;
          _fetchStatus();
        }
      } on TimeoutException {
        // HTTP timed out, will try MQTT fallback
      } catch (e) {
        // HTTP failed, will try MQTT fallback
      }
    }

    // Fallback to MQTT if HTTP failed and MQTT is connected
    if (!httpSuccess && _mqttConnected) {
      Logger.debug('App', 'setMode: Using MQTT fallback');
      final success = await _mqttService.setMode(modeValue);
      Logger.debug('App', 'setMode: MQTT publish result=$success');
      if (success) {
        // Optimistically update local state
        setState(() {
          _currentMode = mode;
        });
      } else {
        _showSnackBar('Failed to set mode via MQTT');
      }
    } else if (!httpSuccess && !_mqttConnected) {
      _showSnackBar('Connection unavailable—check network');
    }
  }

  Future<void> _setOverride(int deciAmps) async {
    // DEV MODE: Just update local state, no network calls
    if (_devMode) {
      setState(() {
        _overrideCurrentA = deciAmps / 10.0;
      });
      return;
    }

    if (_selectedIp.isEmpty && !_mqttConnected) {
      _showSnackBar('Select a device first!');
      return;
    }

    // If already using MQTT mode, skip HTTP and go directly to MQTT
    if (_usingMqtt && _mqttConnected) {
      Logger.debug('App', 'setOverride: Using MQTT directly (usingMqtt=true)');
      final success = await _mqttService.setCurrentOverride(deciAmps);
      Logger.debug('App', 'setOverride: MQTT publish result=$success');
      if (success) {
        setState(() {
          _overrideCurrentA = deciAmps / 10.0;
        });
      } else {
        _showSnackBar('Failed to set override via MQTT');
      }
      return;
    }

    bool httpSuccess = false;

    // Try HTTP first if we have an IP
    if (_selectedIp.isNotEmpty) {
      try {
        final url = Uri.parse('http://$_selectedIp/settings?override_current=$deciAmps');
        final response = await http.post(
          url,
          body: '',
          headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        ).timeout(const Duration(seconds: 5));
        if (response.statusCode == 200) {
          httpSuccess = true;
          _fetchStatus();
        }
      } on TimeoutException {
        // HTTP timed out, will try MQTT fallback
      } catch (e) {
        // HTTP failed, will try MQTT fallback
      }
    }

    // Fallback to MQTT if HTTP failed and MQTT is connected
    if (!httpSuccess && _mqttConnected) {
      Logger.debug('App', 'setOverride: Using MQTT fallback');
      final success = await _mqttService.setCurrentOverride(deciAmps);
      Logger.debug('App', 'setOverride: MQTT publish result=$success');
      if (success) {
        // Optimistically update local state
        setState(() {
          _overrideCurrentA = deciAmps / 10.0;
        });
      } else {
        _showSnackBar('Failed to set override via MQTT');
      }
    } else if (!httpSuccess && !_mqttConnected) {
      _showSnackBar('Connection unavailable—check network');
    }
  }

  Future<List<Map<String, dynamic>>> discoverHttpServices() async {
    final List<Map<String, dynamic>> discovered = [];
    final Set<String> seenIps = {};
    final List<String> foundIps = [];

    try {
      final discovery = await startDiscovery('_http._tcp', ipLookupType: IpLookupType.any);
      FutureOr<void> listener(Service service, ServiceStatus status) {
        if (status == ServiceStatus.found) {
          final String? serviceName = service.name;
          if (serviceName != null) {
            final lowerName = serviceName.toLowerCase();
            if (lowerName.startsWith('smartevse-')) {
              final addresses = service.addresses;
              if (addresses != null && addresses.isNotEmpty) {
                final ip = addresses.first.address;
                if (!seenIps.contains(ip) && foundIps.length < maxDevices) {
                  seenIps.add(ip);
                  foundIps.add(ip);
                }
              }
            }
          }
        }
      }
      discovery.addServiceListener(listener);

      await Future.delayed(const Duration(seconds: 5));   // mDNS scan time 5 sec

      discovery.removeServiceListener(listener);
      await stopDiscovery(discovery);
    } catch (e) {
      _showSnackBar('Discovery error: $e');
    }

    // Fetch serial numbers from /settings for each discovered IP
    final Set<String> seenSerials = {};
    for (final ip in foundIps) {
      final result = await _probeSmartEVSE(ip, const Duration(seconds: 3));
      if (result != null) {
        final serial = result['serial'] as String;
        if (!seenSerials.contains(serial)) {
          seenSerials.add(serial);
          discovered.add(result);
        }
      }
    }

    return discovered;
  }

  /// Subnet scan fallback: Scans all IPs on the local subnet for SmartEVSE devices
  /// by requesting /settings endpoint and validating the response structure.
  Future<List<Map<String, dynamic>>> _scanSubnetForDevices({
    Function(int scanned, int total)? onProgress,
  }) async {
    final List<Map<String, dynamic>> discovered = [];
    final Set<String> seenSerials = {};

    try {
      // Get the device's WiFi IP address
      final networkInfo = NetworkInfo();
      final wifiIP = await networkInfo.getWifiIP();
      
      if (wifiIP == null || wifiIP.isEmpty) {
        Logger.warning('App', 'Subnet scan: Could not get WiFi IP address');
        return discovered;
      }

      Logger.debug('App', 'Subnet scan: Device IP is $wifiIP');

      // Extract subnet (e.g., "192.168.1." from "192.168.1.100")
      final lastDot = wifiIP.lastIndexOf('.');
      if (lastDot == -1) {
        Logger.warning('App', 'Subnet scan: Invalid IP format');
        return discovered;
      }
      final subnet = wifiIP.substring(0, lastDot + 1);
      Logger.debug('App', 'Subnet scan: Scanning subnet $subnet*');

      // Scan all 254 addresses in parallel batches
      const batchSize = 50;  // Number of concurrent requests
      const timeout = Duration(seconds: 2);
      int scanned = 0;

      for (int batchStart = 1; batchStart <= 254; batchStart += batchSize) {
        final futures = <Future<void>>[];
        final batchEnd = (batchStart + batchSize - 1).clamp(1, 254);

        for (int i = batchStart; i <= batchEnd; i++) {
          final ip = '$subnet$i';
          futures.add(_probeSmartEVSE(ip, timeout).then((result) {
            if (result != null) {
              final serial = result['serial'] as String;
              if (!seenSerials.contains(serial) && discovered.length < maxDevices) {
                seenSerials.add(serial);
                discovered.add(result);
                Logger.debug('App', 'Subnet scan: Found SmartEVSE-$serial at $ip');
              }
            }
          }));
        }

        await Future.wait(futures);
        scanned = batchEnd;
        onProgress?.call(scanned, 254);
      }

      Logger.debug('App', 'Subnet scan: Complete. Found ${discovered.length} device(s)');
    } catch (e) {
      Logger.error('App', 'Subnet scan error: $e');
    }

    return discovered;
  }

  /// Probe a single IP address to check if it's a SmartEVSE device
  Future<Map<String, dynamic>?> _probeSmartEVSE(String ip, Duration timeout) async {
    try {
      final url = Uri.parse('http://$ip/settings');
      final response = await http.get(url).timeout(timeout);
      
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        
        // Validate it's a SmartEVSE by checking expected fields
        if (data is Map && 
            data.containsKey('evse') && 
            data.containsKey('settings') &&
            data['evse'] is Map) {
          
          // Extract serial from the serialnr field (required for MQTT pairing)
          if (data.containsKey('serialnr') && data['serialnr'] != null) {
            final serial = data['serialnr'].toString();
            if (serial.isNotEmpty) {
              return {
                'serial': serial,
                'ip': ip,
                'port': 80,
              };
            }
          }
          
          // No valid serial found - skip this device
          Logger.warning('App', 'Device at $ip has no serialnr field');
          return null;
        }
      }
    } on TimeoutException {
      // Timeout is expected for most IPs - ignore silently
    } catch (e) {
      // Other errors (connection refused, etc.) - ignore silently
    }
    return null;
  }

  Future<void> _editDeviceName(String serial) async {
    final device = _findDeviceBySerial(serial);
    if (device == null) {
      Logger.error('App', 'Device with serial $serial not found in stored devices');
      _showSnackBar('Device not found');
      return;
    }

    final currentName = device['customName'] ?? '';
    final controller = TextEditingController(text: currentName);

    final newName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit Device Name'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: 'Enter custom name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (newName != null && newName.isNotEmpty) {
      setState(() {
        device['customName'] = newName;
      });
      _saveStoredDevices();
    } else if (newName != null && newName.isEmpty) {
      setState(() {
        device.remove('customName');
      });
      _saveStoredDevices();
    }
  }

  String _getDeviceDisplayName(Map<String, String> device) {
    return device['customName'] ?? 'SmartEVSE-${device['serial']}';
  }

  /// Helper method to find a device by serial number
  /// Returns null if not found (safer than returning empty map)
  Map<String, String>? _findDeviceBySerial(String? serial) {
    if (serial == null) return null;
    try {
      return _storedDevices.firstWhere((d) => d['serial'] == serial);
    } catch (e) {
      return null;
    }
  }

  // Check if the selected device has a MQTT token (paired)
  bool _isMqttConnected() {
    final device = _findDeviceBySerial(_selectedSerial);
    return device != null && device['token']?.isNotEmpty == true;
  }

  // New: Prompt for Pairing PIN and perform pairing
  Future<void> _promptForPairingPin() async {
    if (_selectedSerial == null) {
      _showSnackBar('Select a device first!');
      return;
    }

    final controller = TextEditingController();
    final pin = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Enter Pairing PIN'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: '6-digit PIN'),
          keyboardType: TextInputType.number,
          maxLength: 6,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final enteredPin = controller.text.trim();
              if (enteredPin.length == 6 && RegExp(r'^\d+$').hasMatch(enteredPin)) {
                Navigator.pop(context, enteredPin);
              } else {
                _showSnackBar('Invalid PIN: Must be 6 digits');
              }
            },
            child: const Text('Pair'),
          ),
        ],
      ),
    );

    if (pin != null) {
      await _pairDevice(pin);
    }
  }

  // New: Make POST request to pair and store token
  Future<void> _pairDevice(String pin) async {
    if (_appUUID == null || _selectedSerial == null) return;

    setState(() => isLoading = true);
    try {
      final url = Uri.parse('https://mqtt.smartevse.nl/pair');
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          "app_uuid": _appUUID,
          "device_serial": 'SmartEVSE-$_selectedSerial',
          "pairing_pin": pin,
        }),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final token = data['mqtt_token'];  // get token
        if (token != null) {
          // Apply token to the current device and any already-paired devices
          // (token is tied to app_uuid, so all paired devices share the same token)
          setState(() {
            for (final device in _storedDevices) {
              // Update if: this is the device being paired, OR device already has a token
              if (device['serial'] == _selectedSerial || 
                  (device['token'] != null && device['token']!.isNotEmpty)) {
                device['token'] = token;
              }
            }
          });
          _saveStoredDevices();
          _showSnackBar('Pairing successful!');
          // Connect to MQTT immediately after pairing
          _connectMqttIfPaired(_selectedSerial!);
        } else {
          _showSnackBar('No token received from server');
        }
      } else {
        _showSnackBar('Pairing failed: ${response.statusCode} - ${response.body}');
      }
    } catch (e) {
      _showSnackBar('Pairing error: $e');
    }
    setState(() => isLoading = false);
  }

  Future<void> _manageDevices() async {
    if (!mounted) return;

    // Show dialog immediately with scanning state
    showDialog(
      context: context,
      barrierDismissible: false,  // Prevent closing during scan
      builder: (context) {
        return _ManageDevicesDialog(
          storedDevices: _storedDevices,
          maxDevices: maxDevices,
          getDeviceDisplayName: _getDeviceDisplayName,
          onEditDeviceName: _editDeviceName,
          onDevicesChanged: (devices) {
            setState(() {
              _storedDevices = devices;
            });
            _saveStoredDevices();
          },
          onDeviceSelected: (serial, ip) {
            if (_selectedSerial == serial) return;
            setState(() {
              _selectedSerial = serial;
              _selectedIp = ip;
            });
            _setActiveEVSE(serial, ip);
          },
          selectedSerial: _selectedSerial,
          discoverMdns: discoverHttpServices,
          discoverSubnet: _scanSubnetForDevices,
          showSnackBar: _showSnackBar,
        );
      },
    );
  }

  // Legacy method kept for reference - now using _ManageDevicesDialog

  void _showSnackBar(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  ButtonStyle _buttonStyle(String mode) {
    return ElevatedButton.styleFrom(
      backgroundColor: _currentMode == mode ? Colors.green : null,
      foregroundColor: Colors.white,  // Force button text to white
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
    );
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,  // Center the title
        leadingWidth: 72,  // Increase leading width to accommodate padding
        leading: _selectedSerial != null
            ? Padding(
          padding: const EdgeInsets.only(left: 16),  // Same spacing as right side
          child: IconButton(
            icon: Icon(
              _usingMqtt
                  ? Icons.cloud  // Using MQTT fallback
                  : _mqttConnected
                      ? Icons.link  // MQTT connected
                      : _isMqttConnected()
                          ? Icons.link  // Has token but not connected
                          : Icons.link_off,  // Not paired
              color: _usingMqtt
                  ? Colors.lightBlue  // Cloud when using MQTT
                  : _mqttConnected
                      ? Colors.green  // Green when MQTT connected
                      : _isMqttConnected()
                          ? Colors.orange  // Orange when paired but not connected
                          : null,  // Default color when not paired
            ),
            tooltip: _usingMqtt
                ? 'Using MQTT (remote)'
                : _mqttConnected
                    ? 'MQTT connected'
                    : _isMqttConnected()
                        ? 'Paired (tap to reconnect)'
                        : 'Not paired (tap to pair)',
            onPressed: () {
              if (_selectedSerial != null) {
                // Always show pairing dialog - allows re-pairing or new pairing
                _promptForPairingPin();
              }
            },
          ),
        )
            : null,
        title: _storedDevices.isNotEmpty && _selectedSerial != null && _storedDevices.any((d) => d['serial'] == _selectedSerial)
            ? DropdownButton<String>(
          value: _selectedSerial,
          underline: const SizedBox(),  // Remove the underline
          style: const TextStyle(fontSize: 22),  // Larger text for selected item
          items: (List.from(_storedDevices)..sort((a, b) => int.parse(a['serial']!) - int.parse(b['serial']!))).map((device) {
            return DropdownMenuItem<String>(
              value: device['serial'],
              child: Text(
                _getDeviceDisplayName(device),
                style: const TextStyle(fontSize: 20),  // Larger text for menu items
              ),
            );
          }).toList(),
          onChanged: (value) {
            final selectedDevice = _findDeviceBySerial(value);
            if (selectedDevice != null) {
              _setActiveEVSE(value!, selectedDevice['ip']!);
            }
          },
        )
            : const Text('SmartEVSE Control'),
        actions: [
          IconButton(
            icon: const Icon(Icons.manage_search),
            iconSize: 32,  // Larger icon size
            onPressed: _manageDevices,  // Always enabled
            tooltip: 'Manage Devices',
          ),
          const SizedBox(width: 16),  // Add space to move button left
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(  // Wrap with SingleChildScrollView for scrolling
              physics: const BouncingScrollPhysics(),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: _selectedIp.isEmpty
                    ? const Center(child: Text('No SmartEVSE selected'))
                    : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_mainsMeterEnabled)
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: boxBackgroundColor,  // Use const color
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: SizedBox(
                          height: 80,  // Fixed height for consistency
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('L1: ${_l1A.toStringAsFixed(1)} A', style: const TextStyle(fontSize: 18)),
                                  Text('L2: ${_l2A.toStringAsFixed(1)} A', style: const TextStyle(fontSize: 18)),
                                  Text('L3: ${_l3A.toStringAsFixed(1)} A', style: const TextStyle(fontSize: 18)),
                                ],
                              ),
                              const Icon(Icons.bolt, size: 32),
                            ],
                          ),
                        ),
                      ),
                    ),
                  if (_mainsMeterEnabled) const SizedBox(width: 12),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: boxBackgroundColor,  // Use const color
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: SizedBox(
                        height: 80,  // Fixed height for consistency
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('${_chargeCurrentA.toStringAsFixed(1)} A', style: const TextStyle(fontSize: 18)),
                                if (_evMeterEnabled)
                                  Text('${_powerKW.toStringAsFixed(1)} kW', style: const TextStyle(fontSize: 18)),
                                if (_evMeterEnabled)
                                  Text('${_chargedKWh.toStringAsFixed(1)} kWh', style: const TextStyle(fontSize: 18)),
                              ],
                            ),
                            _shouldFade
                                ? FadeTransition(
                              opacity: _animationController,
                              child: Icon(Icons.electric_car, size: 32, color: _iconColor),
                            )
                                : Icon(Icons.electric_car, size: 32, color: _iconColor),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: boxBackgroundColor,  // Use const color
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_connectionError != null)
                      Text(_connectionError!, style: const TextStyle(fontSize: 18, color: Colors.orange))
                    else if (_error != 'None' && _error != 'No Power Available')
                      Text(_error, style: const TextStyle(fontSize: 18, color: Colors.red))
                    else
                      if (_stateId == 2)  // Charging
                        Text(
                          '$_nrofphases Phase Charging${_solarStopTimer > 0 ? ' (Stopping in ${_solarStopTimer}s)' : ''}',
                          style: const TextStyle(fontSize: 18),
                        )
                      else Text(status, style: const TextStyle(fontSize: 18)),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: boxBackgroundColor,  // Use const color
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Mode', style: TextStyle(fontSize: 16, color: Colors.lightBlue, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        Flexible(
                          child: ElevatedButton(
                            onPressed: () => _setMode('off'),
                            style: _buttonStyle('off'),
                            child: const Text('Off'),
                          ),
                        ),
                        Flexible(
                          child: ElevatedButton(
                            onPressed: () => _setMode('normal'),
                            style: _buttonStyle('normal'),
                            child: const Text('Normal'),
                          ),
                        ),
                        Flexible(
                          child: ElevatedButton(
                            onPressed: () => _setMode('solar'),
                            style: _buttonStyle('solar'),
                            child: const Text('Solar'),
                          ),
                        ),
                        Flexible(
                          child: ElevatedButton(
                            onPressed: () => _setMode('smart'),
                            style: _buttonStyle('smart'),
                            child: const Text('Smart'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (_loadbl < 2 && _currentMode != 'solar') ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: boxBackgroundColor,  // Use const color
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Override Current:', style: TextStyle(fontSize: 16, color: Colors.lightBlue, fontWeight: FontWeight.bold)),
                      if (_currentMinA >= _currentMaxA) ...[
                        // Show message when slider cannot be displayed (invalid range)
                        const SizedBox(height: 16),
                        Center(
                          child: Text(
                            'Cannot display slider due to invalid range.\nMIN ${_currentMinA}A should be lower than MAX ${_currentMaxA}A',
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 14, color: Colors.orange, fontStyle: FontStyle.italic),
                          ),
                        ),
                        const SizedBox(height: 16),
                      ] else ...[
                        // Show slider when range is valid (MIN < MAX)
                        Theme(
                          data: Theme.of(context).copyWith(
                            sliderTheme: SliderThemeData(
                              thumbColor: Colors.white,  // White thumb
                              activeTrackColor: Colors.green,  // White active track
                              inactiveTrackColor: Colors.grey,  // Grey inactive track
                              overlayColor: Colors.white.withOpacity(0.2),  // Light overlay
                              valueIndicatorColor: boxBackgroundColor,  // Use const color for label background
                              valueIndicatorTextStyle: const TextStyle(color: Colors.white),  // White label text
                            ),
                          ),
                          child: SizedBox(
                            height: 40,
                            child: Slider(
                              value: _overrideCurrentA.clamp(_currentMinA.toDouble(), _currentMaxA.toDouble()),
                              min: _currentMinA.toDouble(),
                              max: _currentMaxA.toDouble(),
                              divisions: (_currentMaxA - _currentMinA),  // Safe: we know max > min here
                              label: '${_overrideCurrentA.clamp(_currentMinA.toDouble(), _currentMaxA.toDouble()).toInt()}A',
                              onChanged: (value) { setState(() => _overrideCurrentA = value); },
                              onChangeEnd: (value) {
                                _setOverride((value * 10).toInt());
                              },
                            ),
                          ),
                        ),
                      ],
                      Center(
                        child: ElevatedButton(
                          onPressed: () => _setOverride(0),
                          style: ElevatedButton.styleFrom(foregroundColor: Colors.white),  // Force white text on button
                          child: const Text('Disable Override'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
              ),
            ),
          ),
          // Version info footer
          SafeArea(
            top: false,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
              color: Colors.black26,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'App: v$_appVersion  |  SmartEVSE: $_smartEVSEVersion',
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'UUID: ${_appUUID ?? '-'}',
                    style: const TextStyle(fontSize: 10, color: Colors.grey),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Stateful dialog for managing devices with hybrid discovery (mDNS + subnet scan)
class _ManageDevicesDialog extends StatefulWidget {
  final List<Map<String, String>> storedDevices;
  final int maxDevices;
  final String Function(Map<String, String>) getDeviceDisplayName;
  final Future<void> Function(String) onEditDeviceName;
  final void Function(List<Map<String, String>>) onDevicesChanged;
  final void Function(String?, String) onDeviceSelected;
  final String? selectedSerial;
  final Future<List<Map<String, dynamic>>> Function() discoverMdns;
  final Future<List<Map<String, dynamic>>> Function({Function(int, int)? onProgress}) discoverSubnet;
  final void Function(String) showSnackBar;

  const _ManageDevicesDialog({
    required this.storedDevices,
    required this.maxDevices,
    required this.getDeviceDisplayName,
    required this.onEditDeviceName,
    required this.onDevicesChanged,
    required this.onDeviceSelected,
    required this.selectedSerial,
    required this.discoverMdns,
    required this.discoverSubnet,
    required this.showSnackBar,
  });

  @override
  State<_ManageDevicesDialog> createState() => _ManageDevicesDialogState();
}

class _ManageDevicesDialogState extends State<_ManageDevicesDialog> {
  List<Map<String, String>> _localStoredDevices = [];
  List<Map<String, dynamic>> _onlineDevices = [];
  bool _isScanning = false;
  String _scanStatus = '';
  int _scanProgress = 0;
  int _scanTotal = 0;
  bool _mdnsComplete = false;

  @override
  void initState() {
    super.initState();
    _localStoredDevices = List.from(widget.storedDevices);
    _startDiscovery();
  }

  Future<void> _startDiscovery() async {
    setState(() {
      _isScanning = true;
      _scanStatus = 'Scanning network (mDNS)...';
      _mdnsComplete = false;
      _onlineDevices = [];
    });

    // Phase 1: mDNS discovery (fast)
    try {
      final mdnsDevices = await widget.discoverMdns();
      if (mounted) {
        setState(() {
          _onlineDevices = mdnsDevices;
          _mdnsComplete = true;
        });
      }
      Logger.debug('App', 'mDNS discovery found ${mdnsDevices.length} device(s)');
    } catch (e) {
      Logger.error('App', 'mDNS discovery error: $e');
    }

    // Phase 2: Subnet scan fallback (if mDNS found nothing or as supplement)
    if (mounted && _onlineDevices.isEmpty) {
      setState(() {
        _scanStatus = 'No devices found via mDNS. Scanning subnet...';
        _scanProgress = 0;
        _scanTotal = 254;
      });

      try {
        final subnetDevices = await widget.discoverSubnet(
          onProgress: (scanned, total) {
            if (mounted) {
              setState(() {
                _scanProgress = scanned;
                _scanTotal = total;
                _scanStatus = 'Scanning subnet... ($scanned/$total)';
              });
            }
          },
        );

        if (mounted) {
          setState(() {
            _onlineDevices = subnetDevices;
          });
        }
        Logger.debug('App', 'Subnet scan found ${subnetDevices.length} device(s)');
      } catch (e) {
        Logger.error('App', 'Subnet scan error: $e');
      }
    }

    if (mounted) {
      // Update stored device IPs if they changed
      _updateStoredDeviceIps();
      
      setState(() {
        _isScanning = false;
        _scanStatus = _onlineDevices.isEmpty 
            ? 'No devices found' 
            : 'Found ${_onlineDevices.length} device(s)';
      });
    }
  }

  /// Update IP addresses in stored devices when found online with different IP
  void _updateStoredDeviceIps() {
    bool updated = false;
    
    for (final online in _onlineDevices) {
      final serial = online['serial'] as String;
      final newIp = online['ip'] as String;
      
      // Find matching stored device
      final storedIndex = _localStoredDevices.indexWhere((d) => d['serial'] == serial);
      if (storedIndex != -1) {
        final storedDevice = _localStoredDevices[storedIndex];
        final oldIp = storedDevice['ip'];
        
        // Update IP if different
        if (oldIp != newIp) {
          Logger.debug('App', 'Device $serial IP changed: $oldIp -> $newIp');
          storedDevice['ip'] = newIp;
          updated = true;
        }
      }
    }
    
    // Save changes if any IPs were updated
    if (updated) {
      widget.onDevicesChanged(_localStoredDevices);
    }
  }

  List<Map<String, dynamic>> _getCombinedDeviceList() {
    Map<String, Map<String, dynamic>> combinedDevices = {};

    // Add stored devices (offline or online)
    for (final stored in _localStoredDevices) {
      combinedDevices[stored['serial']!] = {
        'serial': stored['serial']!,
        'ip': stored['ip']!,
        'isOnline': false,
      };
    }

    // Add or update with online devices
    for (final online in _onlineDevices) {
      final serial = online['serial'] as String;
      combinedDevices[serial] = {
        'serial': serial,
        'ip': online['ip'] as String,
        'isOnline': true,
      };
    }

    // Sort by serial number
    final deviceList = combinedDevices.values.toList();
    deviceList.sort((a, b) {
      // Try numeric comparison first
      final aSerial = int.tryParse(a['serial'] as String);
      final bSerial = int.tryParse(b['serial'] as String);
      if (aSerial != null && bSerial != null) {
        return aSerial - bSerial;
      }
      // Fall back to string comparison
      return (a['serial'] as String).compareTo(b['serial'] as String);
    });

    return deviceList;
  }

  @override
  Widget build(BuildContext context) {
    final deviceList = _getCombinedDeviceList();

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        width: MediaQuery.of(context).size.width * 0.9,
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Manage Devices',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            
            // Scan status and progress
            if (_isScanning) ...[
              Text(
                _scanStatus,
                style: const TextStyle(fontSize: 14, color: Colors.grey),
              ),
              const SizedBox(height: 8),
              if (_scanTotal > 0 && !_mdnsComplete || (_mdnsComplete && _onlineDevices.isEmpty))
                LinearProgressIndicator(
                  value: _scanTotal > 0 ? _scanProgress / _scanTotal : null,
                  backgroundColor: Colors.grey[800],
                  valueColor: const AlwaysStoppedAnimation<Color>(Colors.blue),
                ),
              if (_scanTotal == 0 || (_mdnsComplete && _onlineDevices.isNotEmpty))
                const LinearProgressIndicator(
                  backgroundColor: Colors.grey,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.blue),
                ),
              const SizedBox(height: 8),
            ] else ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    _scanStatus,
                    style: TextStyle(
                      fontSize: 14,
                      color: _onlineDevices.isEmpty ? Colors.orange : Colors.green,
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.refresh, size: 20),
                    onPressed: _startDiscovery,
                    tooltip: 'Scan again',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
            
            // Device list
            Flexible(
              child: deviceList.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(
                          _isScanning
                              ? 'Searching for devices...'
                              : 'No devices found.\nMake sure your SmartEVSE is connected to WiFi.',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.grey),
                        ),
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: deviceList.length,
                      itemBuilder: (context, index) {
                        final device = deviceList[index];
                        final serial = device['serial'] as String;
                        final ip = device['ip'] as String;
                        final isOnline = device['isOnline'] as bool;
                        final storedDevice = _localStoredDevices.cast<Map<String, String>?>().firstWhere(
                          (d) => d?['serial'] == serial,
                          orElse: () => null,
                        );
                        final isStored = storedDevice != null;
                        final displayName = storedDevice != null
                            ? widget.getDeviceDisplayName(storedDevice)
                            : 'SmartEVSE-$serial';

                        return ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 0),
                          leading: isStored
                              ? IconButton(
                                  icon: const Icon(Icons.edit, size: 20),
                                  onPressed: () async {
                                    // Use stored device's serial to ensure match
                                    final storedSerial = storedDevice['serial']!;
                                    await widget.onEditDeviceName(storedSerial);
                                    if (mounted) {
                                      // Sync local devices with parent by calling onDevicesChanged
                                      // This ensures both sides have the same data
                                      widget.onDevicesChanged(_localStoredDevices);
                                      setState(() {});
                                    }
                                  },
                                )
                              : const SizedBox(width: 48),
                          title: Text(
                            '$displayName ($ip)${isOnline ? '' : ' (offline)'}',
                            style: TextStyle(
                              color: isOnline ? null : Colors.grey,
                            ),
                          ),
                          trailing: SizedBox(
                            width: 48,
                            child: Align(
                              alignment: Alignment.centerRight,
                              child: IconButton(
                                icon: Icon(
                                  isStored ? Icons.remove_circle : Icons.add_circle,
                                  color: isStored ? Colors.red : Colors.green,
                                ),
                                onPressed: () async {
                                  if (isStored) {
                                    // Check if device is paired (has token)
                                    final isPaired = storedDevice['token']?.isNotEmpty ?? false;
                                    
                                    // Show confirmation dialog
                                    final confirmed = await showDialog<bool>(
                                      context: context,
                                      builder: (context) => AlertDialog(
                                        title: const Text('Remove Device?'),
                                        content: Text(
                                          isPaired
                                              ? 'This device is paired for remote access. Removing it will require re-pairing.\n\nAre you sure you want to remove "$displayName"?'
                                              : 'Are you sure you want to remove "$displayName"?',
                                        ),
                                        actions: [
                                          TextButton(
                                            onPressed: () => Navigator.pop(context, false),
                                            child: const Text('Cancel'),
                                          ),
                                          TextButton(
                                            onPressed: () => Navigator.pop(context, true),
                                            style: TextButton.styleFrom(foregroundColor: Colors.red),
                                            child: const Text('Remove'),
                                          ),
                                        ],
                                      ),
                                    );
                                    
                                    if (confirmed != true) return;
                                    
                                    // Remove device
                                    setState(() {
                                      _localStoredDevices.removeWhere((d) => d['serial'] == serial);
                                    });
                                    
                                    // Update selected device BEFORE onDevicesChanged to avoid dropdown error
                                    if (widget.selectedSerial == serial) {
                                      if (_localStoredDevices.isNotEmpty) {
                                        widget.onDeviceSelected(
                                          _localStoredDevices.first['serial'],
                                          _localStoredDevices.first['ip']!,
                                        );
                                      } else {
                                        widget.onDeviceSelected(null, '');
                                      }
                                    }
                                    widget.onDevicesChanged(_localStoredDevices);
                                  } else {
                                    // Add device
                                    if (_localStoredDevices.length < widget.maxDevices) {
                                      // Check if we have existing data (token, customName) for this serial
                                      final existingDevice = widget.storedDevices.cast<Map<String, String>?>().firstWhere(
                                        (d) => d?['serial'] == serial,
                                        orElse: () => null,
                                      );
                                      
                                      setState(() {
                                        final newDevice = {'serial': serial, 'ip': ip};
                                        // Preserve token and customName if they exist for this serial
                                        if (existingDevice != null) {
                                          final token = existingDevice['token'];
                                          final customName = existingDevice['customName'];
                                          if (token != null && token.isNotEmpty) {
                                            newDevice['token'] = token;
                                          }
                                          if (customName != null && customName.isNotEmpty) {
                                            newDevice['customName'] = customName;
                                          }
                                        }
                                        _localStoredDevices.add(newDevice);
                                      });
                                      widget.onDevicesChanged(_localStoredDevices);
                                      
                                      // Select this device if none selected
                                      if (widget.selectedSerial == null) {
                                        widget.onDeviceSelected(serial, ip);
                                      }
                                    } else {
                                      widget.showSnackBar('Max ${widget.maxDevices} devices reached');
                                    }
                                  }
                                },
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
            
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _isScanning ? null : () => Navigator.pop(context),
                child: Text(_isScanning ? 'Scanning...' : 'Close'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}