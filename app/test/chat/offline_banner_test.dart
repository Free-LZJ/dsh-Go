import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';
import 'support/sample_chat.dart';

void main() {
  testWidgets('a kept conversation says it is offline, not silently blank', (tester) async {
    usePhoneView(tester);
    final harness = ChatHarness(
      session: 'a',
      connected: false,
      states: {
        'a': ChatState(
          loading: false,
          offline: true,
          title: 'Kept',
          items: [user(1, '上一次的问题'), assistant(2, '上一次的回复')],
        ),
      },
    );
    await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
    await pumpFrames(tester);
    expect(find.text(appL10n.readListOffline), findsOneWidget);
  });

  testWidgets('a connected conversation never claims to be offline', (tester) async {
    usePhoneView(tester);
    final harness = ChatHarness(
      session: 'a',
      states: {
        'a': ChatState(loading: false, title: 'Live', items: [user(1, '问题'), assistant(2, '回复')]),
      },
    );
    await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
    await pumpFrames(tester);
    expect(find.text(appL10n.readListOffline), findsNothing);
  });
}
