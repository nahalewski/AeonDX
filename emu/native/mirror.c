/* Mirroring: the running game's top screen, handed from the HOME menu (Lua,
 * ec_mirror_push after it draws the top screen) to the TV (FoldMirror.java,
 * a Presentation on an external display) without going through Lua strings.
 * Lua copies the picture here; the Presentation's view, on the UI thread,
 * copies the newest one into its Bitmap through JNI. */
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

#include "emucore_internal.h"

static struct {
  pthread_mutex_t lock;
  uint8_t* rgba;
  int w, h;
  long long serial;
} mir = { PTHREAD_MUTEX_INITIALIZER, NULL, 0, 0, 0 };

void ec_mirror_push(const uint8_t* rgba, int w, int h)
{
  if (!rgba || w <= 0 || h <= 0 || w > 4096 || h > 4096) return;
  pthread_mutex_lock(&mir.lock);
  if (w != mir.w || h != mir.h || !mir.rgba) {
    free(mir.rgba);
    mir.rgba = (uint8_t*)malloc((size_t)w * h * 4);
    mir.w = mir.rgba ? w : 0;
    mir.h = mir.rgba ? h : 0;
  }
  if (mir.rgba) {
    memcpy(mir.rgba, rgba, (size_t)w * h * 4);
    mir.serial++;
  }
  pthread_mutex_unlock(&mir.lock);
}

#ifdef __ANDROID__
#include <android/bitmap.h>
#include <jni.h>

/* the newest picture's number (0: none yet) */
JNIEXPORT jlong JNICALL Java_org_love2d_android_FoldMirror_nativeSerial(JNIEnv* env, jclass cls)
{
  (void)env; (void)cls;
  pthread_mutex_lock(&mir.lock);
  long long s = mir.serial;
  pthread_mutex_unlock(&mir.lock);
  return (jlong)s;
}

/* its size, (w << 16) | h */
JNIEXPORT jint JNICALL Java_org_love2d_android_FoldMirror_nativeSize(JNIEnv* env, jclass cls)
{
  (void)env; (void)cls;
  pthread_mutex_lock(&mir.lock);
  int v = (mir.w << 16) | mir.h;
  pthread_mutex_unlock(&mir.lock);
  return v;
}

/* the picture into an ARGB_8888 bitmap of the same size; its number, or -1 */
JNIEXPORT jlong JNICALL Java_org_love2d_android_FoldMirror_nativeCopy(JNIEnv* env, jclass cls, jobject bitmap)
{
  (void)cls;
  AndroidBitmapInfo info;
  if (AndroidBitmap_getInfo(env, bitmap, &info) != ANDROID_BITMAP_RESULT_SUCCESS) return -1;
  if (info.format != ANDROID_BITMAP_FORMAT_RGBA_8888) return -1;
  void* px = NULL;
  if (AndroidBitmap_lockPixels(env, bitmap, &px) != ANDROID_BITMAP_RESULT_SUCCESS || !px) return -1;
  long long s = -1;
  pthread_mutex_lock(&mir.lock);
  if (mir.rgba && (int)info.width == mir.w && (int)info.height == mir.h) {
    /* the bitmap's memory is RGBA byte order, as the picture is */
    for (int y = 0; y < mir.h; y++)
      memcpy((uint8_t*)px + (size_t)y * info.stride, mir.rgba + (size_t)y * mir.w * 4, (size_t)mir.w * 4);
    s = mir.serial;
  }
  pthread_mutex_unlock(&mir.lock);
  AndroidBitmap_unlockPixels(env, bitmap);
  return (jlong)s;
}
#endif
