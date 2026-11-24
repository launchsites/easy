#include "my_application.h"

#include <sys/stat.h>

#include "profile_permissions.h"

int main(int argc, char** argv) {
  constexpr mode_t private_bits = S_IRWXG | S_IRWXO;
  const mode_t inherited_mask = umask(private_bits);
  umask(inherited_mask | private_bits);
  protect_easy_profile(g_get_user_data_dir(), APPLICATION_ID, EASY_BINARY_NAME);
  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
