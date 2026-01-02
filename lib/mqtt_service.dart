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

import 'dart:async';
import 'dart:io';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'utils/logger.dart';

/// Callback type for when MQTT data is received
typedef MqttDataCallback = void Function(Map<String, dynamic> data);

/// Callback type for connection state changes
typedef MqttConnectionCallback = void Function(bool connected);

class MqttService {
  static const String _broker = 'mqtt.smartevse.nl';
  static const int _port = 8883;

  MqttServerClient? _client;
  String? _serial;
  String? _appUuid;
  String? _token;
  bool _isConnected = false;
  Timer? _reconnectTimer;

  MqttDataCallback? onDataReceived;
  MqttConnectionCallback? onConnectionChanged;

  /// Current connection state
  bool get isConnected => _isConnected;

  /// Topics to subscribe to (relative to prefix)
  static const List<String> _subscribeTopics = [
    'Version',
    'Access',
    'ChargeCurrent',
    'ChargeCurrentOverride',
    'Mode',
    'NrOfPhases',
    'State',
    'Error',
    'LoadBl',
    'SolarStopTimer',
    'MainsCurrentL1',
    'MainsCurrentL2',
    'MainsCurrentL3',
    'EVChargePower',
    'EVEnergyCharged',
    'EVImportActiveEnergy',
    'MaxCurrent',
  ];

  /// Get the topic prefix for a serial
  String get _topicPrefix => 'SmartEVSE-$_serial';

  /// Connect to MQTT broker
  Future<bool> connect({
    required String serial,
    required String appUuid,
    required String token,
  }) async {
    // Check if already connected to the same device
    if (_isConnected && _serial == serial && _appUuid == appUuid && _token == token) {
      Logger.debug('MQTT', 'Already connected to $serial, skipping');
      return true;
    }

    // Disconnect any existing connection first
    if (_client != null) {
      Logger.debug('MQTT', 'Disconnecting existing connection before reconnect');
      disconnect();
      // Small delay to ensure clean disconnect
      await Future.delayed(const Duration(milliseconds: 100));
    }

    _serial = serial;
    _appUuid = appUuid;
    _token = token;

    // Create client ID based on appUuid only (consistent across reconnects)
    final clientId = 'smartevse_app_${appUuid.substring(0, 8)}';
    Logger.debug('MQTT', 'Connecting with clientId: $clientId to serial: $serial');

    _client = MqttServerClient.withPort(_broker, clientId, _port);
    _client!.secure = true;
    _client!.securityContext = SecurityContext.defaultContext;
    _client!.keepAlivePeriod = 30;
    _client!.connectTimeoutPeriod = 5000;  // 5 second connection timeout
    _client!.autoReconnect = true;
    _client!.resubscribeOnAutoReconnect = true;
    _client!.onConnected = _onConnected;
    _client!.onDisconnected = _onDisconnected;
    _client!.onAutoReconnect = _onAutoReconnect;
    _client!.onSubscribed = _onSubscribed;

    // Set up connection message with authentication
    final connMessage = MqttConnectMessage()
        .withClientIdentifier(clientId)
        .authenticateAs(appUuid, token)
        .withWillTopic('$_topicPrefix/App/Status')
        .withWillMessage('offline')
        .withWillQos(MqttQos.atLeastOnce)
        .startClean();

    _client!.connectionMessage = connMessage;

    try {
      await _client!.connect();
      if (_client!.connectionStatus?.state == MqttConnectionState.connected) {
        Logger.debug('MQTT', 'Connected successfully');
        _subscribeToTopics();
        return true;
      }
    } catch (e) {
      Logger.error('MQTT', 'Connection error: $e');
      _client?.disconnect();
    }
    return false;
  }

  /// Disconnect from MQTT broker
  void disconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    // Publish offline status before graceful disconnect
    // (Last Will only triggers on unexpected disconnects)
    if (_isConnected && _client != null && _serial != null) {
      _publish('$_topicPrefix/App/Status', 'offline');
    }
    _client?.disconnect();
    _client = null;
    _isConnected = false;
    onConnectionChanged?.call(false);
  }

  /// Subscribe to all relevant topics
  void _subscribeToTopics() {
    if (_client == null || _serial == null) return;

    for (final topic in _subscribeTopics) {
      final fullTopic = '$_topicPrefix/$topic';
      _client!.subscribe(fullTopic, MqttQos.atLeastOnce);
    }

    // Listen for incoming messages
    _client!.updates?.listen(_onMessage);
  }

  /// Handle incoming MQTT messages
  void _onMessage(List<MqttReceivedMessage<MqttMessage>> messages) {
    for (final message in messages) {
      final topic = message.topic;
      final payload = message.payload as MqttPublishMessage;
      final value = MqttPublishPayload.bytesToStringAsString(payload.payload.message);

      // Extract the topic name (without prefix)
      final topicName = topic.replaceFirst('$_topicPrefix/', '');

      // Convert to map and call callback
      final data = _parseTopicValue(topicName, value);
      if (data.isNotEmpty) {
        onDataReceived?.call(data);
      }
    }
  }

  /// Parse topic value into a map with appropriate key
  Map<String, dynamic> _parseTopicValue(String topic, String value) {
    final data = <String, dynamic>{};

    switch (topic) {
      case 'Version':
        data['version'] = value;
        break;
      case 'Access':
        data['access'] = int.tryParse(value) ?? 0;
        break;
      case 'ChargeCurrent':
        // Value is in deciamps, convert to amps
        data['charge_current'] = (int.tryParse(value) ?? 0) / 10.0;
        break;
      case 'ChargeCurrentOverride':
        data['override_current'] = (int.tryParse(value) ?? 0) / 10.0;
        break;
      case 'Mode':
        // Mode comes as string: "Off", "Normal", "Solar", "Smart"
        final modeLower = value.toLowerCase();
        data['mode'] = modeLower;
        data['mode_int'] = _modeStringToInt(modeLower);
        break;
      case 'NrOfPhases':
        data['nrofphases'] = int.tryParse(value) ?? 0;
        break;
      case 'State':
        // State comes as string: "Ready to Charge", "Connected to EV", "Charging", etc.
        data['state'] = value;
        data['state_id'] = _stateStringToId(value); // convert to id
        break;
      case 'Error':
        // Error comes as string, "None" means no error
        data['error'] = value;
        break;
      case 'LoadBl':
        data['loadbl'] = int.tryParse(value) ?? 0;
        break;
      case 'SolarStopTimer':
        data['solar_stop_timer'] = int.tryParse(value) ?? 0;
        break;
      case 'MainsCurrentL1':
        data['l1'] = (int.tryParse(value) ?? 0) / 10.0;
        break;
      case 'MainsCurrentL2':
        data['l2'] = (int.tryParse(value) ?? 0) / 10.0;
        break;
      case 'MainsCurrentL3':
        data['l3'] = (int.tryParse(value) ?? 0) / 10.0;
        break;
      case 'EVChargePower':
        data['power'] = (int.tryParse(value) ?? 0) / 1000.0; // W to kW
        break;
      case 'EVEnergyCharged':
        data['charged_kwh'] = (int.tryParse(value) ?? 0) / 1000.0; // Wh to kWh
        break;
      case 'EVImportActiveEnergy':
        data['import_active_energy'] = (int.tryParse(value) ?? 0) / 1000.0;
        break;
      case 'MaxCurrent':
        // Value is in deciamps, convert to amps
        data['max_current'] = ((int.tryParse(value) ?? 320) / 10.0).toInt();
        break;
    }

    return data;
  }

  /// Convert mode string to int
  int _modeStringToInt(String mode) {
    switch (mode.toLowerCase()) {
      case 'off':
        return 0;
      case 'normal':
        return 1;
      case 'solar':
        return 2;
      case 'smart':
        return 3;
      default:
        return 0;
    }
  }

  /// Convert state string to state ID
  /// States: "Ready to Charge", "Connected to EV", "Charging", "D", 
  /// "Request State B", "State B OK", "Request State C", "State C OK",
  /// "Activate", "Charging Stopped", "Stop Charging"
  int _stateStringToId(String state) {
    switch (state) {
      case 'Ready to Charge':
        return 0;
      case 'Connected to EV':
        return 1;
      case 'Charging':
        return 2;
      case 'D':
        return 3;
      case 'Request State B':
        return 4;
      case 'State B OK':
        return 5;
      case 'Request State C':
        return 6;
      case 'State C OK':
        return 7;
      case 'Activate':
        return 8;
      case 'Charging Stopped':
        return 9;
      case 'Stop Charging':
        return 10;
      default:
        return 0;
    }
  }

  /// Publish mode change
  Future<bool> setMode(int mode) async {
    if (_client == null || !_isConnected || _serial == null) {
      Logger.warning('MQTT', 'setMode: Cannot publish - client=$_client, connected=$_isConnected, serial=$_serial');
      return false;
    }

    // Convert mode int to string: Off, Normal, Solar, Smart
    final modeString = _modeIntToString(mode);
    final topic = '$_topicPrefix/Set/Mode';
    Logger.debug('MQTT', 'setMode: Publishing $modeString to $topic');
    return _publish(topic, modeString);
  }

  /// Convert mode int to string for publishing
  String _modeIntToString(int mode) {
    switch (mode) {
      case 0:
        return 'Off';
      case 1:
        return 'Normal';
      case 2:
        return 'Solar';
      case 3:
        return 'Smart';
      default:
        return 'Off';
    }
  }

  /// Publish current override
  Future<bool> setCurrentOverride(int deciAmps) async {
    if (_client == null || !_isConnected || _serial == null) {
      Logger.warning('MQTT', 'setCurrentOverride: Cannot publish - client=$_client, connected=$_isConnected, serial=$_serial');
      return false;
    }

    final topic = '$_topicPrefix/Set/CurrentOverride';
    Logger.debug('MQTT', 'setCurrentOverride: Publishing $deciAmps to $topic');
    return _publish(topic, deciAmps.toString());
  }

  /// Publish a message to a topic
  bool _publish(String topic, String message) {
    try {
      final builder = MqttClientPayloadBuilder();
      builder.addString(message);
      _client!.publishMessage(topic, MqttQos.atLeastOnce, builder.payload!);
      Logger.debug('MQTT', 'Published "$message" to $topic');
      return true;
    } catch (e) {
      Logger.error('MQTT', 'Publish error: $e');
      return false;
    }
  }

  // Connection callbacks
  void _onConnected() {
    Logger.info('MQTT', 'Connected');
    _isConnected = true;
    // Publish online status so controller knows app is connected
    _publish('$_topicPrefix/App/Status', 'online');
    onConnectionChanged?.call(true);
  }

  void _onDisconnected() {
    Logger.info('MQTT', 'Disconnected');
    _isConnected = false;
    onConnectionChanged?.call(false);
  }

  void _onAutoReconnect() {
    Logger.info('MQTT', 'Auto-reconnecting...');
    _isConnected = false;
    onConnectionChanged?.call(false);
  }

  void _onSubscribed(String topic) {
    Logger.debug('MQTT', 'Subscribed to: $topic');
  }
}
