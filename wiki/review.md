# Overview

## Qt5-QPA-HWComposer

`libminisf.so` is loaded by `qt5-qpa-hwcomposer-plugin` (The latter is loaded by lipstick.)
`HwComposerScreenCapture::create/resolve` uses `android_dlsym` to get function pointers to `minisf_screen_capture_*` functions. 

### HWC2 Integration
`HwComposerScreenCapture::bufferPresented` is called inside each `HWC2Window::present()`, just before `hwc2_compat_display_set_client_target`.
That merely clones the fence of the buffer to wait on it later.

Finally, `HwComposerBackend_v20::swap` (after present() exits), calls `HwComposerScreenCapture::captureFrame()`. This call checks if there is still a **Session**.

If it is, the fence is `sync_wait`-ed, the buffer is `submit()`-ed, meaning it is `render()`ed and swapped into the destination surface which is the encoder's surface.

This does not introduce waiting on the encoder since that swap is using a buffer queue (and `attach()` configured that to use 0 ms). It does introduce a `wait_sync` when screen capturing is on (that could be replaced with sending the fence for the GPU to sync?)

### Session management
When lipstick loads `libminisf.so` through `HwComposerScreenCapture::create()` it also calls the `minisf_screen_capture_session_query` (bound as `m_sessionQuery()`) which:
- Connects to "sailfish.screencap" to receive `sessionChanged` and `binderDied` calls
- Whenever the session changes it copies the new "generation" and W/H/fps to `libminisf.so` local s_session.

At every lipstick frame then the `checkSession()` call gets that session info. 
Only when there is a session there (meaning an encoding client connected) does qpa hwencoder plugin `attach()` to it and also holds reference of the generation of the session and the `m_target` is used to swap the buffers with the encoders' native window. If generation changes  it `detach()`es.

### Rendering
Rendering is done changing the current EGL context and then by submitting a triangle strip of 2 triangles (4 vertices) as parameters to a vertex shader that covers the whole clip area -1 to 1. Then it is a fragment shader that samples the entire screen (0, 1) this time using the triangle strip TexCoords that makes up for a y-flip. 

The width and height could in theory differ from the recording session and the image will be stretched.

## Droidmedia
