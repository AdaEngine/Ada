#include "CAndroid.h"
#ifdef __ANDROID__
#include <android/native_activity.h>
#include <android/window.h>
#include <android/native_window.h>
#include <android/looper.h>
#include <android/choreographer.h>
#include <android/configuration.h>
#include <android/input.h>
#include <android/log.h>
#include <pthread.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <string.h>
#include <stdio.h>
#include <sys/stat.h>
#include <limits.h>
#include <android/asset_manager.h>

extern void ada_android_install_executors(void);
extern void ada_android_execute_job(void *);
extern void ada_android_start(void);
extern void ada_android_frame(int64_t);
extern void ada_android_surface_changed(int32_t, int32_t, float);
extern void ada_android_state(int32_t);
extern void ada_android_touch(int32_t, int32_t, float, float);
extern void ada_android_surface_lost(void);

typedef struct JobNode { void *job; struct JobNode *next; } JobNode;
static pthread_mutex_t job_lock = PTHREAD_MUTEX_INITIALIZER;
static JobNode *head = NULL, *tail = NULL;
static int wake_pipe[2] = {-1, -1};
static ANativeActivity *activity;
static AInputQueue *input_queue;
static bool resumed = false, frame_pending = false;
static uintptr_t frame_generation = 1;
static bool started = false;
static pthread_t main_thread;
static pthread_mutex_t window_lock = PTHREAD_MUTEX_INITIALIZER;
static ANativeWindow *native_window = NULL;
static int width, height;
static float scale = 1;
static char *files_path;

void ada_android_log(const char *message) { __android_log_write(ANDROID_LOG_INFO, "AdaEngine", message); }
void *ada_android_acquire_window(void) {
    pthread_mutex_lock(&window_lock);
    ANativeWindow *window = native_window;
    if (window) ANativeWindow_acquire(window);
    pthread_mutex_unlock(&window_lock);
    return window;
}
void ada_android_release_window(void *window) { if (window) ANativeWindow_release(window); }
void ada_android_enqueue_job(void *job) {
    JobNode *node = malloc(sizeof(JobNode));
    if (!node) abort(); // Swift executor cannot drop a job on allocation failure.
    *node = (JobNode){job, NULL};
    pthread_mutex_lock(&job_lock);
    if (tail) tail->next = node; else head = node;
    tail = node;
    pthread_mutex_unlock(&job_lock);
    char byte = 1;
    (void)write(wake_pipe[1], &byte, 1); // EAGAIN means a wake is already pending.
}
static int drain_jobs(int fd, int events, void *data) {
    (void)events; (void)data;
    char bytes[64]; while (read(fd, bytes, sizeof(bytes)) > 0) {}
    // Bound each drain so a continuously yielding Swift task cannot starve input.
    for (int n = 0; n < 256; n++) {
        pthread_mutex_lock(&job_lock);
        JobNode *node = head;
        if (node) { head = node->next; if (!head) tail = NULL; }
        pthread_mutex_unlock(&job_lock);
        if (!node) break;
        ada_android_execute_job(node->job);
        free(node);
    }
    pthread_mutex_lock(&job_lock);
    bool more = head != NULL;
    pthread_mutex_unlock(&job_lock);
    if (more) { char byte=1; (void)write(wake_pipe[1], &byte, 1); }
    return 1;
}
static void schedule_frame(void);
static void frame_callback(int64_t time, void *data) {
    // Android may discard an activity's pending callback when its surface is
    // destroyed. Old callbacks must not suppress/restart the new frame chain.
    if ((uintptr_t)data != frame_generation) return;
    frame_pending = false;
    if (!resumed || native_window == NULL) return;
    ada_android_frame(time);
    schedule_frame();
}
static void schedule_frame(void) {
    if (resumed && native_window != NULL && !frame_pending) {
        frame_pending = true;
        AChoreographer_postFrameCallback64(AChoreographer_getInstance(), frame_callback, (void *)frame_generation);
    }
}
static void on_resume(ANativeActivity *a) { if (a!=activity) return; resumed=true; ada_android_state(1); schedule_frame(); }
static void on_pause(ANativeActivity *a) { if (a!=activity) return; resumed=false; frame_generation++; frame_pending=false; ada_android_state(0); }
static void on_destroy(ANativeActivity *a) { if (a!=activity) return; resumed=false; frame_generation++; frame_pending=false; activity=NULL; ada_android_state(-1); }
static void on_window_created(ANativeActivity *a, ANativeWindow *window) {
    if (a!=activity) return;
    pthread_mutex_lock(&window_lock);
    if (native_window) ANativeWindow_release(native_window);
    native_window=window; ANativeWindow_acquire(native_window);
    width=ANativeWindow_getWidth(window); height=ANativeWindow_getHeight(window);
    pthread_mutex_unlock(&window_lock);
    ada_android_log("Android native window ready for WebGPU");
    ada_android_surface_changed(width,height,scale);
    if (!started && native_window != NULL) { started=true; ada_android_start(); }
    ada_android_state(resumed ? 1 : 0);
    schedule_frame();
}
static void on_window_resized(ANativeActivity *a, ANativeWindow *window) {
    if (a!=activity) return;
    pthread_mutex_lock(&window_lock);
    width=ANativeWindow_getWidth(window); height=ANativeWindow_getHeight(window);
    pthread_mutex_unlock(&window_lock);
    ada_android_surface_changed(width,height,scale);
}
static void on_window_destroyed(ANativeActivity *a, ANativeWindow *window) {
    if (a!=activity) return;
    (void)window;
    pthread_mutex_lock(&window_lock);
    if (native_window) ANativeWindow_release(native_window);
    native_window=NULL;
    frame_generation++; frame_pending=false;
    pthread_mutex_unlock(&window_lock);
    // Render surface owners have their own ANativeWindow leases. Swift detaches
    // the old swapchain on its main executor without exposing a freed pointer.
    ada_android_surface_lost();
    ada_android_state(0);
}
static int process_input(int fd, int events, void *data) {
    (void)fd; (void)events;
    AInputQueue *queue=data; AInputEvent *event;
    while (AInputQueue_getEvent(queue,&event)>=0) {
        if (AInputQueue_preDispatchEvent(queue,event)) continue;
        int handled=0;
        if (AInputEvent_getType(event)==AINPUT_EVENT_TYPE_MOTION) {
            int action=AMotionEvent_getAction(event);
            int kind=action & AMOTION_EVENT_ACTION_MASK;
            size_t count=AMotionEvent_getPointerCount(event);
            size_t index=(action & AMOTION_EVENT_ACTION_POINTER_INDEX_MASK)>>AMOTION_EVENT_ACTION_POINTER_INDEX_SHIFT;
            for (size_t i=0;i<count;i++) {
                if ((kind==AMOTION_EVENT_ACTION_POINTER_DOWN || kind==AMOTION_EVENT_ACTION_POINTER_UP) && i!=index) continue;
                int phase=kind==AMOTION_EVENT_ACTION_DOWN||kind==AMOTION_EVENT_ACTION_POINTER_DOWN ? 0 :
                    kind==AMOTION_EVENT_ACTION_UP||kind==AMOTION_EVENT_ACTION_POINTER_UP ? 2 : kind==AMOTION_EVENT_ACTION_CANCEL ? 3 : 1;
                ada_android_touch(AMotionEvent_getPointerId(event,i),phase,AMotionEvent_getX(event,i),AMotionEvent_getY(event,i));
            }
            handled=1;
        } else if (AInputEvent_getType(event)==AINPUT_EVENT_TYPE_KEY && AKeyEvent_getKeyCode(event)==AKEYCODE_BACK) {
            if (AKeyEvent_getAction(event)==AKEY_EVENT_ACTION_UP && activity) ANativeActivity_finish(activity);
            handled=1;
        }
        AInputQueue_finishEvent(queue,event,handled);
    }
    return 1;
}
static void input_created(ANativeActivity *a,AInputQueue *queue) {
    if (a!=activity) return;
    input_queue=queue;
    AInputQueue_attachLooper(queue,ALooper_forThread(),ALOOPER_POLL_CALLBACK,process_input,queue);
}
static void input_destroyed(ANativeActivity *a,AInputQueue *queue) {
    (void)a; AInputQueue_detachLooper(queue); if (input_queue==queue) input_queue=NULL;
}
static bool extract_resources(ANativeActivity *a) {
    AAsset *manifest=AAssetManager_open(a->assetManager,"bundles/manifest.txt",AASSET_MODE_BUFFER);
    if (!manifest) return false;
    size_t length=AAsset_getLength(manifest);
    char *text=malloc(length+1);
    if (!text) { AAsset_close(manifest); return false; }
    memcpy(text,AAsset_getBuffer(manifest),length); text[length]=0;
    AAsset_close(manifest);
    bool success=true; char *save;
    for (char *line=strtok_r(text,"\n",&save);line;line=strtok_r(NULL,"\n",&save)) {
        if (line[0]=='/' || strstr(line,"..") || strlen(line)>PATH_MAX/2) { success=false; break; }
        char asset_path[PATH_MAX], output_path[PATH_MAX];
        snprintf(asset_path,sizeof(asset_path),"bundles/%s",line);
        snprintf(output_path,sizeof(output_path),"%s/resources/%s",a->internalDataPath,line);
        for (char *part=output_path+1;*part;part++) {
            if (*part=='/') { *part=0; mkdir(output_path,0700); *part='/'; }
        }
        AAsset *asset=AAssetManager_open(a->assetManager,asset_path,AASSET_MODE_STREAMING);
        char temporary_path[PATH_MAX];
        snprintf(temporary_path,sizeof(temporary_path),"%s.tmp",output_path);
        FILE *file=asset ? fopen(temporary_path,"wb") : NULL;
        if (!file) { if (asset) AAsset_close(asset); success=false; break; }
        char buffer[16384]; int count;
        while ((count=AAsset_read(asset,buffer,sizeof(buffer)))>0) {
            if (fwrite(buffer,1,count,file)!=(size_t)count) { success=false; break; }
        }
        if (count<0) success=false;
        if (fclose(file)!=0) success=false;
        if (success && rename(temporary_path,output_path)!=0) success=false;
        if (!success) unlink(temporary_path);
        AAsset_close(asset);
        if (!success) break;
    }
    free(text); return success;
}
__attribute__((visibility("default"))) void ANativeActivity_onCreate(ANativeActivity *a, void *saved, size_t size) {
    (void)saved; (void)size; activity=a;
    resumed=false; frame_generation++; frame_pending=false;
    if (!files_path) files_path=strdup(a->internalDataPath);
    if (!extract_resources(a)) { ada_android_log("Resource extraction failed"); ANativeActivity_finish(a); return; }
    AConfiguration *configuration=AConfiguration_new();
    AConfiguration_fromAssetManager(configuration,a->assetManager);
    int density=AConfiguration_getDensity(configuration);
    scale=density>0 && density<0xfffe ? density/160.0f : 1;
    AConfiguration_delete(configuration);
    if (wake_pipe[0]<0) {
        if (pipe(wake_pipe)!=0) { ANativeActivity_finish(a); return; }
        fcntl(wake_pipe[0],F_SETFL,O_NONBLOCK); fcntl(wake_pipe[1],F_SETFL,O_NONBLOCK);
        main_thread=pthread_self();
        ada_android_install_executors();
    }
    ALooper_addFd(ALooper_forThread(),wake_pipe[0],ALOOPER_POLL_CALLBACK,ALOOPER_EVENT_INPUT,drain_jobs,NULL);
    a->callbacks->onResume=on_resume; a->callbacks->onPause=on_pause; a->callbacks->onDestroy=on_destroy;
    a->callbacks->onNativeWindowCreated=on_window_created; a->callbacks->onNativeWindowResized=on_window_resized;
    a->callbacks->onNativeWindowDestroyed=on_window_destroyed;
    a->callbacks->onInputQueueCreated=input_created; a->callbacks->onInputQueueDestroyed=input_destroyed;
    ANativeActivity_setWindowFlags(a,AWINDOW_FLAG_FULLSCREEN,0);
    ada_android_log("NativeActivity created");
}
bool ada_android_is_main_thread(void) { return pthread_equal(pthread_self(),main_thread); }
void ada_android_finish(void) { if (activity) ANativeActivity_finish(activity); }
bool ada_android_open_url(const char *url) {
    if (!activity || !resumed || !url || !url[0] || !ada_android_is_main_thread()) return false;
    JNIEnv *env = activity->env;
    if ((*env)->PushLocalFrame(env, 16) < 0) {
        (*env)->ExceptionClear(env);
        return false;
    }
    bool success = false;
    jclass intent_class = (*env)->FindClass(env, "android/content/Intent");
    if (!intent_class) goto cleanup;
    jclass uri_class = (*env)->FindClass(env, "android/net/Uri");
    if (!uri_class) goto cleanup;
    jclass activity_class = (*env)->GetObjectClass(env, activity->clazz);
    if (!activity_class) goto cleanup;
    jmethodID parse = (*env)->GetStaticMethodID(env, uri_class, "parse", "(Ljava/lang/String;)Landroid/net/Uri;");
    if (!parse) goto cleanup;
    jmethodID constructor = (*env)->GetMethodID(env, intent_class, "<init>", "(Ljava/lang/String;Landroid/net/Uri;)V");
    if (!constructor) goto cleanup;
    jmethodID start = (*env)->GetMethodID(env, activity_class, "startActivity", "(Landroid/content/Intent;)V");
    if (!start) goto cleanup;
    jstring address = (*env)->NewStringUTF(env, url);
    if (!address) goto cleanup;
    jstring action = (*env)->NewStringUTF(env, "android.intent.action.VIEW");
    if (!action) goto cleanup;
    jobject uri = (*env)->CallStaticObjectMethod(env, uri_class, parse, address);
    if (!uri || (*env)->ExceptionCheck(env)) goto cleanup;
    jobject intent = (*env)->NewObject(env, intent_class, constructor, action, uri);
    if (!intent || (*env)->ExceptionCheck(env)) goto cleanup;
    (*env)->CallVoidMethod(env, activity->clazz, start, intent);
    success = !(*env)->ExceptionCheck(env);
cleanup:
    if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
    (*env)->PopLocalFrame(env, NULL);
    return success;
}
bool ada_android_has_surface(void) { pthread_mutex_lock(&window_lock); bool value=native_window!=NULL; pthread_mutex_unlock(&window_lock); return value; }
int32_t ada_android_width(void) { pthread_mutex_lock(&window_lock); int value=width; pthread_mutex_unlock(&window_lock); return value; }
int32_t ada_android_height(void) { pthread_mutex_lock(&window_lock); int value=height; pthread_mutex_unlock(&window_lock); return value; }
float ada_android_scale(void) { return scale; }
const char *ada_android_files_path(void) { return files_path; }
#else
// Host builds keep CAndroid importable without Android SDK headers.
void ada_android_log(const char *message) { (void)message; }
bool ada_android_open_url(const char *url) { (void)url; return false; }
#endif
