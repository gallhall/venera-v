import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';

void main() {
  const wj = '⁠';

  test('glues a short last word so it is not split across lines', () {
    expect(
      keepLastWordTogether('转生就是剑 第二季'),
      '转生就是剑 第$wj二$wj季',
    );
    expect(keepLastWordTogether('Spy Family S2'), 'Spy Family S${wj}2');
  });

  test('leaves titles without a usable last word alone', () {
    expect(keepLastWordTogether('航海王'), '航海王');
    expect(keepLastWordTogether(' 航海王'), ' 航海王');
    expect(keepLastWordTogether('航海王 '), '航海王 ');
    expect(
      keepLastWordTogether('Re 從零開始的異世界生活第四章'),
      'Re 從零開始的異世界生活第四章',
    );
  });
}
