import 'turn_notification_gateway.dart';
import 'turn_notification_gateway_stub.dart'
    if (dart.library.io) 'turn_notification_gateway_native.dart'
    if (dart.library.js_interop) 'turn_notification_gateway_web.dart'
    as implementation;

TurnNotificationGateway createTurnNotificationGateway() =>
    implementation.createTurnNotificationGateway();
