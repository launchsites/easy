import 'package:image_picker/image_picker.dart';

import '../../storage/attachment_store.dart';
import '../nutrition_model.dart';

final class AndroidMealPhotoRecovery {
  AndroidMealPhotoRecovery({
    required Future<AttachmentStore?> Function() openAttachments,
    required Future<bool> Function(NutritionMeal) commitDraft,
    Future<LostDataResponse> Function()? retrieveLostData,
    Future<String> Function()? supportDirectory,
    Future<String> Function()? cacheDirectory,
  });

  Future<NutritionMeal?> recover() async => null;
}
