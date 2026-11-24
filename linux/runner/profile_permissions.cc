#include "profile_permissions.h"

#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

namespace {

constexpr int kDirectoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC;
constexpr char kWorkspaceDirectory[] = "easy";
constexpr int kReadFileFlags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK;

bool is_directory_name(const char* name) {
  if (name == nullptr) return false;
  const std::string component(name);
  return !component.empty() && component != "." && component != ".." &&
         component.find('/') == std::string::npos;
}

int open_data_home(const char* path) {
  if (path == nullptr || path[0] != '/') return -1;
  int parent = open("/", kDirectoryFlags);
  const std::string absolute(path);
  size_t cursor = 1;
  while (parent >= 0 && cursor < absolute.size()) {
    const auto slash = absolute.find('/', cursor);
    const auto component = absolute.substr(cursor, slash - cursor);
    cursor = slash == std::string::npos ? absolute.size() : slash + 1;
    if (component.empty() || component == ".") continue;
    if (component == "..") {
      close(parent);
      return -1;
    }
    const int next = openat(parent, component.c_str(), kDirectoryFlags);
    close(parent);
    parent = next;
  }
  return parent;
}

bool owned_directory(int descriptor) {
  struct stat metadata {};
  return fstat(descriptor, &metadata) == 0 && S_ISDIR(metadata.st_mode) &&
         metadata.st_uid == geteuid();
}

void remove_public_access(int descriptor, const struct stat& metadata) {
  constexpr mode_t kPublicBits = S_IRWXG | S_IRWXO;
  if ((metadata.st_mode & kPublicBits) != 0) {
    // Preserve owner rights, including a deliberately read-only profile.
    fchmod(descriptor, metadata.st_mode &
                          (S_IRWXU | S_ISUID | S_ISGID | S_ISVTX));
  }
}

void protect_directory(int descriptor) {
  struct stat metadata {};
  if (fstat(descriptor, &metadata) == 0 && S_ISDIR(metadata.st_mode) &&
      metadata.st_uid == geteuid()) {
    remove_public_access(descriptor, metadata);
  }
}

void protect_legacy_preferences(int legacy) {
  const int preferences =
      openat(legacy, "shared_preferences.json", kReadFileFlags);
  if (preferences < 0) return;
  struct stat metadata {};
  if (fstat(preferences, &metadata) == 0 && S_ISREG(metadata.st_mode) &&
      metadata.st_uid == geteuid() && metadata.st_nlink == 1) {
    remove_public_access(preferences, metadata);
  }
  close(preferences);
}

bool has_easy_database(int workspace) {
  const int database = openat(workspace, "workspace.sqlite3", kReadFileFlags);
  if (database < 0) return false;
  struct stat metadata {};
  char header[72];
  constexpr char kSqliteFormat[] = "SQLite format 3";
  // The SQLite file header stores the workspace application's PRAGMA ID at
  // bytes 68–71. Match lib/storage/src/sqlite_store.dart's 0x45535931.
  const bool recognized =
      fstat(database, &metadata) == 0 && S_ISREG(metadata.st_mode) &&
      metadata.st_uid == geteuid() &&
      pread(database, header, sizeof(header), 0) == sizeof(header) &&
      memcmp(header, kSqliteFormat, sizeof(kSqliteFormat)) == 0 &&
      memcmp(header + 68, "ESY1", 4) == 0;
  close(database);
  return recognized;
}

void protect_legacy_workspace(int data_home, const char* legacy_name) {
  const int legacy = openat(data_home, legacy_name, kDirectoryFlags);
  if (legacy < 0) return;
  if (owned_directory(legacy)) {
    const int workspace = openat(legacy, kWorkspaceDirectory, kDirectoryFlags);
    if (workspace >= 0) {
      if (owned_directory(workspace) && has_easy_database(workspace)) {
        // The executable-name fallback can contain unrelated files. Only
        // the verified Easy workspace and its preference file are tightened.
        protect_directory(workspace);
        protect_legacy_preferences(legacy);
      }
      close(workspace);
    }
  }
  close(legacy);
}

}  // namespace

void protect_easy_profile(const char* data_home, const char* application_id,
                          const char* legacy_executable) {
  if (!is_directory_name(application_id) ||
      !is_directory_name(legacy_executable)) {
    return;
  }
  const int home = open_data_home(data_home);
  if (home < 0) return;
  const int profile = openat(home, application_id, kDirectoryFlags);
  if (profile >= 0) {
    protect_directory(profile);
    close(profile);
  } else if (errno == ENOENT) {
    // path_provider_linux uses the executable-name directory only when the
    // application-ID directory is absent.
    protect_legacy_workspace(home, legacy_executable);
  }
  close(home);
}
