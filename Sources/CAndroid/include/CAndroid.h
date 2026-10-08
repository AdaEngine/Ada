#pragma once
#include <stdint.h>
#include <stdbool.h>
// Activity callbacks and Swift custom MainActor jobs share Android's main looper.
void ada_android_enqueue_job(void *job);
bool ada_android_is_main_thread(void);
void ada_android_finish(void);
bool ada_android_open_url(const char *url);
bool ada_android_has_surface(void);
int32_t ada_android_width(void);
int32_t ada_android_height(void);
float ada_android_scale(void);
const char *ada_android_files_path(void);
// acquire returns a retained ANativeWindow, released by the render surface owner.
void *ada_android_acquire_window(void);
void ada_android_release_window(void *window);
void ada_android_log(const char *message);
