import 'src/attachment_contracts.dart';
import 'src/open_attachment_web.dart'
    if (dart.library.io) 'src/open_attachment_native.dart'
    as implementation;

export 'src/attachment_contracts.dart'
    show
        AttachmentFormat,
        AttachmentKind,
        AttachmentLimits,
        AttachmentRef,
        AttachmentStore,
        AttachmentStoreException,
        StoredAttachment;

/// Opens app-managed local attachment storage. A null result means the
/// platform cannot persist these files. Browsers can still use text capture.
Future<AttachmentStore?> openAttachmentStore({
  String? directoryPath,
  AttachmentLimits limits = const AttachmentLimits(),
}) async {
  limits.validate();
  return implementation.openDefaultAttachmentStore(
    limits: limits,
    directoryPath: directoryPath,
  );
}
