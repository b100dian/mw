/*
 * Copyright (C) 2026 Jolla Ltd.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/*
 * B2 spike (gate-5 §5.4): a process that is not the compositor and never opens the HWC
 * renders with libhybris EGL into a VIRTUAL screen capture session, and binds a Wayland
 * display. Script: animate, pause, animate. See README.md.
 */

#include <EGL/egl.h>
#include <GLES2/gl2.h>
#include <wayland-server.h>

#include <dlfcn.h>
#include <errno.h>
#include <inttypes.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* libhybris-common */
void *android_dlopen(const char *filename, int flags);
void *android_dlsym(void *handle, const char *symbol);

#ifndef EGL_RECORDABLE_ANDROID
#define EGL_RECORDABLE_ANDROID 0x3142
#endif

/* The layout of sailfish::ScreenCaptureSession (droidmedia/screen_capture_service.h). */
struct session {
  uint64_t generation;
  int32_t width;
  int32_t height;
  int32_t fps;
  int32_t target;
  int32_t content_left;
  int32_t content_top;
  int32_t content_right;
  int32_t content_bottom;
};

enum { TARGET_VIRTUAL = 1 };
enum { SESSION_CHANGED = 1, FRAME_REQUESTED = 2 };

typedef EGLBoolean (*PresentationTimeFn)(EGLDisplay, EGLSurface, int64_t);
typedef EGLBoolean (*WaylandDisplayFn)(EGLDisplay, struct wl_display *);

#define MS 1000000LL
#define SEC 1000000000LL

/* Set by the libminisf callback (a Binder thread) and the signal handler. */
static pthread_mutex_t s_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t s_cond;
static int s_session_changed;
static int s_frame_requested;
static volatile sig_atomic_t s_quit;

struct spike {
  int (*query)(struct session *info);
  void (*set_callback)(void (*callback)(void *user, int event), void *user);
  void *(*acquire_generation)(uint64_t generation);
  void *(*native_window)(void *target);
  void (*release)(void *target);

  EGLDisplay dpy;
  EGLConfig config;
  EGLContext ctx;
  PresentationTimeFn presentation_time;

  void *target;                  /* NULL while detached */
  EGLSurface surface;
  struct session session;        /* the attached one */
  uint64_t ignored_generation;
  int repaint;
  int64_t attach_ns;
  int64_t first_pts_ns;
  int64_t next_frame_ns;

  int64_t phase_ns;
  int64_t script_ns;             /* attached time before the current attach */
  unsigned frames;
  unsigned phase_frames[3];
  unsigned attaches;
};

static int64_t monotonic_ns(void)
{
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (int64_t)ts.tv_sec * SEC + ts.tv_nsec;
}

static void on_signal(int sig)
{
  (void)sig;
  s_quit = 1;
}

static void on_event(void *user, int event)
{
  (void)user;
  pthread_mutex_lock(&s_lock);
  if (event == SESSION_CHANGED)
    s_session_changed = 1;
  else if (event == FRAME_REQUESTED)
    s_frame_requested = 1;
  pthread_cond_broadcast(&s_cond);
  pthread_mutex_unlock(&s_lock);
}

/* Waits until an event or the deadline, and takes the pending events. At most 250 ms, so
 * that the caller sees s_quit. */
static void wait_events(int64_t deadline_ns, int *changed, int *requested)
{
  const int64_t max_ns = monotonic_ns() + 250 * MS;
  struct timespec ts;

  if (deadline_ns > max_ns)
    deadline_ns = max_ns;
  ts.tv_sec = deadline_ns / SEC;
  ts.tv_nsec = deadline_ns % SEC;

  pthread_mutex_lock(&s_lock);
  while (!s_session_changed && !s_frame_requested && !s_quit &&
      pthread_cond_timedwait(&s_cond, &s_lock, &ts) != ETIMEDOUT) {
  }
  *changed |= s_session_changed;
  *requested |= s_frame_requested;
  s_session_changed = 0;
  s_frame_requested = 0;
  pthread_mutex_unlock(&s_lock);
}

/* libhybris reads HYBRIS_EGLPLATFORM before EGL_PLATFORM. */
static int check_platform(void)
{
  const char *hybris = getenv("HYBRIS_EGLPLATFORM");
  const char *platform = getenv("EGL_PLATFORM");

  if (hybris && strcmp(hybris, "hwcomposer") != 0) {
    fprintf(stderr, "HYBRIS_EGLPLATFORM=%s overrides EGL_PLATFORM; unset it\n", hybris);
    return 0;
  }
  if (!platform || strcmp(platform, "hwcomposer") != 0) {
    fprintf(stderr, "run with EGL_PLATFORM=hwcomposer\n");
    return 0;
  }
  return 1;
}

static int load_minisf(struct spike *sp)
{
  /* Never closed: libminisf runs Binder threads in this process. */
  void *lib = android_dlopen("libminisf.so", RTLD_LAZY);

  if (!lib) {
    fprintf(stderr, "android_dlopen(libminisf.so) failed\n");
    return 0;
  }
#define RESOLVE(field, name) sp->field = (__typeof__(sp->field))android_dlsym(lib, \
    "minisf_screen_capture_" name)
  RESOLVE(query, "session_query");
  RESOLVE(set_callback, "set_callback");
  RESOLVE(acquire_generation, "target_acquire_generation");
  RESOLVE(native_window, "target_native_window");
  RESOLVE(release, "target_release");
#undef RESOLVE
  if (!sp->query || !sp->set_callback || !sp->acquire_generation || !sp->native_window ||
      !sp->release) {
    fprintf(stderr, "libminisf has no screen capture API\n");
    return 0;
  }
  return 1;
}

static int init_egl(struct spike *sp)
{
  static const EGLint config_attrs[] = {
    EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
    EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
    EGL_RECORDABLE_ANDROID, EGL_TRUE,
    EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
    EGL_NONE
  };
  static const EGLint context_attrs[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
  EGLint major = 0, minor = 0, count = 0;
  EGLBoolean current;

  sp->dpy = eglGetDisplay(EGL_DEFAULT_DISPLAY);
  if (sp->dpy == EGL_NO_DISPLAY || !eglInitialize(sp->dpy, &major, &minor)) {
    fprintf(stderr, "eglInitialize failed: 0x%x\n", eglGetError());
    return 0;
  }
  fprintf(stderr, "EGL %d.%d, vendor %s\n", major, minor, eglQueryString(sp->dpy, EGL_VENDOR));

  if (!eglBindAPI(EGL_OPENGL_ES_API) ||
      !eglChooseConfig(sp->dpy, config_attrs, &sp->config, 1, &count) || count == 0) {
    fprintf(stderr, "no recordable RGBA8888 GLES2 config: 0x%x\n", eglGetError());
    return 0;
  }
  sp->ctx = eglCreateContext(sp->dpy, sp->config, EGL_NO_CONTEXT, context_attrs);
  if (sp->ctx == EGL_NO_CONTEXT) {
    fprintf(stderr, "eglCreateContext failed: 0x%x\n", eglGetError());
    return 0;
  }
  current = eglMakeCurrent(sp->dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, sp->ctx);
  fprintf(stderr, "eglMakeCurrent(no surface): %s\n", current ? "EGL_TRUE" : "EGL_FALSE");

  sp->presentation_time =
      (PresentationTimeFn)eglGetProcAddress("eglPresentationTimeANDROID");
  if (!sp->presentation_time) {
    fprintf(stderr, "no eglPresentationTimeANDROID\n");
    return 0;
  }
  return 1;
}

static int64_t script_time(const struct spike *sp, int64_t now)
{
  return sp->script_ns + (sp->target ? now - sp->attach_ns : 0);
}

/* Returns 0 if EGL failed on a live session. */
static int attach(struct spike *sp, const struct session *s)
{
  void *target = sp->acquire_generation(s->generation);
  void *window = target ? sp->native_window(target) : NULL;
  EGLSurface surface;

  if (!window) {
    fprintf(stderr, "session %" PRIu64 ": no target, waiting for the next one\n",
        s->generation);
    if (target)
      sp->release(target);
    sp->ignored_generation = s->generation;
    return 1;
  }

  surface = eglCreateWindowSurface(sp->dpy, sp->config, (EGLNativeWindowType)window, NULL);
  if (surface == EGL_NO_SURFACE) {
    fprintf(stderr, "eglCreateWindowSurface failed: 0x%x\n", eglGetError());
    sp->release(target);
    return 0;
  }
  if (!eglMakeCurrent(sp->dpy, surface, surface, sp->ctx)) {
    fprintf(stderr, "eglMakeCurrent failed: 0x%x\n", eglGetError());
    eglDestroySurface(sp->dpy, surface);
    sp->release(target);
    return 0;
  }
  if (!eglSwapInterval(sp->dpy, 0))
    fprintf(stderr, "eglSwapInterval(0) failed: 0x%x\n", eglGetError());

  sp->target = target;
  sp->surface = surface;
  sp->session = *s;
  sp->attach_ns = monotonic_ns();
  sp->first_pts_ns = 0;
  sp->next_frame_ns = sp->attach_ns;
  sp->repaint = 1;
  sp->attaches++;
  fprintf(stderr, "attached to session %" PRIu64 ": %dx%d at %d fps, content %d,%d,%d,%d\n",
      s->generation, s->width, s->height, s->fps, s->content_left, s->content_top,
      s->content_right, s->content_bottom);
  return 1;
}

static void detach(struct spike *sp, const char *reason)
{
  if (!eglMakeCurrent(sp->dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, sp->ctx))
    eglMakeCurrent(sp->dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
  eglDestroySurface(sp->dpy, sp->surface);
  sp->release(sp->target);
  sp->script_ns = script_time(sp, monotonic_ns());
  sp->target = NULL;
  sp->surface = EGL_NO_SURFACE;
  fprintf(stderr, "detached from session %" PRIu64 ": %s\n", sp->session.generation, reason);
}

/* Detaches from an ended session and attaches to a new VIRTUAL one. */
static int update_session(struct spike *sp)
{
  struct session s;
  const int active = sp->query(&s);

  if (sp->target && (!active || s.generation != sp->session.generation))
    detach(sp, active ? "replaced" : "ended");
  if (sp->target || !active || s.generation == sp->ignored_generation)
    return 1;

  if (s.target != TARGET_VIRTUAL || s.width <= 0 || s.height <= 0 || s.fps <= 0) {
    fprintf(stderr, "ignoring session %" PRIu64 ": target %d, %dx%d at %d fps\n",
        s.generation, s.target, s.width, s.height, s.fps);
    sp->ignored_generation = s.generation;
    return 1;
  }
  return attach(sp, &s);
}

static void fill(int x, int y, int w, int h, const GLfloat *rgb)
{
  glScissor(x, y, w, h);
  glClearColor(rgb[0], rgb[1], rgb[2], 1.0f);
  glClear(GL_COLOR_BUFFER_BIT);
}

/* Colour bars, a bar at x = t mod width (1 px/ms), and the frame number as 16 blocks,
 * most significant bit first, at the top left (GL's origin is the bottom left). */
static int draw_frame(struct spike *sp, int64_t t)
{
  static const GLfloat bars[7][3] = {
    { 1, 1, 1 }, { 1, 1, 0 }, { 0, 1, 1 }, { 0, 1, 0 }, { 1, 0, 1 }, { 1, 0, 0 }, { 0, 0, 1 },
  };
  static const GLfloat black[3] = { 0, 0, 0 }, white[3] = { 1, 1, 1 }, grey[3] = { .5, .5, .5 };
  const int w = sp->session.width, h = sp->session.height;
  const int block = h / 24 > 8 ? h / 24 : 8, pad = block / 4, gap = block / 8 + 1;
  const int x = (int)((t / MS) % w);
  const unsigned n = sp->frames;
  int64_t pts, swap_start;
  GLenum err;
  int i;

  glViewport(0, 0, w, h);
  glEnable(GL_SCISSOR_TEST);
  for (i = 0; i < 7; i++)
    fill(w * i / 7, 0, w * (i + 1) / 7 - w * i / 7, h, bars[i]);
  fill(x, 0, w / 80 > 4 ? w / 80 : 4, h, black);
  fill(0, h - block - 2 * pad, 16 * block + 2 * pad, block + 2 * pad, grey);
  for (i = 0; i < 16; i++)
    fill(pad + i * block, h - pad - block, block - gap, block,
        (n >> (15 - i)) & 1 ? white : black);
  glDisable(GL_SCISSOR_TEST);

  err = glGetError();
  if (err != GL_NO_ERROR) {
    fprintf(stderr, "frame %u: GL error 0x%x\n", n, err);
    return 0;
  }

  pts = monotonic_ns();
  if (!sp->first_pts_ns)
    sp->first_pts_ns = pts;
  if (!sp->presentation_time(sp->dpy, sp->surface, pts)) {
    fprintf(stderr, "frame %u: eglPresentationTimeANDROID failed: 0x%x\n", n, eglGetError());
    return 0;
  }
  swap_start = monotonic_ns();
  if (!eglSwapBuffers(sp->dpy, sp->surface)) {
    fprintf(stderr, "frame %u: eglSwapBuffers failed: 0x%x\n", n, eglGetError());
    return 0;
  }
  fprintf(stderr, "frame %u t=%.3fs x=%d pts=%.3f swap=%.1fms\n", n, t / 1e9, x,
      (pts - sp->first_pts_ns) / 1e9, (monotonic_ns() - swap_start) / 1e6);
  sp->frames++;
  sp->phase_frames[t / sp->phase_ns < 3 ? t / sp->phase_ns : 2]++;
  return 1;
}

/* A failed frame on an ended session is a detach; on a live one it is a failure. */
static int render(struct spike *sp, int64_t t, int *changed, int *requested)
{
  struct session s;

  if (draw_frame(sp, t))
    return 1;
  wait_events(monotonic_ns() + 500 * MS, changed, requested);
  if (sp->query(&s) && s.generation == sp->session.generation)
    return 0;
  detach(sp, "ended during the frame");
  return 1;
}

static void print_maps(void)
{
  char line[1024], path[512], seen[64][512];
  int n = 0, i;
  FILE *maps = fopen("/proc/self/maps", "r");

  if (!maps)
    return;
  fprintf(stderr, "mapped composer/hwc libraries:\n");
  while (fgets(line, sizeof(line), maps)) {
    if (sscanf(line, "%*s %*s %*s %*s %*s %511[^\n]", path) != 1 ||
        (!strstr(path, "composer") && !strstr(path, "hwc")))
      continue;
    for (i = 0; i < n && strcmp(seen[i], path) != 0; i++) {
    }
    if (i == n && n < 64) {
      strcpy(seen[n++], path);
      fprintf(stderr, "  %s\n", path);
    }
  }
  fclose(maps);
}

int main(int argc, char **argv)
{
  struct spike sp;
  struct wl_display *wl = NULL;
  WaylandDisplayFn bind_wl, unbind_wl;
  EGLBoolean bound = EGL_FALSE;
  pthread_condattr_t attr;
  struct sigaction sa;
  int changed = 1, requested = 0, completed = 0, phase_logged = -1, render_ok;

  memset(&sp, 0, sizeof(sp));
  sp.surface = EGL_NO_SURFACE;
  sp.phase_ns = (argc > 1 ? atoi(argv[1]) : 5) * SEC;
  if (sp.phase_ns <= 0) {
    fprintf(stderr, "usage: %s [seconds per phase, default 5]\n", argv[0]);
    return 2;
  }

  pthread_condattr_init(&attr);
  pthread_condattr_setclock(&attr, CLOCK_MONOTONIC);
  pthread_cond_init(&s_cond, &attr);
  memset(&sa, 0, sizeof(sa));
  sa.sa_handler = on_signal;
  sigaction(SIGINT, &sa, NULL);
  sigaction(SIGTERM, &sa, NULL);

  if (!check_platform() || !load_minisf(&sp) || !init_egl(&sp))
    return 1;

  /* No socket and no clients: this only shows that the bind works in this process. */
  bind_wl = (WaylandDisplayFn)eglGetProcAddress("eglBindWaylandDisplayWL");
  unbind_wl = (WaylandDisplayFn)eglGetProcAddress("eglUnbindWaylandDisplayWL");
  wl = wl_display_create();
  if (bind_wl && wl)
    bound = bind_wl(sp.dpy, wl);
  fprintf(stderr, "eglBindWaylandDisplayWL: %s\n",
      !bind_wl ? "missing" : !wl ? "no wl_display" : bound ? "EGL_TRUE" : "EGL_FALSE");

  sp.set_callback(on_event, NULL);
  fprintf(stderr, "waiting for a VIRTUAL session (Ctrl-C to stop)\n");

  while (!s_quit) {
    int64_t now, t, deadline;
    int phase;

    /* While detached, query on every timeout too: the query also (re)subscribes. */
    if ((changed || !sp.target) && !update_session(&sp))
      break;
    changed = 0;
    if (!sp.target) {
      requested = 0;
      wait_events(monotonic_ns() + SEC, &changed, &requested);
      continue;
    }

    now = monotonic_ns();
    t = script_time(&sp, now);
    phase = (int)(t / sp.phase_ns);
    if (phase >= 3) {
      completed = 1;
      break;
    }
    if (phase != phase_logged) {
      fprintf(stderr, "t=%.3fs: %s\n", t / 1e9, phase == 1 ? "pause" : "animate");
      phase_logged = phase;
    }

    if (phase == 1) {
      if (requested || sp.repaint) {
        fprintf(stderr, "repaint for %s\n", sp.repaint ? "the attach" : "FRAME_REQUESTED");
        if (!render(&sp, t, &changed, &requested))
          break;
      }
      sp.next_frame_ns = now + (2 * sp.phase_ns - t);
      deadline = sp.next_frame_ns;
    } else {
      if (now >= sp.next_frame_ns) {
        if (!render(&sp, t, &changed, &requested))
          break;
        sp.next_frame_ns += SEC / sp.session.fps;
        if (sp.next_frame_ns <= now)
          sp.next_frame_ns = now + SEC / sp.session.fps;
      }
      deadline = sp.next_frame_ns;
    }
    sp.repaint = 0;
    requested = 0;
    if (sp.target)
      wait_events(deadline, &changed, &requested);
  }
  print_maps();

  sp.set_callback(NULL, NULL);
  if (sp.target)
    detach(&sp, "exit");
  if (bound && unbind_wl)
    unbind_wl(sp.dpy, wl);
  if (wl)
    wl_display_destroy(wl);
  eglMakeCurrent(sp.dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
  eglDestroyContext(sp.dpy, sp.ctx);
  eglTerminate(sp.dpy);

  render_ok = completed && sp.phase_frames[0] && sp.phase_frames[2];
  fprintf(stderr, "frames %u (%u/%u/%u per phase), attaches %u\n", sp.frames,
      sp.phase_frames[0], sp.phase_frames[1], sp.phase_frames[2], sp.attaches);
  fprintf(stderr, "render: %s\n", render_ok ? "PASS" : "FAIL");
  fprintf(stderr, "wayland bind: %s\n", bound ? "PASS" : "FAIL");
  return render_ok && bound ? 0 : 1;
}
