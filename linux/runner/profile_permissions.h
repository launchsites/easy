#ifndef RUNNER_PROFILE_PERMISSIONS_H_
#define RUNNER_PROFILE_PERMISSIONS_H_

// Tighten existing Easy storage without following profile symlinks or changing
// the data home. New storage is protected by the runner's process umask.
void protect_easy_profile(const char* data_home, const char* application_id,
                          const char* legacy_executable);

#endif  // RUNNER_PROFILE_PERMISSIONS_H_
