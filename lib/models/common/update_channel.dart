import 'package:PiliPlus/models/common/enum_with_label.dart';

enum UpdateChannel implements EnumWithLabel {
  github('GitHub'),
  domestic('国内渠道');

  @override
  final String label;
  const UpdateChannel(this.label);
}
