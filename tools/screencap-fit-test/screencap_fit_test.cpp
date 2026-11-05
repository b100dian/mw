/*
 * Host check of captureFit() (qt5-qpa-hwcomposer-plugin) against the fit
 * table of wiki/auto-goal1.md §3.2 and the cases of wiki/gate-5.md 5.2.
 * From mw/ (cutils/ holds a stub of the one Android header it needs):
 *
 *   g++ -std=c++17 -Wall -W -fPIC -I/usr/include/qt -Itools/screencap-fit-test \
 *     tools/screencap-fit-test/screencap_fit_test.cpp -lQt5Core -o /tmp/screencap_fit_test &&
 *     /tmp/screencap_fit_test
 *
 * Prints one line per case and exits 1 if any fails.
 */

#include "../../qt5-qpa-hwcomposer-plugin/hwcomposer/hwcomposer_screencapture.h"

#include <stdio.h>

static int failures = 0;

static void check(const char *name, int displayWidth, int displayHeight,
                  int sessionWidth, int sessionHeight, QRect content, int landscapeRotation,
                  int rotation, QRect viewport)
{
    const CaptureFit fit = captureFit(QSize(displayWidth, displayHeight),
                                      QSize(sessionWidth, sessionHeight), content,
                                      landscapeRotation);
    const QRect &vp = fit.viewport;
    const bool ok = fit.rotation == rotation && vp == viewport;
    if (!ok)
        failures++;

    printf("%s %-36s %4dx%-4d -> %4dx%-4d rect %d,%d %dx%d: rotation %d, viewport %d,%d %dx%d",
           ok ? "PASS" : "FAIL", name, displayWidth, displayHeight, sessionWidth, sessionHeight,
           content.x(), content.y(), content.width(), content.height(), fit.rotation,
           vp.x(), vp.y(), vp.width(), vp.height());
    if (!ok)
        printf(" (expected rotation %d, viewport %d,%d %dx%d)", rotation, viewport.x(),
               viewport.y(), viewport.width(), viewport.height());
    printf("\n");
}

// A whole-frame session, picture centred.
static void checkCentred(const char *name, int displayWidth, int displayHeight,
                         int sessionWidth, int sessionHeight, int rotation,
                         int width, int height)
{
    const int x = (sessionWidth - width) / 2;
    const int y = (sessionHeight - height) / 2;
    check(name, displayWidth, displayHeight, sessionWidth, sessionHeight, QRect(), 270,
          rotation, QRect(x, y, width, height));
}

int main()
{
    // auto-goal1 §3.2: landscape sessions turn the portrait panel by 270,
    // the portrait 720x1280 one does not.
    static const struct {
        int width, height;
        int fit[4][2];  // 800x480, 1280x720, 1920x1080, 720x1280
    } table[] = {
        { 1080, 2520, { { 800, 342 }, { 1280, 548 }, { 1920, 822 }, { 548, 1280 } } },
        { 1080, 2400, { { 800, 360 }, { 1280, 576 }, { 1920, 864 }, { 576, 1280 } } },
        { 1080, 2340, { { 800, 368 }, { 1280, 590 }, { 1920, 886 }, { 590, 1280 } } },
        { 720, 1600, { { 800, 360 }, { 1280, 576 }, { 1920, 864 }, { 576, 1280 } } },
        { 1080, 1920, { { 800, 450 }, { 1280, 720 }, { 1920, 1080 }, { 720, 1280 } } },
        { 1440, 3200, { { 800, 360 }, { 1280, 576 }, { 1920, 864 }, { 576, 1280 } } },
    };
    static const int sessions[4][3] = {
        { 800, 480, 270 }, { 1280, 720, 270 }, { 1920, 1080, 270 }, { 720, 1280, 0 },
    };
    for (const auto &panel : table) {
        for (int i = 0; i < 4; i++)
            checkCentred("table", panel.width, panel.height, sessions[i][0], sessions[i][1],
                         sessions[i][2], panel.fit[i][0], panel.fit[i][1]);
    }

    // The display size and its transpose fill the frame, as before the fit.
    checkCentred("display size", 1080, 2520, 1080, 2520, 0, 1080, 2520);
    checkCentred("transposed display size", 1080, 2520, 2520, 1080, 270, 2520, 1080);

    // QPA_HWC_SCREENCAP_LANDSCAPE_ROTATION=90
    check("landscape rotation 90", 1080, 2520, 1280, 720, QRect(), 90,
          90, QRect(0, 86, 1280, 548));

    // Content rects: symmetric, then flush with the top.
    check("content rect 0,60,1280,600", 1080, 2520, 1280, 720, QRect(0, 60, 1280, 600), 270,
          270, QRect(0, 86, 1280, 548));
    check("content rect 0,0,1280,600", 1080, 2520, 1280, 720, QRect(0, 0, 1280, 600), 270,
          270, QRect(0, 26, 1280, 548));
    // An odd rect: sizes round down to even, inside the rect.
    check("content rect 0,0,1279,719", 1080, 2520, 1280, 720, QRect(0, 0, 1279, 719), 270,
          270, QRect(0, 85, 1278, 548));

    // A square panel never turns.
    checkCentred("square panel", 1080, 1080, 1280, 720, 0, 720, 720);
    // Upscaling
    checkCentred("upscale", 720, 1600, 1920, 1080, 270, 1920, 864);
    // A landscape panel turns for a portrait session.
    checkCentred("landscape panel, portrait session", 2520, 1080, 1080, 2520, 270, 1080, 2520);
    checkCentred("landscape panel, landscape session", 2520, 1080, 1280, 720, 0, 1280, 548);

    printf("%s: %d failed\n", failures ? "FAIL" : "PASS", failures);
    return failures ? 1 : 0;
}
