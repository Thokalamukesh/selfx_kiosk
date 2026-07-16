import 'package:api_selfxo_project/core/kiosk_restaurant_meta.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('KioskRestaurantMeta.resolveOrderTypeAvailability', () {
    test('shows pickup when admin order types include takeaway', () {
      final availability = KioskRestaurantMeta.resolveOrderTypeAvailability(
        kioskSettings: {
          'order_types': ['dine_in', 'takeaway'],
        },
      );

      expect(availability['dine_in'], isTrue);
      expect(availability['pickup'], isTrue);
    });

    test('hides pickup when admin order types only include dine in', () {
      final availability = KioskRestaurantMeta.resolveOrderTypeAvailability(
        kioskSettings: {
          'order_types': ['dine_in'],
        },
      );

      expect(availability['dine_in'], isTrue);
      expect(availability['pickup'], isFalse);
    });

    test('hides pickup when admin sends an object config with pickup disabled',
        () {
      final availability = KioskRestaurantMeta.resolveOrderTypeAvailability(
        kioskSettings: {
          'available_order_types': [
            {'type': 'dine_in', 'enabled': true},
            {'type': 'pickup', 'enabled': false},
          ],
        },
      );

      expect(availability['dine_in'], isTrue);
      expect(availability['pickup'], isFalse);
    });

    test('explicit takeaway disabled flag overrides a stale order type list',
        () {
      final availability = KioskRestaurantMeta.resolveOrderTypeAvailability(
        kioskSettings: {
          'order_types': ['dine_in', 'takeaway'],
          'takeaway_enabled': false,
        },
      );

      expect(availability['dine_in'], isTrue);
      expect(availability['pickup'], isFalse);
    });

    test('default order type does not hide pickup when choice is enabled', () {
      final availability = KioskRestaurantMeta.resolveOrderTypeAvailability(
        kioskSettings: {
          'order_type': 'dine_in',
          'allow_order_type_choice': true,
        },
      );

      expect(availability['dine_in'], isTrue);
      expect(availability['pickup'], isTrue);
    });

    test('uses backend ordering block from kiosk bootstrap response', () {
      final availability = KioskRestaurantMeta.resolveOrderTypeAvailability(
        kioskSettings: {
          'enable_pickup': true,
          'enable_delivery': true,
          'enable_dine_in': true,
          'allowed_order_types': ['dine_in', 'pickup', 'delivery'],
          'pos_order_types': ['dine_in', 'takeaway', 'delivery'],
        },
      );

      expect(availability['dine_in'], isTrue);
      expect(availability['pickup'], isTrue);
    });

    test('hides pickup when backend ordering block disables pickup', () {
      final availability = KioskRestaurantMeta.resolveOrderTypeAvailability(
        kioskSettings: {
          'enable_pickup': false,
          'enable_delivery': true,
          'enable_dine_in': true,
          'allowed_order_types': ['dine_in', 'delivery'],
          'pos_order_types': ['dine_in', 'takeaway', 'delivery'],
        },
      );

      expect(availability['dine_in'], isTrue);
      expect(availability['pickup'], isFalse);
    });
  });

  group('KioskRestaurantMeta order type choice', () {
    test('reads admin switch for showing dine in or takeaway buttons', () {
      expect(
        KioskRestaurantMeta.resolveAllowOrderTypeChoice(
          kioskSettings: {'allow_order_type_choice': false},
        ),
        isFalse,
      );
      expect(
        KioskRestaurantMeta.resolveAllowOrderTypeChoice(
          kioskSettings: {'allow_order_type_choice': true},
        ),
        isTrue,
      );
    });

    test('normalizes default order type for hidden choice mode', () {
      expect(
        KioskRestaurantMeta.resolveDefaultOrderType(
          kioskSettings: {'order_type': 'takeaway'},
        ),
        'pickup',
      );
      expect(
        KioskRestaurantMeta.resolveDefaultOrderType(
          kioskSettings: {'order_type': 'pick_up'},
        ),
        'pickup',
      );
      expect(
        KioskRestaurantMeta.resolveDefaultOrderType(
          kioskSettings: {'order_type': 'dine_in'},
        ),
        'dine_in',
      );
    });

    test('extracts top-level admin settings response as kiosk settings', () {
      final bundle = KioskRestaurantMeta.extractBundle({
        'order_type': 'dine_in',
        'allow_order_type_choice': true,
        'require_customer_name': true,
        'payment_at_counter': true,
        'show_item_images': true,
      });

      expect(bundle.kioskSettings?['order_type'], 'dine_in');
      expect(bundle.kioskSettings?['allow_order_type_choice'], isTrue);
      expect(
        KioskRestaurantMeta.resolveAllowOrderTypeChoice(
          kioskSettings: bundle.kioskSettings,
        ),
        isTrue,
      );
      expect(
        KioskRestaurantMeta.resolveDefaultOrderType(
          kioskSettings: bundle.kioskSettings,
        ),
        'dine_in',
      );
      expect(
        KioskRestaurantMeta.resolveOrderTypeAvailability(
          kioskSettings: bundle.kioskSettings,
        )['pickup'],
        isTrue,
      );
    });

    test('extracts top-level pick up admin settings response', () {
      final bundle = KioskRestaurantMeta.extractBundle({
        'order_type': 'pick_up',
        'allow_order_type_choice': true,
        'require_customer_name': true,
        'payment_at_counter': true,
      });

      expect(
        KioskRestaurantMeta.resolveDefaultOrderType(
          kioskSettings: bundle.kioskSettings,
        ),
        'pickup',
      );
      expect(
        KioskRestaurantMeta.resolveOrderTypeAvailability(
          kioskSettings: bundle.kioskSettings,
        )['pickup'],
        isTrue,
      );
    });

    test('welcome hides takeaway when choice is off and default is dine in',
        () {
      final visibleTypes = KioskRestaurantMeta.resolveWelcomeOrderTypes(
        kioskSettings: {
          'order_type': 'dine_in',
          'allow_order_type_choice': false,
          'enable_pickup': true,
          'enable_dine_in': true,
          'allowed_order_types': ['dine_in', 'pickup', 'delivery'],
        },
      );

      expect(visibleTypes['dine_in'], isTrue);
      expect(visibleTypes['pickup'], isFalse);
    });

    test(
        'welcome shows only takeaway when choice is off and default is pick up',
        () {
      final visibleTypes = KioskRestaurantMeta.resolveWelcomeOrderTypes(
        kioskSettings: {
          'order_type': 'pick_up',
          'allow_order_type_choice': false,
          'enable_pickup': true,
          'enable_dine_in': true,
          'allowed_order_types': ['dine_in', 'pickup', 'delivery'],
        },
      );

      expect(visibleTypes['dine_in'], isFalse);
      expect(visibleTypes['pickup'], isTrue);
    });
  });
}
