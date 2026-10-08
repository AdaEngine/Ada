#ifndef ADA_SCRIPT_AOT_FIXTURE_H
#define ADA_SCRIPT_AOT_FIXTURE_H
#include <shared/gravity_aot_runtime.h>
const gravity_aot_module *ada_native_fixture_get_module(void);
const gravity_aot_module *ada_native_hosts_get_module(void);
const gravity_aot_module *ada_native_async_get_module(void);
#endif
