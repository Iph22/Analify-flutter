# Analify for Flutter

Private, simple analytics for Flutter apps on iPhone, Android and desktop: screens, events and signed-in users on your [Analify](https://analify.dev) dashboard.

- Screens recorded automatically as people move around your app.
- No advertising ID, no device identifiers. One random install ID stays in your app's storage so a returning user is counted once.
- Works offline: events wait on the device (up to 7 days) and go out in small batches.

## Install

```yaml
dependencies:
  analify:
    git:
      url: https://github.com/Iph22/Analify-flutter
      ref: 0.1.0
```

## Use

Add an app in Analify (**Add website → App**) to get its key, then:

```dart
import 'package:analify/analify.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Analify.start(key: 'AN-XXXXXXXX', appVersion: '1.0.0');
  runApp(MaterialApp(
    navigatorObservers: [AnalifyObserver()],  // records a screen for every named route
    home: const HomePage(),
  ));
}

// Something happened (text, numbers and true/false properties)
Analify.track('purchase', {'plan': 'pro', 'amount': 9.5});

// After sign-in, with your own user ID (Analify scrambles it before saving). null on sign-out.
Analify.identify(user.id);

// The app was opened from a link: its campaign counts for the next screen
Analify.openedFrom(uri);

// Screens without a named route
Analify.screen('Settings');
```

`Analify.start` also takes `model` (for example from `device_info_plus`) to see phone models in your reports, `host` if you run Analify yourself, and `debug: true` to print what's sent.

## Privacy

What's sent: screen and event names, your properties, the app version, the operating system, and whether it's a phone, tablet or computer. The network address is used by Analify for a moment to estimate country and city, then discarded.

App Store and Google Play privacy forms: usage data (app interactions), for analytics, not linked to the user's identity unless you call `identify`, not used for tracking or shared.

More: [analify.dev/docs#apps](https://analify.dev/docs#apps) · MIT licence
