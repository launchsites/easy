#include "ai_credential_service.h"

#include <cstring>
#include <memory>
#include <libsecret/secret.h>

namespace {

constexpr char kChannel[] = "app.launchsites.easy/ai_credentials";
constexpr char kReferencePrefix[] = "easy.ai.";
constexpr char kCredentialLabel[] = "Easy AI provider key";

const SecretSchema kSchema = {
    "app.launchsites.easy.AiCredential",
    SECRET_SCHEMA_NONE,
    {
        {"application", SECRET_SCHEMA_ATTRIBUTE_STRING},
        {"reference", SECRET_SCHEMA_ATTRIBUTE_STRING},
        {nullptr, SECRET_SCHEMA_ATTRIBUTE_STRING},
    },
};

void respond(FlMethodCall* call, FlValue* value) {
  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_success_response_new(value));
  fl_method_call_respond(call, response, nullptr);
}

void respond_bool(FlMethodCall* call, bool value) {
  g_autoptr(FlValue) result = fl_value_new_bool(value);
  respond(call, result);
}

void respond_error(FlMethodCall* call, const char* code, const char* message) {
  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_error_response_new(code, message, nullptr));
  fl_method_call_respond(call, response, nullptr);
}

void unavailable(FlMethodCall* call) {
  respond_error(call, "credentialServiceUnavailable",
                "The Linux credential service is unavailable.");
}

const char* string_argument(FlValue* args, const char* name) {
  if (!args || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) return nullptr;
  FlValue* field = fl_value_lookup_string(args, name);
  return field && fl_value_get_type(field) == FL_VALUE_TYPE_STRING
             ? fl_value_get_string(field)
             : nullptr;
}

bool valid_reference(const char* reference) {
  constexpr size_t prefix_length = sizeof(kReferencePrefix) - 1;
  if (!reference || std::strlen(reference) != prefix_length + 64 ||
      !g_str_has_prefix(reference, kReferencePrefix)) {
    return false;
  }
  for (auto cursor = reference + prefix_length; *cursor; ++cursor) {
    const auto value = *cursor;
    if ((value < '0' || value > '9') && (value < 'a' || value > 'f')) {
      return false;
    }
  }
  return true;
}

bool valid_secret(const char* secret) {
  if (!secret || !*secret || std::strlen(secret) > 4096) return false;
  for (auto cursor = secret; *cursor; ++cursor) {
    if (*cursor < 0x21 || *cursor > 0x7e) return false;
  }
  return true;
}

void on_collection(GObject*, GAsyncResult* result, gpointer data) {
  g_autoptr(FlMethodCall) call = FL_METHOD_CALL(data);
  g_autoptr(GError) error = nullptr;
  g_autoptr(SecretCollection) collection =
      secret_collection_for_alias_finish(result, &error);
  respond_bool(call, collection != nullptr && error == nullptr);
}

void on_service(GObject*, GAsyncResult* result, gpointer data) {
  g_autoptr(FlMethodCall) call = FL_METHOD_CALL(data);
  g_autoptr(GError) error = nullptr;
  g_autoptr(SecretService) service = secret_service_get_finish(result, &error);
  if (!service || error) {
    respond_bool(call, false);
    return;
  }
  secret_collection_for_alias(service, SECRET_COLLECTION_DEFAULT,
                              SECRET_COLLECTION_NONE, nullptr, on_collection,
                              g_steal_pointer(&call));
}

void on_read(GObject*, GAsyncResult* result, gpointer data) {
  g_autoptr(FlMethodCall) call = FL_METHOD_CALL(data);
  g_autoptr(GError) error = nullptr;
  const std::unique_ptr<gchar, decltype(&secret_password_free)> key(
      secret_password_lookup_finish(result, &error), secret_password_free);
  if (error || (key && !valid_secret(key.get()))) {
    unavailable(call);
    return;
  }
  g_autoptr(FlValue) value = key ? fl_value_new_string(key.get()) : nullptr;
  respond(call, value);
}

void on_write(GObject*, GAsyncResult* result, gpointer data) {
  g_autoptr(FlMethodCall) call = FL_METHOD_CALL(data);
  g_autoptr(GError) error = nullptr;
  if (!secret_password_store_finish(result, &error) || error) {
    unavailable(call);
    return;
  }
  respond(call, nullptr);
}

void on_delete(GObject*, GAsyncResult* result, gpointer data) {
  g_autoptr(FlMethodCall) call = FL_METHOD_CALL(data);
  g_autoptr(GError) error = nullptr;
  secret_password_clear_finish(result, &error);
  if (error) {
    unavailable(call);
    return;
  }
  respond(call, nullptr);
}

void handle_call(FlMethodChannel*, FlMethodCall* call, gpointer) {
  const gchar* method = fl_method_call_get_name(call);
  if (g_str_equal(method, "available")) {
    secret_service_get(SECRET_SERVICE_NONE, nullptr, on_service,
                       g_object_ref(call));
    return;
  }
  const bool reading = g_str_equal(method, "read");
  const bool writing = g_str_equal(method, "write");
  const bool deleting = g_str_equal(method, "delete");
  if (!reading && !writing && !deleting) {
    g_autoptr(FlMethodResponse) response =
        FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
    fl_method_call_respond(call, response, nullptr);
    return;
  }
  FlValue* args = fl_method_call_get_args(call);
  const auto* reference = string_argument(args, "reference");
  const auto* secret = writing ? string_argument(args, "secret") : nullptr;
  if (!valid_reference(reference) || (writing && !valid_secret(secret))) {
    respond_error(call, "invalidCredential", "Invalid provider credential.");
    return;
  }
  // The async libsecret API copies the attributes and keeps the callback on
  // this GLib context. The method call remains alive until it gets one reply.
  if (reading) {
    secret_password_lookup(&kSchema, nullptr, on_read, g_object_ref(call),
                           "application", APPLICATION_ID, "reference",
                           reference, nullptr);
  } else if (writing) {
    secret_password_store(&kSchema, SECRET_COLLECTION_DEFAULT, kCredentialLabel,
                          secret, nullptr, on_write, g_object_ref(call),
                          "application", APPLICATION_ID, "reference", reference,
                          nullptr);
  } else {
    secret_password_clear(&kSchema, nullptr, on_delete, g_object_ref(call),
                          "application", APPLICATION_ID, "reference", reference,
                          nullptr);
  }
}

}  // namespace

void register_ai_credential_service(FlBinaryMessenger* messenger) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel =
      fl_method_channel_new(messenger, kChannel, FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, handle_call, nullptr,
                                            nullptr);
}
