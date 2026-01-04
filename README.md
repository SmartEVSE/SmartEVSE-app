# SmartEVSE v3 app

<img width="409" height="886" alt="image" src="https://github.com/user-attachments/assets/bf1d4737-ba30-4017-828f-b3cebde11ec9" />

Uses Flutter, Android studio, should be portable to iOS

## Getting Started

Install flutter, add %PATH variables. 
Install Android studio, make sure that the command line tools are installed. (Settings → Android SDK → SDK Tools → Command line tools)

Open a terminal window, then run:
- `flutter pub get` to install all dependencies.
- `flutter doctor` shows any potential issues, and ways to fix them.
- `flutter doctor --android-licenses` to accept android licences.
- on phone: Settings → About phone → tap “Build number” 7 times → you are now a developer.
- Back → System → Developer options → enable “USB debugging”.
- Use `flutter devices` to see connected devices.
Then run `flutter run` to run debug version on your connnected phone.
- Build apk for 64 bit android only: `flutter build apk --target-platform android-arm64` (this keeps the .apk relatively small)
- Install on phone `flutter install`. Note that this command will deinstall, and re-install the app, erasing all stored data.
- It might be better to use `adb install -r build/app/outputs/flutter-apk/app-release.apk`
- Note that when re-installing the dev environment, the phone needs to paired again. Re-enable USB debugging on the phone.

Might have missed some steps, let me know and i'll add them.

## Using the App

The SmartEVSE app provides a simple interface to control your SmartEVSE v3 controllers. Here’s a quick overview of the main options and features:

### Device Management

- **Manage Devices**: Tap the magnifying glass icon in the app bar to scan your network for available SmartEVSE devices. You can add, rename, or remove devices from your device list. 
- **Select Device**: Use the dropdown in the app to switch between your stored controllers.

### Pairing for Remote (MQTT) Access

- **Pair Device**: Tap the "link" or "cloud" icon to enter a 6-digit pairing PIN displayed on your SmartEVSE to securely link your app to the device. When paired, the app can use MQTT for remote control if available.

### Main Controls

- **Status Display**: The top panel shows current phase currents, charging current, power, energy used (kWh), and basic operational status.
- **Error & Info Messages**: Any errors or connection issues are displayed at the top of the main view.
- **Mode Selection**: Easily switch the EVSE operating mode:
  - **Off**: EVSE charging is disabled.
  - **Normal**: Standard charging mode, using grid power.
  - **Solar**: Solar-only charging if enough solar power is available.
  - **Smart**: Smart load balancing (if enabled/configured).

- **Override Current** (when available): Set a manual maximum charging current using the slider (within the allowed range), or tap "Disable Override" to return to automatic management. This option is only visible on stand-alone or "master" devices in non-solar mode.

### Privacy and user data
The app does **not** require you to create an account or provide any personal information to use its features.

After installing a unique UUID is generated, which is used as username together with the SmartEVSE serial number and Pairing pin to authenticate the device.
This is only required for the mqtt (cloud) connection.
No privacy-related or personally identifiable data is collected or stored by the app, either locally or remotely. All pairing and device information is kept only on your device for the sake of connecting and controlling your SmartEVSE units.


## Used AI assistants

- Grok (browser)
- Firebender (plugin in Android Studio)


---
A few resources to get you started if this is your first Flutter project:

- [Lab: Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Cookbook: Useful Flutter samples](https://docs.flutter.dev/cookbook)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
