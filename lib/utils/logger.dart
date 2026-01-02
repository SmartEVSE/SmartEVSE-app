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

import 'package:flutter/foundation.dart';

/// Simple logger utility that only outputs in debug mode.
/// 
/// Usage:
///   Logger.debug('MQTT', 'Connected successfully');
///   Logger.info('App', 'User logged in');
///   Logger.warning('Network', 'Connection unstable');
///   Logger.error('API', 'Request failed: $error');
class Logger {
  static const String _appName = 'SmartEVSE';

  /// Log a debug message (only in debug mode)
  static void debug(String tag, String message) {
    if (kDebugMode) {
      print('[$_appName] DEBUG/$tag: $message');
    }
  }

  /// Log an info message (only in debug mode)
  static void info(String tag, String message) {
    if (kDebugMode) {
      print('[$_appName] INFO/$tag: $message');
    }
  }

  /// Log a warning message (only in debug mode)
  static void warning(String tag, String message) {
    if (kDebugMode) {
      print('[$_appName] WARN/$tag: $message');
    }
  }

  /// Log an error message (only in debug mode)
  static void error(String tag, String message) {
    if (kDebugMode) {
      print('[$_appName] ERROR/$tag: $message');
    }
  }
}
